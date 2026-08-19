@isTest
public with sharing class LeaveManagementControllerTest {

    /*
     * LEAVE-27 — rewritten for the Leave_Balance__c grant engine.
     *
     * The previous version asserted the leave fields on User. The engine no longer
     * writes those at all, so this is a replacement rather than an edit.
     *
     * Dates are driven by calling runDaily(Date) directly so the tests do not depend
     * on the day they are run — with one caveat. Accrued_Days__c is a formula using
     * TODAY(), and it returns the full entitlement only once Leave_Year__c is strictly
     * in the past. The grant year is therefore 2026 and the prior year 2025, both of
     * which stay in the past for good, which keeps the carry-over assertions stable.
     */

    private static final Date    GRANT_DAY  = Date.newInstance(2026, 1, 1);
    private static final Integer GRANT_YEAR = 2026;
    private static final Integer PRIOR_YEAR = 2025;

    private static final String ANNUAL     = 'Annual leave';
    private static final String REFRESH    = 'Refresh Leave';
    private static final String SICK       = 'Sick leave';
    private static final String PERSONAL   = 'Personal leave';
    private static final String STATUTORY  = 'Bereavement leave';

    // ------------------------------------------------------------------ fixtures

    /*
     * A fixed policy set. Custom Metadata cannot be inserted by DML and tests see the
     * org's real rows, so configuration is injected rather than read.
     */
    private static List<Leave_Type_Policy__mdt> fixedPolicies() {
        return new List<Leave_Type_Policy__mdt>{
            new Leave_Type_Policy__mdt(Leave_Type__c = ANNUAL, Entitlement_Days__c = 12,
                Accrual_Method__c = 'Monthly', Deducts_Balance__c = true,
                Locked_During_Probation__c = true, Active__c = true),
            new Leave_Type_Policy__mdt(Leave_Type__c = REFRESH, Entitlement_Days__c = null,
                Accrual_Method__c = 'Anniversary', Deducts_Balance__c = true,
                Locked_During_Probation__c = true, Active__c = true),
            new Leave_Type_Policy__mdt(Leave_Type__c = SICK, Entitlement_Days__c = 30,
                Accrual_Method__c = 'Upfront', Deducts_Balance__c = true, Active__c = true),
            new Leave_Type_Policy__mdt(Leave_Type__c = PERSONAL, Entitlement_Days__c = 3,
                Accrual_Method__c = 'Upfront', Deducts_Balance__c = true, Active__c = true),
            new Leave_Type_Policy__mdt(Leave_Type__c = STATUTORY, Entitlement_Days__c = 0,
                Accrual_Method__c = null, Deducts_Balance__c = false, Active__c = true)
        };
    }

    private static List<Refresh_Leave_Rule__mdt> fixedTiers() {
        List<Refresh_Leave_Rule__mdt> rules = new List<Refresh_Leave_Rule__mdt>();
        for (Integer y = 1; y <= 5; y++) {
            rules.add(new Refresh_Leave_Rule__mdt(
                Years_of_Service__c = y, Days_Granted__c = y,
                Grant_Window_Months__c = 1, Active__c = true
            ));
        }
        return rules;
    }

    private static void useFixtures() {
        LeaveManagementController.policyOverride = fixedPolicies();
        LeaveManagementController.ruleOverride   = fixedTiers();
    }

    @testSetup
    static void setupTestData() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> users = new List<User>{
            newUser(p.Id, 'CapCarry',   Date.newInstance(2020, 3, 1)),
            newUser(p.Id, 'AtCap',      Date.newInstance(2020, 3, 1)),
            newUser(p.Id, 'UnderCap',   Date.newInstance(2020, 3, 1)),
            newUser(p.Id, 'NoPrior',    Date.newInstance(2020, 3, 1)),
            newUser(p.Id, 'Future',     Date.newInstance(2026, 3, 1)),
            newUser(p.Id, 'HireJan',    Date.newInstance(2026, 1, 10)),
            newUser(p.Id, 'HireOct',    Date.newInstance(2026, 10, 20)),
            newUser(p.Id, 'Anniv3',     Date.newInstance(2023, 3, 15)),
            newUser(p.Id, 'Anniv7',     Date.newInstance(2019, 6, 10)),
            newUser(p.Id, 'LeapJoin',   Date.newInstance(2024, 2, 29)),
            newUser(p.Id, 'CarryLapse', Date.newInstance(2020, 1, 1)),
            newUser(p.Id, 'RefLapse',   Date.newInstance(2020, 1, 1))
        };
        // User is a setup object; runAs lets the Leave_Balance__c inserts below share
        // this transaction without MIXED_DML_OPERATION.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert users;
        }

        Map<String, Id> byName = new Map<String, Id>();
        for (User u : users) byName.put(u.LastName, u.Id);

        // Prior-year annual rows. Available = Entitlement - Used because 2025 is a
        // closed year, so Accrued_Days__c returns the full entitlement.
        insert new List<Leave_Balance__c>{
            priorAnnual(byName.get('CapCarry'), 12, 4),    // available 8  -> capped to 6
            priorAnnual(byName.get('AtCap'),    12, 6),    // available 6  -> carries 6
            priorAnnual(byName.get('UnderCap'), 12, 6.5),  // available 5.5 -> carries 5.5
            priorAnnual(byName.get('CarryLapse'), 12, 0)
        };
    }

    private static Leave_Balance__c priorAnnual(Id employeeId, Decimal entitlement, Decimal used) {
        return new Leave_Balance__c(
            Employee__c = employeeId, Leave_Type__c = ANNUAL, Leave_Year__c = PRIOR_YEAR,
            External_Key__c = employeeId + '-' + ANNUAL + '-' + PRIOR_YEAR,
            Entitlement_Days__c = entitlement, Accrual_Method__c = 'Monthly',
            Used_Days__c = used, Carry_Over_Days__c = 0, Pending_Days__c = 0,
            Granted_On__c = Date.newInstance(PRIOR_YEAR, 1, 1), Status__c = 'Active'
        );
    }

    private static User newUser(Id profileId, String lastName, Date startDate) {
        String uniqueName = lastName + DateTime.now().getTime() + Math.round(Math.random() * 10000);
        return new User(
            FirstName = 'Test', LastName = lastName,
            Email = uniqueName + '@example.com',
            Username = uniqueName + '@example.com.leavetest',
            Alias = lastName.left(8), CommunityNickname = uniqueName.left(40),
            TimeZoneSidKey = 'Asia/Bangkok', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', ProfileId = profileId,
            LanguageLocaleKey = 'en_US', Start_Date__c = startDate
        );
    }

    private static Id userId(String lastName) {
        return [SELECT Id FROM User WHERE LastName = :lastName LIMIT 1].Id;
    }

    /** The balance row for a name, type and year, or null if the engine made none. */
    private static Leave_Balance__c row(String lastName, String leaveType, Integer yr) {
        List<Leave_Balance__c> found = [
            SELECT Entitlement_Days__c, Used_Days__c, Carry_Over_Days__c, Carry_Over_Expiry__c,
                   Expiry_Date__c, Granted_On__c, Available_Days__c, Accrual_Method__c,
                   Locked_During_Probation__c, Leave_Type__c, Leave_Year__c
            FROM Leave_Balance__c
            WHERE Employee__r.LastName = :lastName AND Leave_Type__c = :leaveType
              AND Leave_Year__c = :yr
        ];
        return found.isEmpty() ? null : found[0];
    }

    // ------------------------------------------------------------------ annual grant

    @isTest
    static void annualGrantCapsCarryOverAtSixDays() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(GRANT_DAY);
        Test.stopTest();

        Leave_Balance__c r = row('CapCarry', ANNUAL, GRANT_YEAR);
        System.assertEquals(12, r.Entitlement_Days__c, 'the new year starts at a flat 12');
        System.assertEquals(6, r.Carry_Over_Days__c, '8 days available is capped at 6');
        System.assertEquals(0, r.Used_Days__c, 'consumption resets');
        System.assertEquals(Date.newInstance(GRANT_YEAR, 6, 30), r.Carry_Over_Expiry__c,
            'carry over expires on June 30');
        System.assertEquals(GRANT_DAY, r.Granted_On__c, 'the grant is stamped for idempotency');
    }

    @isTest
    static void annualGrantCarriesBalancesAtOrBelowTheCap() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(GRANT_DAY);
        Test.stopTest();

        System.assertEquals(6, row('AtCap', ANNUAL, GRANT_YEAR).Carry_Over_Days__c,
            'exactly at the cap carries in full');
        System.assertEquals(5.5, row('UnderCap', ANNUAL, GRANT_YEAR).Carry_Over_Days__c,
            'below the cap carries the fractional balance intact');
        System.assertEquals(0, row('NoPrior', ANNUAL, GRANT_YEAR).Carry_Over_Days__c,
            'no prior year row means nothing to carry');
    }

    @isTest
    static void annualGrantCreatesARowForEveryActiveType() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(GRANT_DAY);
        Test.stopTest();

        System.assertEquals(30, row('NoPrior', SICK, GRANT_YEAR).Entitlement_Days__c,
            'sick leave is granted upfront');
        System.assertEquals(3, row('NoPrior', PERSONAL, GRANT_YEAR).Entitlement_Days__c,
            'personal leave is granted upfront');
        System.assertEquals(0, row('NoPrior', STATUTORY, GRANT_YEAR).Entitlement_Days__c,
            'statutory types still need a row, with no entitlement');

        Leave_Balance__c refresh = row('NoPrior', REFRESH, GRANT_YEAR);
        System.assertNotEquals(null, refresh, 'refreshment gets a row on January 1');
        System.assertEquals(null, refresh.Granted_On__c,
            'but is not granted until the anniversary');
    }

    @isTest
    static void annualGrantSkipsJoinersLaterInTheYear() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(GRANT_DAY);
        Test.stopTest();

        System.assertEquals(null, row('Future', ANNUAL, GRANT_YEAR),
            'someone joining in March gets the pro-rated new-hire grant instead');
    }

    @isTest
    static void annualGrantIsIdempotentWithinTheYear() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(GRANT_DAY);
        // Spend a day, then re-run the same grant.
        Leave_Balance__c r = row('CapCarry', ANNUAL, GRANT_YEAR);
        update new Leave_Balance__c(Id = [SELECT Id FROM Leave_Balance__c
            WHERE Employee__r.LastName = 'CapCarry' AND Leave_Type__c = :ANNUAL
              AND Leave_Year__c = :GRANT_YEAR].Id, Used_Days__c = 2);
        LeaveManagementController.runDaily(GRANT_DAY);
        Test.stopTest();

        System.assertEquals(2, row('CapCarry', ANNUAL, GRANT_YEAR).Used_Days__c,
            'a second run in the same year must not reset consumption');
        System.assertEquals(6, row('CapCarry', ANNUAL, GRANT_YEAR).Carry_Over_Days__c,
            'nor re-carry the balance');
    }

    // ------------------------------------------------------------------ new hire

    @isTest
    static void newHireGrantIsProRatedByJoiningMonth() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2026, 1, 10));
        Test.stopTest();

        System.assertEquals(12, row('HireJan', ANNUAL, GRANT_YEAR).Entitlement_Days__c,
            'joining in January earns 13 - 1 = 12 days');
    }

    @isTest
    static void newHireGrantLateInTheYearIsSmaller() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2026, 10, 20));
        Test.stopTest();

        System.assertEquals(3, row('HireOct', ANNUAL, GRANT_YEAR).Entitlement_Days__c,
            'joining in October earns 13 - 10 = 3 days');
    }

    /*
     * The gap that made LEAVE-27 urgent: without a full set of rows a new hire's
     * first request of any type cannot be approved, because a missing balance row is
     * a hard error in ApplicationItemTriggerLogic.
     */
    @isTest
    static void newHireGetsARowForEveryActiveType() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2026, 10, 20));
        Test.stopTest();

        System.assertEquals(30, row('HireOct', SICK, GRANT_YEAR).Entitlement_Days__c,
            'sick leave is not pro-rated');
        System.assertEquals(3, row('HireOct', PERSONAL, GRANT_YEAR).Entitlement_Days__c,
            'personal leave is not pro-rated');
        System.assertNotEquals(null, row('HireOct', STATUTORY, GRANT_YEAR),
            'statutory types get a row so requests can be approved');
        System.assertNotEquals(null, row('HireOct', REFRESH, GRANT_YEAR),
            'refreshment gets a row, ungranted until the anniversary');
    }

    @isTest
    static void newHireIsNotGrantedBeforeJoining() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2026, 10, 19));
        Test.stopTest();

        System.assertEquals(null, row('HireOct', ANNUAL, GRANT_YEAR),
            'nothing is granted the day before joining');
    }

    // ------------------------------------------------------------------ refreshment

    /*
     * LEAVE-41. Anniv3 joined on 15 March; the grant now lands on the 1st, because the
     * anniversary MONTH is the rule. The tier is unchanged by moving the date forward:
     * monthsBetween ignores the day, so 1 March of the fourth year still reads as
     * thirty-six months.
     */
    @isTest
    static void refreshGrantLandsAtTheStartOfTheAnniversaryMonth() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2026, 3, 1));
        Test.stopTest();

        Leave_Balance__c r = row('Anniv3', REFRESH, GRANT_YEAR);
        System.assertEquals(3, r.Entitlement_Days__c, 'three completed years grants three days');
        System.assertEquals(Date.newInstance(2026, 4, 1), r.Expiry_Date__c,
            'the window is one month from the grant');
        System.assertEquals(Date.newInstance(2026, 3, 1), r.Granted_On__c,
            'stamped on the first of the anniversary month, not the joining day');
    }

    /*
     * The other half of the same rule, and the behaviour that actually changed: before
     * LEAVE-41 only the joining day granted, so a run on any other day of the month did
     * nothing. It has to grant now, or a missed 1st would lose the year's refreshment.
     */
    @isTest
    static void refreshGrantStillLandsIfTheFirstOfTheMonthIsMissed() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2026, 3, 14));
        Test.stopTest();

        Leave_Balance__c r = row('Anniv3', REFRESH, GRANT_YEAR);
        System.assertNotEquals(null, r, 'a later day in the anniversary month still grants');
        System.assertEquals(3, r.Entitlement_Days__c);
        System.assertEquals(Date.newInstance(2026, 3, 14), r.Granted_On__c,
            'stamped for the day it actually ran');
    }

    @isTest
    static void refreshGrantBeyondTheTopTierKeepsUsingIt() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2026, 6, 10));
        Test.stopTest();

        System.assertEquals(5, row('Anniv7', REFRESH, GRANT_YEAR).Entitlement_Days__c,
            'seven years keeps matching the highest configured tier');
    }

    /*
     * February 29 used to need a special case, because the joining day never came round
     * in a common year. Matching the month removes the problem rather than handling it.
     */
    @isTest
    static void aFebruary29JoinerIsGrantedLikeAnyoneElse() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2026, 2, 1));
        Test.stopTest();

        Leave_Balance__c r = row('LeapJoin', REFRESH, GRANT_YEAR);
        System.assertNotEquals(null, r,
            'the anniversary month arrives every year, leap or not');
        System.assertEquals(Date.newInstance(2026, 2, 1), r.Granted_On__c);
    }

    @isTest
    static void refreshGrantIgnoresMonthsThatAreNotTheAnniversary() {
        useFixtures();
        Test.startTest();
        // Anniv3 joined in March; April is nobody's business.
        LeaveManagementController.runDaily(Date.newInstance(2026, 4, 14));
        Test.stopTest();

        Leave_Balance__c r = row('Anniv3', REFRESH, GRANT_YEAR);
        System.assert(r == null || r.Granted_On__c == null,
            'a month that is not the anniversary month grants nothing');
    }

    /*
     * What makes "the start of the month" true with a job that runs every day: the first
     * run in the anniversary month stamps Granted_On__c and every later run that month
     * finds it set and skips. Without this the grant would repeat daily all month.
     */
    @isTest
    static void refreshGrantHappensOncePerAnniversaryMonth() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2026, 3, 1));
        update new Leave_Balance__c(Id = [SELECT Id FROM Leave_Balance__c
            WHERE Employee__r.LastName = 'Anniv3' AND Leave_Type__c = :REFRESH].Id,
            Used_Days__c = 2);
        LeaveManagementController.runDaily(Date.newInstance(2026, 3, 2));
        LeaveManagementController.runDaily(Date.newInstance(2026, 3, 20));
        Test.stopTest();

        Leave_Balance__c r = row('Anniv3', REFRESH, GRANT_YEAR);
        System.assertEquals(Date.newInstance(2026, 3, 1), r.Granted_On__c,
            'still stamped for the first run of the month');
        System.assertEquals(2, r.Used_Days__c,
            'and later runs in the same month do not re-grant over what was spent');
    }

    @isTest
    static void refreshGrantIsIdempotentWithinTheYear() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2026, 3, 15));
        update new Leave_Balance__c(Id = [SELECT Id FROM Leave_Balance__c
            WHERE Employee__r.LastName = 'Anniv3' AND Leave_Type__c = :REFRESH].Id,
            Used_Days__c = 1);
        LeaveManagementController.runDaily(Date.newInstance(2026, 3, 15));
        Test.stopTest();

        System.assertEquals(1, row('Anniv3', REFRESH, GRANT_YEAR).Used_Days__c,
            'a second run on the same anniversary must not reset consumption');
    }

    // ------------------------------------------------------------------ expiry

    /*
     * Carry over is consumed before current-year entitlement, so only the unconsumed
     * part lapses. Reducing Carry_Over_Days__c to the consumed amount removes exactly
     * the unused days while leaving the already-taken ones accounted for.
     */
    @isTest
    static void lapsedCarryOverKeepsOnlyTheConsumedPortion() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(GRANT_DAY);            // carry 6, expiry Jun 30
        update new Leave_Balance__c(Id = [SELECT Id FROM Leave_Balance__c
            WHERE Employee__r.LastName = 'CapCarry' AND Leave_Type__c = :ANNUAL
              AND Leave_Year__c = :GRANT_YEAR].Id, Used_Days__c = 4);
        LeaveManagementController.runDaily(Date.newInstance(2026, 7, 1));
        Test.stopTest();

        Leave_Balance__c r = row('CapCarry', ANNUAL, GRANT_YEAR);
        System.assertEquals(4, r.Carry_Over_Days__c,
            '4 of the 6 carried-in days were taken, so only those 4 survive');
        System.assertEquals(null, r.Carry_Over_Expiry__c, 'the expiry date is cleared');
        System.assertEquals(4, r.Used_Days__c, 'consumption is not rewritten');
    }

    @isTest
    static void carryOverSurvivesUpToItsExpiryDate() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(GRANT_DAY);
        LeaveManagementController.runDaily(Date.newInstance(2026, 6, 30));
        Test.stopTest();

        Leave_Balance__c r = row('CapCarry', ANNUAL, GRANT_YEAR);
        System.assertEquals(6, r.Carry_Over_Days__c, 'carry over survives on its expiry date');
        System.assertEquals(Date.newInstance(2026, 6, 30), r.Carry_Over_Expiry__c,
            'and the date is still set');
    }

    @isTest
    static void lapsedRefreshmentIsWipedDownToWhatWasUsed() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2026, 3, 15));   // 3 days, expires Apr 15
        update new Leave_Balance__c(Id = [SELECT Id FROM Leave_Balance__c
            WHERE Employee__r.LastName = 'Anniv3' AND Leave_Type__c = :REFRESH].Id,
            Used_Days__c = 1);
        LeaveManagementController.runDaily(Date.newInstance(2026, 4, 16));
        Test.stopTest();

        Leave_Balance__c r = row('Anniv3', REFRESH, GRANT_YEAR);
        System.assertEquals(1, r.Entitlement_Days__c,
            'the two unused days are wiped; the one taken remains accounted for');
        System.assertEquals(0, r.Available_Days__c, 'nothing is left to use');
        System.assertEquals(Date.newInstance(2026, 4, 15), r.Expiry_Date__c,
            'the expiry date is retained as the date the grant lapsed');
    }

    /*
     * The retained expiry date keeps matching the sweep's query on every later run.
     * Guards against the row being rewritten once there is nothing left to drop —
     * a re-upsert every night would also mean a log file every night.
     */
    @isTest
    static void lapsedRefreshmentIsNotRewrittenOnLaterRuns() {
        useFixtures();
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2026, 3, 15));   // grant, expires Apr 15
        LeaveManagementController.runDaily(Date.newInstance(2026, 4, 16));   // sweeps it to zero

        /*
         * Asserted against this row rather than against Limits.getDmlRows(). The grant
         * engine queries User, and tests see the org's real users however the fixtures
         * are built, so a colleague with a May anniversary makes a transaction-wide DML
         * count depend on the staff list. What matters here is narrower and stable: the
         * lapsed row itself is not rewritten.
         */
        Datetime touchedBefore = [SELECT LastModifiedDate FROM Leave_Balance__c
                                  WHERE Employee__r.LastName = 'Anniv3'
                                    AND Leave_Type__c = :REFRESH].LastModifiedDate;
        LeaveManagementController.runDaily(Date.newInstance(2026, 5, 20));
        Test.stopTest();

        System.assertEquals(touchedBefore,
            [SELECT LastModifiedDate FROM Leave_Balance__c
             WHERE Employee__r.LastName = 'Anniv3'
               AND Leave_Type__c = :REFRESH].LastModifiedDate,
            'the lapsed row must not be rewritten by a later run');

        Leave_Balance__c r = row('Anniv3', REFRESH, GRANT_YEAR);
        System.assertEquals(0, r.Entitlement_Days__c, 'still zero');
        System.assertEquals(Date.newInstance(2026, 4, 15), r.Expiry_Date__c,
            'the lapse date still stands');
    }

    @isTest
    static void januaryGrantSurvivesTheSameRunsExpirySweep() {
        useFixtures();
        Test.startTest();
        // The prior-year row for CarryLapse has a June 30 expiry that has long passed.
        // The January 1 run must grant the new year without its own sweep undoing it.
        LeaveManagementController.runDaily(GRANT_DAY);
        Test.stopTest();

        Leave_Balance__c r = row('CarryLapse', ANNUAL, GRANT_YEAR);
        System.assertEquals(12, r.Entitlement_Days__c, 'the new year is granted');
        System.assertEquals(Date.newInstance(GRANT_YEAR, 6, 30), r.Carry_Over_Expiry__c,
            'the freshly written expiry date is not swept by the same run');
    }

}
