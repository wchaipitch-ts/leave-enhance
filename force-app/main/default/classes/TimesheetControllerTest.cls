@isTest
private class TimesheetControllerTest {

    /*
     * Every test of TimesheetController lives here.
     *
     * The class used to be the timesheet methods alone, with getLeaveOverview,
     * updateApplicationItem, deleteApplicationItem and the unpaid conversion each in a
     * class of their own. One controller now has one test class, so a change to it has
     * one place to look and one class to run.
     *
     * The sections below keep the fixtures they were written against, and keep them
     * apart: a section reads only the users it made, because a query for "the Draft" or
     * "the Annual balance" would otherwise pick up another section's. Helpers are
     * prefixed with the section they belong to for the same reason.
     */

    // ------------------------------------------------------------ shared fixtures

    private static User enrUser = TST_TestDataFactory.createEngineerUser();

    /*
     * The delete and edit fixtures are dated in March of next year. That keeps the
     * record in the future whenever the suite runs, so
     * LeaveRequestCurrentDate_ValidationRule never demands a remark, and keeps both ends
     * of a range inside one calendar year, which Leave_Request_No_Year_Span requires.
     * Neither of those employees is given a Leave_Balance__c row: without one
     * LeaveSplitService finds no balance to measure against and leaves the record alone,
     * so those tests see the edit, or the delete, and nothing else.
     */
    private static final Date FROM_DATE = Date.newInstance(System.today().year() + 1, 3, 10);
    private static final Date TO_DATE   = Date.newInstance(System.today().year() + 1, 3, 12);

    /** The joining date the overview section reports on. */
    private static final Date JOINED = Date.newInstance(2022, 8, 1);

    private static final Date MONDAY_EPOCH = Date.newInstance(1900, 1, 1);

    /*
     * CompanyName is how a section finds its own users again: unique per section, and
     * cheaper to carry than an Id through a @testSetup boundary.
     */
    private static final String DEL_EMPLOYEE  = 'ADLEMP';
    private static final String DEL_OUTSIDER  = 'ADLOUT';
    private static final String EDT_EMPLOYEE  = 'AIEEMP';
    private static final String EDT_OUTSIDER  = 'AIEOUT';
    private static final String OVW_EMPLOYEE  = 'OVWEMP';
    private static final String OVW_OUTSIDER  = 'OVWOUT';
    private static final String CONV_EMPLOYEE = 'CONVTEST';

    /* The delete fixtures are told apart by their remark, because several share a status. */
    private static final String SOLO        = 'a draft on its own';
    private static final String PENDING     = 'submitted already';
    private static final String REJECTED    = 'turned down';
    private static final String HAS_DRAFT   = 'a draft with a draft continuation';
    private static final String HAS_LIVE    = 'a draft with a live continuation';
    private static final String CHILD_DRAFT = 'the draft continuation';
    private static final String CHILD_LIVE  = 'the live continuation';

    private static Map<String, Id> userIdByCompany = new Map<String, Id>();

    private static Id userIdFor(String company) {
        if (!userIdByCompany.containsKey(company)) {
            userIdByCompany.put(company,
                [SELECT Id FROM User WHERE CompanyName = :company LIMIT 1].Id);
        }
        return userIdByCompany.get(company);
    }

    private static Integer testYear() {
        return System.today().year();
    }

    private static Id leaveRecordTypeId() {
        Schema.RecordTypeInfo info = Schema.SObjectType.ApplicationItem__c
            .getRecordTypeInfosByDeveloperName().get('Leave_Request');
        return info == null ? null : info.getRecordTypeId();
    }

    private static User buildUser(String firstName, String lastName, String uniqueName,
                                  String company, String alias, Id profileId, Date startDate) {
        return new User(
            FirstName = firstName, LastName = lastName,
            Email = uniqueName + '@example.com',
            Username = uniqueName + '@example.com.tsctest',
            Alias = alias, CompanyName = company, TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', ProfileId = profileId,
            LanguageLocaleKey = 'en_US', Start_Date__c = startDate
        );
    }

    private static Id delEmployeeId()  { return userIdFor(DEL_EMPLOYEE); }
    private static User delOutsider()  { return new User(Id = userIdFor(DEL_OUTSIDER)); }
    private static Id edtEmployeeId()  { return userIdFor(EDT_EMPLOYEE); }
    private static User edtOutsider()  { return new User(Id = userIdFor(EDT_OUTSIDER)); }
    private static Id ovwEmployeeId()  { return userIdFor(OVW_EMPLOYEE); }
    private static User ovwOutsider()  { return new User(Id = userIdFor(OVW_OUTSIDER)); }
    private static Id convEmployeeId() { return userIdFor(CONV_EMPLOYEE); }

    /**
     * One setup for the whole class.
     *
     * TST_TestDataFactory inserts the engineer user while this class is initialised,
     * outside any runAs, so every insert of a non-setup object below stays inside one:
     * the mixed DML rule counts the transaction, not the statement.
     */
    @testSetup
    static void prepareTestData() {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = String.valueOf(DateTime.now().getTime());
        User systemUser = new User(Id = UserInfo.getUserId());

        User delEmployee = buildUser('Delete', DEL_EMPLOYEE, 'adlemp' + unique,
            DEL_EMPLOYEE, 'demp', standard.Id, Date.newInstance(2022, 8, 1));
        User delOutsider = buildUser('Delete', DEL_OUTSIDER, 'adlout' + unique,
            DEL_OUTSIDER, 'dout', standard.Id, Date.newInstance(2022, 8, 1));
        User edtEmployee = buildUser('Edit', EDT_EMPLOYEE, 'aieemp' + unique,
            EDT_EMPLOYEE, 'aemp', standard.Id, Date.newInstance(2022, 8, 1));
        User edtOutsider = buildUser('Edit', EDT_OUTSIDER, 'aieout' + unique,
            EDT_OUTSIDER, 'aout', standard.Id, Date.newInstance(2022, 8, 1));
        User ovwEmployee = buildUser('Overview', OVW_EMPLOYEE, 'ovwemp' + unique,
            OVW_EMPLOYEE, 'oemp', standard.Id, JOINED);
        User ovwOutsider = buildUser('Overview', OVW_OUTSIDER, 'ovwout' + unique,
            OVW_OUTSIDER, 'oout', standard.Id, JOINED);
        User convEmployee = buildUser('Convert', 'Tester', 'conv' + unique,
            CONV_EMPLOYEE, 'conv', standard.Id, Date.newInstance(2020, 1, 1));

        System.runAs(systemUser) {
            insert new List<User>{
                delEmployee, delOutsider, edtEmployee, edtOutsider,
                ovwEmployee, ovwOutsider, convEmployee
            };
        }

        Integer yr = System.today().year();

        System.runAs(systemUser) {
            // deleteApplicationItem
            ApplicationItem__c hasDraft = delLeaveRequest(delEmployee.Id, 'Draft', HAS_DRAFT);
            ApplicationItem__c hasLive  = delLeaveRequest(delEmployee.Id, 'Draft', HAS_LIVE);
            insert new List<ApplicationItem__c>{
                delLeaveRequest(delEmployee.Id, 'Draft',    SOLO),
                delLeaveRequest(delEmployee.Id, 'Pending',  PENDING),
                delLeaveRequest(delEmployee.Id, 'Rejected', REJECTED),
                hasDraft,
                hasLive
            };

            // Split_From__c can only be set once the parents have Ids, so the
            // continuations go in as a second pass. They are built by hand rather than
            // split, so that a test about the cascade is testing the cascade.
            insert new List<ApplicationItem__c>{
                delUnpaidContinuation(delEmployee.Id, 'Draft',   CHILD_DRAFT, hasDraft.Id),
                delUnpaidContinuation(delEmployee.Id, 'Pending', CHILD_LIVE,  hasLive.Id)
            };

            // updateApplicationItem
            insert new List<ApplicationItem__c>{
                edtLeaveRequest(edtEmployee.Id, 'Draft'),
                edtLeaveRequest(edtEmployee.Id, 'Pending'),
                edtLeaveRequest(edtEmployee.Id, 'Rejected')
            };

            // getLeaveOverview
            insert new List<Leave_Balance__c>{
                ovwBalanceRow(ovwEmployee.Id, 'Annual leave', yr,     12, 2, 1),
                ovwBalanceRow(ovwEmployee.Id, 'Sick leave',   yr,     30, 0, 0),
                ovwBalanceRow(ovwEmployee.Id, 'Annual leave', yr - 1, 10, 0, 4)
            };

            // the unpaid conversion
            insert new List<Leave_Balance__c>{
                convBalanceRow(convEmployee.Id, 'Annual leave', yr, 2),  // two days back in hand
                convBalanceRow(convEmployee.Id, 'Unpaid leave', yr, 0)   // granted as it is used
            };
        }

        System.runAs(enrUser) {
            insert new Timestamp__c(Stamped_Date__c = Date.newInstance(2023, 8, 30));
        }
    }


    // =====================================================================
    // The timesheet itself — avatar, permission, holidays, stamps.
    // =====================================================================

    private static testMethod void testGetUserAvatar01(){
		TimesheetController controller = new TimesheetController();
        System.runAs ( enrUser ) {
			Test.startTest();
            User userInfo = TimesheetController.getUserAvatar(enrUser.Id);
			Test.stopTest();
            Assert.areEqual('User1 Test1', userInfo.Name);
		}
        
    }
    
    private static testMethod void testGetUserAvatar02(){
		TimesheetController controller = new TimesheetController();
        System.runAs ( enrUser ) {
			Test.startTest();
            User userInfo = TimesheetController.getUserAvatar(null);
			Test.stopTest();
            Assert.isNull(userInfo);
		}
        
    }

    // private static testMethod void testCheckPermissionUser01(){
    //     System.runAs(enrUser){
    //         Test.startTest();
    //         boolean isHavePermission = TimesheetController.checkPermissionUser();
    //         Test.stopTest();
    //         Assert.areEqual(false, isHavePermission, 'User must have permission');
    //     }
    // }

    @isTest(seeAllData=false)
    static void testCheckPermissionUserWithPermissionSet() {
        // Assign the "Time_Sheet_Management_Screen_Permission" permission set to the user
        TST_TestDataFactory.assignPermissionSetToUser(enrUser, 'Time_Sheet_Management_Screen_Permission');
        
        // Run the checkPermissionUser method as the engineer user
        System.runAs(enrUser) {
            Test.startTest();
            boolean hasPermission = TimesheetController.checkPermissionUser();
            Test.stopTest();
            
            // Verify that the user has the permission
            System.assertEquals(true, hasPermission, 'Engineer user should have the permission set.');
        }
    }

    @isTest(seeAllData=false)
    static void testCheckPermissionUserWithoutPermissionSet() {
        // Run the checkPermissionUser method as the engineer user without assigning any permission set
        System.runAs(enrUser) {
            Test.startTest();
            boolean hasPermission = TimesheetController.checkPermissionUser();
            Test.stopTest();
            
            // Verify that the user does not have the permission
            System.assertEquals(false, hasPermission, 'Engineer user should not have the permission set.');
        }
    }

    private static testMethod void testGetActiveUser01(){
        Test.startTest();
        List<User> userList = TimesheetController.getActiveUser();
        Test.stopTest();
    }

    private static testMethod void testGetHolidays01(){
        System.runAs(enrUser){
            Test.startTest();
            List<Holiday> holidayList = TimesheetController.getHolidays( String.valueOf(System.Today().year()),'01');
            Test.stopTest();
        }
    }

    private static testMethod void testGetHolidays02(){
        System.runAs(enrUser){
            Test.startTest();
            List<Holiday> holidayList = TimesheetController.getHolidays( String.valueOf(System.Today().year()),'99');
            Test.stopTest();
            Assert.areEqual(new List<Holiday>(), holidayList);
        }
    }

    private static testMethod void testGetLeaveRequestes01(){
        System.runAs(enrUser){
            Test.startTest();
            List<ApplicationItem__c> applicationItems = TimesheetController.getLeaveRequestes( enrUser.Id, String.valueOf(System.Today().year()), '01' );
            Test.stopTest();
        }
    }

    private static testMethod void testGetLeaveRequestes02(){
        System.runAs(enrUser){
            Test.startTest();
            List<ApplicationItem__c> applicationItems = TimesheetController.getLeaveRequestes( enrUser.Id, String.valueOf(System.Today().year()), '99' );
            Test.stopTest();
            Assert.areEqual(new List<ApplicationItem__c>(), applicationItems);
        }
    }

    private static testMethod void testGetTimeStamps01(){
        System.runAs(enrUser){
            Test.startTest();
            List<Timestamp__c> stampedList = TimesheetController.getTimeStamps( enrUser.Id, String.valueOf(System.Today().year()), '01' );
            Test.stopTest();
        }
    }

    private static testMethod void testGetTimeStamps02(){
        System.runAs(enrUser){
            Test.startTest();
            List<Timestamp__c> stampedList = TimesheetController.getTimeStamps( enrUser.Id, String.valueOf(System.Today().year()), '99' );
            Test.stopTest();
            Assert.areEqual(new List<Timestamp__c>(), stampedList);
        }
    }

    private static testMethod void testCreateTimeStamps01(){
        System.runAs(enrUser){
            Test.startTest();
            String msg = TimesheetController.createTimeStamps(String.valueOf(System.Today()), '08:25', '17:40', 'remark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testCreateTimeStamps02(){
        System.runAs(enrUser){
            Test.startTest();
            String msg = TimesheetController.createTimeStamps(String.valueOf(System.Today()), null, '17:40', 'remark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testCreateTimeStamps03(){
        System.runAs(enrUser){
            Test.startTest();
            String msg = TimesheetController.createTimeStamps(String.valueOf(System.Today()), '08:25', null, 'remark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testCreateTimeStamps04(){
        System.runAs(enrUser){
            Test.startTest();
            String msg = TimesheetController.createTimeStamps(String.valueOf(System.Today()), null, null, 'remark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testCreateTimeStamps05(){
        System.runAs(enrUser){
            Test.startTest();
            String msg = TimesheetController.createTimeStamps(String.valueOf(System.Today()), '08', null, 'remark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testUpdateTimeStamps01(){
        System.runAs(enrUser){
            Date dateStamp = Date.newInstance(2023, 8, 30);
            Timestamp__c timestamp = [SELECT Id, Name FROM Timestamp__c WHERE OwnerId =:enrUser.Id AND Stamped_Date__c =:dateStamp];
            Test.startTest();
            String msg = TimesheetController.updateTimeStamps(timestamp.Name, TRUE, FALSE, '8:25', null, 'testRemark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testUpdateTimeStamps02(){
        System.runAs(enrUser){
            Date dateStamp = Date.newInstance(2023, 8, 30);
            Timestamp__c timestamp = [SELECT Id, Name FROM Timestamp__c WHERE OwnerId =:enrUser.Id AND Stamped_Date__c =:dateStamp];
            Test.startTest();
            String msg = TimesheetController.updateTimeStamps(timestamp.Name, FALSE, TRUE, null, '17:45', 'testRemark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testUpdateTimeStamps03(){
        System.runAs(enrUser){
            Date dateStamp = Date.newInstance(2023, 8, 30);
            Timestamp__c timestamp = [SELECT Id, Name FROM Timestamp__c WHERE OwnerId =:enrUser.Id AND Stamped_Date__c =:dateStamp];
            Test.startTest();
            String msg = TimesheetController.updateTimeStamps(timestamp.Name, FALSE, FALSE, null, null, 'Test Remark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testUpdateTimeStamps04(){
        System.runAs(enrUser){
            Date dateStamp = Date.newInstance(2023, 8, 30);
            Timestamp__c timestamp = [SELECT Id, Name FROM Timestamp__c WHERE OwnerId =:enrUser.Id AND Stamped_Date__c =:dateStamp];
            Test.startTest();
            String msg = TimesheetController.updateTimeStamps(timestamp.Name, FALSE, FALSE, null, null, null, '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testUpdateTimeStamps05(){
        System.runAs(enrUser){
            Test.startTest();
            String msg = TimesheetController.updateTimeStamps(null, TRUE, TRUE, '08:25', '17:45', 'testRemark', '', '', '');
            Test.stopTest();
        }
    }

    // =====================================================================
    // getLeaveOverview — the leave cards, the year picker, monthly hours.
    //
    // Which leave types come back is decided by the org's real
    // Leave_Type_Policy__mdt rows, so the assertions here are about behaviour —
    // Annual is present, the figures agree with LeaveBalanceService, the
    // anniversary lands on the joining day — not about a count that changes the
    // next time a type is configured.
    // =====================================================================

    private static Leave_Balance__c ovwBalanceRow(Id ownerId, String leaveType, Integer yr,
                                                  Decimal entitlement, Decimal carryOver, Decimal used) {
        return new Leave_Balance__c(
            Employee__c = ownerId, Leave_Type__c = leaveType, Leave_Year__c = yr,
            External_Key__c = ownerId + '-' + leaveType + '-' + yr,
            Entitlement_Days__c = entitlement, Accrual_Method__c = 'Upfront',
            Carry_Over_Days__c = carryOver, Used_Days__c = used,
            Pending_Days__c = 0, Status__c = 'Active'
        );
    }

    private static LeaveBalanceService.LeaveBalanceView ovwLineFor(
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
            TimesheetController.getLeaveOverview(ovwEmployeeId(), testYear(), 8);
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
            TimesheetController.getLeaveOverview(ovwEmployeeId(), testYear(), 8);

        System.assertEquals(ovwEmployeeId(), o.employee.userId);
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
            LeaveBalanceService.getBalances(ovwEmployeeId(), testYear());

        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(ovwEmployeeId(), testYear(), 8);

        System.assertEquals(direct.size(), o.balances.size(), 'the same rows, in the same order');
        for (Integer i = 0; i < direct.size(); i++) {
            System.assertEquals(direct[i].leaveType, o.balances[i].leaveType);
            System.assertEquals(direct[i].available, o.balances[i].available);
        }

        LeaveBalanceService.LeaveBalanceView annual = ovwLineFor(o, 'Annual leave');
        System.assertNotEquals(null, annual, 'Annual leave is always on the page');
        System.assertEquals(13, annual.available, '12 entitlement + 2 carried in - 1 used');
    }

    /* The single figure that replaces User.Annual_Leave_Day__c on the timesheet card. */
    @isTest
    static void annualAvailableMirrorsTheAnnualCard() {
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(ovwEmployeeId(), testYear(), 8);

        System.assertEquals(ovwLineFor(o, 'Annual leave').available, o.annualAvailable,
            'the lifted figure and the card cannot disagree');
    }

    @isTest
    static void theYearPickerOffersBothYears() {
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(ovwEmployeeId(), testYear(), 8);

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
            TimesheetController.getLeaveOverview(ovwEmployeeId(), testYear(), 8);

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
        System.runAs(ovwOutsider()) {
            try {
                TimesheetController.getLeaveOverview(ovwEmployeeId(), testYear(), 8);
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
        System.runAs(ovwOutsider()) {
            try {
                OvertimeSummaryService.getApprovedOvertimeHours(ovwEmployeeId(), testYear(), 8);
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
        System.runAs(ovwOutsider()) {
            try {
                TimesheetController.getLeaveOverview(ovwEmployeeId(), testYear(), 8);
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
        System.assertEquals(ovwEmployeeId(),
            LeaveBalanceService.assertCanView(ovwEmployeeId()),
            'and an authorised caller still resolves to the employee asked for');
    }

    // ------------------------------------------------------------- monthly hours

    /*
     * The working day is configured as Custom Labels, and an org is free to change them,
     * so these read the labels rather than hard coding 7.5 and 08:30. What is asserted is
     * the arithmetic over whatever is configured.
     */
    private static Decimal ovwLabelHours(String raw) {
        return Decimal.valueOf(raw.trim());
    }

    private static Decimal ovwRegularDay() {
        return ovwLabelHours(System.Label.MaxHourPerDay);
    }

    /* A weekday in the requested month that no Holiday record falls on. */
    private static Date ovwPlainWeekdayIn(Integer yr, Integer mo) {
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

    private static void ovwStamp(Id ownerId, Date d, Time timeIn, Time timeOut) {
        insert new Timestamp__c(
            OwnerId = ownerId, Stamped_Date__c = d,
            Stamped_TimeIn__c = timeIn, Stamped_TimeOut__c = timeOut);
    }

    /* Approved leave on one day, owned by the employee the overview is asked about. */
    private static void ovwApprovedLeave(Id ownerId, Date d, String periodLeave) {
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
            TimesheetController.getLeaveOverview(ovwEmployeeId(), yr, 8);
        Test.stopTest();

        System.assertEquals(ovwRegularDay() * workingDays, o.standardWork,
            'weekdays that are not company holidays, at a full day each');
    }

    @isTest
    static void anEmptyMonthWorksNoHours() {
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(ovwEmployeeId(), testYear(), 8);

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
        Date day = ovwPlainWeekdayIn(yr, 8);
        ovwStamp(ovwEmployeeId(), day, Time.newInstance(7, 0, 0, 0), Time.newInstance(22, 0, 0, 0));

        Test.startTest();
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(ovwEmployeeId(), yr, 8);
        Test.stopTest();

        System.assertEquals(ovwRegularDay(), o.workedHours,
            'fifteen hours on the clock is still one working day of attendance');
    }

    @isTest
    static void totalHoursIsWorkedPlusApprovedOvertime() {
        Integer yr = testYear();
        Date day = ovwPlainWeekdayIn(yr, 8);
        ovwStamp(ovwEmployeeId(), day, Time.newInstance(7, 0, 0, 0), Time.newInstance(22, 0, 0, 0));

        Test.startTest();
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(ovwEmployeeId(), yr, 8);
        Test.stopTest();

        System.assertEquals(o.workedHours + o.overtimeHours, o.totalHours,
            'the two figures are disjoint, so they add');
    }

    /* Half the day is leave, so at most half a day of it can be attendance. */
    @isTest
    static void amLeaveLeavesOnlyTheAfternoonToWork() {
        Integer yr = testYear();
        Date day = ovwPlainWeekdayIn(yr, 8);
        ovwApprovedLeave(ovwEmployeeId(), day, 'AM leave');
        ovwStamp(ovwEmployeeId(), day, Time.newInstance(7, 0, 0, 0), Time.newInstance(22, 0, 0, 0));

        Test.startTest();
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(ovwEmployeeId(), yr, 8);
        Test.stopTest();

        System.assert(o.workedHours > 0, 'the afternoon was worked');
        System.assert(o.workedHours < ovwRegularDay(),
            'but the morning was leave, so it is short of a full day');
    }

    @isTest
    static void aFullDayOfLeaveIsNotWorkedHours() {
        Integer yr = testYear();
        Date day = ovwPlainWeekdayIn(yr, 8);
        ovwApprovedLeave(ovwEmployeeId(), day, 'All day');
        ovwStamp(ovwEmployeeId(), day, Time.newInstance(8, 30, 0, 0), Time.newInstance(17, 0, 0, 0));

        Test.startTest();
        TimesheetController.LeaveOverview o =
            TimesheetController.getLeaveOverview(ovwEmployeeId(), yr, 8);
        Test.stopTest();

        System.assertEquals(0, o.workedHours,
            'the day is leave, whatever the clock says');
    }

    @isTest
    static void anEmployeeWithNoBalanceRowsStillRenders() {
        Test.startTest();
        TimesheetController.LeaveOverview o;
        System.runAs(ovwOutsider()) {
            o = TimesheetController.getLeaveOverview(null, testYear(), 8);
        }
        Test.stopTest();

        System.assertNotEquals(null, o.balances,
            'configured types come back at zero rather than vanishing');
        System.assertEquals(0, o.annualAvailable);
        System.assertEquals(0, o.availableYears.size(), 'and the picker offers nothing');
    }

    // =====================================================================
    // updateApplicationItem — editing a request from the list view.
    // =====================================================================

    private static ApplicationItem__c edtLeaveRequest(Id ownerId, String status) {
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

    /**
     * The one request in the given status. Scoped to the employee this section makes:
     * the delete section keeps fixtures in the same three statuses.
     */
    private static ApplicationItem__c edtRequestIn(String status) {
        return [
            SELECT Id, Status__c, OwnerId, Request_Type__c, Period_Leave__c,
                   Term_From__c, Term_To__c, Remark__c
            FROM ApplicationItem__c
            WHERE OwnerId = :edtEmployeeId() AND Status__c = :status
            LIMIT 1
        ];
    }

    private static ApplicationItem__c edtReread(Id recordId) {
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
        ApplicationItem__c draft = edtRequestIn('Draft');

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

        ApplicationItem__c stored = edtReread(draft.Id);
        System.assertEquals('Sick leave', stored.Request_Type__c, 'the database agrees');
        System.assertEquals('corrected reason', stored.Remark__c);
    }

    /*
     * The whole point of taking the payload at face value: a blank Term_To__c is how the
     * form says "one day", not "leave the end date alone".
     */
    @isTest
    static void clearingTheEndDateMakesItASingleDayRequest() {
        ApplicationItem__c draft = edtRequestIn('Draft');

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
        System.assertEquals(0.5, edtReread(draft.Id).Leave_Days__c,
            'the trigger recounted it as a half day');
    }

    /*
     * Remark__c is required at the schema level, so the payload cannot blank it. The
     * database refuses it and the message has to reach the user rather than being
     * swallowed - the same path as a validation rule.
     */
    @isTest
    static void blankingTheRequiredRemarkIsRefused() {
        ApplicationItem__c draft = edtRequestIn('Draft');
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
        System.assertEquals('original reason', edtReread(draft.Id).Remark__c, 'and nothing moved');
    }

    // ------------------------------------------------------------------ Draft only

    @isTest
    static void aPendingRequestCannotBeEdited() {
        ApplicationItem__c pending = edtRequestIn('Pending');
        try {
            TimesheetController.updateApplicationItem(
                new ApplicationItem__c(Id = pending.Id, Remark__c = 'too late'));
            System.assert(false, 'a submitted request must not be editable');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        System.assertEquals('original reason', edtReread(pending.Id).Remark__c, 'and nothing moved');
    }

    @isTest
    static void aRejectedRequestCannotBeEdited() {
        ApplicationItem__c rejected = edtRequestIn('Rejected');
        try {
            TimesheetController.updateApplicationItem(
                new ApplicationItem__c(Id = rejected.Id, Remark__c = 'reopening this'));
            System.assert(false, 'a refused request must not be editable');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        System.assertEquals('original reason', edtReread(rejected.Id).Remark__c, 'and nothing moved');
    }

    // ------------------------------------------------------------------ the whitelist

    /*
     * The guard that matters most. The method runs in system mode, where a status or an
     * owner posted from the client would otherwise be written straight through - taking
     * a Draft to Approved without any of the deduction the approval path performs.
     */
    @isTest
    static void statusAndOwnerCannotBeSetFromThePayload() {
        ApplicationItem__c draft = edtRequestIn('Draft');

        Test.startTest();
        ApplicationItem__c saved = TimesheetController.updateApplicationItem(
            new ApplicationItem__c(
                Id              = draft.Id,
                Status__c       = 'Approved',
                OwnerId         = edtOutsider().Id,
                Request_Type__c = 'Annual leave',
                Period_Leave__c = 'All day',
                Term_From__c    = FROM_DATE,
                Term_To__c      = TO_DATE,
                Remark__c       = 'still just a draft'
            ));
        Test.stopTest();

        System.assertEquals('Draft', saved.Status__c, 'the status is not the client\'s to set');
        System.assertEquals(edtEmployeeId(), saved.OwnerId, 'nor is the owner');
        System.assertEquals('still just a draft', saved.Remark__c,
            'while the whitelisted field did save');
    }

    // ------------------------------------------------------------------ permission

    @isTest
    static void anotherEmployeeCannotEditYourDraft() {
        ApplicationItem__c draft = edtRequestIn('Draft');

        Test.startTest();
        System.runAs(edtOutsider()) {
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

        System.assertEquals('original reason', edtReread(draft.Id).Remark__c, 'and nothing moved');
    }

    @isTest
    static void theOwnerCanEditTheirOwn() {
        ApplicationItem__c draft = edtRequestIn('Draft');

        Test.startTest();
        System.runAs(new User(Id = edtEmployeeId())) {
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

        System.assertEquals('my own request', edtReread(draft.Id).Remark__c,
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
        ApplicationItem__c draft = edtRequestIn('Draft');
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
        System.assertEquals('All day', edtReread(draft.Id).Period_Leave__c, 'and nothing moved');
    }

    // =====================================================================
    // deleteApplicationItem — removing a request from the list view.
    //
    // Each fixture is identified by its remark, because several of them share a
    // status. The continuations these tests need are built by hand rather than
    // split, so that a test about the cascade is testing the cascade rather than
    // the splitting.
    // =====================================================================

    private static ApplicationItem__c delLeaveRequest(Id ownerId, String status, String remark) {
        return new ApplicationItem__c(
            RecordTypeId    = leaveRecordTypeId(),
            OwnerId         = ownerId,
            Status__c       = status,
            Request_Type__c = 'Annual leave',
            Period_Leave__c = 'All day',
            Term_From__c    = FROM_DATE,
            Term_To__c      = TO_DATE,
            Remark__c       = remark
        );
    }

    private static ApplicationItem__c delUnpaidContinuation(Id ownerId, String status,
                                                        String remark, Id parentId) {
        ApplicationItem__c child = delLeaveRequest(ownerId, status, remark);
        child.Request_Type__c = 'Unpaid leave';
        child.Split_From__c   = parentId;
        return child;
    }

    /** The one request carrying the given remark. */
    private static ApplicationItem__c delRequestFor(String remark) {
        return [
            SELECT Id, Name, Status__c, OwnerId, Remark__c, Split_From__c, Request_Type__c
            FROM ApplicationItem__c
            WHERE Remark__c = :remark
            LIMIT 1
        ];
    }

    private static Boolean delStillExists(String remark) {
        return [SELECT COUNT() FROM ApplicationItem__c WHERE Remark__c = :remark] > 0;
    }

    // ------------------------------------------------------------------ the delete

    @isTest
    static void aDraftIsDeleted() {
        Id draftId = delRequestFor(SOLO).Id;

        Test.startTest();
        TimesheetController.deleteApplicationItem(draftId);
        Test.stopTest();

        System.assertEquals(0,
            [SELECT COUNT() FROM ApplicationItem__c WHERE Id = :draftId],
            'the draft is gone');
    }

    // ------------------------------------------------------------------ Draft only

    @isTest
    static void aPendingRequestCannotBeDeleted() {
        Id pendingId = delRequestFor(PENDING).Id;
        try {
            TimesheetController.deleteApplicationItem(pendingId);
            System.assert(false, 'a submitted request must not be deletable');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        System.assert(delStillExists(PENDING), 'and it is still there');
    }

    @isTest
    static void aRejectedRequestCannotBeDeleted() {
        Id rejectedId = delRequestFor(REJECTED).Id;
        try {
            TimesheetController.deleteApplicationItem(rejectedId);
            System.assert(false, 'a refused request must not be deletable');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        System.assert(delStillExists(REJECTED), 'and it is still there');
    }

    // ------------------------------------------------------------------ the continuation

    /*
     * Deleting the original takes only the original. The unpaid days are leave the
     * employee is still taking, so the continuation survives as an ordinary unpaid
     * request - orphaned, because Split_From__c is deleteConstraint=SetNull and there is
     * no longer anything for it to point at.
     */
    @isTest
    static void aDraftContinuationSurvivesItsParent() {
        Id parentId = delRequestFor(HAS_DRAFT).Id;

        Test.startTest();
        TimesheetController.deleteApplicationItem(parentId);
        Test.stopTest();

        System.assert(!delStillExists(HAS_DRAFT), 'the request is gone');
        System.assert(delStillExists(CHILD_DRAFT), 'but its unpaid continuation stayed');

        ApplicationItem__c child = delRequestFor(CHILD_DRAFT);
        System.assertEquals(null, child.Split_From__c, 'and the platform emptied the lookup');
        System.assertEquals('Unpaid leave', child.Request_Type__c, 'still unpaid leave');
    }

    /*
     * The same, for a continuation already through to the approval path. This is the
     * case the behaviour exists for: cascading would have cancelled a live request as a
     * side effect of tidying up a different one.
     */
    @isTest
    static void aLiveContinuationSurvivesItsParent() {
        Id parentId = delRequestFor(HAS_LIVE).Id;

        Test.startTest();
        TimesheetController.deleteApplicationItem(parentId);
        Test.stopTest();

        System.assert(!delStillExists(HAS_LIVE), 'the request is gone');
        System.assert(delStillExists(CHILD_LIVE), 'and the live continuation is untouched');

        ApplicationItem__c child = delRequestFor(CHILD_LIVE);
        System.assertEquals(null, child.Split_From__c, 'beyond the emptied lookup');
        System.assertEquals('Pending', child.Status__c, 'its status is its own business');
    }

    // ------------------------------------------------------------------ permission

    @isTest
    static void anotherEmployeeCannotDeleteYourDraft() {
        Id draftId = delRequestFor(SOLO).Id;

        Test.startTest();
        System.runAs(delOutsider()) {
            LeaveBalanceService.canViewOthersCache = null;
            try {
                TimesheetController.deleteApplicationItem(draftId);
                System.assert(false, 'one employee must not delete another employee\'s request');
            } catch (AuraHandledException e) {
                System.assert(true);
            }
        }
        Test.stopTest();

        System.assert(delStillExists(SOLO), 'and nothing moved');
    }

    /*
     * No profile in this org holds delete access on ApplicationItem__c, and the owner
     * still gets to remove their own draft - which is the whole reason the DML lives in
     * a without sharing class rather than behind an object permission.
     */
    @isTest
    static void theOwnerCanDeleteTheirOwn() {
        Id draftId = delRequestFor(SOLO).Id;

        Test.startTest();
        System.runAs(new User(Id = delEmployeeId())) {
            LeaveBalanceService.canViewOthersCache = null;
            TimesheetController.deleteApplicationItem(draftId);
        }
        Test.stopTest();

        System.assert(!delStillExists(SOLO), 'no permission set is needed for your own draft');
    }

    // ------------------------------------------------------------------ bad input

    @isTest
    static void aNullIdIsRejected() {
        try {
            TimesheetController.deleteApplicationItem(null);
            System.assert(false, 'a delete with no Id must be rejected');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @isTest
    static void anAlreadyDeletedRequestIsReportedAsGone() {
        Id draftId = delRequestFor(SOLO).Id;
        delete new ApplicationItem__c(Id = draftId);

        try {
            TimesheetController.deleteApplicationItem(draftId);
            System.assert(false, 'a request that no longer exists must be reported as such');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }
    
    private static List<Date> convWorkingDays(Date startDay, Integer n) {
        Set<Date> holidays = ApplicationItemTriggerLogic.holidaysBetween(
            startDay, startDay.addDays(n * 3 + 10));
        List<Date> days = new List<Date>();
        Date cursor = startDay;
        while (days.size() < n) {
            if (Math.mod(MONDAY_EPOCH.daysBetween(cursor), 7) < 5 && !holidays.contains(cursor)) {
                days.add(cursor);
            }
            cursor = cursor.addDays(1);
        }
        return days;
    }

    private static void convUseTestPolicies() {
        ApplicationItemTriggerLogic.policyOverride = new List<Leave_Type_Policy__mdt>{
            new Leave_Type_Policy__mdt(Leave_Type__c = 'Annual leave', Active__c = true,
                Deducts_Balance__c = true, Overflow_To__c = 'Unpaid leave'),
            new Leave_Type_Policy__mdt(Leave_Type__c = 'Unpaid leave', Active__c = true,
                Deducts_Balance__c = true, Grants_On_Use__c = true)
        };
    }

    /*
     * Conversion is a manager action, and the running test user holds no permission
     * sets. Every test below is somebody permitted doing the converting; the ones that
     * are about the permission itself say so by not calling this, or by turning it off.
     */
    private static void convAsManager() {
        LeaveConversionService.permittedOverride = true;
    }

    private static Leave_Balance__c convBalanceRow(Id ownerId, String leaveType, Integer yr, Decimal entitlement) {
        return new Leave_Balance__c(
            Employee__c = ownerId, Leave_Type__c = leaveType, Leave_Year__c = yr,
            External_Key__c = ownerId + '-' + leaveType + '-' + yr,
            Entitlement_Days__c = entitlement, Accrual_Method__c = 'Upfront',
            Carry_Over_Days__c = 0, Used_Days__c = 0, Pending_Days__c = 0, Status__c = 'Active'
        );
    }

    /** An unpaid request of `workingDays` days, in the state it is being converted from. */
    private static ApplicationItem__c convRaiseUnpaid(Integer workingDays, String status) {
        List<Date> days = convWorkingDays(Date.newInstance(testYear(), 3, 2), workingDays);
        ApplicationItem__c appl = new ApplicationItem__c(
            Request_Type__c = 'Unpaid leave', Period_Leave__c = 'All day',
            Term_From__c = days[0],
            Term_To__c = (workingDays == 1 ? null : days[workingDays - 1]),
            Remark__c = 'conversion test', Status__c = status, OwnerId = convEmployeeId()
        );
        insert appl;
        return appl;
    }

    /*
     * Raises the Annual entitlement past the two days the setup grants, for a test that
     * needs more. Accrued_To_Date__c is written from it on save under Upfront accrual.
     */
    private static void convAnnualEntitlement(Decimal days) {
        Leave_Balance__c bal = [
            SELECT Id FROM Leave_Balance__c
            WHERE Employee__c = :convEmployeeId() AND Leave_Type__c = 'Annual leave' LIMIT 1
        ];
        update new Leave_Balance__c(Id = bal.Id, Entitlement_Days__c = days);
    }

    /** A single-day unpaid absence taken as a morning or an afternoon. */
    private static ApplicationItem__c convRaiseUnpaidHalf(String period, String status) {
        ApplicationItem__c appl = new ApplicationItem__c(
            Request_Type__c = 'Unpaid leave', Period_Leave__c = period,
            Term_From__c = convWorkingDays(Date.newInstance(testYear(), 3, 2), 1)[0],
            Remark__c = 'conversion test', Status__c = status, OwnerId = convEmployeeId()
        );
        insert appl;
        return appl;
    }

    private static ApplicationItem__c convReload(Id applId) {
        return [SELECT Request_Type__c, Status__c, Leave_Days__c, Term_From__c, Term_To__c,
                       Period_Leave__c,
                       Converted_From_Unpaid__c, Converted_From_Status__c, Converted_On__c,
                       Converted_By__c, Split_From__c
                FROM ApplicationItem__c WHERE Id = :applId];
    }

    private static List<ApplicationItem__c> convChildrenOf(Id parentId) {
        return [SELECT Request_Type__c, Status__c, Leave_Days__c, Term_From__c, Term_To__c,
                       Period_Leave__c, Converted_From_Unpaid__c, Converted_From_Status__c,
                       Converted_By__c
                FROM ApplicationItem__c WHERE Split_From__c = :parentId
                ORDER BY Term_From__c];
    }

    /** What a revert put back: the unpaid records raised beside a revoked conversion. */
    private static List<ApplicationItem__c> convRestoredUnpaidUnder(Id parentId) {
        return [SELECT Request_Type__c, Status__c, Leave_Days__c, Term_From__c, Term_To__c,
                       Period_Leave__c
                FROM ApplicationItem__c
                WHERE Split_From__c = :parentId
                  AND Request_Type__c = 'Unpaid leave'
                  AND Status__c != 'Rejected'
                ORDER BY Term_From__c];
    }

    private static Leave_Balance__c convBalance(String leaveType) {
        return [SELECT Entitlement_Days__c, Used_Days__c, Available_Balance__c
                FROM Leave_Balance__c
                WHERE Employee__c = :convEmployeeId() AND Leave_Type__c = :leaveType LIMIT 1];
    }

    // ------------------------------------------------------------------ the figures

    @isTest
    static void theCardCountsWhatTheBalanceCanAffordRatherThanWhatWasAsked() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(3, 'Approved');

        Test.startTest();
        LeaveConversionService.ConversionView v = TimesheetController.getUnpaidConversion(appl.Id);
        Test.stopTest();

        System.assertEquals(3, v.remainingUnpaidDays, 'three days are being taken unpaid');
        System.assertEquals(2, v.convertibleDays, 'but only two Annual days exist to pay for them');
        System.assertEquals(0, v.convertedDays, 'and nothing has been converted yet');
        System.assertEquals(true, v.canConvert, 'so the button is live');
        System.assertEquals('Draft', v.conversionStatus, 'which is what the card calls that');
    }

    @isTest
    static void aRequestWithAnApproverOnItCannotBeConverted() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(2, 'Pending');

        Test.startTest();
        LeaveConversionService.ConversionView v = TimesheetController.getUnpaidConversion(appl.Id);
        Test.stopTest();

        System.assertEquals(false, v.canConvert, 'a request in front of an approver is not ours to cut');
        System.assertEquals(0, v.convertibleDays, 'and nothing is offered');
        System.assert(v.blockedReason.contains('approver'), 'the reason says why: ' + v.blockedReason);
    }

    // ------------------------------------------------------------ approved, in full

    @isTest
    static void convertingAnApprovedRequestInFullGivesBackTheUnpaidDaysAndPaysThem() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(2, 'Approved');
        System.assertEquals(2, convBalance('Unpaid leave').Used_Days__c, 'taken unpaid to begin with');

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, null);
        Test.stopTest();

        System.assertEquals('Rejected', convReload(appl.Id).Status__c,
            'the settled unpaid request is reversed, which is the only edit it allows');
        Leave_Balance__c unpaid = convBalance('Unpaid leave');
        System.assertEquals(0, unpaid.Used_Days__c, 'the unpaid days come back');
        System.assertEquals(0, unpaid.Entitlement_Days__c,
            'and the entitlement granted on use unwinds with them');

        List<ApplicationItem__c> raised = convChildrenOf(appl.Id);
        System.assertEquals(1, raised.size(), 'one request replaces it');
        System.assertEquals('Annual leave', raised[0].Request_Type__c, 'now a paid one');
        System.assertEquals('Approved', raised[0].Status__c,
            'approved as it was made: the manager converting it is the one who would sign');
        System.assertEquals(2, raised[0].Leave_Days__c, 'for the days that were unpaid');
        System.assertEquals(true, raised[0].Converted_From_Unpaid__c, 'and it says where it came from');
        System.assertEquals('Approved', raised[0].Converted_From_Status__c,
            'including what the days were, which is what reverting has to put back');

        System.assertEquals(2, convBalance('Annual leave').Used_Days__c,
            'and the Annual balance is spent in the same transaction, by the ordinary '
          + 'deduction rather than by anything the conversion does itself');
    }

    // ------------------------------------------------------------ approved, in part

    @isTest
    static void aPartialConversionLeavesTheRestUnpaidAndStillApproved() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(5, 'Approved');
        List<Date> days = convWorkingDays(Date.newInstance(testYear(), 3, 2), 5);

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, 2);
        Test.stopTest();

        System.assertEquals('Rejected', convReload(appl.Id).Status__c, 'the original is reversed whole');

        List<ApplicationItem__c> raised = convChildrenOf(appl.Id);
        System.assertEquals(2, raised.size(), 'and rebuilt as the two things it now is');

        System.assertEquals('Annual leave', raised[0].Request_Type__c,
            'the earliest days convert first, as the split consumes balance in date order');
        System.assertEquals('Approved', raised[0].Status__c, 'paid as it was converted');
        System.assertEquals(2, raised[0].Leave_Days__c, 'two days paid');
        System.assertEquals(days[0], raised[0].Term_From__c, 'starting where the absence did');
        System.assertEquals(days[1], raised[0].Term_To__c, 'and stopping at the second day');

        System.assertEquals('Unpaid leave', raised[1].Request_Type__c, 'the rest stays unpaid');
        System.assertEquals('Approved', raised[1].Status__c,
            'and stays approved: nobody is asked to sign again for days already signed for');
        System.assertEquals(3, raised[1].Leave_Days__c, 'three days of it');
        System.assertEquals(days[2], raised[1].Term_From__c, 'picking up the day after the paid ones');

        Leave_Balance__c unpaid = convBalance('Unpaid leave');
        System.assertEquals(3, unpaid.Used_Days__c, 'only the days still unpaid are charged');
        System.assertEquals(3, unpaid.Entitlement_Days__c, 'and only those are granted');
    }

    @isTest
    static void moreDaysThanTheBalanceHoldsIsRefused() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(5, 'Approved');

        Test.startTest();
        try {
            TimesheetController.convertUnpaidLeave(appl.Id, 5);
            System.assert(false, 'five days cannot be converted against a two day balance');
        } catch (AuraHandledException e) {
            // expected
        }
        Test.stopTest();

        System.assertEquals('Approved', convReload(appl.Id).Status__c, 'and nothing was disturbed');
        System.assertEquals(0, convChildrenOf(appl.Id).size(), 'no half-made family left behind');
    }

    // ---------------------------------------------------------------------- drafts

    @isTest
    static void aDraftConvertsInPlaceBecauseItHasSpentNothing() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(2, 'Draft');

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, null);
        Test.stopTest();

        ApplicationItem__c after = convReload(appl.Id);
        System.assertEquals('Annual leave', after.Request_Type__c, 'the request itself becomes the paid one');
        System.assertEquals('Approved', after.Status__c,
            'and is approved in the same breath: an Annual request left in Draft here '
          + 'would be a conversion that never reached the balance');
        System.assertEquals(2, convBalance('Annual leave').Used_Days__c, 'which it did');
        System.assertEquals(true, after.Converted_From_Unpaid__c, 'marked as converted');
        System.assertEquals(UserInfo.getUserId(), after.Converted_By__c, 'by whoever did it');
        System.assertEquals(0, convChildrenOf(appl.Id).size(),
            'and no second record: there was nothing settled to reverse');
    }

    @isTest
    static void aPartialDraftConversionShortensTheUnpaidRequestRatherThanReversingIt() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(4, 'Draft');
        List<Date> days = convWorkingDays(Date.newInstance(testYear(), 3, 2), 4);

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, 2);
        Test.stopTest();

        ApplicationItem__c after = convReload(appl.Id);
        System.assertEquals('Unpaid leave', after.Request_Type__c, 'the remainder is still unpaid');
        System.assertEquals('Draft', after.Status__c, 'and never left Draft');
        System.assertEquals(days[2], after.Term_From__c, 'it starts after the days that were converted');
        System.assertEquals(2, after.Leave_Days__c, 'leaving two unpaid days');

        List<ApplicationItem__c> raised = convChildrenOf(appl.Id);
        System.assertEquals(1, raised.size(), 'with the paid days beside it');
        System.assertEquals('Annual leave', raised[0].Request_Type__c, 'as Annual leave');
        System.assertEquals(2, raised[0].Leave_Days__c, 'for the two earliest days');
        System.assertEquals(days[0], raised[0].Term_From__c, 'starting where the absence did');
    }

    @isTest
    static void theCardReadsPartiallyConvertedOnceSomeDaysHaveMoved() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(4, 'Draft');

        Test.startTest();
        LeaveConversionService.ConversionView v = TimesheetController.convertUnpaidLeave(appl.Id, 2);
        Test.stopTest();

        System.assertEquals(2, v.convertedDays, 'two days converted');
        System.assertEquals(2, v.remainingUnpaidDays, 'two still unpaid');
        System.assertEquals('Partially Converted', v.conversionStatus, 'which is what that is called');
        System.assertEquals(1, v.convertedRequests.size(), 'and the card can link to what it made');
        System.assertEquals('Approved', v.convertedRequests[0].status, 'paid as it was converted');
        System.assertEquals(0, convBalance('Annual leave').Available_Balance__c,
            'the two Annual days are genuinely gone, not merely claimed');
        System.assertEquals(false, v.canConvert,
            'so the remaining unpaid days have nothing left to convert into');
    }

    // --------------------------------------------------------------------- revert

    /*
     * Reverting is not rejecting the absence. It revokes the paid request the conversion
     * produced and puts the days back as unpaid — and because these days had been
     * approved unpaid, they come back approved unpaid. Sending the employee round for a
     * second signature on days they already took, because somebody tried a correction
     * and undid it, would be an odd thing to do to them.
     */
    @isTest
    static void revertingAnApprovedConversionPutsTheDaysBackAsTheyWere() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(2, 'Approved');

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, null);
        System.assertEquals(0, convBalance('Unpaid leave').Used_Days__c,
            'the conversion gave the unpaid days back first');
        TimesheetController.revertConversion(appl.Id, 'converted by mistake');
        Test.stopTest();

        List<ApplicationItem__c> paid = [
            SELECT Status__c FROM ApplicationItem__c
            WHERE Split_From__c = :appl.Id AND Request_Type__c = 'Annual leave'
        ];
        System.assertEquals(1, paid.size(), 'the paid request is still there');
        System.assertEquals('Rejected', paid[0].Status__c, 'but revoked');

        /*
         * The absence is the record it always was, not a replacement standing in for it.
         * Raising a new one left the employee's history carrying a rejected husk and a
         * fresh LR- number for days that never moved.
         */
        ApplicationItem__c after = convReload(appl.Id);
        System.assertEquals('Approved', after.Status__c,
            'the original comes back, approved as it was before anybody converted it');
        System.assertEquals('Unpaid leave', after.Request_Type__c, 'and unpaid as it was');
        System.assertEquals(2, after.Leave_Days__c, 'for all of its days');
        System.assertEquals(0, convRestoredUnpaidUnder(appl.Id).size(),
            'with nothing raised beside it');

        Leave_Balance__c unpaid = convBalance('Unpaid leave');
        System.assertEquals(2, unpaid.Used_Days__c, 'charged to the unpaid balance again');
        System.assertEquals(2, unpaid.Entitlement_Days__c, 'with the entitlement granted to match');
        System.assertEquals(0, convBalance('Annual leave').Used_Days__c,
            'and the Annual days the conversion spent are given back');
    }

    /*
     * A Draft was shortened rather than replaced, so undoing it can put the days back on
     * the record they came off and leave the absence as one request again — the shape it
     * had before anybody pressed anything.
     */
    @isTest
    static void revertingADraftConversionGivesTheRequestItsDaysBack() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(4, 'Draft');
        List<Date> days = convWorkingDays(Date.newInstance(testYear(), 3, 2), 4);

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, 2);
        System.assertEquals(days[2], convReload(appl.Id).Term_From__c, 'shortened by the conversion');
        TimesheetController.revertConversion(appl.Id, 'not needed after all');
        Test.stopTest();

        ApplicationItem__c after = convReload(appl.Id);
        System.assertEquals(days[0], after.Term_From__c, 'and given its start date back');
        System.assertEquals(4, after.Leave_Days__c, 'all four days unpaid again');
        System.assertEquals('Unpaid leave', after.Request_Type__c, 'on the original record');
        System.assertEquals(0, convRestoredUnpaidUnder(appl.Id).size(),
            'with nothing raised beside it: the absence is one request, as it started');
    }

    /*
     * A Draft converted in full became the paid request itself. The card follows it there
     * — otherwise a conversion made in error on a Draft would be undoable only by hand,
     * which is exactly the case somebody is most likely to want back.
     */
    @isTest
    static void revertingAConversionMadeInPlaceTurnsTheRequestBack() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(2, 'Draft');

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, null);
        System.assertEquals('Annual leave', convReload(appl.Id).Request_Type__c, 'converted in place');
        LeaveConversionService.ConversionView v =
            TimesheetController.getUnpaidConversion(appl.Id);
        System.assertEquals(true, v.showsConversion,
            'and the card stays on it, because this record is now the conversion');
        System.assertEquals(true, v.canRevert, 'offering the way back');

        TimesheetController.revertConversion(appl.Id, 'wrong request');
        Test.stopTest();

        /*
         * Rejected rather than edited back. The conversion approved it, so it has spent
         * Annual balance and booked its days, and only a rejection gives those back —
         * the same route every other revoked request takes.
         */
        ApplicationItem__c after = convReload(appl.Id);
        System.assertEquals('Rejected', after.Status__c, 'the paid request is revoked');
        System.assertEquals(0, convBalance('Annual leave').Used_Days__c,
            'which is what puts the Annual days back');

        List<ApplicationItem__c> back = [
            SELECT Status__c, Request_Type__c, Leave_Days__c
            FROM ApplicationItem__c
            WHERE OwnerId = :convEmployeeId() AND Request_Type__c = 'Unpaid leave'
              AND Status__c != 'Rejected' AND Id != :appl.Id
        ];
        System.assertEquals(1, back.size(), 'and the days come back as unpaid');
        System.assertEquals('Draft', back[0].Status__c,
            'as the Draft they were before anybody converted them');
        System.assertEquals(2, back[0].Leave_Days__c, 'all of them');
    }

    @isTest
    static void thereIsNothingToRevertOnARequestNobodyConverted() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(2, 'Approved');

        Test.startTest();
        LeaveConversionService.ConversionView v = TimesheetController.getUnpaidConversion(appl.Id);
        System.assertEquals(false, v.canRevert, 'nothing has been converted, so nothing to revoke');

        try {
            TimesheetController.revertConversion(appl.Id, 'no reason');
            System.assert(false, 'and pressing it anyway is refused');
        } catch (AuraHandledException e) {
            // expected
        }
        Test.stopTest();

        System.assertEquals('Approved', convReload(appl.Id).Status__c,
            'the absence itself is untouched: reverting is about the conversion, not the leave');
    }

    @isTest
    static void aRequestThatIsNotUnpaidIsNotTheCardSBusiness() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = new ApplicationItem__c(
            Request_Type__c = 'Annual leave', Period_Leave__c = 'All day',
            Term_From__c = convWorkingDays(Date.newInstance(testYear(), 3, 2), 1)[0],
            Remark__c = 'conversion test', Status__c = 'Draft', OwnerId = convEmployeeId()
        );
        insert appl;

        Test.startTest();
        LeaveConversionService.ConversionView v = TimesheetController.getUnpaidConversion(appl.Id);
        Test.stopTest();

        System.assertEquals(false, v.canConvert, 'paid leave has nothing to convert');
        System.assertEquals(false, v.showsConversion,
            'and no conversion produced it either, so the card removes itself');
    }

    // ------------------------------------------------------------------ permission

    @isTest
    static void anEmployeeWithoutThePermissionIsShownNoCardAtAll() {
        convUseTestPolicies();
        LeaveConversionService.permittedOverride = false;
        ApplicationItem__c appl = convRaiseUnpaid(3, 'Approved');

        Test.startTest();
        LeaveConversionService.ConversionView v = TimesheetController.getUnpaidConversion(appl.Id);
        Test.stopTest();

        System.assertEquals(false, v.showsConversion,
            'the card removes itself rather than explaining a correction they cannot make');
        System.assertEquals(false, v.canConvert,
            'and the view never claims a button convert() would refuse');
        System.assertEquals(0, v.convertibleDays, 'so nothing is offered');
    }

    @isTest
    static void convertingWithoutThePermissionIsRefused() {
        convUseTestPolicies();
        LeaveConversionService.permittedOverride = false;
        ApplicationItem__c appl = convRaiseUnpaid(3, 'Approved');

        Test.startTest();
        Boolean refused = false;
        try {
            TimesheetController.convertUnpaidLeave(appl.Id, 2);
        } catch (AuraHandledException e) {
            // The message is asserted through blockedReason below. AuraHandledException
            // reports getMessage() as "Script-thrown exception" under test, which is why
            // nothing here reads it — the same reason the other refusal tests do not.
            refused = true;
        }
        Test.stopTest();

        System.assertEquals(true, refused, 'an unpermitted caller reached the conversion');
        System.assertEquals(false,
            TimesheetController.getUnpaidConversion(appl.Id).showsConversion,
            'and the card was never offered to them in the first place — the reason is '
          + 'withheld along with the figures, because none of it is theirs to read');
        System.assertEquals('Unpaid leave', convReload(appl.Id).Request_Type__c,
            'the days are still unpaid');
        System.assertEquals(0, convChildrenOf(appl.Id).size(), 'and nothing was raised beside them');
    }

    @isTest
    static void revertingWithoutThePermissionIsRefused() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(3, 'Approved');
        TimesheetController.convertUnpaidLeave(appl.Id, 2);

        // The conversion stands; it is the taking back that this caller may not do.
        LeaveConversionService.permittedOverride = false;

        Test.startTest();
        Boolean refused = false;
        try {
            TimesheetController.revertConversion(appl.Id, 'changed my mind');
        } catch (AuraHandledException e) {
            refused = true;
        }
        Test.stopTest();

        System.assertEquals(true, refused, 'an unpermitted caller revoked a conversion');
        System.assertEquals('Approved', convChildrenOf(appl.Id)[0].Status__c,
            'and the converted days are still paid, which is the point of refusing');
    }

    @isTest
    static void aBoundaryHalfDayConvertsAsItsOwnRecord() {
        convUseTestPolicies();
        convAsManager();
        convAnnualEntitlement(3);  // the setup's two days cannot pay for two and a half
        List<Date> days = convWorkingDays(Date.newInstance(testYear(), 3, 2), 3);
        ApplicationItem__c appl = convRaiseUnpaid(3, 'Approved');

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, 2.5);
        Test.stopTest();

        System.assertEquals('Rejected', convReload(appl.Id).Status__c, 'the original is reversed whole');

        List<ApplicationItem__c> raised = convChildrenOf(appl.Id);
        System.assertEquals(3, raised.size(), 'rebuilt as the three records it now is');

        System.assertEquals('Annual leave', raised[0].Request_Type__c, 'the whole paid days');
        System.assertEquals('All day', raised[0].Period_Leave__c, 'in one range');
        System.assertEquals(days[0], raised[0].Term_From__c, 'from the first day');
        System.assertEquals(days[1], raised[0].Term_To__c, 'to the second');
        System.assertEquals(2, raised[0].Leave_Days__c, 'two days of it');

        System.assertEquals('Annual leave', raised[1].Request_Type__c, 'then the paid morning');
        System.assertEquals('AM leave', raised[1].Period_Leave__c, 'as a morning, on its own record');
        System.assertEquals(days[2], raised[1].Term_From__c, 'on the boundary day');
        System.assertEquals(0.5, raised[1].Leave_Days__c, 'counting half a day');

        System.assertEquals('Unpaid leave', raised[2].Request_Type__c, 'and the afternoon stays unpaid');
        System.assertEquals('PM leave', raised[2].Period_Leave__c, 'as an afternoon');
        System.assertEquals(days[2], raised[2].Term_From__c, 'on the same day');
        System.assertEquals(0.5, raised[2].Leave_Days__c, 'the other half of it');

        System.assertEquals(2.5, convBalance('Annual leave').Used_Days__c,
            'and the Annual balance is spent to the half day, as the split spends it');
    }

    @isTest
    static void anAbsenceThatIsItselfHalfADayConvertsWithoutBecomingAWholeOne() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaidHalf('PM leave', 'Approved');
        System.assertEquals(0.5, convReload(appl.Id).Leave_Days__c, 'half a day taken unpaid');

        Test.startTest();
        LeaveConversionService.ConversionView v = TimesheetController.getUnpaidConversion(appl.Id);
        System.assertEquals(0.5, v.convertibleDays, 'and half a day is what is on offer');
        TimesheetController.convertUnpaidLeave(appl.Id, 0.5);
        Test.stopTest();

        List<ApplicationItem__c> raised = convChildrenOf(appl.Id);
        System.assertEquals(1, raised.size(), 'one paid record replaces it');
        System.assertEquals('Annual leave', raised[0].Request_Type__c, 'now paid');
        System.assertEquals('PM leave', raised[0].Period_Leave__c,
            'and still the afternoon: the absence happened then, and converting it is '
          + 'about who pays rather than when it fell');
        System.assertEquals(0.5, raised[0].Leave_Days__c, 'half a day, not a whole one');
        System.assertEquals(0.5, convBalance('Annual leave').Used_Days__c, 'half a day spent');
    }

    @isTest
    static void aQuarterDayIsRefusedBecauseNoBalanceHoldsOne() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(3, 'Approved');

        Test.startTest();
        Boolean refused = false;
        try {
            TimesheetController.convertUnpaidLeave(appl.Id, 1.25);
        } catch (AuraHandledException e) {
            refused = true;
        }
        Test.stopTest();

        System.assertEquals(true, refused, 'a quarter day is not a thing a balance can hold');
        System.assertEquals(0, convChildrenOf(appl.Id).size(), 'and nothing was raised');
    }

    /*
     * Reverting has to put a half day back as a half day. Restoring it as a whole one
     * would grant an unpaid day, and the entitlement that comes with it, for a morning
     * the employee worked.
     */
    @isTest
    static void revertingAHalfDayConversionPutsBackAHalfDay() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaidHalf('PM leave', 'Approved');

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, 0.5);
        TimesheetController.revertConversion(appl.Id, 'converted in error');
        Test.stopTest();

        ApplicationItem__c after = convReload(appl.Id);
        System.assertEquals('Approved', after.Status__c, 'the original afternoon comes back');
        System.assertEquals('Unpaid leave', after.Request_Type__c, 'unpaid again');
        System.assertEquals('PM leave', after.Period_Leave__c,
            'and still an afternoon — restoring it as a whole day would grant an unpaid '
          + 'day, and the entitlement behind it, for a morning that was worked');
        System.assertEquals(0.5, after.Leave_Days__c, 'half a day, not a whole one');
        System.assertEquals(0, convBalance('Annual leave').Used_Days__c, 'the Annual day is given back');
        System.assertEquals(0.5, convBalance('Unpaid leave').Used_Days__c, 'charged unpaid again');
    }

    /*
     * The case that put a red banner on a colleague's screen. ApplicationItem__c is
     * Public Read, so opening somebody else's leave request is ordinary; the card used
     * to answer that by throwing, which the LWC renders as an error.
     */
    @isTest
    static void someoneWhoMayNotSeeTheBalanceGetsNoCardRatherThanAnError() {
        convUseTestPolicies();
        convAsManager();
        LeaveBalanceService.canViewOthersCache = false;  // not on the timesheet permission
        ApplicationItem__c appl = convRaiseUnpaid(3, 'Approved');

        Test.startTest();
        LeaveConversionService.ConversionView v = TimesheetController.getUnpaidConversion(appl.Id);
        Test.stopTest();

        System.assertEquals(false, v.showsConversion, 'the card takes itself off the page');
        System.assertEquals(false, v.canConvert, 'and offers nothing');
        System.assertEquals(0, v.convertibleDays,
            'the figures are withheld, not zeroed: this caller may not have them');
    }

    @isTest
    static void actingOnARecordYouMayNotSeeIsStillRefused() {
        convUseTestPolicies();
        convAsManager();
        ApplicationItem__c appl = convRaiseUnpaid(3, 'Approved');
        LeaveBalanceService.canViewOthersCache = false;

        Test.startTest();
        Boolean refused = false;
        try {
            TimesheetController.convertUnpaidLeave(appl.Id, 2);
        } catch (AuraHandledException e) {
            refused = true;
        }
        Test.stopTest();

        System.assertEquals(true, refused,
            'looking is silent, but acting is not: convert still asserts');
        System.assertEquals(0, convChildrenOf(appl.Id).size(), 'and nothing was raised');
    }

    /*
     * A partial conversion left an unpaid remainder standing beside the converted days.
     * The restored source covers those dates again, so the remainder cannot stay: two
     * records claiming the same day would deduct the unpaid balance for it twice.
     */
    @isTest
    static void revertingAPartialConversionClearsTheRemainderItRaised() {
        convUseTestPolicies();
        convAsManager();
        List<Date> days = convWorkingDays(Date.newInstance(testYear(), 3, 2), 5);
        ApplicationItem__c appl = convRaiseUnpaid(5, 'Approved');

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, 2);
        System.assertEquals(2, convChildrenOf(appl.Id).size(),
            'two days paid and three left unpaid beside them');
        TimesheetController.revertConversion(appl.Id, 'converted in error');
        Test.stopTest();

        ApplicationItem__c after = convReload(appl.Id);
        System.assertEquals('Approved', after.Status__c, 'the whole absence comes back on one record');
        System.assertEquals(days[0], after.Term_From__c, 'over the dates it always had');
        System.assertEquals(days[4], after.Term_To__c, 'to the end of it');
        System.assertEquals(5, after.Leave_Days__c, 'all five days');

        for (ApplicationItem__c one : convChildrenOf(appl.Id)) {
            System.assertEquals('Rejected', one.Status__c,
                'and everything raised to stand in for it is revoked, not left claiming '
              + 'the same dates: ' + one.Request_Type__c);
        }

        Leave_Balance__c unpaid = convBalance('Unpaid leave');
        System.assertEquals(5, unpaid.Used_Days__c,
            'the unpaid balance is charged once for five days, not twice for three of them');
        System.assertEquals(0, convBalance('Annual leave').Used_Days__c, 'and the Annual days come back');
    }
}