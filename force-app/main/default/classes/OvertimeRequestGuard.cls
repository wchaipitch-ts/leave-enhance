/*
 * LEAVE-43 — who an Overtime Request belongs to.
 *
 * Overtime is entered by a manager on somebody else's behalf, which makes it the one
 * request type where the person who saves the record is not the person it is about.
 * OwnerId defaults to whoever clicked Save, and OwnerId is the only attribution
 * ApplicationItem__c has - so before this class the hours landed on the manager's
 * overtime summary, the manager's OT tab, a Man_hour__c against the manager, and
 * Owner_Name__c - labelled "Requester Name" - read the manager. Nothing errored.
 *
 * The fix copies Employee__c into OwnerId rather than teaching every reader about a new
 * field. OvertimeSummaryService, TimesheetController.getApplicationItems, the Man_hour__c
 * booking and Owner_Name__c all key on OwnerId already and are left untouched, which also
 * keeps this change clear of the leave screens somebody else owns.
 *
 * WHEN THE HANDOVER HAPPENS: on approval, not at creation.
 *
 * The manager keeps the record while they are still working on it, which is what makes it
 * editable at all - ApplicationItem__c is Public Read Only, so transferring at insert left
 * the manager unable to correct their own typo a second after saving it. It also puts the
 * right person in the approval chain: allowedSubmitters is the owner, and the approver is
 * the owner's hierarchy Manager, so a manager claiming overtime for their report sends it
 * to their own boss rather than to themselves.
 *
 * Nothing downstream minds the delay. OvertimeSummaryService counts only Approved records,
 * and createLeaveRecordQueueable re-queries after the transaction commits - both therefore
 * read the owner this class has already moved.
 */
public without sharing class OvertimeRequestGuard {

    private static final String PERMISSION = 'Create_Overtime_Request';
    private static final String STATUS_APPROVED = 'Approved';

    // Test hook. FeatureManagement reads the running user's assignments, and granting a
    // permission set to yourself mid-transaction needs System.runAs gymnastics that
    // obscure what is actually being tested.
    @TestVisible private static Boolean permittedOverride;

    /** True when the running user may raise overtime for somebody else. */
    public static Boolean permitted() {
        if (permittedOverride != null) {
            return permittedOverride;
        }
        return FeatureManagement.checkPermission(PERMISSION);
    }

    /*
     * Runs in the before contexts over overtime records only - the handler has already
     * split the batch by record type, so a leave request never reaches here and never
     * needs the permission.
     */
    public static void enforce(List<ApplicationItem__c> overtime, Map<Id, ApplicationItem__c> oldMap) {
        if (overtime.isEmpty()) {
            return;
        }
        List<ApplicationItem__c> allowed = refuseUnpermittedCreation(overtime, oldMap);
        transferOwnershipOnApproval(allowed, oldMap);
    }

    /*
     * Record type visibility keeps the New button honest, but it governs the UI alone -
     * Apex and the API can set RecordTypeId directly. This is the check that actually
     * holds, which is why the restriction is a custom permission rather than a profile
     * name: a cloned profile would quietly slip past the latter.
     *
     * An update counts only when the record is crossing INTO the overtime record type.
     * Otherwise every later edit of an existing overtime request would demand the
     * creation permission, and the employee it belongs to does not have it.
     */
    private static List<ApplicationItem__c> refuseUnpermittedCreation(
            List<ApplicationItem__c> overtime, Map<Id, ApplicationItem__c> oldMap) {

        if (permitted()) {
            return overtime;
        }

        List<ApplicationItem__c> untouched = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : overtime) {
            Boolean becomingOvertime = oldMap == null
                || (oldMap.get(appl.Id) != null && oldMap.get(appl.Id).RecordTypeId != appl.RecordTypeId);
            if (becomingOvertime) {
                appl.addError('Overtime requests are raised by managers on an employee\'s behalf. '
                    + 'Ask an administrator for the Overtime Request Manager permission set if you '
                    + 'need to record overtime for your team.');
            } else {
                untouched.add(appl);
            }
        }
        return untouched;
    }

    /*
     * Ownership moves to the employee as the request crosses into Approved, and only then.
     *
     * Only a transition counts: re-saving a record that is already Approved must not move
     * anything, and a record inserted straight into Approved has no prior state so it
     * transfers immediately. Blank Employee__c is left alone and reported by
     * Overtime_Employee_Required, which puts the message on the field.
     */
    private static void transferOwnershipOnApproval(List<ApplicationItem__c> overtime,
                                                    Map<Id, ApplicationItem__c> oldMap) {
        List<ApplicationItem__c> approving = new List<ApplicationItem__c>();
        Set<Id> employeeIds = new Set<Id>();

        for (ApplicationItem__c appl : overtime) {
            if (!STATUS_APPROVED.equals(appl.Status__c) || appl.Employee__c == null) {
                continue;
            }
            if (oldMap != null) {
                ApplicationItem__c prior = oldMap.get(appl.Id);
                if (prior == null || STATUS_APPROVED.equals(prior.Status__c)) {
                    continue;
                }
            }
            if (appl.OwnerId == appl.Employee__c) {
                continue; // already theirs, nothing to move
            }
            approving.add(appl);
            employeeIds.add(appl.Employee__c);
        }
        if (approving.isEmpty()) {
            return;
        }

        /*
         * Checked at the moment of transfer rather than at creation, because someone can
         * leave between the two. Salesforce refuses to make an inactive user a record owner
         * and names neither the field nor the person when it does, so the approver is told
         * who the problem is instead of being handed a bare failure.
         */
        Map<Id, User> employees = new Map<Id, User>([
            SELECT Id, Name, IsActive FROM User WHERE Id IN :employeeIds
        ]);

        for (ApplicationItem__c appl : approving) {
            User employee = employees.get(appl.Employee__c);
            if (employee == null || employee.IsActive != true) {
                appl.addError(nameOf(employee)
                    + ' is not an active user, so this overtime cannot be handed over to them '
                    + 'on approval. Reassign it to an active employee first.');
                continue;
            }
            appl.OwnerId = appl.Employee__c;
        }
    }

    private static String nameOf(User employee) {
        return employee == null ? 'That employee' : employee.Name;
    }
}