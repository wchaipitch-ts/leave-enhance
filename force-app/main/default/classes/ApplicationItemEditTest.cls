@isTest
private class ApplicationItemEditTest {

    /*
     * TimesheetController.updateApplicationItem — editing a request from the list view.
     *
     * A separate class rather than additions to TimesheetControllerTest, which belongs to
     * the timesheet work and covers the methods this one leaves alone. Same split as
     * LeaveOverviewTest.
     *
     * Every fixture is dated in March of next year. That keeps the record in the future
     * whenever the suite runs, so LeaveRequestCurrentDate_ValidationRule never demands a
     * remark, and keeps both ends of a range inside one calendar year, which
     * Leave_Request_No_Year_Span requires. No Leave_Balance__c rows are created: without
     * one LeaveSplitService finds no balance to measure against and leaves the record
     * alone, so these tests see the edit and nothing else.
     */

    private static final Date FROM_DATE = Date.newInstance(System.today().year() + 1, 3, 10);
    private static final Date TO_DATE   = Date.newInstance(System.today().year() + 1, 3, 12);

    private static Id cachedEmployeeId;
    private static Id cachedOutsiderId;

    private static Id employeeId() {
        if (cachedEmployeeId == null) {
            cachedEmployeeId = [SELECT Id FROM User WHERE CompanyName = 'AIEEMP' LIMIT 1].Id;
        }
        return cachedEmployeeId;
    }

    private static User outsider() {
        if (cachedOutsiderId == null) {
            cachedOutsiderId = [SELECT Id FROM User WHERE CompanyName = 'AIEOUT' LIMIT 1].Id;
        }
        return new User(Id = cachedOutsiderId);
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String stamp = String.valueOf(DateTime.now().getTime());
        User employee = buildUser('aieemp' + stamp, 'AIEEMP', 'aemp', p.Id);
        User outsider = buildUser('aieout' + stamp, 'AIEOUT', 'aout', p.Id);

        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ employee, outsider };
        }

        insert new List<ApplicationItem__c>{
            leaveRequest(employee.Id, 'Draft'),
            leaveRequest(employee.Id, 'Pending'),
            leaveRequest(employee.Id, 'Rejected')
        };
    }

    private static User buildUser(String uniqueName, String company, String alias, Id profileId) {
        return new User(
            FirstName = 'Edit', LastName = company,
            Email = uniqueName + '@example.com',
            Username = uniqueName + '@example.com.aietest',
            Alias = alias, CompanyName = company, TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', ProfileId = profileId,
            LanguageLocaleKey = 'en_US', Start_Date__c = Date.newInstance(2022, 8, 1)
        );
    }

    private static Id leaveRecordTypeId() {
        Schema.RecordTypeInfo info = Schema.SObjectType.ApplicationItem__c
            .getRecordTypeInfosByDeveloperName().get('Leave_Request');
        return info == null ? null : info.getRecordTypeId();
    }

    private static ApplicationItem__c leaveRequest(Id ownerId, String status) {
        return new ApplicationItem__c(
            RecordTypeId    = leaveRecordTypeId(),
            OwnerId         = ownerId,
            Status__c       = status,
            Request_Type__c = 'Annual leave',
            Period_Leave__c = 'All day',
            Term_From__c    = FROM_DATE,
            Term_To__c      = TO_DATE,
            Remark__c       = 'original reason'
        );
    }

    /** The one request in the given status. */
    private static ApplicationItem__c requestIn(String status) {
        return [
            SELECT Id, Status__c, OwnerId, Request_Type__c, Period_Leave__c,
                   Term_From__c, Term_To__c, Remark__c
            FROM ApplicationItem__c
            WHERE Status__c = :status
            LIMIT 1
        ];
    }

    private static ApplicationItem__c reread(Id recordId) {
        return [
            SELECT Id, Status__c, OwnerId, Request_Type__c, Period_Leave__c,
                   Term_From__c, Term_To__c, Remark__c, Leave_Days__c
            FROM ApplicationItem__c
            WHERE Id = :recordId
        ];
    }

    // ------------------------------------------------------------------ the edit

    @isTest
    static void aDraftIsUpdatedAndHandedBack() {
        ApplicationItem__c draft = requestIn('Draft');

        Test.startTest();
        ApplicationItem__c saved = TimesheetController.updateApplicationItem(
            new ApplicationItem__c(
                Id              = draft.Id,
                Request_Type__c = 'Sick leave',
                Period_Leave__c = 'All day',
                Term_From__c    = FROM_DATE,
                Term_To__c      = FROM_DATE.addDays(1),
                Remark__c       = 'corrected reason'
            ));
        Test.stopTest();

        System.assertNotEquals(null, saved, 'the saved record comes back');
        System.assertEquals('Sick leave', saved.Request_Type__c, 'the type changed');
        System.assertEquals(FROM_DATE.addDays(1), saved.Term_To__c, 'the end date changed');
        System.assertEquals('corrected reason', saved.Remark__c, 'the remark changed');
        System.assertEquals('Draft', saved.Status__c, 'and it is still a Draft');

        ApplicationItem__c stored = reread(draft.Id);
        System.assertEquals('Sick leave', stored.Request_Type__c, 'the database agrees');
        System.assertEquals('corrected reason', stored.Remark__c);
    }

    /*
     * The whole point of taking the payload at face value: a blank Term_To__c is how the
     * form says "one day", not "leave the end date alone".
     */
    @isTest
    static void clearingTheEndDateMakesItASingleDayRequest() {
        ApplicationItem__c draft = requestIn('Draft');

        Test.startTest();
        ApplicationItem__c saved = TimesheetController.updateApplicationItem(
            new ApplicationItem__c(
                Id              = draft.Id,
                Request_Type__c = 'Annual leave',
                Period_Leave__c = 'AM leave',
                Term_From__c    = FROM_DATE,
                Term_To__c      = null,
                Remark__c       = 'now a half day'
            ));
        Test.stopTest();

        System.assertEquals(null, saved.Term_To__c, 'the range collapsed');
        System.assertEquals(0.5, reread(draft.Id).Leave_Days__c,
            'the trigger recounted it as a half day');
    }

    /*
     * Remark__c is required at the schema level, so the payload cannot blank it. The
     * database refuses it and the message has to reach the user rather than being
     * swallowed - the same path as a validation rule.
     */
    @isTest
    static void blankingTheRequiredRemarkIsRefused() {
        ApplicationItem__c draft = requestIn('Draft');
        try {
            TimesheetController.updateApplicationItem(
                new ApplicationItem__c(
                    Id              = draft.Id,
                    Request_Type__c = 'Annual leave',
                    Period_Leave__c = 'All day',
                    Term_From__c    = FROM_DATE,
                    Term_To__c      = TO_DATE,
                    Remark__c       = null
                ));
            System.assert(false, 'a required field cannot be cleared');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        System.assertEquals('original reason', reread(draft.Id).Remark__c, 'and nothing moved');
    }

    // ------------------------------------------------------------------ Draft only

    @isTest
    static void aPendingRequestIsRefused() {
        ApplicationItem__c pending = requestIn('Pending');
        try {
            TimesheetController.updateApplicationItem(
                new ApplicationItem__c(Id = pending.Id, Remark__c = 'too late'));
            System.assert(false, 'a submitted request must not be editable');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        System.assertEquals('original reason', reread(pending.Id).Remark__c, 'and nothing moved');
    }

    @isTest
    static void aRejectedRequestIsRefused() {
        ApplicationItem__c rejected = requestIn('Rejected');
        try {
            TimesheetController.updateApplicationItem(
                new ApplicationItem__c(Id = rejected.Id, Remark__c = 'reopening this'));
            System.assert(false, 'a refused request must not be editable');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        System.assertEquals('original reason', reread(rejected.Id).Remark__c, 'and nothing moved');
    }

    // ------------------------------------------------------------------ the whitelist

    /*
     * The guard that matters most. The method runs in system mode, where a status or an
     * owner posted from the client would otherwise be written straight through - taking
     * a Draft to Approved without any of the deduction the approval path performs.
     */
    @isTest
    static void statusAndOwnerCannotBeSetFromThePayload() {
        ApplicationItem__c draft = requestIn('Draft');

        Test.startTest();
        ApplicationItem__c saved = TimesheetController.updateApplicationItem(
            new ApplicationItem__c(
                Id              = draft.Id,
                Status__c       = 'Approved',
                OwnerId         = outsider().Id,
                Request_Type__c = 'Annual leave',
                Period_Leave__c = 'All day',
                Term_From__c    = FROM_DATE,
                Term_To__c      = TO_DATE,
                Remark__c       = 'still just a draft'
            ));
        Test.stopTest();

        System.assertEquals('Draft', saved.Status__c, 'the status is not the client\'s to set');
        System.assertEquals(employeeId(), saved.OwnerId, 'nor is the owner');
        System.assertEquals('still just a draft', saved.Remark__c,
            'while the whitelisted field did save');
    }

    // ------------------------------------------------------------------ permission

    @isTest
    static void anotherEmployeeCannotEditYourDraft() {
        ApplicationItem__c draft = requestIn('Draft');

        Test.startTest();
        System.runAs(outsider()) {
            LeaveBalanceService.canViewOthersCache = null;
            try {
                TimesheetController.updateApplicationItem(
                    new ApplicationItem__c(Id = draft.Id, Remark__c = 'not mine to touch'));
                System.assert(false, 'one employee must not edit another employee\'s request');
            } catch (AuraHandledException e) {
                System.assert(true);
            }
        }
        Test.stopTest();

        System.assertEquals('original reason', reread(draft.Id).Remark__c, 'and nothing moved');
    }

    @isTest
    static void theOwnerCanEditTheirOwn() {
        ApplicationItem__c draft = requestIn('Draft');

        Test.startTest();
        System.runAs(new User(Id = employeeId())) {
            LeaveBalanceService.canViewOthersCache = null;
            TimesheetController.updateApplicationItem(
                new ApplicationItem__c(
                    Id              = draft.Id,
                    Request_Type__c = 'Annual leave',
                    Period_Leave__c = 'All day',
                    Term_From__c    = FROM_DATE,
                    Term_To__c      = TO_DATE,
                    Remark__c       = 'my own request'
                ));
        }
        Test.stopTest();

        System.assertEquals('my own request', reread(draft.Id).Remark__c,
            'no permission set is needed for your own draft');
    }

    // ------------------------------------------------------------------ bad input

    @isTest
    static void aMissingIdIsRejected() {
        try {
            TimesheetController.updateApplicationItem(new ApplicationItem__c(Remark__c = 'x'));
            System.assert(false, 'an edit with no Id must be rejected');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @isTest
    static void aNullPayloadIsRejected() {
        try {
            TimesheetController.updateApplicationItem(null);
            System.assert(false, 'a null payload must be rejected');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    /*
     * A validation rule has to reach the user as its own message rather than as a raw
     * DmlException: a half-day period across a range is exactly the mistake the edit
     * form lets somebody make.
     */
    @isTest
    static void aValidationRuleIsSurfacedAsAMessage() {
        ApplicationItem__c draft = requestIn('Draft');
        try {
            TimesheetController.updateApplicationItem(
                new ApplicationItem__c(
                    Id              = draft.Id,
                    Request_Type__c = 'Annual leave',
                    Period_Leave__c = 'AM leave',
                    Term_From__c    = FROM_DATE,
                    Term_To__c      = TO_DATE,
                    Remark__c       = 'half a day across three'
                ));
            System.assert(false, 'a half day across a range must be refused');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        System.assertEquals('All day', reread(draft.Id).Period_Leave__c, 'and nothing moved');
    }
}