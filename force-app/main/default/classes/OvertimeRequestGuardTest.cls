/*
 * LEAVE-43 — an overtime request belongs to the employee, not to the manager who typed it.
 *
 * The running test user stands in for the manager throughout: they hold the permission
 * (through permittedOverride, since FeatureManagement reads real assignments) and they are
 * the one performing the DML, so OwnerId defaults to them.
 *
 * The handover happens on APPROVAL, not at creation - the manager needs to stay able to edit
 * the draft they just saved, and ApplicationItem__c is Public Read Only. Most of the cases
 * below are therefore about when ownership moves rather than whether it does.
 */
@isTest
private class OvertimeRequestGuardTest {

    private static Id cachedEmployeeId;
    private static Id cachedRetiredId;

    private static Id employeeId() {
        if (cachedEmployeeId == null) {
            cachedEmployeeId = [SELECT Id FROM User WHERE CompanyName = 'OTGUARD' AND IsActive = TRUE LIMIT 1].Id;
        }
        return cachedEmployeeId;
    }

    private static Id retiredEmployeeId() {
        if (cachedRetiredId == null) {
            cachedRetiredId = [SELECT Id FROM User WHERE CompanyName = 'OTGUARD' AND IsActive = FALSE LIMIT 1].Id;
        }
        return cachedRetiredId;
    }

    private static Id overtimeRecordTypeId() {
        return Schema.SObjectType.ApplicationItem__c
            .getRecordTypeInfosByDeveloperName().get('Overtime_Request').getRecordTypeId();
    }

    private static Id leaveRecordTypeId() {
        return Schema.SObjectType.ApplicationItem__c
            .getRecordTypeInfosByDeveloperName().get('Leave_Request').getRecordTypeId();
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String stem = 'otg' + DateTime.now().getTime();
        List<User> staff = new List<User>{
            buildUser(p.Id, stem + 'a', 'Worked', 'Overtime', 'otga', true),
            buildUser(p.Id, stem + 'b', 'Left', 'Company',  'otgb', false)
        };
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert staff;

            /*
             * Salesforce refuses to make somebody a record owner unless they can read the
             * object - TRANSFER_REQUIRES_READ. That is a real constraint on this feature, not
             * a test detail: an employee named on an overtime request must have at least Read
             * on ApplicationItem__c or the approval that hands it to them fails. Granted here
             * with the narrowest possible permission set so the handover under test is the
             * thing being exercised, rather than the platform refusing it for other reasons.
             */
            PermissionSet readOnly = new PermissionSet(
                Name = 'OTGuard_Read', Label = 'OT Guard Read');
            insert readOnly;
            insert new ObjectPermissions(
                ParentId = readOnly.Id, SobjectType = 'ApplicationItem__c',
                PermissionsRead = true, PermissionsCreate = false,
                PermissionsEdit = false, PermissionsDelete = false);
            insert new PermissionSetAssignment(
                AssigneeId = staff[0].Id, PermissionSetId = readOnly.Id);
        }
    }

    private static User buildUser(Id profileId, String stem, String first, String last,
                                  String alias, Boolean active) {
        return new User(
            FirstName = first, LastName = last,
            Email = stem + '@example.com', Username = stem + '@example.com.otguard',
            Alias = alias, CompanyName = 'OTGUARD', TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', ProfileId = profileId,
            LanguageLocaleKey = 'en_US', IsActive = active,
            Start_Date__c = Date.newInstance(2020, 1, 1)
        );
    }

    /*
     * Term_From__c is dated tomorrow so LeaveRequestCurrentDate_ValidationRule, which is not
     * scoped to a record type, does not demand a remark for a past date on top of everything
     * else being asserted. Remark__c is set anyway.
     */
    private static ApplicationItem__c overtime(Id employee) {
        return new ApplicationItem__c(
            RecordTypeId = overtimeRecordTypeId(),
            Employee__c  = employee,
            Term_From__c = System.today().addDays(1),
            OT_Start__c  = Time.newInstance(18, 0, 0, 0),
            OT_End__c    = Time.newInstance(21, 0, 0, 0),
            Remark__c    = 'guard test', Status__c = 'Draft'
        );
    }

    private static ApplicationItem__c reload(Id applId) {
        return [SELECT OwnerId, Employee__c, Overtime_Hours__c, RecordTypeId
                FROM ApplicationItem__c WHERE Id = :applId];
    }

    private static String errorFrom(DmlException e) {
        return e.getDmlMessage(0);
    }

    // --------------------------------------------------------------------- attribution

    @isTest
    static void theManagerKeepsTheRecordUntilItIsApproved() {
        OvertimeRequestGuard.permittedOverride = true;
        ApplicationItem__c a = overtime(employeeId());
        insert a;

        ApplicationItem__c saved = reload(a.Id);
        System.assertEquals(UserInfo.getUserId(), saved.OwnerId,
            'the manager keeps it while they are still working on it - ApplicationItem__c is '
            + 'Public Read Only, so handing it over now would lock them out of their own draft');
        System.assertEquals(employeeId(), saved.Employee__c,
            'but the record already says who it is for');
        System.assertEquals(3, saved.Overtime_Hours__c, 'and the hour count runs from Draft');
    }

    @isTest
    static void approvalHandsTheRecordToTheEmployee() {
        OvertimeRequestGuard.permittedOverride = true;
        ApplicationItem__c a = overtime(employeeId());
        insert a;

        Test.startTest();
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');
        Test.stopTest();

        System.assertEquals(employeeId(), reload(a.Id).OwnerId,
            'the hours were worked by the employee, so the approved record is theirs');
    }

    /*
     * The handover is gated on the transition into Approved, not on the record merely being
     * Approved. The half of that worth asserting is this one - an ordinary save moves nothing -
     * because the other half is unreachable: re-pointing Employee__c on a settled record is
     * refused by Approved_Request_Is_Locked before the guard ever sees it, which makes the
     * transition check belt and braces behind a validation rule rather than the only defence.
     */
    @isTest
    static void anOrdinarySaveMovesNothing() {
        OvertimeRequestGuard.permittedOverride = true;
        ApplicationItem__c a = overtime(employeeId());
        insert a;

        update new ApplicationItem__c(Id = a.Id, Remark__c = 'guard test amended');
        System.assertEquals(UserInfo.getUserId(), reload(a.Id).OwnerId,
            'editing a draft is not an approval, so nothing is handed over');

        update new ApplicationItem__c(Id = a.Id, Status__c = 'Pending');
        System.assertEquals(UserInfo.getUserId(), reload(a.Id).OwnerId,
            'and neither is submitting it - the manager owns it right up to the signature');
    }

    @isTest
    static void correctingTheEmployeeBeforeApprovalStillLandsRight() {
        OvertimeRequestGuard.permittedOverride = true;
        ApplicationItem__c a = overtime(employeeId());
        insert a;

        // Raised against the wrong person, corrected while it is still the manager's.
        update new ApplicationItem__c(Id = a.Id, Employee__c = UserInfo.getUserId());
        System.assertEquals(UserInfo.getUserId(), reload(a.Id).OwnerId,
            'still the manager, because nothing has been approved yet');

        Test.startTest();
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');
        Test.stopTest();

        System.assertEquals(UserInfo.getUserId(), reload(a.Id).OwnerId,
            'and approval hands it to whoever the field says by then');
    }

    @isTest
    static void anOvertimeRequestWithNoEmployeeIsRefused() {
        OvertimeRequestGuard.permittedOverride = true;
        ApplicationItem__c a = overtime(null);
        try {
            insert a;
            System.assert(false, 'with no employee the hours would land on the manager');
        } catch (DmlException e) {
            System.assert(errorFrom(e).contains('Choose the Employee'), errorFrom(e));
        }
    }

    /*
     * Someone can leave between the request being raised and the manager's boss signing it,
     * so the check belongs at the handover rather than at creation - the draft itself is
     * fine, it is the transfer that cannot happen.
     */
    @isTest
    static void anInactiveEmployeeIsRefusedAtApprovalByName() {
        OvertimeRequestGuard.permittedOverride = true;
        ApplicationItem__c a = overtime(retiredEmployeeId());
        insert a;
        System.assertEquals(UserInfo.getUserId(), reload(a.Id).OwnerId,
            'the draft saves fine - nothing has been handed over yet');

        try {
            update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');
            System.assert(false, 'an inactive user cannot own a record');
        } catch (DmlException e) {
            System.assert(errorFrom(e).contains('not an active user'), errorFrom(e));
            // Asserted against the stored Name rather than a literal: this org renders
            // User.Name last name first, and the point is that the person is named at all.
            String expected = [SELECT Name FROM User WHERE Id = :retiredEmployeeId()].Name;
            System.assert(errorFrom(e).contains(expected),
                'the message should name them rather than leave the manager guessing: '
                + errorFrom(e));
        }
    }

    // --------------------------------------------------------------------- permission

    @isTest
    static void withoutThePermissionOvertimeCannotBeRaised() {
        OvertimeRequestGuard.permittedOverride = false;
        try {
            insert overtime(employeeId());
            System.assert(false, 'only a manager raises overtime');
        } catch (DmlException e) {
            System.assert(errorFrom(e).contains('Overtime Request Manager'), errorFrom(e));
        }
    }

    @isTest
    static void aLeaveRequestNeedsNoOvertimePermission() {
        OvertimeRequestGuard.permittedOverride = false;
        insert new ApplicationItem__c(
            RecordTypeId = leaveRecordTypeId(),
            Request_Type__c = 'Annual leave', Period_Leave__c = 'All day',
            Term_From__c = System.today().addDays(1),
            Remark__c = 'guard test', Status__c = 'Draft', OwnerId = employeeId());

        System.assertEquals(1, [SELECT COUNT() FROM ApplicationItem__c
                                WHERE RecordTypeId = :leaveRecordTypeId()],
            'employees raise their own leave and never touch the overtime permission');
    }

    /*
     * Record type visibility governs the New button. This is the hole it leaves: saving as
     * a leave request and then switching the record type over.
     */
    @isTest
    static void switchingARecordIntoOvertimeNeedsThePermission() {
        OvertimeRequestGuard.permittedOverride = false;
        ApplicationItem__c a = new ApplicationItem__c(
            RecordTypeId = leaveRecordTypeId(),
            Request_Type__c = 'Annual leave', Period_Leave__c = 'All day',
            Term_From__c = System.today().addDays(1),
            Remark__c = 'guard test', Status__c = 'Draft', OwnerId = employeeId());
        insert a;

        try {
            update new ApplicationItem__c(Id = a.Id, RecordTypeId = overtimeRecordTypeId(),
                Employee__c = employeeId(), OT_Start__c = Time.newInstance(18, 0, 0, 0),
                OT_End__c = Time.newInstance(21, 0, 0, 0));
            System.assert(false, 'the record type is not a way around the permission');
        } catch (DmlException e) {
            System.assert(errorFrom(e).contains('Overtime Request Manager'), errorFrom(e));
        }
    }

    /*
     * The employee the request belongs to does not hold the creation permission, and must
     * not need it merely to look at or touch their own record afterwards.
     */
    @isTest
    static void editingAnExistingOvertimeRecordNeedsNoPermission() {
        OvertimeRequestGuard.permittedOverride = true;
        ApplicationItem__c a = overtime(employeeId());
        insert a;

        OvertimeRequestGuard.permittedOverride = false;
        update new ApplicationItem__c(Id = a.Id, Remark__c = 'guard test amended');

        System.assertEquals('guard test amended',
            [SELECT Remark__c FROM ApplicationItem__c WHERE Id = :a.Id].Remark__c,
            'an existing overtime record is not re-gated on every save');
    }

    // --------------------------------------------------------------------------- bulk

    @isTest
    static void twoHundredApprovalsAreHandedOverInOneTransaction() {
        OvertimeRequestGuard.permittedOverride = true;
        List<ApplicationItem__c> batch = new List<ApplicationItem__c>();
        for (Integer i = 0; i < 200; i++) {
            batch.add(overtime(employeeId()));
        }

        insert batch;
        for (ApplicationItem__c a : batch) {
            a.Status__c = 'Approved';
        }

        Test.startTest();
        Integer before = Limits.getQueries();
        update batch;
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        System.assertEquals(200, [SELECT COUNT() FROM ApplicationItem__c
                                  WHERE OwnerId = :employeeId()
                                    AND RecordTypeId = :overtimeRecordTypeId()],
            'every one of them was handed over on approval');
        System.assert(spent <= 5,
            'the employee lookup is one query for the batch, not one per record: ' + spent);
    }
}