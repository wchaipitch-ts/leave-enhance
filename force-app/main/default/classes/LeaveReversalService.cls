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

    private static final String TYPE_UNPAID = 'Unpaid leave';

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
        List<ApplicationItem__c> tails = [
            SELECT Id, Request_Type__c, Status__c, Term_From__c, Term_To__c, OwnerId,
                   Split_From__c, Split_From__r.Request_Type__c, RecordTypeId, Leave_Days__c
            FROM ApplicationItem__c
            WHERE Split_From__c IN :rejectedParentIds
              AND Request_Type__c = :TYPE_UNPAID
              AND Status__c NOT IN ('Approved', 'Rejected')
        ];
        if (tails.isEmpty()) {
            return;
        }

        List<ApplicationItem__c> promoted = new List<ApplicationItem__c>();
        for (ApplicationItem__c tail : tails) {
            String originalType = tail.Split_From__r.Request_Type__c;
            // The parent may itself have been converted to Unpaid leave when nothing
            // was affordable. Promoting to Unpaid leave would be a no-op.
            if (String.isBlank(originalType) || TYPE_UNPAID.equals(originalType)) {
                continue;
            }
            tail.Request_Type__c = originalType;
            promoted.add(tail);
        }
        if (promoted.isEmpty()) {
            return;
        }

        update promoted;

        // Re-measured against the balance the rejection just freed. Anything still
        // beyond it splits back out as a fresh unpaid tail.
        LeaveSplitService.reevaluate([
            SELECT Id, OwnerId, Request_Type__c, Status__c, Term_From__c, Term_To__c,
                   Leave_Days__c, Split_From__c, RecordTypeId, Remark__c
            FROM ApplicationItem__c WHERE Id IN :promoted
        ]);
    }

    private static Decimal floorAtZero(Decimal value) {
        return value < 0 ? 0 : value;
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}