/*
 *  — undoing an approval.
 *
 * Until now nothing ran when a request left the Approved state. Rejecting or deleting
 * an approved request left the balance spent, the calendar entries standing and the
 * timesheet booked, for an absence nobody was taking. After  it also left the
 * unpaid half of a split queued for approval on its own.
 *
 * Three things have to come back:
 *
 *   the balance   restoreBalances, in the before context, so the give-back and the
 *                 cleared stamp land on the same save
 *   the bookings  clearBookings, in the after context — deleting Events earlier would
 *                 trip EventTriggerLogic, which refuses while the request still reads
 *                 Approved. By the after context it reads Rejected and the guard passes
 *   the tail      promoteUnpaidSiblings, because a refused paid half frees the balance
 *                 the unpaid half was denied
 *
 * What is given back is Balance_Applied_Days__c, not Leave_Days__c. The day count is
 * rewritten on every save and can be edited after approval; the applied figure is what
 * was actually taken, so it is the only safe thing to return.
 */
public without sharing class LeaveReversalService {

    /*
     * Man_hour__c ids captured while the request still exists. On delete the lookup to
     * the parent is set to null as part of the delete, so by the after context there is
     * nothing left to match on — they have to be collected in the before context and
     * removed in the after one.
     */
    @TestVisible private static Set<Id> manHoursPendingDelete = new Set<Id>();

    /**
     * Gives back exactly what each request took. Runs in the before context on records
     * leaving Approved, so clearing the stamp needs no second DML.
     */
    public static void restoreBalances(List<ApplicationItem__c> leavingApproved) {
        if (leavingApproved.isEmpty()) {
            return;
        }
        Map<Id, Decimal> giveBackByBalance = new Map<Id, Decimal>();

        for (ApplicationItem__c appl : leavingApproved) {
            Decimal applied = zeroIfNull(appl.Balance_Applied_Days__c);
            if (applied > 0 && appl.Leave_Balance__c != null) {
                giveBackByBalance.put(appl.Leave_Balance__c,
                    zeroIfNull(giveBackByBalance.get(appl.Leave_Balance__c)) + applied);
            }
            // Cleared whether or not a balance was found, so a record can never be
            // reversed twice off the same stamp.
            appl.Balance_Applied_Days__c = null;
            appl.Carry_Over_Days_Used__c = 0;
            appl.Leave_Balance__c = null;
        }
        if (giveBackByBalance.isEmpty()) {
            return;
        }

        List<Leave_Balance__c> toUpdate = new List<Leave_Balance__c>();
        for (Leave_Balance__c bal : [
            SELECT Id, Leave_Type__c, Entitlement_Days__c, Used_Days__c
            FROM Leave_Balance__c WHERE Id IN :giveBackByBalance.keySet()
            FOR UPDATE
        ]) {
            Decimal giveBack = giveBackByBalance.get(bal.Id);
            bal.Used_Days__c = floorAtZero(zeroIfNull(bal.Used_Days__c) - giveBack);

            /*
             * A Grants_On_Use__c type has its entitlement granted as it is used, so the
             * give-back has to unwind both sides. Leaving the entitlement up would turn
             * the row into a pile of free days the employee could then spend — and
             * because Accrued_Days__c is a formula over the entitlement, the balance page
             * would show them as accrued and available.
             *
             * Read from the policy rather than from a hardcoded Unpaid leave check, so
             * this cannot drift from the grant in ApplicationItemTriggerLogic: whatever
             * grants on use unwinds on use.
             */
            Leave_Type_Policy__mdt policy = ApplicationItemTriggerLogic.policyFor(bal.Leave_Type__c);
            if (policy != null && policy.Grants_On_Use__c == true) {
                bal.Entitlement_Days__c = floorAtZero(zeroIfNull(bal.Entitlement_Days__c) - giveBack);
            }
            toUpdate.add(bal);
        }
        update toUpdate;
    }

    /** Same arithmetic for a deleted request, which has no in-flight record to clear. */
    public static void restoreBalancesForDeleted(List<ApplicationItem__c> deleted) {
        List<ApplicationItem__c> copies = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : deleted) {
            copies.add(new ApplicationItem__c(
                Balance_Applied_Days__c = appl.Balance_Applied_Days__c,
                Leave_Balance__c = appl.Leave_Balance__c
            ));
        }
        restoreBalances(copies);
    }

    /**
     * Removes the calendar entries and timesheet bookings the approval created.
     *
     * Man hours are matched on their lookup to the request, never on date and remark.
     * Guessing would risk deleting a row somebody entered by hand on the same day —
     * rows booked before that lookup existed are left alone for the same reason.
     */
    public static void clearBookings(Set<Id> applIds) {
        if (applIds.isEmpty() && manHoursPendingDelete.isEmpty()) {
            return;
        }
        if (!applIds.isEmpty()) {
            delete [SELECT Id FROM Event WHERE WhatId IN :applIds];
            delete [SELECT Id FROM Man_hour__c WHERE Application_Item__c IN :applIds];
        }
        if (!manHoursPendingDelete.isEmpty()) {
            delete [SELECT Id FROM Man_hour__c WHERE Id IN :manHoursPendingDelete];
            manHoursPendingDelete.clear();
        }
    }

    /** Called in the before-delete context, while the lookup still points somewhere. */
    public static void rememberBookingsOf(List<ApplicationItem__c> aboutToBeDeleted) {
        Set<Id> ids = new Map<Id, ApplicationItem__c>(aboutToBeDeleted).keySet();
        for (Man_hour__c mh : [SELECT Id FROM Man_hour__c WHERE Application_Item__c IN :ids]) {
            manHoursPendingDelete.add(mh.Id);
        }
    }

    /**
     *  / G2. A refused paid half frees the balance its unpaid tail was denied,
     * so the tail is turned back into the type the employee originally asked for and
     * re-measured against the balance. Whatever still does not fit splits out again.
     *
     * Only tails that have not been approved are promoted. Once unpaid days have been
     * approved they have been taken, and turning them into paid days after the fact is
     * a payroll correction somebody should make deliberately — not something a trigger
     * should do quietly on a status change.
     */
    public static void promoteUnpaidSiblings(Set<Id> rejectedParentIds) {
        if (rejectedParentIds.isEmpty()) {
            return;
        }
        List<ApplicationItem__c> siblings = [
            SELECT Id, Request_Type__c, Status__c, Term_From__c, Term_To__c, OwnerId,
                   Split_From__c, Split_From__r.Request_Type__c, RecordTypeId, Leave_Days__c
            FROM ApplicationItem__c
            WHERE Split_From__c IN :rejectedParentIds
              AND Status__c NOT IN ('Approved', 'Rejected')
            ORDER BY Split_From__c, Term_From__c
        ];
        if (siblings.isEmpty()) {
            return;
        }

        Map<Id, List<ApplicationItem__c>> byParent = new Map<Id, List<ApplicationItem__c>>();
        for (ApplicationItem__c sib : siblings) {
            if (!byParent.containsKey(sib.Split_From__c)) {
                byParent.put(sib.Split_From__c, new List<ApplicationItem__c>());
            }
            byParent.get(sib.Split_From__c).add(sib);
        }

        List<ApplicationItem__c> keep = new List<ApplicationItem__c>();
        List<ApplicationItem__c> discard = new List<ApplicationItem__c>();

        for (List<ApplicationItem__c> family : byParent.values()) {
            String originalType = family[0].Split_From__r.Request_Type__c;
            /*
             * The parent may itself have been rewritten to a later type in the chain
             * when nothing above it was affordable. Promoting to what the record already
             * is would be a no-op, and with a single survivor there is nothing to merge
             * either, so the family is left as it stands.
             */
            if (String.isBlank(originalType)
                || (family.size() == 1 && originalType.equals(family[0].Request_Type__c))) {
                continue;
            }

            /*
             * The survivors are merged onto the earliest of them, which takes the type
             * the employee originally asked for and the whole span the family covered.
             * The walk then divides it again from the top of the chain.
             *
             * Moving each record up one place instead would be wrong as often as it was
             * right: with Refresh -> Annual -> Unpaid, how far the Annual and Unpaid
             * stretches shift depends on how many refresh days the rejection freed, not
             * on their position. Rebuilding asks the question once and gets every shape.
             */
            ApplicationItem__c head = family[0];
            Date furthest = endOf(head);
            for (Integer i = 1; i < family.size(); i++) {
                Date candidate = endOf(family[i]);
                if (candidate > furthest) {
                    furthest = candidate;
                }
                discard.add(family[i]);
            }
            head.Request_Type__c = originalType;
            head.Term_To__c = furthest;
            keep.add(head);
        }

        // Re-measured against the balance the rejection just freed. Anything still
        // beyond it splits back out down the chain as before.
        LeaveSplitService.rebuildFrom(keep, discard);
    }

    private static Date endOf(ApplicationItem__c appl) {
        return appl.Term_To__c == null ? appl.Term_From__c : appl.Term_To__c;
    }

    private static Decimal floorAtZero(Decimal value) {
        return value < 0 ? 0 : value;
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}