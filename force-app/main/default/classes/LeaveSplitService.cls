/*
 * LEAVE-33 — splitting a request that runs past the balance.
 *
 * Replaces the LWOP fields and the two-stage approval gate that preceded it. Instead of
 * one record carrying "20 days, 12 of them unpaid" across six extra fields, the request
 * becomes two ordinary records:
 *
 *     Annual leave  7-16 Sep   8 days   -> the Annual balance
 *     Unpaid leave 17 Sep-2 Oct 12 days -> the Unpaid leave balance
 *
 * Everything after that is the engine that already existed. Both records count their
 * own days, deduct their own balance, book their own Man_hour__c and go through their
 * own approval. There is no gate to enforce and no bespoke unpaid arithmetic, because
 * unpaid leave is now just a leave type like any other.
 *
 * The split runs on INSERT, not on approval. The employee finds out what will and will
 * not be paid at the moment they save, rather than discovering it after someone signs
 * — and the Managing Director receives a plain Unpaid leave request to approve rather
 * than a checkbox buried on somebody else's record.
 *
 * Balance is consumed in date order, so the paid days are the EARLY ones and the unpaid
 * remainder is the tail. A part day at the boundary goes to the unpaid side: with 2.5
 * days left and 5 requested, 2 are paid and 3 unpaid, and the half day stays in the
 * balance rather than being silently rounded away.
 */
public without sharing class LeaveSplitService {

    @TestVisible private static final String TYPE_UNPAID = 'Unpaid leave';

    /*
     * Records this run has already split, or created by splitting. Shortening the
     * original is a DML on the same object from its own trigger, so without this the
     * update re-enters and reconsiders a record that is now, by construction, exactly
     * within its balance.
     */
    @TestVisible private static Set<Id> handled = new Set<Id>();

    /**
     * Splits any newly created leave request whose days run past the balance.
     * Runs after insert, because the unpaid record has to point back at a saved parent.
     */
    public static void splitOverBalance(List<ApplicationItem__c> newRecords) {
        List<ApplicationItem__c> candidates = new List<ApplicationItem__c>();
        Set<String> keys = new Set<String>();

        for (ApplicationItem__c appl : newRecords) {
            if (!isSplittable(appl)) {
                continue;
            }
            candidates.add(appl);
            keys.add(ApplicationItemTriggerLogic.balanceKey(
                appl.OwnerId, appl.Request_Type__c, appl.Term_From__c.year()));
        }
        if (candidates.isEmpty()) {
            return;
        }

        Map<String, Decimal> availableByKey = new Map<String, Decimal>();
        for (Leave_Balance__c bal : [
            SELECT External_Key__c, Accrued_Days__c, Carry_Over_Days__c, Used_Days__c
            FROM Leave_Balance__c
            WHERE External_Key__c IN :keys
        ]) {
            availableByKey.put(bal.External_Key__c,
                zeroIfNull(bal.Accrued_Days__c) + zeroIfNull(bal.Carry_Over_Days__c)
                    - zeroIfNull(bal.Used_Days__c));
        }

        Set<Date> holidays = ApplicationItemTriggerLogic.holidaysForBatch(candidates);
        List<ApplicationItem__c> toShorten = new List<ApplicationItem__c>();
        List<ApplicationItem__c> unpaidRecords = new List<ApplicationItem__c>();
        List<ApplicationItem__c> toConvert = new List<ApplicationItem__c>();

        for (ApplicationItem__c appl : candidates) {
            Decimal available = availableByKey.get(ApplicationItemTriggerLogic.balanceKey(
                appl.OwnerId, appl.Request_Type__c, appl.Term_From__c.year()));

            // No balance row is a data problem, reported precisely by deductLeaveBalance
            // at approval. Splitting on a guess would hide it behind a plausible record.
            if (available == null) {
                continue;
            }

            Decimal requested = zeroIfNull(appl.Leave_Days__c);
            if (requested <= available) {
                continue; // affordable in full
            }

            // Whole days only: a part day at the boundary belongs to the unpaid side.
            Integer paidDays = available <= 0 ? 0 : (Integer) available.round(System.RoundingMode.DOWN);

            if (paidDays == 0) {
                /*
                 * Nothing is affordable, so there is no paid half to keep. Creating an
                 * empty record beside a full unpaid one helps nobody; the request itself
                 * becomes the unpaid one, and the employee still gets exactly the days
                 * they asked for on exactly the dates they asked for.
                 */
                toConvert.add(new ApplicationItem__c(Id = appl.Id, Request_Type__c = TYPE_UNPAID));
                handled.add(appl.Id);
                continue;
            }

            List<Date> workingDays = ApplicationItemTriggerLogic.workingDaysFor(appl, holidays);
            if (workingDays.size() <= paidDays) {
                continue; // nothing left over once whole days are counted
            }

            toShorten.add(new ApplicationItem__c(
                Id = appl.Id, Term_To__c = workingDays[paidDays - 1]));
            unpaidRecords.add(unpaidContinuation(appl, workingDays[paidDays]));
            handled.add(appl.Id);
        }

        if (!toConvert.isEmpty()) {
            update toConvert;
        }
        if (!toShorten.isEmpty()) {
            update toShorten;
        }
        if (!unpaidRecords.isEmpty()) {
            insert unpaidRecords;
        }
    }

    /*
     * The tail of the original, as its own request. Mirrors the parent's status so a
     * draft splits into two drafts and a submitted request into two submitted ones,
     * and both travel through approval together.
     */
    private static ApplicationItem__c unpaidContinuation(ApplicationItem__c parent, Date startFrom) {
        return new ApplicationItem__c(
            RecordTypeId    = parent.RecordTypeId,
            Request_Type__c = TYPE_UNPAID,
            Period_Leave__c = 'All day',
            Term_From__c    = startFrom,
            Term_To__c      = parent.Term_To__c,
            Remark__c       = continuationRemark(parent),
            Status__c       = parent.Status__c,
            OwnerId         = parent.OwnerId,
            Split_From__c   = parent.Id
        );
    }

    private static String continuationRemark(ApplicationItem__c parent) {
        String suffix = ' [unpaid continuation of ' + parent.Request_Type__c + ']';
        String base = parent.Remark__c == null ? '' : parent.Remark__c;
        Integer room = 255 - suffix.length();
        return (base.length() > room ? base.substring(0, room) : base) + suffix;
    }

    private static Boolean isSplittable(ApplicationItem__c appl) {
        if (handled.contains(appl.Id)) {
            return false;
        }
        // The unpaid half of an earlier split, which by definition cannot split again.
        if (appl.Split_From__c != null) {
            return false;
        }
        if (appl.Term_From__c == null || zeroIfNull(appl.Leave_Days__c) <= 0) {
            return false;
        }
        if (ApplicationItemTriggerHandler.isOvertimeRequest(appl)) {
            return false;
        }
        Leave_Type_Policy__mdt policy = ApplicationItemTriggerLogic.policyFor(appl.Request_Type__c);
        return policy != null && policy.Counts_Toward_LWOP_Check__c == true;
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}
