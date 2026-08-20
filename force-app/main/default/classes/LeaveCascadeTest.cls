@isTest
private class LeaveCascadeTest {

    /*
     * LEAVE-46 — a request that outruns its pool cascades down the chain.
     *
     * Refresh Leave overflows into Annual leave and Annual leave into Unpaid leave, so a
     * long Refresh Leave request can produce three records. LeaveSplitTest covers the
     * single-hop case it was written for; this covers the walk itself, the expiring
     * grant, and the balance that used to go negative because neither the split nor the
     * approval check applied to Refresh Leave at all.
     *
     * A separate class rather than additions to LeaveSplitTest: the fixtures differ (a
     * Refresh Leave policy and a windowed balance row) and mixing them would make both
     * harder to read.
     *
     * Policies are overridden in memory, as they are in LeaveSplitTest, because the
     * chain lives in Custom Metadata that a scratch org has no reason to carry.
     */

    private static final Date MONDAY_EPOCH = Date.newInstance(1900, 1, 1);
    private static final String REFRESH = 'Refresh Leave';
    private static final String ANNUAL  = 'Annual leave';
    private static final String UNPAID  = 'Unpaid leave';

    private static Id cachedUserId;

    private static Id employeeId() {
        if (cachedUserId == null) {
            cachedUserId = [SELECT Id FROM User WHERE CompanyName = 'CASCADETEST' LIMIT 1].Id;
        }
        return cachedUserId;
    }

    private static Integer testYear() {
        return System.today().year();
    }

    /*
     * Refresh Leave overflows to Annual, Annual to Unpaid, and Unpaid ends the chain.
     * Unpaid grants its entitlement as it is used, which is what lets it absorb whatever
     * the paid pools could not fund.
     */
    private static void useTestPolicies() {
        ApplicationItemTriggerLogic.policyOverride = new List<Leave_Type_Policy__mdt>{
            new Leave_Type_Policy__mdt(Leave_Type__c = REFRESH, Active__c = true,
                Deducts_Balance__c = true, Overflow_To__c = ANNUAL),
            new Leave_Type_Policy__mdt(Leave_Type__c = ANNUAL, Active__c = true,
                Deducts_Balance__c = true, Overflow_To__c = UNPAID),
            new Leave_Type_Policy__mdt(Leave_Type__c = UNPAID, Active__c = true,
                Deducts_Balance__c = true, Grants_On_Use__c = true)
        };
    }

    /** Exactly n working days from start, so a range's day count is never in doubt. */
    private static List<Date> nWorkingDays(Date startDay, Integer n) {
        Set<Date> holidays =
            ApplicationItemTriggerLogic.holidaysBetween(startDay, startDay.addDays(n * 3 + 10));
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

    private static List<Date> workdays(Integer n) {
        return nWorkingDays(Date.newInstance(testYear(), 3, 2), n);
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'casc' + DateTime.now().getTime();
        User u = new User(
            FirstName = 'Cascade', LastName = 'Tester',
            Email = unique + '@example.com', Username = unique + '@example.com.casctest',
            Alias = 'casc', CompanyName = 'CASCADETEST', TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', ProfileId = p.Id,
            LanguageLocaleKey = 'en_US', Start_Date__c = Date.newInstance(2020, 1, 1)
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }

        Integer yr = System.today().year();
        insert new List<Leave_Balance__c>{
            row(u.Id, REFRESH, yr, 3),   // three refresh days
            row(u.Id, ANNUAL,  yr, 4),   // four annual days behind them
            row(u.Id, UNPAID,  yr, 0)    // no entitlement; granted as it is used
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

    /** Moves a balance to a different figure than the fixture gave it. */
    private static void setEntitlement(String leaveType, Decimal days) {
        Leave_Balance__c bal = balance(leaveType);
        bal.Entitlement_Days__c = days;
        update bal;
    }

    private static ApplicationItem__c raise(String type, Integer workingDays, String status) {
        List<Date> days = workdays(workingDays);
        return new ApplicationItem__c(
            Request_Type__c = type, Period_Leave__c = 'All day',
            Term_From__c = days[0],
            Term_To__c = (workingDays == 1 ? null : days[workingDays - 1]),
            Remark__c = 'cascade test', Status__c = status, OwnerId = employeeId()
        );
    }

    private static ApplicationItem__c reload(Id applId) {
        return [SELECT Request_Type__c, Leave_Days__c, Term_From__c, Term_To__c, Status__c,
                       Split_From__c
                FROM ApplicationItem__c WHERE Id = :applId];
    }

    /** The continuations of a request, earliest first — the order they were allocated. */
    private static List<ApplicationItem__c> continuationsOf(Id parentId) {
        return [SELECT Request_Type__c, Leave_Days__c, Term_From__c, Term_To__c, Status__c,
                       Split_From__c
                FROM ApplicationItem__c WHERE Split_From__c = :parentId
                ORDER BY Term_From__c];
    }

    private static Leave_Balance__c balance(String leaveType) {
        return [SELECT Id, Entitlement_Days__c, Used_Days__c, Available_Days__c,
                       Granted_On__c, Expiry_Date__c
                FROM Leave_Balance__c
                WHERE Employee__c = :employeeId() AND Leave_Type__c = :leaveType LIMIT 1];
    }

    // -------------------------------------------------------------------- the walk

    /*
     * The whole point of LEAVE-46. Ten days against three refresh and four annual comes
     * out 3 / 4 / 3, in date order, with the unpaid remainder last.
     */
    @isTest
    static void refreshOverflowsThroughAnnualBeforeReachingUnpaid() {
        useTestPolicies();
        List<Date> days = workdays(10);

        ApplicationItem__c appl = raise(REFRESH, 10, 'Draft');
        insert appl;

        ApplicationItem__c head = reload(appl.Id);
        System.assertEquals(REFRESH, head.Request_Type__c, 'the head keeps the type asked for');
        System.assertEquals(3, head.Leave_Days__c, 'three refresh days were available');
        System.assertEquals(days[2], head.Term_To__c, 'and it ends on the third working day');

        List<ApplicationItem__c> tail = continuationsOf(appl.Id);
        System.assertEquals(2, tail.size(), 'one annual stretch and one unpaid stretch');

        System.assertEquals(ANNUAL, tail[0].Request_Type__c);
        System.assertEquals(4, tail[0].Leave_Days__c, 'four annual days were available');
        System.assertEquals(days[3], tail[0].Term_From__c, 'starting the day after the refresh half');
        System.assertEquals(days[6], tail[0].Term_To__c);

        System.assertEquals(UNPAID, tail[1].Request_Type__c);
        System.assertEquals(3, tail[1].Leave_Days__c, 'and the last three are unpaid');
        System.assertEquals(days[7], tail[1].Term_From__c);
        System.assertEquals(days[9], tail[1].Term_To__c, 'the family still ends where the request did');
    }

    /*
     * The distinction from the behaviour that preceded it: the overflow does not go
     * straight to unpaid while there is still paid balance to spend.
     */
    @isTest
    static void nothingBecomesUnpaidWhileAnnualCanStillCoverIt() {
        useTestPolicies();
        setEntitlement(ANNUAL, 20);

        ApplicationItem__c appl = raise(REFRESH, 10, 'Draft');
        insert appl;

        List<ApplicationItem__c> tail = continuationsOf(appl.Id);
        System.assertEquals(1, tail.size(), 'annual absorbs the whole overflow');
        System.assertEquals(ANNUAL, tail[0].Request_Type__c);
        System.assertEquals(7, tail[0].Leave_Days__c, '10 asked for, 3 of them refresh');
        System.assertEquals(3, reload(appl.Id).Leave_Days__c);
    }

    @isTest
    static void aRequestInsideTheRefreshBalanceIsLeftAlone() {
        useTestPolicies();
        ApplicationItem__c appl = raise(REFRESH, 3, 'Draft');
        insert appl;

        System.assertEquals(REFRESH, reload(appl.Id).Request_Type__c);
        System.assertEquals(3, reload(appl.Id).Leave_Days__c);
        System.assertEquals(0, continuationsOf(appl.Id).size(), 'nothing raised beside it');
    }

    /*
     * No refresh balance at all. Creating an empty refresh record beside a full annual
     * one helps nobody, so the request itself becomes the annual one — the same move the
     * single-hop split made when it converted a request to Unpaid leave.
     */
    @isTest
    static void aRequestWithNoRefreshLeftBecomesAnAnnualOne() {
        useTestPolicies();
        setEntitlement(REFRESH, 0);

        ApplicationItem__c appl = raise(REFRESH, 3, 'Draft');
        insert appl;

        ApplicationItem__c head = reload(appl.Id);
        System.assertEquals(ANNUAL, head.Request_Type__c, 'moved down the chain, not split');
        System.assertEquals(3, head.Leave_Days__c, 'and it still covers every day asked for');
        System.assertEquals(0, continuationsOf(appl.Id).size());
    }

    /* Neither paid pool has anything, so the chain runs to its end in one hop. */
    @isTest
    static void withNoPaidBalanceAnywhereTheWholeRequestIsUnpaid() {
        useTestPolicies();
        setEntitlement(REFRESH, 0);
        setEntitlement(ANNUAL, 0);

        ApplicationItem__c appl = raise(REFRESH, 4, 'Draft');
        insert appl;

        System.assertEquals(UNPAID, reload(appl.Id).Request_Type__c);
        System.assertEquals(4, reload(appl.Id).Leave_Days__c);
        System.assertEquals(0, continuationsOf(appl.Id).size());
    }

    /* A part day at a boundary belongs to the next pool, not to a rounding rule. */
    @isTest
    static void aPartDayAtTheBoundaryPassesToTheNextPool() {
        useTestPolicies();
        setEntitlement(REFRESH, 2.5);
        setEntitlement(ANNUAL, 20);

        ApplicationItem__c appl = raise(REFRESH, 6, 'Draft');
        insert appl;

        System.assertEquals(2, reload(appl.Id).Leave_Days__c, 'two whole refresh days');
        System.assertEquals(4, continuationsOf(appl.Id)[0].Leave_Days__c, 'the rest to annual');

        // Nothing is spent until somebody approves it, so the half day is only proved
        // to have survived once the refresh segment has actually been taken.
        Test.startTest();
        update new ApplicationItem__c(Id = appl.Id, Status__c = 'Approved');
        Test.stopTest();

        System.assertEquals(2, balance(REFRESH).Used_Days__c);
        System.assertEquals(0.5, balance(REFRESH).Available_Days__c,
            'the half day stays in the balance rather than being rounded away');
    }

    // ------------------------------------------------------------ expiring grants

    /*
     * A refresh grant is good for a month. Days past its expiry cannot be funded by it
     * however much balance is left, so the run stops there and the rest cascades on.
     */
    @isTest
    static void refreshDaysBeyondTheExpiryCascadeToAnnual() {
        useTestPolicies();
        setEntitlement(REFRESH, 10);
        setEntitlement(ANNUAL, 20);
        List<Date> days = workdays(5);

        Leave_Balance__c refreshRow = balance(REFRESH);
        refreshRow.Granted_On__c = days[0].addDays(-7);
        refreshRow.Expiry_Date__c = days[1];          // only the first two days are inside
        update refreshRow;

        ApplicationItem__c appl = raise(REFRESH, 5, 'Draft');
        insert appl;

        ApplicationItem__c head = reload(appl.Id);
        System.assertEquals(2, head.Leave_Days__c,
            'ten days of balance, but the window closes after two of them');
        System.assertEquals(days[1], head.Term_To__c);

        List<ApplicationItem__c> tail = continuationsOf(appl.Id);
        System.assertEquals(1, tail.size());
        System.assertEquals(ANNUAL, tail[0].Request_Type__c);
        System.assertEquals(3, tail[0].Leave_Days__c);
        System.assertEquals(days[2], tail[0].Term_From__c);
    }

    /* A request that begins after the grant has lapsed draws nothing from it. */
    @isTest
    static void anExpiredGrantFundsNothingAtAll() {
        useTestPolicies();
        setEntitlement(REFRESH, 10);
        setEntitlement(ANNUAL, 20);
        List<Date> days = workdays(4);

        Leave_Balance__c refreshRow = balance(REFRESH);
        refreshRow.Granted_On__c = days[0].addDays(-40);
        refreshRow.Expiry_Date__c = days[0].addDays(-1);
        update refreshRow;

        ApplicationItem__c appl = raise(REFRESH, 4, 'Draft');
        insert appl;

        System.assertEquals(ANNUAL, reload(appl.Id).Request_Type__c);
        System.assertEquals(4, reload(appl.Id).Leave_Days__c);
        System.assertEquals(0, balance(REFRESH).Used_Days__c, 'the lapsed grant is untouched');
    }

    /* Annual and Sick carry no expiry, and must not be constrained as though they did. */
    @isTest
    static void aBalanceWithNoExpiryIsNotWindowed() {
        useTestPolicies();
        setEntitlement(REFRESH, 0);
        setEntitlement(ANNUAL, 20);
        System.assertEquals(null, balance(ANNUAL).Expiry_Date__c, 'the fixture sets none');

        ApplicationItem__c appl = raise(REFRESH, 6, 'Draft');
        insert appl;

        System.assertEquals(ANNUAL, reload(appl.Id).Request_Type__c);
        System.assertEquals(6, reload(appl.Id).Leave_Days__c, 'every day funded by annual');
    }

    // --------------------------------------------------------------- the deduction

    /* Each segment spends its own pool, and no pool is spent twice. */
    @isTest
    static void eachSegmentDeductsItsOwnBalanceOnApproval() {
        useTestPolicies();
        ApplicationItem__c appl = raise(REFRESH, 10, 'Draft');
        insert appl;

        List<ApplicationItem__c> family = new List<ApplicationItem__c>{ reload(appl.Id) };
        family.addAll(continuationsOf(appl.Id));
        for (ApplicationItem__c rec : family) {
            rec.Status__c = 'Approved';
        }

        Test.startTest();
        update family;
        Test.stopTest();

        System.assertEquals(3, balance(REFRESH).Used_Days__c);
        System.assertEquals(0, balance(REFRESH).Available_Days__c);
        System.assertEquals(4, balance(ANNUAL).Used_Days__c);
        System.assertEquals(0, balance(ANNUAL).Available_Days__c);
        System.assertEquals(3, balance(UNPAID).Used_Days__c);
        System.assertEquals(0, balance(UNPAID).Available_Days__c,
            'unpaid grants as it is used, so it never reads negative');
    }

    /*
     * The bug LEAVE-46 opens with. Refresh Leave was splittable by nothing and refused
     * by nothing, so ten days against three drove the balance to -7 and the page read
     * "-7 available". Here the chain is deliberately removed, which is exactly the
     * configuration that used to be silent — the approval must still refuse it.
     */
    @isTest
    static void anOverdrawIsRefusedEvenWhenNothingSplitsIt() {
        ApplicationItemTriggerLogic.policyOverride = new List<Leave_Type_Policy__mdt>{
            new Leave_Type_Policy__mdt(Leave_Type__c = REFRESH, Active__c = true,
                Deducts_Balance__c = true)   // no Overflow_To__c: nothing will split it
        };

        ApplicationItem__c appl = raise(REFRESH, 10, 'Draft');
        insert appl;
        System.assertEquals(0, continuationsOf(appl.Id).size(), 'nothing split it, as configured');

        Test.startTest();
        String message;
        try {
            update new ApplicationItem__c(Id = appl.Id, Status__c = 'Approved');
            System.assert(false, 'ten days against three must not be approved');
        } catch (DmlException e) {
            message = e.getDmlMessage(0);
        }
        Test.stopTest();

        System.assert(message.contains('only 3'), 'the refusal names what is left: ' + message);
        System.assert(message.contains('Shorten it'),
            'and offers the remedy for a type with nowhere to overflow: ' + message);
        System.assertEquals(0, balance(REFRESH).Used_Days__c, 'nothing was taken');
        System.assertEquals(3, balance(REFRESH).Available_Days__c, 'and nothing went negative');
    }

    /* With a chain configured the refusal points at the split instead. */
    @isTest
    static void anOverdrawOfASplittableTypeIsToldToSplit() {
        useTestPolicies();
        ApplicationItem__c appl = raise(REFRESH, 3, 'Draft');
        insert appl;
        // Spent behind the request's back, after the split measured the balance.
        Leave_Balance__c refreshRow = balance(REFRESH);
        refreshRow.Used_Days__c = 2;
        update refreshRow;

        Test.startTest();
        String message;
        try {
            update new ApplicationItem__c(Id = appl.Id, Status__c = 'Approved');
            System.assert(false, 'three days against one must not be approved');
        } catch (DmlException e) {
            message = e.getDmlMessage(0);
        }
        Test.stopTest();

        System.assert(message.contains('Annual leave request'),
            'the remedy names the pool it would overflow into: ' + message);
    }

    // ---------------------------------------------------------------- the rebuild

    /*
     * Rejecting the head frees its balance, and the survivors have to move up a place
     * each — the annual stretch back to refresh, the unpaid stretch to annual. Promoting
     * only the unpaid tail, which is what the single-hop version did, would have left
     * the annual stretch where it was and skipped the refresh days entirely.
     */
    @isTest
    static void rejectingTheHeadRebuildsTheRestOfTheFamily() {
        useTestPolicies();
        setEntitlement(ANNUAL, 3);

        ApplicationItem__c appl = raise(REFRESH, 9, 'Draft');
        insert appl;

        // 3 refresh + 3 annual + 3 unpaid before anything is refused.
        List<ApplicationItem__c> before = continuationsOf(appl.Id);
        System.assertEquals(2, before.size());
        System.assertEquals(ANNUAL, before[0].Request_Type__c);
        System.assertEquals(UNPAID, before[1].Request_Type__c);

        /*
         * Approved first, because only a record LEAVING Approved gives its balance back
         * — that transition is what the whole reversal path keys on. A request refused
         * straight out of Draft never took anything, so there is nothing to redistribute.
         */
        update new ApplicationItem__c(Id = appl.Id, Status__c = 'Approved');
        System.assertEquals(3, balance(REFRESH).Used_Days__c, 'the head took its three days');

        Test.startTest();
        update new ApplicationItem__c(Id = appl.Id, Status__c = 'Rejected');
        Test.stopTest();

        System.assertEquals(0, balance(REFRESH).Used_Days__c, 'and handed them straight back');

        System.assertEquals('Rejected', reload(appl.Id).Status__c, 'the head stays refused');

        /*
         * The survivors were merged onto the earlier of them and split again, so the
         * family is now nested rather than flat: what is left hangs off the promoted
         * record instead of off the rejected head. That is how the promotion path has
         * always rebuilt, and it is why the two are read separately here.
         */
        List<ApplicationItem__c> after = continuationsOf(appl.Id);
        System.assertEquals(1, after.size(), 'the two survivors were merged into one');
        System.assertEquals(REFRESH, after[0].Request_Type__c,
            'the refused refresh days are available again, so the survivor takes them');
        System.assertEquals(3, after[0].Leave_Days__c);

        List<ApplicationItem__c> rebuilt = continuationsOf(after[0].Id);
        System.assertEquals(1, rebuilt.size());
        System.assertEquals(ANNUAL, rebuilt[0].Request_Type__c,
            'and what was unpaid has moved up into annual');
        System.assertEquals(3, rebuilt[0].Leave_Days__c);

        System.assertEquals(0, [
            SELECT COUNT() FROM ApplicationItem__c
            WHERE OwnerId = :employeeId() AND Request_Type__c = :UNPAID
        ], 'nothing is unpaid any more: the freed refresh days covered the shortfall');
    }

    // ------------------------------------------------------------------- the chain

    @isTest
    static void theChainIsWalkedInOrderAndStops() {
        useTestPolicies();
        System.assertEquals(new List<String>{ REFRESH, ANNUAL, UNPAID },
            LeaveSplitService.chainFor(REFRESH));
        System.assertEquals(new List<String>{ ANNUAL, UNPAID },
            LeaveSplitService.chainFor(ANNUAL));
        System.assertEquals(new List<String>{ UNPAID },
            LeaveSplitService.chainFor(UNPAID), 'the end of the chain');
        System.assertEquals(0, LeaveSplitService.chainFor('No such type').size(),
            'a type with no policy row has no chain at all');
    }

    /* A cycle is a configuration mistake, and must not hang the save. */
    @isTest
    static void aCycleInTheConfigurationTerminates() {
        ApplicationItemTriggerLogic.policyOverride = new List<Leave_Type_Policy__mdt>{
            new Leave_Type_Policy__mdt(Leave_Type__c = ANNUAL, Active__c = true,
                Deducts_Balance__c = true, Overflow_To__c = REFRESH),
            new Leave_Type_Policy__mdt(Leave_Type__c = REFRESH, Active__c = true,
                Deducts_Balance__c = true, Overflow_To__c = ANNUAL)
        };

        System.assertEquals(new List<String>{ ANNUAL, REFRESH },
            LeaveSplitService.chainFor(ANNUAL), 'each type appears once and the walk stops');
    }
}
