@isTest
private class LeaveSplitTest {

    /*
     * LEAVE-33 — splitting a request that runs past the balance.
     *
     * Policies are overridden in memory rather than read from the org, because the
     * split turns on Unpaid leave having Deducts_Balance__c set and that is a manual
     * Custom Metadata edit. Overriding keeps these tests honest about the code they
     * exercise instead of failing on a checkbox nobody has ticked yet.
     *
     * Balances use Upfront accrual so Accrued_Days__c does not move with the calendar.
     */

    private static final Date MONDAY_EPOCH = Date.newInstance(1900, 1, 1);
    private static Id cachedUserId;

    private static Id employeeId() {
        if (cachedUserId == null) {
            cachedUserId = [SELECT Id FROM User WHERE CompanyName = 'SPLITTEST' LIMIT 1].Id;
        }
        return cachedUserId;
    }

    private static Integer testYear() {
        return System.today().year();
    }

    /** Exactly n working days from start, so a range's day count is never in doubt. */
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
            new Leave_Type_Policy__mdt(Leave_Type__c = 'Sick leave', Active__c = true,
                Deducts_Balance__c = true, Overflow_To__c = 'Unpaid leave'),
            new Leave_Type_Policy__mdt(Leave_Type__c = 'Personal leave', Active__c = true,
                Deducts_Balance__c = true),
            // Grants_On_Use__c is what raises the entitlement as unpaid days are taken,
            // so theUnpaidBalanceNeverReadsNegative depends on it being set here.
            new Leave_Type_Policy__mdt(Leave_Type__c = 'Unpaid leave', Active__c = true,
                Deducts_Balance__c = true, Grants_On_Use__c = true)
        };
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'split' + DateTime.now().getTime();
        User u = new User(
            FirstName = 'Split', LastName = 'Tester',
            Email = unique + '@example.com', Username = unique + '@example.com.splittest',
            Alias = 'splt', CompanyName = 'SPLITTEST', TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', ProfileId = p.Id,
            LanguageLocaleKey = 'en_US', Start_Date__c = Date.newInstance(2020, 1, 1)
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }

        Integer yr = System.today().year();
        insert new List<Leave_Balance__c>{
            row(u.Id, 'Annual leave',   yr, 5),   // 5 available
            row(u.Id, 'Unpaid leave',   yr, 0),   // no entitlement; granted as it is used
            row(u.Id, 'Personal leave', yr, 2),   // deducts, but outside the split check
            row(u.Id, 'Sick leave',     yr, 0)    // nothing at all
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
            Remark__c = 'split test', Status__c = status, OwnerId = employeeId()
        );
    }

    private static ApplicationItem__c reload(Id applId) {
        return [SELECT Request_Type__c, Leave_Days__c, Term_From__c, Term_To__c, Status__c,
                       Split_From__c, Leave_Balance__c
                FROM ApplicationItem__c WHERE Id = :applId];
    }

    private static List<ApplicationItem__c> continuationOf(Id parentId) {
        return [SELECT Request_Type__c, Leave_Days__c, Term_From__c, Term_To__c, Status__c, Split_From__c
                FROM ApplicationItem__c WHERE Split_From__c = :parentId];
    }

    private static Leave_Balance__c balance(String leaveType) {
        return [SELECT Entitlement_Days__c, Used_Days__c, Available_Days__c
                FROM Leave_Balance__c
                WHERE Employee__c = :employeeId() AND Leave_Type__c = :leaveType LIMIT 1];
    }

    // ------------------------------------------------------------------ no split

    @isTest
    static void aRequestInsideTheBalanceIsLeftAlone() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Annual leave', 3, 'Pending');
        insert appl;

        System.assertEquals(3, reload(appl.Id).Leave_Days__c, 'three days, untouched');
        System.assertEquals(0, continuationOf(appl.Id).size(), 'and nothing raised beside it');
    }

    @isTest
    static void aTypeOutsideTheCheckIsNeverSplit() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Personal leave', 5, 'Pending');
        insert appl;

        System.assertEquals(5, reload(appl.Id).Leave_Days__c,
            'personal leave has Counts Toward LWOP Check off, so it is left whole');
        System.assertEquals(0, continuationOf(appl.Id).size(), 'and no unpaid record appears');
    }

    // ------------------------------------------------------------------ the split

    @isTest
    static void aRequestBeyondTheBalanceBecomesTwoRecords() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Annual leave', 8, 'Pending');
        insert appl;

        ApplicationItem__c paid = reload(appl.Id);
        System.assertEquals('Annual leave', paid.Request_Type__c, 'the original keeps its type');
        System.assertEquals(5, paid.Leave_Days__c, 'cut down to the five days the balance covers');

        List<ApplicationItem__c> tail = continuationOf(appl.Id);
        System.assertEquals(1, tail.size(), 'exactly one unpaid record is raised');
        System.assertEquals('Unpaid leave', tail[0].Request_Type__c, 'and it is unpaid leave');
        System.assertEquals(3, tail[0].Leave_Days__c, 'carrying the three days beyond the balance');
    }

    @isTest
    static void theUnpaidDaysAreTheTailNotTheHead() {
        useTestPolicies();
        List<Date> days = nWorkingDays(Date.newInstance(testYear(), 3, 2), 8);
        ApplicationItem__c appl = raise('Annual leave', 8, 'Pending');
        insert appl;

        ApplicationItem__c paid = reload(appl.Id);
        ApplicationItem__c unpaid = continuationOf(appl.Id)[0];

        System.assertEquals(days[0], paid.Term_From__c, 'the paid half starts where the request did');
        System.assertEquals(days[4], paid.Term_To__c, 'and stops on the fifth working day');
        System.assertEquals(days[5], unpaid.Term_From__c, 'the unpaid half picks up on the sixth');
        System.assertEquals(days[7], unpaid.Term_To__c, 'and runs to the original end date');
    }

    @isTest
    static void aPartDayAtTheBoundaryGoesToTheUnpaidSide() {
        useTestPolicies();
        // Leave two and a half days available.
        Leave_Balance__c bal = [SELECT Id FROM Leave_Balance__c
                                WHERE Employee__c = :employeeId() AND Leave_Type__c = 'Annual leave'];
        update new Leave_Balance__c(Id = bal.Id, Used_Days__c = 2.5);

        ApplicationItem__c appl = raise('Annual leave', 5, 'Pending');
        insert appl;

        System.assertEquals(2, reload(appl.Id).Leave_Days__c,
            'two whole days are paid; the half day is not split across records');
        System.assertEquals(3, continuationOf(appl.Id)[0].Leave_Days__c,
            'and the remaining three go unpaid');
    }

    @isTest
    static void withNothingAffordableTheRequestItselfBecomesUnpaid() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Sick leave', 4, 'Pending');
        insert appl;

        System.assertEquals('Unpaid leave', reload(appl.Id).Request_Type__c,
            'with no balance at all there is no paid half worth keeping');
        System.assertEquals(4, reload(appl.Id).Leave_Days__c, 'the dates asked for are unchanged');
        System.assertEquals(0, continuationOf(appl.Id).size(), 'and no second record is raised');
    }

    @isTest
    static void theUnpaidRecordMirrorsTheParentAndPointsBackAtIt() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Annual leave', 8, 'Draft');
        insert appl;

        ApplicationItem__c unpaid = continuationOf(appl.Id)[0];
        System.assertEquals('Draft', unpaid.Status__c,
            'a draft splits into two drafts, so both travel through approval together');
        System.assertEquals(appl.Id, unpaid.Split_From__c, 'and the tail names its parent');
    }

    @isTest
    static void theUnpaidRecordIsNotItselfSplit() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Annual leave', 8, 'Pending');
        insert appl;

        System.assertEquals(2, [SELECT COUNT() FROM ApplicationItem__c WHERE OwnerId = :employeeId()],
            'one split produces two records and then stops');
    }

    // ------------------------------------------------------------------ balances

    @isTest
    static void approvingBothHalvesMovesBothBalances() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Annual leave', 8, 'Pending');
        insert appl;
        ApplicationItem__c unpaid = continuationOf(appl.Id)[0];

        Test.startTest();
        update new List<ApplicationItem__c>{
            new ApplicationItem__c(Id = appl.Id, Status__c = 'Approved'),
            new ApplicationItem__c(Id = unpaid.Id, Status__c = 'Approved')
        };
        Test.stopTest();

        System.assertEquals(5, balance('Annual leave').Used_Days__c, 'the annual balance is emptied');
        System.assertEquals(0, balance('Annual leave').Available_Days__c, 'exactly, not past it');
        System.assertEquals(3, balance('Unpaid leave').Used_Days__c,
            'and the unpaid days are counted on their own row');
    }

    @isTest
    static void theUnpaidBalanceNeverReadsNegative() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Annual leave', 8, 'Pending');
        insert appl;

        Test.startTest();
        update new ApplicationItem__c(Id = continuationOf(appl.Id)[0].Id, Status__c = 'Approved');
        Test.stopTest();

        Leave_Balance__c unpaid = balance('Unpaid leave');
        System.assertEquals(3, unpaid.Used_Days__c, 'three unpaid days taken');
        System.assertEquals(3, unpaid.Entitlement_Days__c,
            'entitlement is granted as it is used, so the row is a count and not a debt');
        System.assertEquals(0, unpaid.Available_Days__c,
            'which is what keeps the balance page from reading minus three');
    }

    @isTest
    static void approvalStampsTheBalanceItDrewOn() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Annual leave', 3, 'Pending');
        insert appl;

        Test.startTest();
        update new ApplicationItem__c(Id = appl.Id, Status__c = 'Approved');
        Test.stopTest();

        Leave_Balance__c annual = [SELECT Id FROM Leave_Balance__c
                                   WHERE Employee__c = :employeeId() AND Leave_Type__c = 'Annual leave'];
        System.assertEquals(annual.Id, reload(appl.Id).Leave_Balance__c,
            'so every balance carries a related list of what consumed it');
    }

    // ------------------------------------------------------------------ backstop

    @isTest
    static void aStaleSplitIsRefusedRatherThanOverdrawn() {
        useTestPolicies();
        /*
         * Two requests raised while both looked affordable. Whichever is approved
         * second finds the balance gone, and its unpaid half was never created because
         * at the time it was raised there was nothing to separate out.
         */
        ApplicationItem__c first = raise('Annual leave', 3, 'Pending');
        ApplicationItem__c second = raise('Annual leave', 3, 'Pending');
        List<Date> later = nWorkingDays(Date.newInstance(testYear(), 4, 1), 3);
        second.Term_From__c = later[0];
        second.Term_To__c = later[2];
        insert new List<ApplicationItem__c>{ first, second };

        System.assertEquals(0, continuationOf(first.Id).size(), 'each looked affordable on its own');
        System.assertEquals(0, continuationOf(second.Id).size());

        update new ApplicationItem__c(Id = first.Id, Status__c = 'Approved');

        try {
            update new ApplicationItem__c(Id = second.Id, Status__c = 'Approved');
            System.assert(false, 'the second must not push the balance negative');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('day(s) remain'),
                'the error should say the balance moved underneath it: ' + e.getMessage());
        }
        System.assertEquals(3, balance('Annual leave').Used_Days__c, 'only the first was taken');
    }

    // -------------------------------------------------------- LEAVE-37, split on edit

    /*
     * The reported bug. Saving a request and setting its end date afterwards - which is
     * what filling the form in two passes gives you - left a request longer than the
     * balance with no unpaid half, and it could then never be approved.
     */
    @isTest
    static void wideningASavedRequestSplitsIt() {
        useTestPolicies();
        List<Date> days = nWorkingDays(Date.newInstance(testYear(), 3, 2), 8);

        ApplicationItem__c appl = new ApplicationItem__c(
            Request_Type__c = 'Annual leave', Period_Leave__c = 'All day',
            Term_From__c = days[0], Remark__c = 'saved first',
            Status__c = 'Pending', OwnerId = employeeId());
        insert appl;
        System.assertEquals(0, continuationOf(appl.Id).size(), 'one day is affordable');

        Test.startTest();
        update new ApplicationItem__c(Id = appl.Id, Term_To__c = days[7]);
        Test.stopTest();

        System.assertEquals(days[4], reload(appl.Id).Term_To__c,
            'cut back to the five days the balance covers');
        System.assertEquals(5, reload(appl.Id).Leave_Days__c);

        List<ApplicationItem__c> tail = continuationOf(appl.Id);
        System.assertEquals(1, tail.size(), 'the widened days become an unpaid request');
        System.assertEquals('Unpaid leave', tail[0].Request_Type__c);
        System.assertEquals(days[5], tail[0].Term_From__c, 'picking up the day after the paid half');
        System.assertEquals(days[7], tail[0].Term_To__c);
        System.assertEquals(3, tail[0].Leave_Days__c);
    }

    /*
     * Widening something already split must move the continuation, not raise a second
     * one beside it - two unpaid tails on one absence would both have to be approved.
     */
    @isTest
    static void wideningAnAlreadySplitRequestReplacesItsContinuation() {
        useTestPolicies();
        List<Date> days = nWorkingDays(Date.newInstance(testYear(), 3, 2), 12);

        ApplicationItem__c appl = raise('Annual leave', 8, 'Pending');
        insert appl;
        System.assertEquals(1, continuationOf(appl.Id).size(), 'split on insert as before');

        Test.startTest();
        update new ApplicationItem__c(Id = appl.Id, Term_To__c = days[11]);
        Test.stopTest();

        List<ApplicationItem__c> tail = continuationOf(appl.Id);
        System.assertEquals(1, tail.size(), 'still exactly one continuation');
        System.assertEquals(days[5], tail[0].Term_From__c, 'still starting where the paid half ends');
        System.assertEquals(days[11], tail[0].Term_To__c, 'and now reaching the new end date');
        System.assertEquals(7, tail[0].Leave_Days__c);
        System.assertEquals(days[4], reload(appl.Id).Term_To__c, 'the paid half is unchanged');
    }

    /*
     * Rebuilding a family deletes its continuation first, so an edit that does not
     * change the shape of the request must not reach that code at all.
     */
    @isTest
    static void editingTheRemarkLeavesTheSplitAlone() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Annual leave', 8, 'Pending');
        insert appl;
        ApplicationItem__c before = continuationOf(appl.Id)[0];

        Test.startTest();
        update new ApplicationItem__c(Id = appl.Id, Remark__c = 'fixed a typo');
        Test.stopTest();

        List<ApplicationItem__c> tail = continuationOf(appl.Id);
        System.assertEquals(1, tail.size(), 'the continuation survives an unrelated edit');
        System.assertEquals(before.Id, tail[0].Id, 'and is the same record, not a rebuild');
        System.assertEquals(before.Term_To__c, tail[0].Term_To__c);
    }

    /*
     * An approved continuation has spent balance and booked its days. Rebuilding it
     * would unpick both, so the family is left intact and the edit is refused later.
     */
    @isTest
    static void anApprovedContinuationIsNotRebuilt() {
        useTestPolicies();
        List<Date> days = nWorkingDays(Date.newInstance(testYear(), 3, 2), 12);

        ApplicationItem__c appl = raise('Annual leave', 8, 'Pending');
        insert appl;
        ApplicationItem__c tail = continuationOf(appl.Id)[0];
        update new ApplicationItem__c(Id = tail.Id, Status__c = 'Approved');

        Test.startTest();
        update new ApplicationItem__c(Id = appl.Id, Term_To__c = days[11]);
        Test.stopTest();

        List<ApplicationItem__c> after = continuationOf(appl.Id);
        System.assertEquals(1, after.size(), 'no second continuation is raised');
        System.assertEquals(tail.Id, after[0].Id, 'and the approved one is still there');
        System.assertEquals('Approved', after[0].Status__c);
        System.assertEquals(days[7], after[0].Term_To__c, 'with the dates it was approved for');
    }
}