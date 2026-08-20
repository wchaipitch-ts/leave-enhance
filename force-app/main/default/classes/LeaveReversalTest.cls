@isTest
private class LeaveReversalTest {

    /*
     * LEAVE-34 — undoing an approval.
     *
     * Policies are overridden in memory so Unpaid leave deducts a balance regardless of
     * the org's Custom Metadata, which is a manual edit and therefore not something a
     * test should depend on.
     */

    private static final Date MONDAY_EPOCH = Date.newInstance(1900, 1, 1);
    private static Id cachedUserId;

    private static Id employeeId() {
        if (cachedUserId == null) {
            cachedUserId = [SELECT Id FROM User WHERE CompanyName = 'REVTEST' LIMIT 1].Id;
        }
        return cachedUserId;
    }

    private static Integer testYear() {
        return System.today().year();
    }

    private static List<Date> nWorkingDays(Date startDay, Integer n) {
        Set<Date> holidays = ApplicationItemTriggerLogic.holidaysBetween(startDay, startDay.addDays(n * 3 + 10));
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

    private static void useTestPolicies() {
        ApplicationItemTriggerLogic.policyOverride = new List<Leave_Type_Policy__mdt>{
            new Leave_Type_Policy__mdt(Leave_Type__c = 'Annual leave', Active__c = true,
                Deducts_Balance__c = true, Overflow_To__c = 'Unpaid leave'),
            new Leave_Type_Policy__mdt(Leave_Type__c = 'Unpaid leave', Active__c = true,
                Deducts_Balance__c = true, Grants_On_Use__c = true),
            /*
             * A statutory type, to prove the unwind follows the flag rather than the
             * Unpaid leave name it used to be hardcoded to. Overflow_To__c
             * stays blank: a type with no pool cannot run short, and making it splittable
             * would send every request straight to Unpaid leave instead.
             */
            new Leave_Type_Policy__mdt(Leave_Type__c = 'Bereavement leave', Active__c = true,
                Deducts_Balance__c = true, Grants_On_Use__c = true)
        };
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'rev' + DateTime.now().getTime();
        User u = new User(
            FirstName = 'Reversal', LastName = 'Tester',
            Email = unique + '@example.com', Username = unique + '@example.com.revtest',
            Alias = 'revt', CompanyName = 'REVTEST', TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', ProfileId = p.Id,
            LanguageLocaleKey = 'en_US', Start_Date__c = Date.newInstance(2020, 1, 1)
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }

        Integer yr = System.today().year();
        insert new List<Leave_Balance__c>{
            row(u.Id, 'Annual leave', yr, 5),
            row(u.Id, 'Unpaid leave', yr, 0),
            row(u.Id, 'Bereavement leave', yr, 0)
        };
    }

    private static Leave_Balance__c row(Id ownerId, String leaveType, Integer yr, Decimal entitlement) {
        return new Leave_Balance__c(
            Employee__c = ownerId, Leave_Type__c = leaveType, Leave_Year__c = yr,
            External_Key__c = ownerId + '-' + leaveType + '-' + yr,
            Entitlement_Days__c = entitlement, Accrual_Method__c = 'Upfront',
            Carry_Over_Days__c = 0, Used_Days__c = 0, Pending_Days__c = 0, Status__c = 'Active'
        );
    }

    private static ApplicationItem__c raise(String type, Integer workingDays, String status) {
        List<Date> days = nWorkingDays(Date.newInstance(testYear(), 3, 2), workingDays);
        return new ApplicationItem__c(
            Request_Type__c = type, Period_Leave__c = 'All day',
            Term_From__c = days[0],
            Term_To__c = (workingDays == 1 ? null : days[workingDays - 1]),
            Remark__c = 'reversal test', Status__c = status, OwnerId = employeeId()
        );
    }

    private static Leave_Balance__c balance(String leaveType) {
        return [SELECT Entitlement_Days__c, Used_Days__c, Available_Days__c
                FROM Leave_Balance__c
                WHERE Employee__c = :employeeId() AND Leave_Type__c = :leaveType LIMIT 1];
    }

    private static ApplicationItem__c reload(Id applId) {
        return [SELECT Request_Type__c, Status__c, Leave_Days__c, Term_To__c,
                       Balance_Applied_Days__c, Leave_Balance__c, Carry_Over_Days_Used__c
                FROM ApplicationItem__c WHERE Id = :applId];
    }

    // ------------------------------------------------------------------ the stamp

    @isTest
    static void approvalRecordsWhatItTook() {
        useTestPolicies();
        ApplicationItem__c a = raise('Annual leave', 3, 'Pending');
        insert a;
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');

        System.assertEquals(3, reload(a.Id).Balance_Applied_Days__c,
            'the applied figure is what reversal will give back');
    }

    @isTest
    static void stretchingAnApprovedRequestIsRefused() {
        useTestPolicies();
        ApplicationItem__c a = raise('Annual leave', 1, 'Pending');
        insert a;
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');

        /*
         * This was the drift LEAVE-34 made safe and LEAVE-35 removed. Stretching an
         * approved request rewrote Leave_Days__c without deducting the extra days, so
         * the record claimed more absence than the balance had paid for. The applied
         * figure stayed honest, which is what made reversal correct — but the record
         * itself was still wrong, so the edit is now refused outright.
         */
        List<Date> days = nWorkingDays(Date.newInstance(testYear(), 3, 2), 4);
        try {
            update new ApplicationItem__c(Id = a.Id, Term_To__c = days[3]);
            System.assert(false, 'an approved request must not be stretched');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('cannot be changed'), e.getMessage());
        }

        ApplicationItem__c after = reload(a.Id);
        System.assertEquals(1, after.Leave_Days__c, 'the day count is as approved');
        System.assertEquals(1, after.Balance_Applied_Days__c, 'and matches what was deducted');
    }

    // ------------------------------------------------------------------ rejection

    @isTest
    static void rejectingAnApprovedRequestGivesTheDaysBack() {
        useTestPolicies();
        ApplicationItem__c a = raise('Annual leave', 3, 'Pending');
        insert a;

        Test.startTest();
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');
        System.assertEquals(2, balance('Annual leave').Available_Days__c, 'three of five taken');

        update new ApplicationItem__c(Id = a.Id, Status__c = 'Rejected');
        Test.stopTest();

        System.assertEquals(5, balance('Annual leave').Available_Days__c,
            'a refused absence consumes nothing');
        System.assertEquals(0, balance('Annual leave').Used_Days__c, 'and leaves no usage behind');
    }

    @isTest
    static void rejectionClearsTheStampAndTheLink() {
        useTestPolicies();
        ApplicationItem__c a = raise('Annual leave', 3, 'Pending');
        insert a;
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');
        System.assertNotEquals(null, reload(a.Id).Leave_Balance__c, 'linked while it holds days');

        update new ApplicationItem__c(Id = a.Id, Status__c = 'Rejected');

        ApplicationItem__c after = reload(a.Id);
        System.assertEquals(null, after.Balance_Applied_Days__c,
            'nothing is applied, so nothing can be reversed twice');
        System.assertEquals(null, after.Leave_Balance__c,
            'and it drops out of the balance related list');
    }

    @isTest
    static void rejectionRemovesTheCalendarEntries() {
        useTestPolicies();
        ApplicationItem__c a = raise('Annual leave', 3, 'Pending');
        insert a;

        Test.startTest();
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');
        System.assertEquals(3, [SELECT COUNT() FROM Event WHERE WhatId = :a.Id], 'three days blocked out');

        update new ApplicationItem__c(Id = a.Id, Status__c = 'Rejected');
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Event WHERE WhatId = :a.Id],
            'a refused absence leaves nothing in the diary');
    }

    @isTest
    static void rejectionRemovesTheTimesheetBookings() {
        useTestPolicies();
        ApplicationItem__c a = raise('Annual leave', 3, 'Pending');
        insert a;

        Test.startTest();
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');
        Test.stopTest();
        System.assertEquals(3, [SELECT COUNT() FROM Man_hour__c WHERE Application_Item__c = :a.Id],
            'the Queueable booked three days');

        update new ApplicationItem__c(Id = a.Id, Status__c = 'Rejected');

        System.assertEquals(0, [SELECT COUNT() FROM Man_hour__c WHERE Application_Item__c = :a.Id],
            'and the reversal takes them back out');
    }

    @isTest
    static void reversingTwiceGivesNothingBackTwice() {
        useTestPolicies();
        ApplicationItem__c a = raise('Annual leave', 3, 'Pending');
        insert a;
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Rejected');
        update new ApplicationItem__c(Id = a.Id, Remark__c = 'edited after rejection');

        System.assertEquals(5, balance('Annual leave').Available_Days__c,
            'only a transition out of Approved reverses, so an edit cannot repeat it');
    }

    @isTest
    static void aRequestThatWasNeverApprovedReversesNothing() {
        useTestPolicies();
        ApplicationItem__c a = raise('Annual leave', 3, 'Pending');
        insert a;
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Rejected');

        System.assertEquals(5, balance('Annual leave').Available_Days__c, 'untouched');
    }

    // ------------------------------------------------------------------ deletion

    @isTest
    static void deletingAnApprovedRequestGivesTheDaysBack() {
        useTestPolicies();
        ApplicationItem__c a = raise('Annual leave', 3, 'Pending');
        insert a;

        Test.startTest();
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');
        Test.stopTest();
        System.assertEquals(2, balance('Annual leave').Available_Days__c);

        delete a;

        System.assertEquals(5, balance('Annual leave').Available_Days__c,
            'after delete was declared on the trigger but never routed until now');
        System.assertEquals(0, [SELECT COUNT() FROM Man_hour__c WHERE Remark__c = 'reversal test'],
            'and the bookings go with it');
    }

    // ------------------------------------------------------------------ unpaid

    @isTest
    static void reversingUnpaidDaysUnwindsTheGrantedEntitlement() {
        useTestPolicies();
        ApplicationItem__c a = raise('Annual leave', 8, 'Pending');
        insert a;
        ApplicationItem__c tail = [SELECT Id FROM ApplicationItem__c WHERE Split_From__c = :a.Id];

        Test.startTest();
        update new ApplicationItem__c(Id = tail.Id, Status__c = 'Approved');
        Test.stopTest();
        System.assertEquals(3, balance('Unpaid leave').Entitlement_Days__c,
            'entitlement was granted as it was used');

        update new ApplicationItem__c(Id = tail.Id, Status__c = 'Rejected');

        Leave_Balance__c unpaid = balance('Unpaid leave');
        System.assertEquals(0, unpaid.Used_Days__c, 'the days come back');
        System.assertEquals(0, unpaid.Entitlement_Days__c,
            'and so does the entitlement, or the row becomes free unpaid days to spend');
        System.assertEquals(0, unpaid.Available_Days__c, 'leaving the row exactly where it started');
    }

    /*
     * The delete path for a grant-on-use type. Both sides have to come back: leaving the
     * entitlement standing would leave the row reading one accrued, available day of
     * Bereavement leave that nobody granted, because Accrued_Days__c is a formula over
     * the entitlement this wrote.
     */
    @isTest
    static void deletingGrantOnUseLeaveUnwindsBothSides() {
        useTestPolicies();
        ApplicationItem__c a = raise('Bereavement leave', 2, 'Pending');
        insert a;

        Test.startTest();
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');
        Test.stopTest();

        Leave_Balance__c taken = balance('Bereavement leave');
        System.assertEquals(2, taken.Used_Days__c, 'the days are counted');
        System.assertEquals(2, taken.Entitlement_Days__c, 'and granted as they are used');
        System.assertEquals(0, taken.Available_Days__c, 'so the row never reads negative');

        delete a;

        Leave_Balance__c restored = balance('Bereavement leave');
        System.assertEquals(0, restored.Used_Days__c, 'the days come back');
        System.assertEquals(0, restored.Entitlement_Days__c,
            'and so does the entitlement, or the row becomes free days to spend');
        System.assertEquals(0, restored.Available_Days__c, 'leaving the row where it started');
    }

    /** The same unwind on rejection, which reaches restoreBalances by a different route. */
    @isTest
    static void rejectingGrantOnUseLeaveUnwindsBothSides() {
        useTestPolicies();
        ApplicationItem__c a = raise('Bereavement leave', 2, 'Pending');
        insert a;

        Test.startTest();
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Rejected');
        Test.stopTest();

        Leave_Balance__c restored = balance('Bereavement leave');
        System.assertEquals(0, restored.Used_Days__c, 'the days come back');
        System.assertEquals(0, restored.Entitlement_Days__c, 'and the entitlement with them');
    }

    // ------------------------------------------------------------------ promotion

    @isTest
    static void rejectingThePaidHalfPromotesTheUnpaidTail() {
        useTestPolicies();
        // 8 working days against 5 available: 5 paid, 3 unpaid.
        ApplicationItem__c a = raise('Annual leave', 8, 'Pending');
        insert a;
        ApplicationItem__c tail = [SELECT Id, Request_Type__c, Leave_Days__c
                                   FROM ApplicationItem__c WHERE Split_From__c = :a.Id];
        System.assertEquals('Unpaid leave', tail.Request_Type__c, 'unpaid to begin with');
        System.assertEquals(3, tail.Leave_Days__c);

        Test.startTest();
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Rejected');
        Test.stopTest();

        ApplicationItem__c promoted = reload(tail.Id);
        System.assertEquals('Annual leave', promoted.Request_Type__c,
            'the refused paid half freed the balance the tail was denied');
        System.assertEquals(3, promoted.Leave_Days__c,
            'three days fit inside the five given back, so it is not split again');
        System.assertEquals(5, balance('Annual leave').Available_Days__c,
            'and nothing is consumed until the promoted request is approved');
    }

    @isTest
    static void aTailTooLongToPayIsPromotedAndSplitAgain() {
        useTestPolicies();
        /*
         * Drop the balance to 2 so an 8 day request leaves a 6 day tail. Rejecting the
         * paid half returns only 2 days, so the promoted tail cannot fit either and has
         * to split a second time.
         */
        update new Leave_Balance__c(
            Id = [SELECT Id FROM Leave_Balance__c WHERE Employee__c = :employeeId()
                  AND Leave_Type__c = 'Annual leave'].Id, Used_Days__c = 3);

        ApplicationItem__c a = raise('Annual leave', 8, 'Pending');
        insert a;
        ApplicationItem__c tail = [SELECT Id FROM ApplicationItem__c WHERE Split_From__c = :a.Id];

        Test.startTest();
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Approved');
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Rejected');
        Test.stopTest();

        ApplicationItem__c promoted = reload(tail.Id);
        System.assertEquals('Annual leave', promoted.Request_Type__c, 'promoted to the paid type');
        System.assertEquals(2, promoted.Leave_Days__c, 'cut to the two days now available');
        System.assertEquals(1, [SELECT COUNT() FROM ApplicationItem__c WHERE Split_From__c = :tail.Id],
            'with the remaining four raised as a fresh unpaid tail');
    }

    @isTest
    static void anAlreadyApprovedTailIsLeftAlone() {
        useTestPolicies();
        ApplicationItem__c a = raise('Annual leave', 8, 'Pending');
        insert a;
        ApplicationItem__c tail = [SELECT Id FROM ApplicationItem__c WHERE Split_From__c = :a.Id];

        Test.startTest();
        update new List<ApplicationItem__c>{
            new ApplicationItem__c(Id = a.Id, Status__c = 'Approved'),
            new ApplicationItem__c(Id = tail.Id, Status__c = 'Approved')
        };
        update new ApplicationItem__c(Id = a.Id, Status__c = 'Rejected');
        Test.stopTest();

        System.assertEquals('Unpaid leave', reload(tail.Id).Request_Type__c,
            'unpaid days already taken are a payroll correction, not a trigger\'s decision');
        System.assertEquals(3, balance('Unpaid leave').Used_Days__c, 'so the unpaid row stands');
    }
}