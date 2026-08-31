@isTest
private class LeaveAccrualServiceTest {

    private static final Date JOINED_2020 = Date.newInstance(2020, 1, 1);

    // ------------------------------------------------------------------ the rule

    @isTest
    static void noJoiningDateAccruesNothing() {
        System.assertEquals(0, LeaveAccrualService.accruedFor(
            null, 2024, 'Upfront', 12, Date.newInstance(2024, 6, 15)),
            'An employee with no joining date cannot be measured, so nothing is earned.');
    }

    @isTest
    static void futureLeaveYearAccruesNothing() {
        System.assertEquals(0, LeaveAccrualService.accruedFor(
            JOINED_2020, 2025, 'Upfront', 12, Date.newInstance(2024, 6, 15)),
            'A year that has not started yet has earned nothing, whatever the method.');
    }

    @isTest
    static void closedYearReadsFullEntitlement() {
        // Monthly, and deliberately measured in January so a calendar-derived accrual
        // would come out at one day. The year is over; what was granted was earned.
        System.assertEquals(12, LeaveAccrualService.accruedFor(
            JOINED_2020, 2023, 'Monthly', 12, Date.newInstance(2024, 1, 5)),
            'A closed year reads its full entitlement rather than re-deriving it.');
    }

    @isTest
    static void upfrontAndBlankMethodsReadFullEntitlement() {
        Date midYear = Date.newInstance(2024, 2, 3);
        System.assertEquals(30, LeaveAccrualService.accruedFor(
            JOINED_2020, 2024, 'Upfront', 30, midYear),
            'Upfront is granted in full on day one.');
        System.assertEquals(3, LeaveAccrualService.accruedFor(
            JOINED_2020, 2024, null, 3, midYear),
            'A blank method is not an accrual, so the entitlement stands in full.');
        System.assertEquals(6, LeaveAccrualService.accruedFor(
            JOINED_2020, 2024, 'Anniversary', 6, midYear),
            'Refreshment is granted on the anniversary, not accrued month by month.');
    }

    @isTest
    static void continuingEmployeeIsCreditedOnTheFirstOfTheMonth() {
        System.assertEquals(4, LeaveAccrualService.accruedFor(
            JOINED_2020, 2024, 'Monthly', 12, Date.newInstance(2024, 4, 30)),
            'End of April is four days: the day for May has not been reached yet.');
        System.assertEquals(5, LeaveAccrualService.accruedFor(
            JOINED_2020, 2024, 'Monthly', 12, Date.newInstance(2024, 5, 1)),
            'The 1st is when it lands for somebody already in service.');
        System.assertEquals(5, LeaveAccrualService.accruedFor(
            JOINED_2020, 2024, 'Monthly', 12, Date.newInstance(2024, 5, 15)),
            'And it does not move again during the month.');
    }

    @isTest
    static void continuingEmployeeIsNotPaidTwiceAtMonthEnd() {
        System.assertEquals(5, LeaveAccrualService.accruedFor(
            JOINED_2020, 2024, 'Monthly', 12, Date.newInstance(2024, 5, 31)),
            'May was already credited on 1 May. Crediting month end as well would pay '
            + 'the same month twice and hand over June a day early.');
    }

    @isTest
    static void continuingEmployeeOpensTheYearWithADayAndIsFullByDecember() {
        System.assertEquals(1, LeaveAccrualService.accruedFor(
            JOINED_2020, 2024, 'Monthly', 12, Date.newInstance(2024, 1, 1)),
            'January opens with January already earned.');
        System.assertEquals(11, LeaveAccrualService.accruedFor(
            JOINED_2020, 2024, 'Monthly', 12, Date.newInstance(2024, 11, 30)),
            'Eleven by the end of November.');
        System.assertEquals(12, LeaveAccrualService.accruedFor(
            JOINED_2020, 2024, 'Monthly', 12, Date.newInstance(2024, 12, 1)),
            'The twelfth lands on 1 December, not on New Year\'s Eve.');
    }

    @isTest
    static void continuingEmployeeIsUnaffectedByMonthLength() {
        // The month-end bump is what made February interesting, and nothing has one now.
        System.assertEquals(2, LeaveAccrualService.accruedFor(
            JOINED_2020, 2024, 'Monthly', 12, Date.newInstance(2024, 2, 28)),
            'Two days all through February, leap year or not.');
        System.assertEquals(2, LeaveAccrualService.accruedFor(
            JOINED_2020, 2024, 'Monthly', 12, Date.newInstance(2024, 2, 29)),
            'The extra day of a leap February changes nothing here.');
    }

    @isTest
    static void joinerIsCreditedOnTheFirstOfTheJoiningMonth() {
        Date joinedJuly = Date.newInstance(2024, 7, 10);
        System.assertEquals(1, LeaveAccrualService.accruedFor(
            joinedJuly, 2024, 'Monthly', 6, Date.newInstance(2024, 7, 10)),
            'A joiner holds a day the day they join: the joining month is credited at '
            + 'its start, exactly as every other month is.');
        System.assertEquals(1, LeaveAccrualService.accruedFor(
            joinedJuly, 2024, 'Monthly', 6, Date.newInstance(2024, 7, 31)),
            'And month end adds nothing on top — July was credited once already.');
    }

    @isTest
    static void joinerIsUnaffectedByMonthLength() {
        // February was the interesting case only because the joiner branch carried a
        // last-day-of-month bump. It no longer does, so February reads like any month.
        Date joinedJan2024 = Date.newInstance(2024, 1, 10);
        System.assertEquals(2, LeaveAccrualService.accruedFor(
            joinedJan2024, 2024, 'Monthly', 12, Date.newInstance(2024, 2, 1)),
            'February is earned on the 1st, not at the end.');
        System.assertEquals(2, LeaveAccrualService.accruedFor(
            joinedJan2024, 2024, 'Monthly', 12, Date.newInstance(2024, 2, 29)),
            'The extra day of a leap February changes nothing.');
        System.assertEquals(2, LeaveAccrualService.accruedFor(
            Date.newInstance(2023, 1, 10), 2023, 'Monthly', 12, Date.newInstance(2023, 2, 28)),
            'Nor does the last day of a common February.');
    }

    @isTest
    static void monthlyForAJoinerCountsFromTheJoiningMonth() {
        Date joinedJuly = Date.newInstance(2024, 7, 10);
        System.assertEquals(3, LeaveAccrualService.accruedFor(
            joinedJuly, 2024, 'Monthly', 6, Date.newInstance(2024, 9, 15)),
            'A July joiner holds July, August and September by mid-September — counted '
            + 'from the joining month, not from January.');
    }

    @isTest
    static void joinerTopsOutAtTheProRatedEntitlementAndNoSooner() {
        Date joinedMarch = Date.newInstance(2026, 3, 19);
        System.assertEquals(6, LeaveAccrualService.accruedFor(
            joinedMarch, 2026, 'Monthly', 10, Date.newInstance(2026, 8, 25)),
            'March through August inclusive is six days, not five: August is credited on '
            + 'the 1st rather than the 31st.');
        System.assertEquals(10, LeaveAccrualService.accruedFor(
            joinedMarch, 2026, 'Monthly', 10, Date.newInstance(2026, 12, 1)),
            'The tenth and last day lands on 1 December. Crediting the month in progress '
            + 'brings the entitlement forward by a month, it does not overpay it.');
    }

    @isTest
    static void monthlyNeverGoesNegativeBeforeTheJoiningMonth() {
        // A row created in advance for somebody joining in November, read in March.
        System.assertEquals(0, LeaveAccrualService.accruedFor(
            Date.newInstance(2024, 11, 4), 2024, 'Monthly', 2, Date.newInstance(2024, 3, 15)),
            'Months before the joining month are not a debt.');
    }

    @isTest
    static void monthlyIsCappedAtTheEntitlement() {
        System.assertEquals(3, LeaveAccrualService.accruedFor(
            JOINED_2020, 2024, 'Monthly', 3, Date.newInstance(2024, 12, 31)),
            'Twelve months earned against a three day entitlement is still three days.');
        System.assertEquals(0, LeaveAccrualService.accruedFor(
            JOINED_2020, 2024, 'Monthly', null, Date.newInstance(2024, 12, 31)),
            'A blank entitlement is a zero ceiling, not an unlimited one.');
    }

    @isTest
    static void availableIsAccruedPlusCarriedInLessUsed() {
        System.assertEquals(8, LeaveAccrualService.availableFor(6, 4, 2),
            'Accrued + carried in - used.');
        System.assertEquals(0, LeaveAccrualService.availableFor(null, null, null),
            'Blanks count as zero rather than making the whole figure null.');
        System.assertEquals(-3, LeaveAccrualService.availableFor(2, 0, 5),
            'Overdrawn reads negative; hiding that would hide the overdraft.');
    }

    @isTest
    static void aBlankFigureCountsAsMovedEvenWhenTheAnswerIsZero() {
        // The shape a recreated field leaves behind: real inputs, blank derived figures.
        Leave_Balance__c bal = new Leave_Balance__c(
            Leave_Year__c       = 2024,
            Accrual_Method__c   = 'Monthly',
            Entitlement_Days__c = 12,
            Carry_Over_Days__c  = 0,
            Used_Days__c        = 0
        );
        // Measured before the employee joined, which is one of the few ways a Monthly
        // row genuinely reads zero now that every row opens its first month with a day.
        Date joinedNovember = Date.newInstance(2024, 11, 4);
        Date midMarch = Date.newInstance(2024, 3, 15);

        System.assert(LeaveAccrualService.applyTo(bal, joinedNovember, midMarch),
            'A blank figure is always wrong, even when the answer happens to be zero — '
            + 'reading it as zero would leave the backfill nothing to write.');
        System.assertEquals(0, bal.Accrued_To_Date__c, 'Nothing earned before joining.');
        System.assertEquals(0, bal.Available_Balance__c, 'And nothing available.');

        System.assertEquals(false, LeaveAccrualService.applyTo(bal, joinedNovember, midMarch),
            'Second time round the figures are filled and unchanged, so nothing moved.');
    }

    // ------------------------------------------------------------------ plumbing

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String stamp = String.valueOf(DateTime.now().getTime());
        User employee = new User(
            FirstName = 'Accrual',
            LastName = 'ACCEMP',
            Email = 'accemp' + stamp + '@example.com',
            Username = 'accemp' + stamp + '@example.com.acctest',
            Alias = 'aemp',
            CompanyName = 'ACCEMP',
            TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = p.Id,
            LanguageLocaleKey = 'en_US',
            Start_Date__c = JOINED_2020
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert employee;
        }
    }

    private static Id employeeId() {
        return [SELECT Id FROM User WHERE CompanyName = 'ACCEMP' LIMIT 1].Id;
    }

    private static Leave_Balance__c row(String leaveType, Integer yr, String method,
                                        Decimal entitlement, Decimal carryOver, Decimal used) {
        Id ownerId = employeeId();
        return new Leave_Balance__c(
            Employee__c         = ownerId,
            Leave_Type__c       = leaveType,
            Leave_Year__c       = yr,
            External_Key__c     = ownerId + '-' + leaveType + '-' + yr,
            Entitlement_Days__c = entitlement,
            Accrual_Method__c   = method,
            Carry_Over_Days__c  = carryOver,
            Used_Days__c        = used,
            Pending_Days__c     = 0,
            Status__c           = 'Active'
        );
    }

    private static Leave_Balance__c reload(Id balanceId) {
        return [
            SELECT Accrued_To_Date__c, Available_Balance__c
            FROM Leave_Balance__c WHERE Id = :balanceId
        ];
    }

    @isTest
    static void insertStampsBothFigures() {
        Leave_Balance__c bal = row('Sick leave', System.today().year(), 'Upfront', 30, 0, 4);

        Test.startTest();
        insert bal;
        Test.stopTest();

        Leave_Balance__c saved = reload(bal.Id);
        System.assertEquals(30, saved.Accrued_To_Date__c,
            'The trigger fills the accrual on insert; nothing else was going to.');
        System.assertEquals(26, saved.Available_Balance__c, '30 accrued less 4 used.');
    }

    @isTest
    static void spendingDaysMovesAvailableOnTheSameSave() {
        Leave_Balance__c bal = row('Sick leave', System.today().year(), 'Upfront', 30, 0, 0);
        insert bal;

        Test.startTest();
        update new Leave_Balance__c(Id = bal.Id, Used_Days__c = 7);
        Test.stopTest();

        Leave_Balance__c saved = reload(bal.Id);
        System.assertEquals(30, saved.Accrued_To_Date__c, 'Spending days does not change the accrual.');
        System.assertEquals(23, saved.Available_Balance__c,
            'Available follows Used on the same DML, with no second write from the caller.');
    }

    @isTest
    static void handEditedFiguresAreOverwrittenOnSave() {
        Leave_Balance__c bal = row('Sick leave', System.today().year(), 'Upfront', 30, 0, 0);
        insert bal;

        Test.startTest();
        // What somebody typing into the record page would do, if the field were editable.
        update new Leave_Balance__c(Id = bal.Id, Accrued_To_Date__c = 999, Available_Balance__c = 999);
        Test.stopTest();

        Leave_Balance__c saved = reload(bal.Id);
        System.assertEquals(30, saved.Accrued_To_Date__c,
            'These are derived figures, so a hand edit cannot survive the save.');
        System.assertEquals(30, saved.Available_Balance__c, 'Same for Available.');
    }

    @isTest
    static void sweepCatchesTheCalendarMovingWithNoSave() {
        Integer yr = System.today().year();
        // The clock is pinned BEFORE the insert, so the row is stamped with a January
        // accrual whatever the real date happens to be when this test runs.
        LeaveAccrualService.todayOverride = Date.newInstance(yr, 1, 15);
        Leave_Balance__c bal = row('Annual leave', yr, 'Monthly', 12, 3, 1);
        insert bal;
        System.assertEquals(1, reload(bal.Id).Accrued_To_Date__c,
            'Mid-January a continuing employee holds January\'s day — the starting '
            + 'point for the sweep.');

        Test.startTest();
        // Travel to 31 December of the same leave year without touching the record —
        // exactly the situation no trigger can see.
        LeaveAccrualService.todayOverride = Date.newInstance(yr, 12, 31);
        Integer moved = LeaveAccrualService.sweep(LeaveAccrualService.asOfDate());
        Test.stopTest();

        System.assertEquals(1, moved, 'The one row whose figures moved is the one that was saved.');
        Leave_Balance__c saved = reload(bal.Id);
        System.assertEquals(12, saved.Accrued_To_Date__c,
            'Twelve completed months by 31 December, capped at the entitlement.');
        System.assertEquals(14, saved.Available_Balance__c, '12 accrued plus 3 carried in less 1 used.');
    }

    @isTest
    static void sweepWritesNothingWhenNothingMoved() {
        Integer yr = System.today().year();
        LeaveAccrualService.todayOverride = Date.newInstance(yr, 5, 15);
        insert row('Annual leave', yr, 'Monthly', 12, 0, 0);

        Test.startTest();
        Integer moved = LeaveAccrualService.sweep(LeaveAccrualService.asOfDate());
        Test.stopTest();

        System.assertEquals(0, moved,
            'Run twice against the same date the sweep must be a no-op, or it would '
            + 'rewrite every balance in the org every night.');
    }

    @isTest
    static void sweepLeavesClosedRowsAlone() {
        Integer yr = System.today().year();
        LeaveAccrualService.todayOverride = Date.newInstance(yr, 1, 15);

        Leave_Balance__c active = row('Annual leave', yr, 'Monthly', 12, 0, 0);
        // A second Monthly row that would move by exactly as much, but is settled.
        Leave_Balance__c closed = row('Personal leave', yr, 'Monthly', 12, 0, 0);
        closed.Status__c = 'Closed';
        insert new List<Leave_Balance__c>{ active, closed };

        Test.startTest();
        LeaveAccrualService.todayOverride = Date.newInstance(yr, 12, 31);
        Integer moved = LeaveAccrualService.sweep(LeaveAccrualService.asOfDate());
        Test.stopTest();

        System.assertEquals(1, moved, 'Only the active row is swept.');
        System.assertEquals(12, reload(active.Id).Accrued_To_Date__c, 'The active row moved.');
        System.assertEquals(1, reload(closed.Id).Accrued_To_Date__c,
            'Still the single day it was stamped with in January: a closed year is '
            + 'settled and the sweep must not reopen it.');
    }
}