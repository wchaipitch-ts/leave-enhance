@isTest
private class OvertimeRequestTest {

    /*
     * LEAVE-31 — Overtime Requests.
     *
     * The point of the record type split is that an overtime request moves no leave
     * balance, produces no calendar Event and needs no Leave Type Policy, while still
     * booking the project time it represents. Several tests below assert the absence
     * of those things, because silently deducting leave for an overtime claim is the
     * failure this whole split exists to prevent.
     */

    private static final Date MONDAY_EPOCH = Date.newInstance(1900, 1, 1);
    private static Id cachedUserId;

    private static Id testUserId() {
        if (cachedUserId == null) {
            cachedUserId = [SELECT Id FROM User WHERE CompanyName = 'OTTEST' LIMIT 1].Id;
        }
        return cachedUserId;
    }

    private static Id overtimeRecordTypeId() {
        return Schema.SObjectType.ApplicationItem__c
            .getRecordTypeInfosByDeveloperName().get('Overtime_Request').getRecordTypeId();
    }

    /** The real project the overtime is worked on, created in setup. */
    private static Id testProjectId() {
        return [SELECT Id FROM Project__c WHERE Project_Name__c = 'OT Test Project' LIMIT 1].Id;
    }

    private static Integer testYear() {
        return System.today().year();
    }

    private static Date saturdayInTestYear() {
        Date d = Date.newInstance(testYear(), 3, 1);
        Integer dayOfWeek = Math.mod(MONDAY_EPOCH.daysBetween(d), 7); // 0 = Monday
        return d.addDays(Math.mod(5 - dayOfWeek + 7, 7));
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniqueName = 'ot' + DateTime.now().getTime();
        User u = new User(
            FirstName = 'Overtime',
            LastName = 'Tester',
            Email = uniqueName + '@example.com',
            Username = uniqueName + '@example.com.ottest',
            Alias = 'otte',
            CompanyName = 'OTTEST',
            TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = p.Id,
            LanguageLocaleKey = 'en_US',
            Start_Date__c = Date.newInstance(2020, 1, 1)
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }

        /*
         * A real project for the hours to land on. Overtime_Project_Required makes this
         * mandatory: without it the claim will not save at all, and the assertions below
         * about where the hours go would have nothing to measure.
         */
        insert new Project__c(
            RecordTypeId    = Schema.SObjectType.Project__c
                .getRecordTypeInfosByDeveloperName().get('non_Charged').getRecordTypeId(),
            Project_Name__c = 'OT Test Project',
            Start_Date__c   = Date.newInstance(System.today().year(), 1, 1),
            Due_Date__c     = Date.newInstance(System.today().year(), 12, 31)
        );

        // An annual balance the overtime must be shown NOT to touch.
        Integer yr = System.today().year();
        insert new Leave_Balance__c(
            Employee__c         = u.Id,
            Leave_Type__c       = 'Annual leave',
            Leave_Year__c       = yr,
            External_Key__c     = u.Id + '-Annual leave-' + yr,
            Entitlement_Days__c = 12,
            Accrual_Method__c   = 'Upfront',
            Carry_Over_Days__c  = 0,
            Used_Days__c        = 0,
            Pending_Days__c     = 0,
            Status__c           = 'Active'
        );
    }

    /** 18:00 to 21:00 - three hours. */
    private static ApplicationItem__c overtimeRequest() {
        /*
         * LEAVE-43. Overtime is raised by a manager on somebody else's behalf now, so saving
         * one needs the creation permission and an Employee to attribute it to. Employee__c is
         * the user these tests already owned the record as, and OwnerId is copied from it - so
         * every assertion below measures exactly what it measured before.
         */
        OvertimeRequestGuard.permittedOverride = true;
        return new ApplicationItem__c(
            RecordTypeId = overtimeRecordTypeId(),
            Employee__c  = testUserId(),
            Term_From__c = Date.newInstance(testYear(), 3, 2),
            OT_Start__c  = Time.newInstance(18, 0, 0, 0),
            OT_End__c    = Time.newInstance(21, 0, 0, 0),
            Remark__c    = 'overtime test',
            Status__c    = 'Pending',
            Project__c   = testProjectId(),
            OwnerId      = testUserId()
        );
    }

    private static ApplicationItem__c reload(Id applId) {
        return [SELECT Overtime_Hours__c, Leave_Days__c, Status__c
                FROM ApplicationItem__c WHERE Id = :applId];
    }

    private static void approve(ApplicationItem__c appl) {
        appl.Status__c = 'Approved';
        update appl;
    }

    private static List<Man_hour__c> overtimeManHours() {
        return [SELECT Performed_Date__c, Performed_Hours__c, Work__c
                FROM Man_hour__c WHERE Work__c = 'Overtime' ORDER BY Performed_Date__c];
    }

    // ------------------------------------------------------------------ hours

    @isTest
    static void hoursComeFromTheTimeWindow() {
        ApplicationItem__c appl = overtimeRequest();
        insert appl;

        System.assertEquals(3, reload(appl.Id).Overtime_Hours__c,
            '18:00 to 21:00 is three hours');
    }

    @isTest
    static void partHoursAreKept() {
        ApplicationItem__c appl = overtimeRequest();
        appl.OT_End__c = Time.newInstance(20, 30, 0, 0);
        insert appl;

        System.assertEquals(2.5, reload(appl.Id).Overtime_Hours__c,
            '18:00 to 20:30 is two and a half hours');
    }

    @isTest
    static void hoursAreCountedFromDraftOnward() {
        ApplicationItem__c appl = overtimeRequest();
        appl.Status__c = 'Draft';
        insert appl;

        System.assertEquals(3, reload(appl.Id).Overtime_Hours__c,
            'the approver must be able to see the figure before approving it');
    }

    @isTest
    static void aRangeMultipliesTheWindowByEveryDate() {
        ApplicationItem__c appl = overtimeRequest();
        appl.Term_To__c = appl.Term_From__c.addDays(2);
        insert appl;

        System.assertEquals(9, reload(appl.Id).Overtime_Hours__c,
            'three hours on each of three dates');
    }

    @isTest
    static void weekendOvertimeStillCounts() {
        Date sat = saturdayInTestYear();
        ApplicationItem__c appl = overtimeRequest();
        appl.Term_From__c = sat;
        appl.Term_To__c   = sat.addDays(1); // Saturday and Sunday
        insert appl;

        System.assertEquals(6, reload(appl.Id).Overtime_Hours__c,
            'overtime is not skipped on weekends - that is when it happens');
    }

    // ------------------------------------------------------------------ isolation

    @isTest
    static void approvedOvertimeMovesNoLeaveBalance() {
        ApplicationItem__c appl = overtimeRequest();
        insert appl;

        Test.startTest();
        approve(appl);
        Test.stopTest();

        System.assertEquals(0, [
            SELECT Used_Days__c FROM Leave_Balance__c
            WHERE Employee__c = :testUserId() AND Leave_Type__c = 'Annual leave' LIMIT 1
        ].Used_Days__c, 'an overtime claim must never consume leave');
    }

    @isTest
    static void approvedOvertimeCreatesNoCalendarEvent() {
        ApplicationItem__c appl = overtimeRequest();
        insert appl;

        Test.startTest();
        approve(appl);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Event WHERE WhatId = :appl.Id],
            'overtime is hours already worked, not an absence to block out in a diary');
    }

    @isTest
    static void overtimeNeedsNoLeaveTypePolicy() {
        // Request_Type__c is left blank on overtime, which on a leave request would
        // fail with "has no active Leave Type Policy record".
        ApplicationItem__c appl = overtimeRequest();
        appl.Status__c = 'Approved';

        Test.startTest();
        insert appl;
        Test.stopTest();

        System.assertEquals('Approved', reload(appl.Id).Status__c,
            'an overtime request approves without any leave classification');
    }

    // ------------------------------------------------------------------ man hours

    @isTest
    static void approvalBooksOneManHourPerDate() {
        ApplicationItem__c appl = overtimeRequest();
        appl.Term_To__c = appl.Term_From__c.addDays(2);
        insert appl;

        Test.startTest();
        approve(appl);
        Test.stopTest();

        List<Man_hour__c> booked = overtimeManHours();
        System.assertEquals(3, booked.size(), 'one booking per date in the range');
        for (Man_hour__c mh : booked) {
            System.assertEquals(3, mh.Performed_Hours__c, 'each date carries the OT window');
        }
    }

    /*
     * The hours land on the project the manager named. Before the Project field they went
     * to a per-year "Overtime FYxx" bucket invented by the booking logic, so every overtime
     * record in the org reported against the same project and none of them against the work
     * they were actually done for.
     */
    @isTest
    static void bookingHangsOffTheChosenProject() {
        ApplicationItem__c appl = overtimeRequest();
        insert appl;

        Test.startTest();
        approve(appl);
        Test.stopTest();

        List<Man_hour__c> booked = [
            SELECT ProjectAssign_No__r.Project_No__c, ProjectAssign_No__r.Assignee__c
            FROM Man_hour__c WHERE Work__c = 'Overtime'
        ];
        System.assertEquals(1, booked.size(), 'one date, one booking');
        System.assertEquals(testProjectId(), booked[0].ProjectAssign_No__r.Project_No__c,
            'the hours book against the project on the request');
        System.assertEquals(testUserId(), booked[0].ProjectAssign_No__r.Assignee__c,
            'and against the employee who worked them');

        String bucket = 'Overtime FY' + String.valueOf(testYear()).substring(2, 4);
        System.assertEquals(0, [SELECT COUNT() FROM Project__c WHERE Project_Name__c = :bucket],
            'and the yearly catch-all is not created at all');
        System.assertEquals(0, [SELECT COUNT() FROM Man_hour__c WHERE Work__c = 'Annual leave'],
            'and books nothing under a leave type');
    }

    /*
     * A range crossing a month boundary still needs one assignment per month, which the
     * name-keyed version of book() got for free and the Id-keyed one has to keep. Both
     * months hang off the same chosen project.
     */
    @isTest
    static void aRangeAcrossMonthsGetsAnAssignmentInEach() {
        ApplicationItem__c appl = overtimeRequest();
        appl.Term_From__c = Date.newInstance(testYear(), 3, 30);
        appl.Term_To__c   = Date.newInstance(testYear(), 4, 2);
        insert appl;

        Test.startTest();
        approve(appl);
        Test.stopTest();

        Set<Id> assigns = new Set<Id>();
        for (Man_hour__c mh : [
            SELECT ProjectAssign_No__c, ProjectAssign_No__r.Project_No__c
            FROM Man_hour__c WHERE Work__c = 'Overtime'
        ]) {
            assigns.add(mh.ProjectAssign_No__c);
            System.assertEquals(testProjectId(), mh.ProjectAssign_No__r.Project_No__c,
                'every date books against the one chosen project');
        }
        System.assertEquals(4, [SELECT COUNT() FROM Man_hour__c WHERE Work__c = 'Overtime'],
            'four dates, four bookings');
        System.assertEquals(2, assigns.size(), 'March and April get an assignment each');
    }

    /*
     * The employee needs no pre-existing assignment on the project - book() creates the
     * monthly one on demand, exactly as it always did for the yearly bucket. Asserted
     * because the alternative was to refuse the approval, and this is the deliberate choice.
     */
    @isTest
    static void anUnassignedEmployeeGetsAnAssignmentMade() {
        System.assertEquals(0, [
            SELECT COUNT() FROM ProjectAssign__c
            WHERE Project_No__c = :testProjectId() AND Assignee__c = :testUserId()
        ], 'the employee starts with no assignment on this project');

        ApplicationItem__c appl = overtimeRequest();
        insert appl;

        Test.startTest();
        approve(appl);
        Test.stopTest();

        System.assertEquals(1, [
            SELECT COUNT() FROM ProjectAssign__c
            WHERE Project_No__c = :testProjectId() AND Assignee__c = :testUserId()
        ], 'approving the claim created it');
    }

    /** The rule that makes the field mandatory, and only for overtime. */
    @isTest
    static void overtimeWithoutAProjectIsRefused() {
        ApplicationItem__c appl = overtimeRequest();
        appl.Project__c = null;

        Test.startTest();
        String message = '';
        try {
            insert appl;
            System.assert(false, 'a claim with no project should not save');
        } catch (DmlException e) {
            message = e.getDmlMessage(0);
        }
        Test.stopTest();

        System.assert(message.contains('Project'),
            'the message names the field: ' + message);
    }

    @isTest
    static void pendingOvertimeBooksNothing() {
        ApplicationItem__c appl = overtimeRequest();
        insert appl;

        Test.startTest();
        Test.stopTest();

        System.assertEquals(0, overtimeManHours().size(),
            'hours are only counted once the request is approved');
    }

    @isTest
    static void anApprovedOvertimeClaimIsLockedToo() {
        // LEAVE-35 locks approved requests of either record type. An overtime claim
        // whose hours could be edited after approval is a claim for whatever the
        // claimant last typed.
        ApplicationItem__c appl = overtimeRequest();
        insert appl;

        Test.startTest();
        approve(appl);
        Test.stopTest();

        try {
            update new ApplicationItem__c(Id = appl.Id,
                OT_End__c = Time.newInstance(23, 0, 0, 0));
            System.assert(false, 'an approved overtime claim must not be editable');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('cannot be changed'), e.getMessage());
        }

        System.assertEquals(3, reload(appl.Id).Overtime_Hours__c, 'the hours stand as approved');
        System.assertEquals(1, overtimeManHours().size(), 'and nothing is booked twice');
    }

    // ------------------------------------------------------------------ summary

    @isTest
    static void monthlyTotalSumsApprovedOvertime() {
        ApplicationItem__c first = overtimeRequest();
        ApplicationItem__c second = overtimeRequest();
        second.Term_From__c = first.Term_From__c.addDays(1);
        insert new List<ApplicationItem__c>{ first, second };

        Test.startTest();
        for (ApplicationItem__c appl : new List<ApplicationItem__c>{ first, second }) {
            appl.Status__c = 'Approved';
        }
        update new List<ApplicationItem__c>{ first, second };
        Test.stopTest();

        System.assertEquals(6,
            OvertimeSummaryService.getApprovedOvertimeHours(testUserId(), testYear(), 3),
            'two three-hour claims in March');
    }

    @isTest
    static void monthlyTotalIgnoresUnapprovedAndOtherMonths() {
        ApplicationItem__c pending = overtimeRequest();
        ApplicationItem__c aprilApproved = overtimeRequest();
        aprilApproved.Term_From__c = Date.newInstance(testYear(), 4, 6);
        insert new List<ApplicationItem__c>{ pending, aprilApproved };

        Test.startTest();
        approve(aprilApproved);
        Test.stopTest();

        System.assertEquals(0,
            OvertimeSummaryService.getApprovedOvertimeHours(testUserId(), testYear(), 3),
            'a pending March claim contributes nothing');
        System.assertEquals(3,
            OvertimeSummaryService.getApprovedOvertimeHours(testUserId(), testYear(), 4),
            'and the April one lands in April');
    }

    @isTest
    static void aRangeCrossingAMonthSplitsBetweenThem() {
        // 30 and 31 March, then 1 and 2 April.
        ApplicationItem__c appl = overtimeRequest();
        appl.Term_From__c = Date.newInstance(testYear(), 3, 30);
        appl.Term_To__c   = Date.newInstance(testYear(), 4, 2);
        insert appl;

        Test.startTest();
        approve(appl);
        Test.stopTest();

        Decimal march = OvertimeSummaryService.getApprovedOvertimeHours(testUserId(), testYear(), 3);
        Decimal april = OvertimeSummaryService.getApprovedOvertimeHours(testUserId(), testYear(), 4);

        System.assertEquals(6, march, 'two dates fall in March');
        System.assertEquals(6, april, 'two dates fall in April');
        System.assertEquals(reload(appl.Id).Overtime_Hours__c, march + april,
            'the two months add up to the request, not to double it');
    }

    @isTest
    static void monthlyTotalDefaultsToTheRunningUser() {
        System.assertEquals(0,
            OvertimeSummaryService.getApprovedOvertimeHours(null, testYear(), 3),
            'a null employee means the running user, who has claimed nothing');
    }

    @isTest
    static void monthlyTotalRejectsABadMonth() {
        try {
            OvertimeSummaryService.getApprovedOvertimeHours(testUserId(), testYear(), 13);
            System.assert(false, 'month 13 must not be accepted');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }
}