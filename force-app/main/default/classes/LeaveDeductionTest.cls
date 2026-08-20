@isTest
private class LeaveDeductionTest {

    /*
     * balance deduction against Leave_Balance__c.
     *
     * Rewritten from the User-field version. Balances no longer live on a setup
     * object, so there is no @future and no need to assert after Test.stopTest();
     * the balance write is part of the same transaction as the approval.
     *
     * Classification comes from the org's real Leave_Type_Policy__mdt rows, so these
     * tests also assert that the configuration is right, not only the code.
     */

    private static final Date MONDAY_EPOCH = Date.newInstance(1900, 1, 1);
    private static Id cachedUserId;

    private static Id testUserId() {
        if (cachedUserId == null) {
            cachedUserId = [SELECT Id FROM User WHERE CompanyName = 'LEAVETEST' LIMIT 1].Id;
        }
        return cachedUserId;
    }

    private static Integer testYear() {
        return System.today().year();
    }

    /** A fixed weekday-agnostic date: single-day requests ignore weekends entirely. */
    private static Date singleDate() {
        return Date.newInstance(testYear(), 3, 2);
    }

    private static Date mondayInTestYear() {
        Date d = Date.newInstance(testYear(), 3, 2);
        Integer dayOfWeek = Math.mod(MONDAY_EPOCH.daysBetween(d), 7);
        return d.addDays(Math.mod(7 - dayOfWeek, 7));
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniqueName = 'deduct' + DateTime.now().getTime();
        User u = new User(
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
            Start_Date__c = Date.newInstance(2020, 1, 1)
        );
        // User is a setup object. Wrapping the insert in runAs lets the Leave_Balance__c
        // inserts below run in the same test setup without MIXED_DML_OPERATION.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }

        Integer yr = System.today().year();
        insert new List<Leave_Balance__c>{
            /*
             * Upfront rather than the production Monthly. Accrued_Days__c is
             * a formula over TODAY(), so under Monthly the annual balance would be 3
             * days in January and 15 in December — and now that a shortfall is stopped
             * at approval, the multi-day tests below would pass or fail depending on
             * the month the suite ran in. Nothing here asserts on accrual, so pinning
             * it removes the seasonality without weakening the tests.
             */
            balanceRow(u.Id, 'Annual leave',   yr, 12, 'Upfront',     3),
            balanceRow(u.Id, 'Refresh Leave',  yr, 2,  'Anniversary', 0),
            balanceRow(u.Id, 'Sick leave',     yr, 30, 'Upfront',     0),
            balanceRow(u.Id, 'Personal leave', yr, 3,  'Upfront',     0),
            // Unpaid leave now deducts too, so it needs a row like any other
            // type. Entitlement stays at zero - it is granted as it is used.
            balanceRow(u.Id, 'Unpaid leave',   yr, 0,  'Upfront',     0),
            /*
             * The Grants_On_Use__c types. They deduct like any other, so a missing row
             * is now a hard error at approval rather than a silent no-op — which is why
             * they are created here. Zero entitlement is the point: approval raises it
             * by the days taken. The grant engine writes a row for every active policy
             * in production, so this mirrors it rather than inventing a fixture.
             */
            balanceRow(u.Id, 'Bereavement leave', yr, 0, null, 0),
            balanceRow(u.Id, 'Maternity leave',   yr, 0, null, 0),
            balanceRow(u.Id, 'Other',             yr, 0, null, 0)
        };
    }

    private static Leave_Balance__c balanceRow(Id ownerId, String leaveType, Integer yr,
                                               Decimal entitlement, String accrual, Decimal carryOver) {
        return new Leave_Balance__c(
            Employee__c         = ownerId,
            Leave_Type__c       = leaveType,
            Leave_Year__c       = yr,
            External_Key__c     = ownerId + '-' + leaveType + '-' + yr,
            Entitlement_Days__c = entitlement,
            Accrual_Method__c   = accrual,
            Carry_Over_Days__c  = carryOver,
            Used_Days__c        = 0,
            Pending_Days__c     = 0,
            Status__c           = 'Active'
        );
    }

    private static Leave_Balance__c balance(String leaveType) {
        return [
            SELECT Used_Days__c, Carry_Over_Days__c, Entitlement_Days__c, Available_Days__c
            FROM Leave_Balance__c
            WHERE Employee__c = :testUserId() AND Leave_Type__c = :leaveType
            LIMIT 1
        ];
    }

    private static ApplicationItem__c request(String type, String period) {
        return new ApplicationItem__c(
            Request_Type__c = type,
            Period_Leave__c = period,
            Term_From__c    = singleDate(),
            Remark__c       = 'deduction test',
            Status__c       = 'Pending',
            OwnerId         = testUserId()
        );
    }

    private static void approve(ApplicationItem__c appl) {
        appl.Status__c = 'Approved';
        update appl;
    }

    private static Decimal carryAttribution(Id applId) {
        return [SELECT Carry_Over_Days_Used__c FROM ApplicationItem__c WHERE Id = :applId].Carry_Over_Days_Used__c;
    }

    // ---------------------------------------------------------------- day counting

    @isTest
    static void singleDayRequestCountsOneDay() {
        ApplicationItem__c appl = request('Annual leave', 'All day');
        insert appl;
        System.assertEquals(1, [SELECT Leave_Days__c FROM ApplicationItem__c WHERE Id = :appl.Id].Leave_Days__c,
            'a request with no end date is a single day');
    }

    @isTest
    static void halfDayCountsAsHalfADay() {
        ApplicationItem__c appl = request('Annual leave', 'AM leave');
        insert appl;
        approve(appl);

        System.assertEquals(0.5, [SELECT Leave_Days__c FROM ApplicationItem__c WHERE Id = :appl.Id].Leave_Days__c,
            'AM leave is half a day');
        System.assertEquals(0.5, balance('Annual leave').Used_Days__c, 'half a day is consumed');
    }

    @isTest
    static void multiDayRangeCountsWorkingDaysOnly() {
        Date mon = mondayInTestYear();
        Date nextMon = mon.addDays(7);
        Integer holidays = [SELECT COUNT() FROM Holiday
                            WHERE ActivityDate >= :mon AND ActivityDate <= :nextMon];

        ApplicationItem__c appl = request('Annual leave', 'All day');
        appl.Term_From__c = mon;
        appl.Term_To__c   = nextMon;
        insert appl;

        System.assertEquals(6 - holidays,
            [SELECT Leave_Days__c FROM ApplicationItem__c WHERE Id = :appl.Id].Leave_Days__c,
            'Monday to the following Monday is six working days, excluding both weekend days');
    }

    @isTest
    static void multiDayRequestDeductsEveryWorkingDay() {
        Date mon = mondayInTestYear();
        Date fri = mon.addDays(4);
        Integer holidays = [SELECT COUNT() FROM Holiday
                            WHERE ActivityDate >= :mon AND ActivityDate <= :fri];

        ApplicationItem__c appl = request('Annual leave', 'All day');
        appl.Term_From__c = mon;
        appl.Term_To__c   = fri;
        insert appl;
        approve(appl);

        System.assertEquals(5 - holidays, balance('Annual leave').Used_Days__c,
            'the whole range is deducted, not just the first day');
    }

    // ---------------------------------------------------------------- deduction

    @isTest
    static void annualLeaveIncrementsUsedOnItsOwnRow() {
        ApplicationItem__c appl = request('Annual leave', 'All day');
        insert appl;
        approve(appl);

        System.assertEquals(1, balance('Annual leave').Used_Days__c, 'one day is consumed');
        System.assertEquals(3, balance('Annual leave').Carry_Over_Days__c,
            'carried-in carry over is fixed for the year and is not decremented');
        System.assertEquals(1, carryAttribution(appl.Id),
            'the day is attributed to carry over, which is consumed first');
    }

    @isTest
    static void carryOverAttributionStopsAtTheCarriedInAmount() {
        // 3 carry over days available, 4 requested across one batch
        List<ApplicationItem__c> batch = new List<ApplicationItem__c>();
        for (Integer i = 0; i < 4; i++) {
            ApplicationItem__c appl = request('Annual leave', 'All day');
            appl.Term_From__c = singleDate().addDays(i);
            batch.add(appl);
        }
        insert batch;

        for (ApplicationItem__c appl : batch) {
            appl.Status__c = 'Approved';
        }
        update batch;

        System.assertEquals(4, balance('Annual leave').Used_Days__c, 'all four days are consumed');

        Decimal totalFromCarry = 0;
        for (ApplicationItem__c appl : [SELECT Carry_Over_Days_Used__c FROM ApplicationItem__c WHERE Id IN :batch]) {
            totalFromCarry += appl.Carry_Over_Days_Used__c;
        }
        System.assertEquals(3, totalFromCarry,
            'attribution across the batch adds up to exactly the carry over carried in');
    }

    @isTest
    static void refreshLeaveOnlyTouchesItsOwnRow() {
        ApplicationItem__c appl = request('Refresh Leave', 'All day');
        insert appl;
        approve(appl);

        System.assertEquals(1, balance('Refresh Leave').Used_Days__c, 'refresh leave draws from its own row');
        System.assertEquals(0, balance('Annual leave').Used_Days__c, 'the annual row is untouched');
        System.assertEquals(0, carryAttribution(appl.Id), 'only annual leave attributes to carry over');
    }

    @isTest
    static void sickAndPersonalUseTheirOwnRows() {
        /*
         * LEAVE-42 gave Personal leave a document requirement from day zero, which
         * refuses any Personal leave request created already Pending. This test is
         * about which balance row the deduction lands on, so the document gate is
         * stood down rather than satisfied with a file that proves nothing here.
         */
        LeaveDocumentPolicy.bypassOverride = true;
        ApplicationItem__c sick = request('Sick leave', 'All day');
        ApplicationItem__c personal = request('Personal leave', 'PM leave');
        insert new List<ApplicationItem__c>{ sick, personal };

        sick.Status__c = 'Approved';
        personal.Status__c = 'Approved';
        update new List<ApplicationItem__c>{ sick, personal };

        System.assertEquals(1, balance('Sick leave').Used_Days__c, 'sick leave uses the sick row');
        System.assertEquals(0.5, balance('Personal leave').Used_Days__c, 'personal leave uses the personal row');
        System.assertEquals(0, balance('Annual leave').Used_Days__c, 'neither touches the annual row');
    }

    /*
     * Statutory leave is an entitlement per occasion, not an annual allowance, so there
     * is no pool to run down. Approval grants the days it takes: the row keeps a true
     * count of what has been used and never reads negative, which is the same treatment
     * gave Unpaid leave and is now driven by Grants_On_Use__c rather than by a
     * hardcoded type name.
     *
     * This replaces statutoryLeaveDeductsNothing, which asserted the previous
     * configuration: those types had Deducts_Balance__c false and were recorded without
     * touching a balance at all, so nothing anywhere counted how much had been taken.
     */
    @isTest
    static void statutoryLeaveGrantsItselfAsItIsTaken() {
        List<ApplicationItem__c> batch = new List<ApplicationItem__c>{
            request('Bereavement leave', 'All day'),
            request('Maternity leave', 'All day'),
            request('Other', 'All day')
        };
        insert batch;

        for (ApplicationItem__c appl : batch) {
            appl.Status__c = 'Approved';
        }
        update batch;

        for (String leaveType : new List<String>{ 'Bereavement leave', 'Maternity leave', 'Other' }) {
            Leave_Balance__c row = balance(leaveType);
            System.assertEquals(1, row.Used_Days__c, leaveType + ': the day is counted');
            System.assertEquals(1, row.Entitlement_Days__c,
                leaveType + ': entitlement is granted as it is used');
            System.assertEquals(0, row.Available_Days__c,
                leaveType + ': so the row never reads negative');
        }

        System.assertEquals(0, balance('Annual leave').Used_Days__c,
            'and none of it leaks into a pooled row');
        System.assertEquals(0, balance('Sick leave').Used_Days__c);
    }

    /*
     * The half day matters: grant-on-use adds exactly what was taken, so a 0.5 day
     * request must leave the row at 0.5 used and 0.5 granted, not rounded to a whole day.
     */
    @isTest
    static void grantOnUseFollowsAHalfDayExactly() {
        ApplicationItem__c appl = request('Bereavement leave', 'AM leave');
        insert appl;
        approve(appl);

        Leave_Balance__c row = balance('Bereavement leave');
        System.assertEquals(0.5, row.Used_Days__c, 'half a day taken');
        System.assertEquals(0.5, row.Entitlement_Days__c, 'and half a day granted');
        System.assertEquals(0, row.Available_Days__c, 'leaving the row at zero');
    }

    @isTest
    static void unpaidLeaveTakenDirectlyIsCountedToo() {
        /*
         * moved Unpaid leave out of the statutory group above. It now deducts
         * like any other type, so a day booked deliberately as unpaid lands on the same
         * row as a day converted by the splitter — one honest total of unpaid days.
         */
        ApplicationItem__c appl = request('Unpaid leave', 'All day');
        insert appl;
        approve(appl);

        Leave_Balance__c unpaid = [
            SELECT Used_Days__c, Entitlement_Days__c, Available_Days__c
            FROM Leave_Balance__c
            WHERE Employee__c = :testUserId() AND Leave_Type__c = 'Unpaid leave' LIMIT 1
        ];
        System.assertEquals(1, unpaid.Used_Days__c, 'the day is counted');
        System.assertEquals(1, unpaid.Entitlement_Days__c, 'entitlement is granted as it is used');
        System.assertEquals(0, unpaid.Available_Days__c, 'so the row never reads negative');
        System.assertEquals(0, balance('Annual leave').Used_Days__c, 'and no paid balance is touched');
    }

    @isTest
    static void overspendSplitsIntoAnUnpaidRequest() {
        /*
         * This assertion has been rewritten twice, which is worth recording.
         *
         * Originally it asserted that approval sailed through and drove Used_Days__c
         * past the entitlement — a balance that could go arbitrarily negative was the
         * bug, not the feature.  replaced that with a Managing Director gate on
         * the same record. replaced the gate with a split: the request is cut
         * down to what the balance covers and the remainder becomes its own Unpaid
         * leave record, which is an ordinary request needing an ordinary approval.
         *
         * 12 entitlement + 3 carry over = 15 available, against a four-week range.
         */
        Date mon = mondayInTestYear();
        ApplicationItem__c appl = request('Annual leave', 'All day');
        appl.Term_From__c = mon;
        appl.Term_To__c   = mon.addDays(27);
        insert appl;

        ApplicationItem__c original = [SELECT Leave_Days__c, Term_To__c FROM ApplicationItem__c
                                       WHERE Id = :appl.Id];
        System.assertEquals(15, original.Leave_Days__c,
            'the original is cut down to exactly what the balance covers');

        ApplicationItem__c unpaid = [SELECT Request_Type__c, Leave_Days__c, Term_From__c, Split_From__c
                                     FROM ApplicationItem__c WHERE Split_From__c = :appl.Id];
        System.assertEquals('Unpaid leave', unpaid.Request_Type__c,
            'the remainder is raised as unpaid leave');
        System.assert(unpaid.Term_From__c > original.Term_To__c,
            'the unpaid days are the tail, picking up where the paid ones stop');

        /*
         * Approved by Id, not by pushing the in-memory copy back. That copy still
         * carries the end date the employee typed, and saving it would undo the
         * shortening the split just applied — which the backstop in deductLeaveBalance
         * then refuses, correctly but confusingly.
         */
        update new ApplicationItem__c(Id = appl.Id, Status__c = 'Approved');
        System.assertEquals(15, balance('Annual leave').Used_Days__c,
            'approval now empties the balance exactly, never past it');
    }

    // ---------------------------------------------------------------- guards

    @isTest
    static void anApprovedRequestCannotBeEdited() {
        /*
         * closed this off entirely. It used to assert that a second save did
         * not deduct a second time, which was true but not enough: the edit still
         * rewrote Leave_Days__c without touching the balance, so the record and the
         * balance drifted apart. An approved request is now settled and refuses changes.
         */
        ApplicationItem__c appl = request('Annual leave', 'All day');
        insert appl;
        approve(appl);

        try {
            update new ApplicationItem__c(Id = appl.Id, Remark__c = 'edited after approval');
            System.assert(false, 'an approved request must not be editable');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('cannot be changed'),
                'the error should say the request is settled: ' + e.getMessage());
        }
        System.assertEquals(1, balance('Annual leave').Used_Days__c, 'and the balance is untouched');
    }

    @isTest
    static void anApprovedRequestCanStillBeRejected() {
        ApplicationItem__c appl = request('Annual leave', 'All day');
        insert appl;
        approve(appl);

        // The one change the lock allows, because it reverses everything behind it.
        update new ApplicationItem__c(Id = appl.Id, Status__c = 'Rejected');

        System.assertEquals(0, balance('Annual leave').Used_Days__c,
            'rejecting is the way out, and it gives the day back');
    }

    @isTest
    static void insertedAsApprovedDeductsOnce() {
        ApplicationItem__c appl = request('Annual leave', 'All day');
        appl.Status__c = 'Approved';
        insert appl;

        System.assertEquals(1, balance('Annual leave').Used_Days__c,
            'a record created already approved deducts exactly once');
    }

    @isTest
    static void pendingAndRejectedRequestsDeductNothing() {
        ApplicationItem__c pending = request('Annual leave', 'All day');
        ApplicationItem__c rejected = request('Annual leave', 'All day');
        insert new List<ApplicationItem__c>{ pending, rejected };

        rejected.Status__c = 'Rejected';
        update rejected;

        System.assertEquals(0, balance('Annual leave').Used_Days__c,
            'nothing is consumed before approval, and a rejected request never consumed anything');
    }

    @isTest
    static void unknownLeaveTypeIsRejected() {
        // No policy rows at all, so every type is unclassified.
        ApplicationItemTriggerLogic.policyOverride = new List<Leave_Type_Policy__mdt>();

        ApplicationItem__c appl = request('Annual leave', 'All day');
        appl.Status__c = 'Approved';
        try {
            insert appl;
            System.assert(false, 'an unclassified leave type must not be approvable');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('Leave Type Policy'),
                'the error should name the missing policy record: ' + e.getMessage());
        }
    }

    @isTest
    static void missingBalanceRowIsRejected() {
        delete [SELECT Id FROM Leave_Balance__c
                WHERE Employee__c = :testUserId() AND Leave_Type__c = 'Annual leave'];

        ApplicationItem__c appl = request('Annual leave', 'All day');
        appl.Status__c = 'Approved';
        try {
            insert appl;
            System.assert(false, 'approval must not silently succeed with no balance row');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('balance exists'),
                'the error should say the balance row is missing: ' + e.getMessage());
        }
    }
}