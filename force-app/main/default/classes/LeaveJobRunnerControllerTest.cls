@isTest
private class LeaveJobRunnerControllerTest {

    /*
     * LEAVE-49 — the temporary year-end test harness.
     *
     * The behaviour worth pinning is not the arithmetic, which is
     * LeaveManagementControllerTest's job. It is the three things that make the screen
     * safe to hand to somebody: that it refuses outside a sandbox, that a preview really
     * does roll back, and that a committed run really does not.
     */

    private static final String ANNUAL = 'Annual leave';

    private static Id cachedUserId;

    private static Id employeeId() {
        if (cachedUserId == null) {
            cachedUserId = [SELECT Id FROM User WHERE CompanyName = 'JOBRUNTEST' LIMIT 1].Id;
        }
        return cachedUserId;
    }

    private static Integer priorYear() {
        return System.today().year();
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'jobrun' + DateTime.now().getTime();
        User u = new User(
            FirstName = 'Job', LastName = 'Runner',
            Email = unique + '@example.com', Username = unique + '@example.com.jobruntest',
            Alias = 'jrun', CompanyName = 'JOBRUNTEST', TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', ProfileId = p.Id,
            LanguageLocaleKey = 'en_US', Start_Date__c = Date.newInstance(2020, 3, 15)
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }

        Integer yr = System.today().year();
        insert new Leave_Balance__c(
            Employee__c = u.Id, Leave_Type__c = ANNUAL, Leave_Year__c = yr,
            External_Key__c = u.Id + '-' + ANNUAL + '-' + yr,
            Entitlement_Days__c = 12, Accrual_Method__c = 'Upfront',
            Carry_Over_Days__c = 6, Used_Days__c = 4, Pending_Days__c = 0,
            Carry_Over_Expiry__c = Date.newInstance(yr, 6, 30), Status__c = 'Active'
        );
    }

    private static Leave_Balance__c annualRow() {
        return [SELECT Carry_Over_Days__c, Used_Days__c, Carry_Over_Expiry__c
                FROM Leave_Balance__c
                WHERE Employee__c = :employeeId() AND Leave_Type__c = :ANNUAL LIMIT 1];
    }

    // ------------------------------------------------------------------ the guards

    /*
     * The gate that matters most. runDaily rewrites entitlements for every employee in
     * the org, and a screen that can do that to live payroll from a button is a mis-click
     * away from a very bad afternoon.
     */
    @isTest
    static void itRefusesOutsideASandbox() {
        LeaveJobRunnerController.sandboxOverride = false;

        Test.startTest();
        try {
            LeaveJobRunnerController.run(Date.newInstance(2027, 1, 1), employeeId(), 2027, false);
            System.assert(false, 'a production org must not be able to run the job from a button');
        } catch (AuraHandledException e) {
            // expected
        }
        Test.stopTest();
    }

    @isTest
    static void theEmployeeListIsAlsoGated() {
        LeaveJobRunnerController.sandboxOverride = false;
        try {
            LeaveJobRunnerController.getEmployees();
            System.assert(false, 'the picklist must not load in production either');
        } catch (AuraHandledException e) {
            // expected
        }
    }

    @isTest
    static void aDateIsRequired() {
        LeaveJobRunnerController.sandboxOverride = true;
        try {
            LeaveJobRunnerController.run(null, employeeId(), 2027, false);
            System.assert(false, 'refused');
        } catch (AuraHandledException e) {
            // expected
        }
    }

    @isTest
    static void anEmployeeIsRequired() {
        LeaveJobRunnerController.sandboxOverride = true;
        try {
            LeaveJobRunnerController.run(Date.newInstance(2027, 1, 1), null, 2027, false);
            System.assert(false, 'refused');
        } catch (AuraHandledException e) {
            // expected
        }
    }

    // ------------------------------------------------------------ preview vs commit

    /*
     * The whole reason the screen is safe to hand over. A preview must report what WOULD
     * happen and leave the database exactly as it found it — if this ever regresses, the
     * button labelled "nothing is saved" starts lying.
     */
    @isTest
    static void aPreviewReportsTheChangeAndKeepsNoneOfIt() {
        LeaveJobRunnerController.sandboxOverride = true;
        Leave_Balance__c before = annualRow();

        Test.startTest();
        LeaveJobRunnerController.RunResult r = LeaveJobRunnerController.run(
            Date.newInstance(priorYear(), 7, 1), employeeId(), priorYear(), false);
        Test.stopTest();

        System.assertEquals(false, r.applied, 'reported as a preview');
        System.assert(r.summary.contains('Preview only'), r.summary);
        System.assert(r.changedRows > 0, 'the sweep did something worth showing');

        Leave_Balance__c after = annualRow();
        System.assertEquals(before.Carry_Over_Days__c, after.Carry_Over_Days__c,
            'and the database is untouched');
        System.assertEquals(before.Used_Days__c, after.Used_Days__c);
        System.assertEquals(before.Carry_Over_Expiry__c, after.Carry_Over_Expiry__c);
    }

    /* The mirror: committing keeps what the preview only showed. */
    @isTest
    static void acommittedRunKeepsTheChange() {
        LeaveJobRunnerController.sandboxOverride = true;

        Test.startTest();
        LeaveJobRunnerController.RunResult r = LeaveJobRunnerController.run(
            Date.newInstance(priorYear(), 7, 1), employeeId(), priorYear(), true);
        Test.stopTest();

        System.assertEquals(true, r.applied);
        System.assert(r.summary.contains('Applied'), r.summary);

        Leave_Balance__c after = annualRow();
        System.assertEquals(0, after.Carry_Over_Days__c, 'the bucket was emptied and kept');
        System.assertEquals(0, after.Used_Days__c, 'along with the days it paid for');
    }

    // --------------------------------------------------------------- what it reports

    /*
     * The screen exists to make a change legible, so the before-and-after has to be in
     * the payload rather than left for the reader to work out.
     */
    @isTest
    static void changedFiguresCarryBothSides() {
        LeaveJobRunnerController.sandboxOverride = true;

        Test.startTest();
        LeaveJobRunnerController.RunResult r = LeaveJobRunnerController.run(
            Date.newInstance(priorYear(), 7, 1), employeeId(), priorYear(), false);
        Test.stopTest();

        Boolean foundCarry = false;
        for (LeaveJobRunnerController.BalanceRow row : r.rows) {
            if (!ANNUAL.equals(row.leaveType)) {
                continue;
            }
            System.assertEquals(true, row.changed, 'the annual row moved');
            for (LeaveJobRunnerController.Cell c : row.cells) {
                if ('Carried In'.equals(c.label)) {
                    foundCarry = true;
                    System.assertEquals(true, c.changed);
                    System.assertEquals('6 → 0', c.value,
                        'both sides of the change, in one cell');
                }
            }
        }
        System.assertEquals(true, foundCarry, 'the Carried In figure is reported');
    }

    /*
     * A repeat run is meant to be a no-op, and the screen must say so plainly rather
     * than leaving a BA wondering whether the button worked.
     */
    @isTest
    static void aRunThatChangesNothingSaysSo() {
        LeaveJobRunnerController.sandboxOverride = true;

        Test.startTest();
        LeaveJobRunnerController.run(
            Date.newInstance(priorYear(), 7, 1), employeeId(), priorYear(), true);
        LeaveJobRunnerController.RunResult again = LeaveJobRunnerController.run(
            Date.newInstance(priorYear(), 7, 2), employeeId(), priorYear(), false);
        Test.stopTest();

        System.assertEquals(0, again.changedRows, 'the sweep had already done its work');
        System.assert(again.summary.contains('changed nothing'), again.summary);
    }

    @isTest
    static void theEmployeeListComesBackForThePicklist() {
        LeaveJobRunnerController.sandboxOverride = true;

        Test.startTest();
        List<Map<String, Object>> options = LeaveJobRunnerController.getEmployees();
        Test.stopTest();

        System.assert(!options.isEmpty(), 'there is at least the test employee');
        Boolean found = false;
        for (Map<String, Object> o : options) {
            if (employeeId().equals(o.get('value'))) {
                found = true;
                System.assert(((String) o.get('label')).contains('joined'),
                    'the joining date is on the label, because it decides the anniversary month');
            }
        }
        System.assertEquals(true, found);
    }

    /*
     * The component shares a tab with the employee-facing balance screen, so for an
     * ordinary employee it must report itself unavailable and render nothing. Edit access
     * to Leave_Balance__c must not be enough - that is granted far too widely.
     */
    @isTest
    static void anOrdinaryEmployeeSeesNothing() {
        LeaveJobRunnerController.sandboxOverride = true;
        User plain = [SELECT Id FROM User WHERE Id = :employeeId()];

        Test.startTest();
        Boolean available;
        System.runAs(plain) {
            available = LeaveJobRunnerController.isAvailable();
        }
        Test.stopTest();

        System.assertEquals(false, available,
            'without the custom permission the component must not render at all');
    }

    /* And it answers false rather than throwing, so the page does not show an error box. */
    @isTest
    static void availabilityIsFalseNotAnErrorOutsideASandbox() {
        LeaveJobRunnerController.sandboxOverride = false;
        System.assertEquals(false, LeaveJobRunnerController.isAvailable());
    }

    /*
     * Skipping a year is the easiest way to make carry over look broken: the engine reads
     * the year immediately before, so jumping 2026 straight to 2028 finds no 2027 row and
     * carries nothing. Measured against dev5 that is the difference between carrying 1 day
     * and carrying none, and the screen has to say so rather than leaving a BA to guess.
     */
    @isTest
    static void skippingAYearIsCalledOut() {
        LeaveJobRunnerController.sandboxOverride = true;
        Integer twoYearsOn = priorYear() + 2;

        Test.startTest();
        LeaveJobRunnerController.RunResult r = LeaveJobRunnerController.run(
            Date.newInstance(twoYearsOn, 1, 1), employeeId(), twoYearsOn, false);
        Test.stopTest();

        System.assertEquals(true, r.priorYearMissing);
        System.assert(r.summary.contains('no ' + (twoYearsOn - 1) + ' Annual leave row'),
            r.summary);
    }

    /* And stays quiet when the preceding year is actually there. */
    @isTest
    static void theNextYearRunIsNotFlagged() {
        LeaveJobRunnerController.sandboxOverride = true;

        Test.startTest();
        LeaveJobRunnerController.RunResult r = LeaveJobRunnerController.run(
            Date.newInstance(priorYear() + 1, 1, 1), employeeId(), priorYear() + 1, false);
        Test.stopTest();

        System.assertEquals(false, r.priorYearMissing,
            'the current year row exists, so carry over has something to read');
        System.assert(!r.summary.contains('Annual leave row'), r.summary);
    }
}
