/*
 * LEAVE-30 — Leave Without Pay.
 *
 * When a request asks for more days than the balance holds, the shortfall does not
 * block the request and does not silently overdraw the balance. It becomes unpaid
 * days, which the Managing Director signs off separately from the ordinary leave
 * approval. The request keeps its original leave type: an employee with 2 days left
 * who takes 5 days of annual leave has taken annual leave, 3 days of it unpaid, and
 * payroll needs to see it that way. Rewriting Request_Type__c to "Unpaid leave"
 * would throw away both the reason for the absence and the 2 paid days they had.
 *
 * Two passes, because a preview and a deduction need different guarantees:
 *
 *   assess()  runs on every save, whatever the status. It is a forecast, measured
 *             against the balance as committed right now, so the employee and the
 *             approver can see the unpaid portion long before anyone approves.
 *             Deliberately does NOT reserve anything: other requests sitting in
 *             Pending are not counted, because most of them are not yet real.
 *
 *   settle()  runs at approval only, inside the FOR UPDATE lock taken by
 *             deductLeaveBalance, and against the running in-transaction figure.
 *             This is the authority. Whatever assess() forecast, the split written
 *             here is the one the balance is moved by.
 *
 * The gap between the two is the point. Two requests can each look fully paid while
 * the balance covers only one of them; whichever is approved second finds the money
 * gone and is stopped at approval with a message saying so, rather than quietly
 * pushing the balance negative.
 */
public class LeaveWithoutPayService {

    @TestVisible private static final String STATUS_NOT_REQUIRED = 'Not Required';
    @TestVisible private static final String STATUS_PENDING      = 'Pending MD Approval';
    @TestVisible private static final String STATUS_APPROVED     = 'Approved';
    @TestVisible private static final String STATUS_REJECTED     = 'Rejected';

    /*
     * Forecast pass. Sets LWOP_Days__c and moves LWOP_Status__c into or out of
     * Pending MD Approval so the request carries its own answer to "does this need
     * Yuta-san?" from the moment it is saved.
     */
    public static void assess(List<ApplicationItem__c> requests, Map<Id, ApplicationItem__c> oldMap) {
        if (requests.isEmpty()) {
            return;
        }

        List<ApplicationItem__c> eligible = new List<ApplicationItem__c>();
        Set<String> keys = new Set<String>();

        for (ApplicationItem__c appl : requests) {
            /*
             * Once the balance has been moved, the split on the record is history and
             * must not be recomputed. Re-running the forecast here would measure the
             * request against a balance its own deduction had already reduced, find
             * the shortfall it just created, and send an approved request back to the
             * Managing Director for days that were in fact paid.
             */
            if (alreadySettled(appl, oldMap)) {
                continue;
            }
            if (!countsTowardLwop(appl)) {
                // Covers a request whose type was changed to one that cannot go unpaid.
                // Leaving a stale Pending MD Approval on it would park it in front of
                // the Managing Director forever.
                clear(appl, oldMap);
                continue;
            }
            eligible.add(appl);
            keys.add(ApplicationItemTriggerLogic.balanceKey(
                appl.OwnerId, appl.Request_Type__c, appl.Term_From__c.year()));
        }
        if (eligible.isEmpty()) {
            return;
        }

        Map<String, Decimal> availableByKey = new Map<String, Decimal>();
        for (Leave_Balance__c bal : [
            SELECT External_Key__c, Accrued_Days__c, Carry_Over_Days__c, Used_Days__c
            FROM Leave_Balance__c
            WHERE External_Key__c IN :keys
        ]) {
            availableByKey.put(bal.External_Key__c, availableOn(bal));
        }

        for (ApplicationItem__c appl : eligible) {
            Decimal available = availableByKey.get(ApplicationItemTriggerLogic.balanceKey(
                appl.OwnerId, appl.Request_Type__c, appl.Term_From__c.year()));

            /*
             * No balance row. Not this method's job to report: deductLeaveBalance
             * already fails the approval with a precise message. Forecasting "every
             * day unpaid" here would dress a missing-data problem up as a plausible
             * number and send the request to the Managing Director instead.
             */
            if (available == null) {
                continue;
            }

            applyShortfall(appl, oldMap, shortfall(zeroIfNull(appl.Leave_Days__c), available));
        }
    }

    /*
     * Authoritative pass, called per record from deductLeaveBalance with the balance
     * left after everything already deducted in this transaction.
     *
     * Returns the number of days to deduct, or null when the request must not be
     * approved — in which case the error is already on the record.
     */
    public static Decimal settle(ApplicationItem__c appl, Decimal available) {
        Decimal days = zeroIfNull(appl.Leave_Days__c);

        // Types outside the LWOP check keep the pre-LEAVE-30 behaviour exactly:
        // the full request is deducted, and overdrawing is still possible.
        if (!countsTowardLwop(appl)) {
            return days;
        }

        Decimal lwopDays = shortfall(days, available);
        appl.LWOP_Days__c = lwopDays;

        if (lwopDays <= 0) {
            return days;
        }

        if (!STATUS_APPROVED.equals(appl.LWOP_Status__c)) {
            appl.addError(appl.Request_Type__c + ': ' + format(days) + ' day(s) requested but only '
                + format(available < 0 ? 0 : available) + ' day(s) available. The remaining '
                + format(lwopDays) + ' day(s) would be unpaid, so the Managing Director must '
                + 'approve the Leave Without Pay before this request can be approved.');
            return null;
        }

        /*
         * The approval was for a specific number of unpaid days. If the request has
         * since grown — a longer date range, or another request approved first eating
         * the balance this one was counting on — that signature no longer covers it.
         */
        if (lwopDays > zeroIfNull(appl.LWOP_Approved_Days__c)) {
            appl.addError(appl.Request_Type__c + ': the unpaid portion is now ' + format(lwopDays)
                + ' day(s), but the Managing Director approved only '
                + format(zeroIfNull(appl.LWOP_Approved_Days__c)) + ' day(s). '
                + 'The Leave Without Pay must be approved again for the new amount.');
            return null;
        }

        return days - lwopDays;
    }

    /*
     * Records who signed off and for how much, from the running user rather than
     * anything on the record, so LWOP Approved By can only ever name the person who
     * actually performed the approval. Moving the status anywhere other than Approved
     * clears the stamp, which is what stops a rejected request from still carrying a
     * previous approver's name.
     *
     * Who is allowed to make this change is enforced by the
     * Leave_Request_LWOP_Approval_Permission validation rule.
     */
    public static void stampApproval(List<ApplicationItem__c> requests, Map<Id, ApplicationItem__c> oldMap) {
        for (ApplicationItem__c appl : requests) {
            if (!statusBeingChangedNow(appl, oldMap)) {
                continue;
            }
            if (STATUS_APPROVED.equals(appl.LWOP_Status__c)) {
                appl.LWOP_Approved_By__c   = UserInfo.getUserId();
                appl.LWOP_Approved_On__c   = System.now();
                appl.LWOP_Approved_Days__c = zeroIfNull(appl.LWOP_Days__c);
            } else {
                appl.LWOP_Approved_By__c   = null;
                appl.LWOP_Approved_On__c   = null;
                appl.LWOP_Approved_Days__c = null;
            }
        }
    }

    // ------------------------------------------------------------------ internals

    private static void applyShortfall(ApplicationItem__c appl,
                                       Map<Id, ApplicationItem__c> oldMap,
                                       Decimal lwopDays) {
        if (lwopDays <= 0) {
            clear(appl, oldMap);
            return;
        }
        appl.LWOP_Days__c = lwopDays;

        // The Managing Director is acting on this record in this very save. Their
        // decision wins over anything forecast here.
        if (statusBeingChangedNow(appl, oldMap)) {
            return;
        }
        if (STATUS_REJECTED.equals(appl.LWOP_Status__c)) {
            return; // already refused; shortening the request is the way out
        }
        if (STATUS_APPROVED.equals(appl.LWOP_Status__c)
                && lwopDays <= zeroIfNull(appl.LWOP_Approved_Days__c)) {
            return; // still within what was signed off
        }
        if (STATUS_APPROVED.equals(appl.LWOP_Status__c)) {
            appl.LWOP_Approved_By__c   = null;
            appl.LWOP_Approved_On__c   = null;
            appl.LWOP_Approved_Days__c = null;
        }
        appl.LWOP_Status__c = STATUS_PENDING;
    }

    private static void clear(ApplicationItem__c appl, Map<Id, ApplicationItem__c> oldMap) {
        appl.LWOP_Days__c = 0;
        if (statusBeingChangedNow(appl, oldMap)) {
            return;
        }
        appl.LWOP_Status__c        = STATUS_NOT_REQUIRED;
        appl.LWOP_Approved_By__c   = null;
        appl.LWOP_Approved_On__c   = null;
        appl.LWOP_Approved_Days__c = null;
    }

    /*
     * True for a record that was already Approved before this save and still is —
     * meaning deductLeaveBalance moved its balance in an earlier transaction. It is
     * not enough to test the new value alone: a request crossing INTO Approved right
     * now has not been settled yet and does still need assessing.
     */
    private static Boolean alreadySettled(ApplicationItem__c appl, Map<Id, ApplicationItem__c> oldMap) {
        if (oldMap == null) {
            return false;
        }
        ApplicationItem__c prior = oldMap.get(appl.Id);
        return prior != null
            && 'Approved'.equals(prior.Status__c)
            && 'Approved'.equals(appl.Status__c);
    }

    private static Boolean statusBeingChangedNow(ApplicationItem__c appl,
                                                 Map<Id, ApplicationItem__c> oldMap) {
        if (oldMap == null) {
            // On insert there is nothing to compare against, so anything other than
            // the default counts as a deliberate choice by whoever created the record.
            return appl.LWOP_Status__c != null && !STATUS_NOT_REQUIRED.equals(appl.LWOP_Status__c);
        }
        ApplicationItem__c prior = oldMap.get(appl.Id);
        return prior != null && prior.LWOP_Status__c != appl.LWOP_Status__c;
    }

    private static Boolean countsTowardLwop(ApplicationItem__c appl) {
        if (appl.Term_From__c == null) {
            return false;
        }
        Leave_Type_Policy__mdt policy = ApplicationItemTriggerLogic.policyFor(appl.Request_Type__c);
        return policy != null && policy.Counts_Toward_LWOP_Check__c == true;
    }

    /** Mirrors the Available_Days__c formula, in Apex so it can be run mid-transaction. */
    private static Decimal availableOn(Leave_Balance__c bal) {
        return zeroIfNull(bal.Accrued_Days__c)
             + zeroIfNull(bal.Carry_Over_Days__c)
             - zeroIfNull(bal.Used_Days__c);
    }

    private static Decimal shortfall(Decimal days, Decimal available) {
        Decimal usable = available < 0 ? 0 : available;
        Decimal unpaid = days - usable;
        return unpaid < 0 ? 0 : unpaid;
    }

    /** Trims the trailing zero so a whole day reads "3" and a half day reads "0.5". */
    private static String format(Decimal value) {
        return value == value.round(System.RoundingMode.DOWN)
            ? String.valueOf(value.setScale(0))
            : String.valueOf(value.setScale(1));
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}
