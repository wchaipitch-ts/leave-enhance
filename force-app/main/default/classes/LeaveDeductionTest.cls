@isTest
private class LeaveDeductionTest {

    /*
     * LEAVE-18 — balance deduction on approval (LEAVE-13, spec §3.5).
     *
     * The User update happens in an @future, so every assertion on a balance has to
     * come after Test.stopTest().
     */

    private static User owner() {
        return [
            SELECT Id, Annual_Leave_Day__c, Annual_Leave_Used__c, Carry_Over_Days__c,
                   Refresh_Leave_Days__c, Sick_Leave_Used__c, Personal_Leave_Used__c
            FROM User WHERE CompanyName = 'LEAVETEST' LIMIT 1
        ];
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniqueName = 'deduct' + DateTime.now().getTime();
        insert new User(
            FirstName = 'Deduct',
            LastName = 'Tester',
            Email = uniqueName + '@example.com',
            Username = uniqueName + '@example.com.deducttest',
            Alias = 'dedu',
            CompanyName = 'LEAVETEST',
            TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = p.Id,
            LanguageLocaleKey = 'en_US',
            Start_Date__c = Date.newInstance(2020, 1, 1),
            Annual_Leave_Allocated__c = 12,
            Annual_Leave_Day__c = 12,
            Annual_Leave_Used__c = 0,
            Carry_Over_Days__c = 3,
            Refresh_Leave_Days__c = 2,
            Sick_Leave_Used__c = 0,
            Personal_Leave_Used__c = 0
        );
    }

    private static ApplicationItem__c request(Id ownerId, String type, String period) {
        return new ApplicationItem__c(
            Request_Type__c = type,
            Period_Leave__c = period,
            Term_From__c    = System.today().addDays(30),
            Remark__c       = 'deduction test',
            Status__c       = 'Pending',
            OwnerId         = ownerId
        );
    }

    private static void approve(ApplicationItem__c appl) {
        appl.Status__c = 'Approved';
        update appl;
    }

    @isTest
    static void annualLeaveDrawsFromCarryOverFirst() {
        ApplicationItem__c appl = request(owner().Id, 'Annual leave', 'All day');
        insert appl;

        Test.startTest();
        approve(appl);
        Test.stopTest();

        User u = owner();
        System.assertEquals(2, u.Carry_Over_Days__c, 'a full day comes out of carry over while it lasts');
        System.assertEquals(12, u.Annual_Leave_Day__c, 'the current year balance is untouched while carry over remains');
        System.assertEquals(1, u.Annual_Leave_Used__c, 'consumption is counted regardless of bucket');
        System.assertEquals(1, [SELECT Carry_Over_Days_Used__c FROM ApplicationItem__c WHERE Id = :appl.Id].Carry_Over_Days_Used__c,
            'the split is recorded on the request');
    }

    @isTest
    static void annualLeaveSpillsIntoCurrentYearWhenCarryOverRunsOut() {
        // 3 carry over days available, 4 requested across two approvals
        List<ApplicationItem__c> batch = new List<ApplicationItem__c>();
        Id ownerId = owner().Id;
        for (Integer i = 0; i < 4; i++) {
            batch.add(request(ownerId, 'Annual leave', 'All day'));
        }
        insert batch;

        Test.startTest();
        for (ApplicationItem__c appl : batch) {
            appl.Status__c = 'Approved';
        }
        update batch;
        Test.stopTest();

        User u = owner();
        System.assertEquals(0, u.Carry_Over_Days__c, 'carry over is exhausted first');
        System.assertEquals(11, u.Annual_Leave_Day__c, 'the fourth day spills into the current year');
        System.assertEquals(4, u.Annual_Leave_Used__c, 'all four days are counted as used');

        Decimal totalFromCarry = 0;
        for (ApplicationItem__c appl : [SELECT Carry_Over_Days_Used__c FROM ApplicationItem__c WHERE Id IN :batch]) {
            totalFromCarry += appl.Carry_Over_Days_Used__c;
        }
        System.assertEquals(3, totalFromCarry, 'the attribution across the batch adds up to the carry over consumed');
    }

    @isTest
    static void halfDayDeductsHalfADay() {
        ApplicationItem__c appl = request(owner().Id, 'Annual leave', 'AM leave');
        insert appl;

        Test.startTest();
        approve(appl);
        Test.stopTest();

        User u = owner();
        System.assertEquals(2.5, u.Carry_Over_Days__c, 'AM leave costs half a day');
        System.assertEquals(0.5, u.Annual_Leave_Used__c, 'half a day is counted as used');
    }

    @isTest
    static void balanceIsAllowedToGoNegative() {
        User u = owner();
        update new User(Id = u.Id, Carry_Over_Days__c = 0, Annual_Leave_Day__c = 0);

        ApplicationItem__c appl = request(u.Id, 'Annual leave', 'All day');
        insert appl;

        Test.startTest();
        approve(appl);
        Test.stopTest();

        System.assertEquals(-1, owner().Annual_Leave_Day__c,
            'approval must not be blocked by an empty balance; preventing overspend is a validation rule');
    }

    @isTest
    static void refreshLeaveOnlyTouchesRefreshDays() {
        ApplicationItem__c appl = request(owner().Id, 'Refresh Leave', 'All day');
        insert appl;

        Test.startTest();
        approve(appl);
        Test.stopTest();

        User u = owner();
        System.assertEquals(1, u.Refresh_Leave_Days__c, 'refresh leave draws from its own pool');
        System.assertEquals(3, u.Carry_Over_Days__c, 'carry over is not touched');
        System.assertEquals(12, u.Annual_Leave_Day__c, 'the annual balance is not touched');
        System.assertEquals(0, u.Annual_Leave_Used__c, 'refresh leave is not counted as annual consumption');
    }

    @isTest
    static void sickAndPersonalLeaveIncrementTheirOwnCounters() {
        Id ownerId = owner().Id;
        ApplicationItem__c sick = request(ownerId, 'Sick leave', 'All day');
        ApplicationItem__c personal = request(ownerId, 'Personal leave', 'PM leave');
        insert new List<ApplicationItem__c>{ sick, personal };

        Test.startTest();
        sick.Status__c = 'Approved';
        personal.Status__c = 'Approved';
        update new List<ApplicationItem__c>{ sick, personal };
        Test.stopTest();

        User u = owner();
        System.assertEquals(1, u.Sick_Leave_Used__c, 'sick leave increments its own counter');
        System.assertEquals(0.5, u.Personal_Leave_Used__c, 'personal leave increments its own counter');
        System.assertEquals(12, u.Annual_Leave_Day__c, 'neither touches the annual balance');
        System.assertEquals(3, u.Carry_Over_Days__c, 'neither touches carry over');
    }

    @isTest
    static void statutoryLeaveDeductsNothing() {
        Id ownerId = owner().Id;
        List<ApplicationItem__c> batch = new List<ApplicationItem__c>{
            request(ownerId, 'Bereavement leave', 'All day'),
            request(ownerId, 'Maternity leave', 'All day'),
            request(ownerId, 'Unpaid leave', 'All day'),
            request(ownerId, 'Other', 'All day')
        };
        insert batch;

        Test.startTest();
        for (ApplicationItem__c appl : batch) {
            appl.Status__c = 'Approved';
        }
        update batch;
        Test.stopTest();

        User u = owner();
        System.assertEquals(12, u.Annual_Leave_Day__c, 'statutory leave leaves the annual balance alone');
        System.assertEquals(3, u.Carry_Over_Days__c, 'statutory leave leaves carry over alone');
        System.assertEquals(0, u.Annual_Leave_Used__c, 'statutory leave is not counted as annual consumption');
        System.assertEquals(0, u.Sick_Leave_Used__c, 'statutory leave does not leak into the sick counter');
    }

    @isTest
    static void editingAnApprovedRequestDoesNotDeductAgain() {
        ApplicationItem__c appl = request(owner().Id, 'Annual leave', 'All day');
        insert appl;
        approve(appl);

        Test.startTest();
        appl.Remark__c = 'edited after approval';
        update appl;
        Test.stopTest();

        User u = owner();
        System.assertEquals(2, u.Carry_Over_Days__c, 'a second save must not deduct a second time');
        System.assertEquals(1, u.Annual_Leave_Used__c, 'consumption is counted once only');
    }

    @isTest
    static void insertedAsApprovedDeductsOnce() {
        ApplicationItem__c appl = request(owner().Id, 'Annual leave', 'All day');
        appl.Status__c = 'Approved';

        Test.startTest();
        insert appl;
        Test.stopTest();

        System.assertEquals(2, owner().Carry_Over_Days__c,
            'a record created already approved deducts exactly once');
    }

    @isTest
    static void pendingAndRejectedRequestsDeductNothing() {
        Id ownerId = owner().Id;
        ApplicationItem__c pending = request(ownerId, 'Annual leave', 'All day');
        ApplicationItem__c rejected = request(ownerId, 'Annual leave', 'All day');
        insert new List<ApplicationItem__c>{ pending, rejected };

        Test.startTest();
        rejected.Status__c = 'Rejected';
        update rejected;
        Test.stopTest();

        User u = owner();
        System.assertEquals(3, u.Carry_Over_Days__c, 'nothing is deducted before approval');
        System.assertEquals(0, u.Annual_Leave_Used__c, 'a rejected request never consumed anything to reverse');
    }
}