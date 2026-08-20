@isTest
private class LeaveOverviewTest {

    /*
     * TimesheetController.getLeaveOverview.
     *
     * A separate class rather than additions to TimesheetControllerTest, which belongs
     * to the timesheet work and covers the methods this one deliberately left alone.
     *
     * Which leave types come back is decided by the org's real Leave_Type_Policy__mdt
     * rows, so the assertions here are about behaviour — Annual is present, the figures
     * agree with LeaveBalanceService, the anniversary lands on the joining day — not
     * about a count that changes the next time a type is configured.
     */

    private static final Date JOINED = Date.newInstance(2022, 8, 1);

    private static Id cachedEmployeeId;
    private static Id cachedOutsiderId;

    private static Id employeeId() {
        if (cachedEmployeeId == null) {
            cachedEmployeeId = [SELECT Id FROM User WHERE CompanyName = 'OVWEMP' LIMIT 1].Id;
        }
        return cachedEmployeeId;
    }

    private static User outsider() {
        if (cachedOutsiderId == null) {
            cachedOutsiderId = [SELECT Id FROM User WHERE CompanyName = 'OVWOUT' LIMIT 1].Id;
        }
        return new User(Id = cachedOutsiderId);
    }

    private static Integer testYear() {
        return System.today().year();
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String stamp = String.valueOf(DateTime.now().getTime());
        User employee = buildUser('ovwemp' + stamp, 'OVWEMP', 'oemp', p.Id);
        User outsider = buildUser('ovwout' + stamp, 'OVWOUT', 'oout', p.Id);

        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ employee, outsider };
        }

        Integer yr = System.today().year();
        insert new List<Leave_Balance__c>{
            balanceRow(employee.Id, 'Annual leave', yr,     12, 2, 1),
            balanceRow(employee.Id, 'Sick leave',   yr,     30, 0, 0),
            balanceRow(employee.Id, 'Annual leave', yr - 1, 10, 0, 4)
        };
    }

    private static User buildUser(String uniqueName, String company, String alias, Id profileId) {
        return new User(
            FirstName = 'Overview', LastName = company,
            Email = uniqueName + '@example.com',
            Username = uniqueName + '@example.com.ovwtest',
            Alias = alias, CompanyName = company, TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', ProfileId = profileId,
            LanguageLocaleKey = 'en_US', Start_Date__c = JOINED
        );
    }

    private static Leave_Balance__c balanceRow(Id ownerId, String leaveType, Integer yr,
                                               Decimal entitlement, Decimal carryOver, Decimal used) {
        return new Leave_Balance__c(
            Employee__c = ownerId, Leave_Type__c = leaveType, Leave_Year__c = yr,
            External_Key__c = ownerId + '-' + leaveType + '-' + yr,
            Entitlement_Days__c = entitlement, Accrual_Method__c = 'Upfront',
            Carry_Over_Days__c = carryOver, Used_Days__c = used,
            Pending_Days__c = 0, Status__c = 'Active'
        );
    }

    private static LeaveBalanceService.LeaveBalanceView lineFor(
            TimesheetController.LeaveOverview o, String leaveType) {
        for (LeaveBalanceService.LeaveBalanceView v : o.balances) {
            if (leaveType.equals(v.leaveType)) {
                return v;
            }
        }
        return null;
    }

    // ------------------------------------------------------------------ one call

    @isTest
    static void oneCallReturnsEveryPieceTheCardsNeed() {
        Test.startTest();
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(employeeId(), testYear(), 8);
        Test.stopTest();

        System.assertNotEquals(null, o.employee, 'the employee panel');
        System.assertNotEquals(null, o.balances, 'the balance cards');
        System.assertNotEquals(null, o.availableYears, 'the year picker');
        System.assertNotEquals(null, o.overtimeHours, 'the overtime figure');
        System.assertEquals(testYear(), o.year);
        System.assertEquals(8, o.month);
    }

    @isTest
    static void theEmployeePanelIsPopulated() {
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(employeeId(), testYear(), 8);

        System.assertEquals(employeeId(), o.employee.userId);
        System.assertEquals(JOINED, o.employee.startDate, 'the joining date drives everything else');
        System.assertEquals(JOINED.addDays(119), o.employee.probationEndDate,
            'probation end is a formula over the joining date');
        System.assertEquals(false, o.employee.onProbation,
            'a 2022 joiner is long past probation');
    }

    /*
     * The figures must be the ones LeaveBalanceService produces, not a second
     * calculation that can drift away from it.
     */
    @isTest
    static void theBalancesAgreeWithTheBalanceService() {
        List<LeaveBalanceService.LeaveBalanceView> direct =
            LeaveBalanceService.getBalances(employeeId(), testYear());

        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(employeeId(), testYear(), 8);

        System.assertEquals(direct.size(), o.balances.size(), 'the same rows, in the same order');
        for (Integer i = 0; i < direct.size(); i++) {
            System.assertEquals(direct[i].leaveType, o.balances[i].leaveType);
            System.assertEquals(direct[i].available, o.balances[i].available);
        }

        LeaveBalanceService.LeaveBalanceView annual = lineFor(o, 'Annual leave');
        System.assertNotEquals(null, annual, 'Annual leave is always on the page');
        System.assertEquals(13, annual.available, '12 entitlement + 2 carried in - 1 used');
    }

    /* The single figure that replaces User.Annual_Leave_Day__c on the timesheet card. */
    @isTest
    static void annualAvailableMirrorsTheAnnualCard() {
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(employeeId(), testYear(), 8);

        System.assertEquals(lineFor(o, 'Annual leave').available, o.annualAvailable,
            'the lifted figure and the card cannot disagree');
    }

    @isTest
    static void theYearPickerOffersBothYears() {
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(employeeId(), testYear(), 8);

        System.assertEquals(2, o.availableYears.size());
        System.assertEquals(testYear(), o.availableYears[0], 'newest first');
        System.assertEquals(testYear() - 1, o.availableYears[1]);
    }

    // --------------------------------------------------------------- anniversary

    /*
     * The bug this replaces: the card announced the next refreshment grant as 1 January,
     * which is right only for a 1 January joiner.
     */
    @isTest
    static void theNextGrantIsTheJoiningDayNotJanuaryFirst() {
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(employeeId(), testYear(), 8);

        System.assertNotEquals(null, o.nextRefreshmentGrant);
        System.assertEquals(JOINED.month(), o.nextRefreshmentGrant.month(),
            'the anniversary falls in the joining month');
        System.assertEquals(JOINED.day(), o.nextRefreshmentGrant.day());
        System.assert(o.nextRefreshmentGrant >= System.today(),
            'and it is the next one, not one that has passed');
        System.assert(o.nextRefreshmentGrant < System.today().addYears(1).addDays(1),
            'within the coming year');
    }

    // ------------------------------------------------------------------ defaults

    @isTest
    static void nullArgumentsFallBackToTheRunningUserAndToday() {
        Test.startTest();
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(null, null, null);
        Test.stopTest();

        System.assertEquals(UserInfo.getUserId(), o.employee.userId, 'defaults to the caller');
        System.assertEquals(System.today().year(), o.year);
        System.assertEquals(System.today().month(), o.month);
    }

    // ------------------------------------------------------------- authorisation

    /*
     * The permission check lives in LeaveBalanceService. Reaching the balances through
     * it rather than querying Leave_Balance__c here is what keeps that true, so this
     * asserts the guard still bites through the new entry point.
     */
    @isTest
    static void oneEmployeeCannotReadAnothersFigures() {
        Test.startTest();
        System.runAs(outsider()) {
            try {
                TimesheetController.getLeaveOverview(employeeId(), testYear(), 8);
                System.assert(false, 'an ordinary colleague must not see these figures');
            } catch (AuraHandledException e) {
                // expected — the guard reached the caller instead of being swallowed
            }
        }
        Test.stopTest();
    }

    /*
     * The overtime total used to have no check of its own. ApplicationItem__c
     * is Public Read Only, so `with sharing` withheld nothing and any employee could
     * read back a colleague's hours by passing their Id.
     */
    @isTest
    static void oneEmployeeCannotReadAnothersOvertime() {
        Test.startTest();
        System.runAs(outsider()) {
            try {
                OvertimeSummaryService.getApprovedOvertimeHours(employeeId(), testYear(), 8);
                System.assert(false, 'overtime hours are no more public than the balances');
            } catch (AuraHandledException e) {
                // expected
            }
        }
        Test.stopTest();
    }

    /*
     * The guard has to be the overview's own, not a side effect of the balance call
     * being first. Reordering those lines must not be able to open the method up.
     */
    @isTest
    static void theOverviewRefusesBeforeItReadsAnything() {
        Test.startTest();
        System.runAs(outsider()) {
            try {
                TimesheetController.getLeaveOverview(employeeId(), testYear(), 8);
                System.assert(false, 'refused');
            } catch (AuraHandledException e) {
                // expected
            }
        }
        Test.stopTest();

        /*
         * The answer is cached for the transaction, and the block above cached it for the
         * outsider. Production never changes running user mid-transaction; a test does,
         * which is what the reset hook is for.
         */
        LeaveBalanceService.canViewOthersCache = null;
        System.assertEquals(employeeId(),
            LeaveBalanceService.assertCanView(employeeId()),
            'and an authorised caller still resolves to the employee asked for');
    }

    // ------------------------------------------------------------- monthly hours

    /*
     * The working day is configured as Custom Labels, and an org is free to change them,
     * so these read the labels rather than hard coding 7.5 and 08:30. What is asserted is
     * the arithmetic over whatever is configured.
     */
    private static Decimal labelHours(String raw) {
        return Decimal.valueOf(raw.trim());
    }

    private static Decimal regularDay() {
        return labelHours(System.Label.MaxHourPerDay);
    }

    /* A weekday in the requested month that no Holiday record falls on. */
    private static Date aPlainWeekdayIn(Integer yr, Integer mo) {
        Set<Date> holidays = ApplicationItemTriggerLogic.holidaysBetween(
            Date.newInstance(yr, mo, 1),
            Date.newInstance(yr, mo, Date.daysInMonth(yr, mo)));
        Date cursor = Date.newInstance(yr, mo, 1);
        Date monthEnd = Date.newInstance(yr, mo, Date.daysInMonth(yr, mo));
        while (cursor <= monthEnd) {
            if (Math.mod(Date.newInstance(1900, 1, 1).daysBetween(cursor), 7) < 5
                && !holidays.contains(cursor)) {
                return cursor;
            }
            cursor = cursor.addDays(1);
        }
        return null;
    }

    private static void stamp(Id ownerId, Date d, Time timeIn, Time timeOut) {
        insert new Timestamp__c(
            OwnerId = ownerId, Stamped_Date__c = d,
            Stamped_TimeIn__c = timeIn, Stamped_TimeOut__c = timeOut);
    }

    /* Approved leave on one day, owned by the employee the overview is asked about. */
    private static void approvedLeave(Id ownerId, Date d, String periodLeave) {
        insert new ApplicationItem__c(
            RecordTypeId = Schema.SObjectType.ApplicationItem__c
                .getRecordTypeInfosByDeveloperName().get('Leave_Request').getRecordTypeId(),
            Request_Type__c = 'Annual leave', Period_Leave__c = periodLeave,
            Term_From__c = d, Remark__c = 'monthly hours', Status__c = 'Approved',
            OwnerId = ownerId);
    }

    @isTest
    static void standardWorkIsAFullDayForEveryWorkingDayOfTheMonth() {
        Integer yr = testYear();
        Date monthStart = Date.newInstance(yr, 8, 1);
        Date monthEnd = Date.newInstance(yr, 8, Date.daysInMonth(yr, 8));
        Set<Date> holidays = ApplicationItemTriggerLogic.holidaysBetween(monthStart, monthEnd);

        Integer workingDays = 0;
        for (Date d = monthStart; d <= monthEnd; d = d.addDays(1)) {
            if (Math.mod(Date.newInstance(1900, 1, 1).daysBetween(d), 7) < 5
                && !holidays.contains(d)) {
                workingDays++;
            }
        }

        Test.startTest();
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(employeeId(), yr, 8);
        Test.stopTest();

        System.assertEquals(regularDay() * workingDays, o.standardWork,
            'weekdays that are not company holidays, at a full day each');
    }

    @isTest
    static void anEmptyMonthWorksNoHours() {
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(employeeId(), testYear(), 8);

        System.assertEquals(0, o.workedHours, 'nobody stamped');
        System.assertEquals(o.overtimeHours, o.totalHours,
            'total is overtime alone when nothing was worked');
    }

    /*
     * The figure this replaces included overtime: the screen it is ported from leaves its
     * afternoon segment uncapped, so stamping out at eight in the evening inflated Worked
     * Hours. Overtime is counted from approved requests, so a day here stops at a full one.
     */
    @isTest
    static void aLongDayStillCountsAsOneWorkingDay() {
        Integer yr = testYear();
        Date day = aPlainWeekdayIn(yr, 8);
        stamp(employeeId(), day, Time.newInstance(7, 0, 0, 0), Time.newInstance(22, 0, 0, 0));

        Test.startTest();
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(employeeId(), yr, 8);
        Test.stopTest();

        System.assertEquals(regularDay(), o.workedHours,
            'fifteen hours on the clock is still one working day of attendance');
    }

    @isTest
    static void totalHoursIsWorkedPlusApprovedOvertime() {
        Integer yr = testYear();
        Date day = aPlainWeekdayIn(yr, 8);
        stamp(employeeId(), day, Time.newInstance(7, 0, 0, 0), Time.newInstance(22, 0, 0, 0));

        Test.startTest();
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(employeeId(), yr, 8);
        Test.stopTest();

        System.assertEquals(o.workedHours + o.overtimeHours, o.totalHours,
            'the two figures are disjoint, so they add');
    }

    /* Half the day is leave, so at most half a day of it can be attendance. */
    @isTest
    static void amLeaveLeavesOnlyTheAfternoonToWork() {
        Integer yr = testYear();
        Date day = aPlainWeekdayIn(yr, 8);
        approvedLeave(employeeId(), day, 'AM leave');
        stamp(employeeId(), day, Time.newInstance(7, 0, 0, 0), Time.newInstance(22, 0, 0, 0));

        Test.startTest();
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(employeeId(), yr, 8);
        Test.stopTest();

        System.assert(o.workedHours > 0, 'the afternoon was worked');
        System.assert(o.workedHours < regularDay(),
            'but the morning was leave, so it is short of a full day');
    }

    @isTest
    static void aFullDayOfLeaveIsNotWorkedHours() {
        Integer yr = testYear();
        Date day = aPlainWeekdayIn(yr, 8);
        approvedLeave(employeeId(), day, 'All day');
        stamp(employeeId(), day, Time.newInstance(8, 30, 0, 0), Time.newInstance(17, 0, 0, 0));

        Test.startTest();
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(employeeId(), yr, 8);
        Test.stopTest();

        System.assertEquals(0, o.workedHours,
            'the day is leave, whatever the clock says');
    }

    @isTest
    static void anEmployeeWithNoBalanceRowsStillRenders() {
        Test.startTest();
        TimesheetController.LeaveOverview o;
        System.runAs(outsider()) {
            o = TimesheetController.getLeaveOverview(null, testYear(), 8);
        }
        Test.stopTest();

        System.assertNotEquals(null, o.balances,
            'configured types come back at zero rather than vanishing');
        System.assertEquals(0, o.annualAvailable);
        System.assertEquals(0, o.availableYears.size(), 'and the picker offers nothing');
    }
}