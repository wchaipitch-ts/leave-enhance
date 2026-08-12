public class ApplicationItemTriggerLogic {

    private static final Integer WORKDAY_START_HOUR = 8;
    private static final Integer WORKDAY_START_MIN  = 30;
    private static final Integer LUNCH_END_HOUR     = 13;
    private static final Integer MORNING_END_HOUR   = 12;
    private static final Integer WORKDAY_END_HOUR   = 17;

    private static final String AM_LEAVE  = 'AM leave';
    private static final String PM_LEAVE  = 'PM leave';

    // Request_Type__c values that move a balance. Note that Refresh Leave is the only
    // one with a capital L — the picklist is inconsistent and these must match exactly.
    private static final String TYPE_ANNUAL   = 'Annual leave';
    private static final String TYPE_SICK     = 'Sick leave';
    private static final String TYPE_PERSONAL = 'Personal leave';
    private static final String TYPE_REFRESH  = 'Refresh Leave';

    // Recorded and approved like any other request, but deliberately touching no
    // balance: unpaid leave by definition, and the statutory types which carry their
    // own legal entitlements rather than drawing on a company allowance.
    private static final Set<String> NON_DEDUCTING_TYPES = new Set<String>{
        'Unpaid leave',
        'Bereavement leave',
        'Marriage leave',
        'Maternity leave',
        'Military service leave',
        'Ordination leave',
        'Sterilization leave',
        'Training or knowledge leave',
        'Other'
    };

    /*
     * LEAVE-11: Events are collected and inserted once. The insert used to sit
     * inside the loop, so 150 approvals in one transaction exhausted the DML
     * statement limit.
     *
     * Callers pass records that have just crossed into Approved; the status
     * transition is decided in ApplicationItemTriggerHandler.
     */
    public void setLeaveDateTime(List<ApplicationItem__c> approvedList) {
        List<Event> events = new List<Event>();

        for (ApplicationItem__c appl : approvedList) {
            if (appl.Term_From__c == null) {
                continue;
            }
            Date d = appl.Term_From__c;

            Datetime startDateTime = (PM_LEAVE == appl.Period_Leave__c)
                ? DateTime.newInstance(d.year(), d.month(), d.day(), LUNCH_END_HOUR, 0, 0)
                : DateTime.newInstance(d.year(), d.month(), d.day(), WORKDAY_START_HOUR, WORKDAY_START_MIN, 0);

            Datetime endDateTime = (AM_LEAVE == appl.Period_Leave__c)
                ? DateTime.newInstance(d.year(), d.month(), d.day(), MORNING_END_HOUR, 0, 0)
                : DateTime.newInstance(d.year(), d.month(), d.day(), WORKDAY_END_HOUR, 0, 0);

            events.add(new Event(
                WhatId        = appl.Id,
                Subject       = appl.Request_Type__c,
                OwnerId       = appl.OwnerId,
                StartDateTime = startDateTime,
                EndDateTime   = endDateTime,
                Description   = appl.Period_Leave__c
            ));
        }

        if (!events.isEmpty()) {
            insert events;
        }
    }

    /*
     * LEAVE-13 — balance deduction on approval. See spec §3.5.
     *
     * Runs from a BEFORE trigger on purpose. Carry_Over_Days_Used__c is set directly
     * on the in-flight record, so there is no DML on ApplicationItem__c, and therefore
     * no recursion guard and no interaction with the approval record lock.
     *
     * The User update cannot happen here: User is a setup object and ApplicationItem__c
     * is not, so writing both in one transaction throws MIXED_DML_OPERATION. That is not
     * theoretical — the Minus_Annual_Leave_Day flow did exactly this and failed on every
     * run. The balances therefore travel to an @future method as JSON.
     *
     * Balances are allowed to go negative. Blocking here would fail the whole approval
     * transaction; preventing over-spend belongs in a validation rule (LEAVE-4).
     */
    public void deductLeaveBalance(List<ApplicationItem__c> approvedList) {
        if (approvedList.isEmpty()) {
            return;
        }

        Set<Id> ownerIds = new Set<Id>();
        for (ApplicationItem__c appl : approvedList) {
            if (appl.OwnerId != null) {
                ownerIds.add(appl.OwnerId);
            }
        }
        if (ownerIds.isEmpty()) {
            return;
        }

        Map<Id, User> owners = new Map<Id, User>([
            SELECT Id, Annual_Leave_Day__c, Annual_Leave_Used__c, Carry_Over_Days__c,
                   Refresh_Leave_Days__c, Sick_Leave_Used__c, Personal_Leave_Used__c
            FROM User
            WHERE Id IN :ownerIds
        ]);

        // Users are mutated in place, so several requests approved together for the
        // same person accumulate rather than overwriting each other.
        Set<Id> touched = new Set<Id>();

        for (ApplicationItem__c appl : approvedList) {
            User owner = owners.get(appl.OwnerId);
            if (owner == null) {
                continue;
            }

            String type = appl.Request_Type__c;
            Decimal days = daysFor(appl.Period_Leave__c);
            appl.Carry_Over_Days_Used__c = 0;

            if (TYPE_ANNUAL.equals(type)) {
                // Carry over is consumed first: it expires on June 30, whereas the
                // current year's days run to the end of the year.
                Decimal carryAvailable = zeroIfNull(owner.Carry_Over_Days__c);
                Decimal fromCarry = days <= carryAvailable ? days : carryAvailable;

                owner.Carry_Over_Days__c  = carryAvailable - fromCarry;
                owner.Annual_Leave_Day__c = zeroIfNull(owner.Annual_Leave_Day__c) - (days - fromCarry);
                owner.Annual_Leave_Used__c = zeroIfNull(owner.Annual_Leave_Used__c) + days;

                appl.Carry_Over_Days_Used__c = fromCarry;

            } else if (TYPE_SICK.equals(type)) {
                owner.Sick_Leave_Used__c = zeroIfNull(owner.Sick_Leave_Used__c) + days;

            } else if (TYPE_PERSONAL.equals(type)) {
                owner.Personal_Leave_Used__c = zeroIfNull(owner.Personal_Leave_Used__c) + days;

            } else if (TYPE_REFRESH.equals(type)) {
                owner.Refresh_Leave_Days__c = zeroIfNull(owner.Refresh_Leave_Days__c) - days;

            } else if (NON_DEDUCTING_TYPES.contains(type)) {
                continue;

            } else {
                // Fail loudly rather than silently deducting from the wrong place or
                // nothing at all. A new picklist value must be classified here first.
                appl.addError('Leave type "' + type + '" has no balance rule. '
                    + 'Classify it in ApplicationItemTriggerLogic before this request can be approved.');
                continue;
            }

            touched.add(owner.Id);
        }

        if (touched.isEmpty()) {
            return;
        }

        List<User> balanceUpdates = new List<User>();
        for (Id ownerId : touched) {
            balanceUpdates.add(owners.get(ownerId));
        }
        applyBalances(JSON.serialize(balanceUpdates));
    }

    /*
     * Transaction 2 of the mixed DML split: User only.
     *
     * If this fails the request is already approved but the balance was never moved,
     * and nothing on the record says so. An Error_Log__c is the only trace, so it has
     * to be written even when the update throws.
     */
    @future
    private static void applyBalances(String serialisedUsers) {
        List<User> users = (List<User>) JSON.deserialize(serialisedUsers, List<User>.class);
        try {
            update users;
        } catch (Exception e) {
            System.debug('Leave balance update failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
            try {
                insert new Error_Log__c(Process_Type__c = 'Leave Balance Deduction');
            } catch (Exception logFailure) {
                System.debug('Could not record the balance failure: ' + logFailure.getMessage());
            }
        }
    }

    private static Decimal daysFor(String periodLeave) {
        return (AM_LEAVE == periodLeave || PM_LEAVE == periodLeave) ? 0.5 : 1.0;
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}