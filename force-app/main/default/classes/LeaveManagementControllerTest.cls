@isTest
public with sharing class LeaveManagementControllerTest {

    /*
     * Partial rewrite for LEAVE-17, covering LEAVE-6 (annual grant) and LEAVE-7
     * (new hire grant). Refresh-leave and expiry coverage follows once LEAVE-8
     * and LEAVE-9 are implemented.
     *
     * The previous version of this class asserted the retired 3/6/8/10 tenure
     * ladder and drove the controller through testMode / adjustAnnualLeaveDay(),
     * none of which survive the LEAVE-5 rework, so it was replaced rather than
     * edited. Dates are driven through todayOverride so the tests do not depend
     * on the date they are run.
     */

    private static final Date GRANT_DAY = Date.newInstance(2027, 1, 1);
    private static final Integer GRANT_YEAR = 2027;

    @testSetup
    static void setupTestData() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        List<User> users = new List<User>{
            // 8 days remaining -> carry over capped at 6
            newUser(p.Id, 'CapCarry', Date.newInstance(2020, 3, 1), 8, 4),
            // exactly at the cap -> carries the full 6
            newUser(p.Id, 'AtCap', Date.newInstance(2020, 3, 1), 6, 0),
            // below the cap -> carries the fractional balance intact
            newUser(p.Id, 'UnderCap', Date.newInstance(2020, 3, 1), 5.5, 2),
            // joins during the grant year -> must not receive the January 1 grant
            newUser(p.Id, 'Future', Date.newInstance(2027, 3, 1), 0, 0),
            // new hires, granted on their joining dates
            newUser(p.Id, 'HireJan', Date.newInstance(2027, 1, 10), 0, 0),
            newUser(p.Id, 'HireOct', Date.newInstance(2027, 10, 20), 0, 0),
            // refresh leave anniversaries
            newUser(p.Id, 'Anniv3', Date.newInstance(2024, 3, 15), 0, 0),
            newUser(p.Id, 'Anniv7', Date.newInstance(2020, 6, 10), 0, 0),
            newUser(p.Id, 'LeapJoin', Date.newInstance(2024, 2, 29), 0, 0)
        };

        // expiry cases
        User carryLapsed = newUser(p.Id, 'CarryLapsed', Date.newInstance(2020, 1, 1), 12, 0);
        carryLapsed.Carry_Over_Days__c = 4;
        carryLapsed.Carry_Over_Expiry__c = Date.newInstance(2027, 6, 30);
        carryLapsed.Annual_Leave_Granted_Year__c = 2027;
        users.add(carryLapsed);

        User refreshLapsed = newUser(p.Id, 'RefreshLapsed', Date.newInstance(2020, 1, 1), 12, 0);
        refreshLapsed.Refresh_Leave_Days__c = 3;
        refreshLapsed.Refresh_Leave_Expiry__c = Date.newInstance(2027, 4, 15);
        refreshLapsed.Annual_Leave_Granted_Year__c = 2027;
        refreshLapsed.Refresh_Leave_Granted_Year__c = 2027;
        users.add(refreshLapsed);

        // granted last year with a lapsed expiry: the January 1 run must re-grant and
        // re-date the carry over without the same run's sweep expiring it again
        User rollover = newUser(p.Id, 'Rollover', Date.newInstance(2020, 1, 1), 3, 9);
        rollover.Carry_Over_Days__c = 5;
        rollover.Carry_Over_Expiry__c = Date.newInstance(2026, 6, 30);
        rollover.Annual_Leave_Granted_Year__c = 2026;
        users.add(rollover);

        insert users;
    }

    private static List<Refresh_Leave_Rule__mdt> fixedTiers() {
        List<Refresh_Leave_Rule__mdt> rules = new List<Refresh_Leave_Rule__mdt>();
        for (Integer y = 1; y <= 5; y++) {
            rules.add(new Refresh_Leave_Rule__mdt(
                Years_of_Service__c = y,
                Days_Granted__c = y,
                Grant_Window_Months__c = 1,
                Active__c = true
            ));
        }
        return rules;
    }

    private static User newUser(Id profileId, String lastName, Date startDate, Decimal balance, Decimal used) {
        String uniqueName = lastName + DateTime.now().getTime() + Math.round(Math.random() * 10000);
        return new User(
            FirstName = 'Test',
            LastName = lastName,
            Email = uniqueName + '@example.com',
            Username = uniqueName + '@example.com.leavetest',
            Alias = lastName.left(8),
            CommunityNickname = uniqueName.left(40),
            TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = profileId,
            LanguageLocaleKey = 'en_US',
            Start_Date__c = startDate,
            Annual_Leave_Day__c = balance,
            Annual_Leave_Used__c = used,
            Annual_Leave_Granted_Year__c = null
        );
    }

    private static User load(String lastName) {
        return [
            SELECT Name, Start_Date__c, Probation_End_Date__c,
                   Annual_Leave_Allocated__c, Annual_Leave_Day__c, Annual_Leave_Used__c,
                   Carry_Over_Days__c, Carry_Over_Expiry__c,
                   Annual_Leave_Granted_Year__c,
                   Refresh_Leave_Days__c, Refresh_Leave_Expiry__c, Refresh_Leave_Granted_Year__c
            FROM User WHERE LastName = :lastName LIMIT 1
        ];
    }

    @isTest
    static void annualGrantCapsCarryOverAtSixDays() {
        LeaveManagementController.todayOverride = GRANT_DAY;

        Test.startTest();
        LeaveManagementController.runDaily();
        Test.stopTest();

        User u = load('CapCarry');
        System.assertEquals(12, u.Annual_Leave_Allocated__c, 'allocation is a flat 12 days');
        System.assertEquals(12, u.Annual_Leave_Day__c, 'balance resets to the new allocation');
        System.assertEquals(6, u.Carry_Over_Days__c, '8 remaining days must cap at 6');
        System.assertEquals(0, u.Annual_Leave_Used__c, 'consumption resets for the new year');
        System.assertEquals(Date.newInstance(GRANT_YEAR, 6, 30), u.Carry_Over_Expiry__c, 'carry over expires June 30');
        System.assertEquals(GRANT_YEAR, u.Annual_Leave_Granted_Year__c, 'granted year guard is stamped');
    }

    @isTest
    static void annualGrantCarriesBalancesAtOrBelowTheCap() {
        LeaveManagementController.todayOverride = GRANT_DAY;

        Test.startTest();
        LeaveManagementController.runDaily();
        Test.stopTest();

        System.assertEquals(6, load('AtCap').Carry_Over_Days__c, 'exactly 6 days carries in full');
        System.assertEquals(5.5, load('UnderCap').Carry_Over_Days__c, 'half days survive the carry over');
    }

    @isTest
    static void annualGrantSkipsJoinersLaterInTheYear() {
        LeaveManagementController.todayOverride = GRANT_DAY;

        Test.startTest();
        LeaveManagementController.runDaily();
        Test.stopTest();

        User u = load('Future');
        System.assertEquals(null, u.Annual_Leave_Granted_Year__c,
            'a March joiner must wait for the pro-rated new hire grant, not receive 12 days on January 1');
    }

    @isTest
    static void annualGrantIsIdempotentWithinTheYear() {
        LeaveManagementController.todayOverride = GRANT_DAY;

        Test.startTest();
        LeaveManagementController.runDaily();
        // Spend a day, then re-run: the guard must leave the balance alone.
        User spent = load('CapCarry');
        update new User(Id = spent.Id, Annual_Leave_Day__c = 11, Annual_Leave_Used__c = 1);
        LeaveManagementController.runDaily();
        Test.stopTest();

        User u = load('CapCarry');
        System.assertEquals(11, u.Annual_Leave_Day__c, 'a second run in the same year must not re-grant');
        System.assertEquals(1, u.Annual_Leave_Used__c, 'consumption must not be wiped by a re-run');
    }

    @isTest
    static void newHireGrantIsProRatedByJoiningMonth() {
        LeaveManagementController.todayOverride = Date.newInstance(2027, 1, 10);

        Test.startTest();
        LeaveManagementController.runDaily();
        Test.stopTest();

        User u = load('HireJan');
        System.assertEquals(12, u.Annual_Leave_Allocated__c, 'a January 10 joiner receives 12 days');
        System.assertEquals(12, u.Annual_Leave_Day__c, 'balance matches the grant');
        System.assertEquals(GRANT_YEAR, u.Annual_Leave_Granted_Year__c, 'granted year guard is stamped');
    }

    @isTest
    static void newHireGrantLateInTheYearIsSmaller() {
        LeaveManagementController.todayOverride = Date.newInstance(2027, 10, 20);

        Test.startTest();
        LeaveManagementController.runDaily();
        Test.stopTest();

        System.assertEquals(3, load('HireOct').Annual_Leave_Allocated__c, 'an October 20 joiner receives 3 days');
    }

    @isTest
    static void newHireIsNotGrantedBeforeJoining() {
        LeaveManagementController.todayOverride = Date.newInstance(2027, 10, 19);

        Test.startTest();
        LeaveManagementController.runDaily();
        Test.stopTest();

        System.assertEquals(null, load('HireOct').Annual_Leave_Granted_Year__c,
            'the grant lands on the joining date, not before');
    }

    // ---------------------------------------------------------------- LEAVE-8

    @isTest
    static void refreshGrantMatchesTheTierForCompletedYears() {
        LeaveManagementController.ruleOverride = fixedTiers();

        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2027, 3, 15));
        Test.stopTest();

        User u = load('Anniv3');
        System.assertEquals(3, u.Refresh_Leave_Days__c, '3 completed years grants 3 days');
        System.assertEquals(Date.newInstance(2027, 4, 15), u.Refresh_Leave_Expiry__c,
            'expiry is the anniversary plus the tier grant window');
        System.assertEquals(2027, u.Refresh_Leave_Granted_Year__c, 'granted year guard is stamped');
    }

    @isTest
    static void refreshGrantBeyondTheTopTierKeepsUsingIt() {
        LeaveManagementController.ruleOverride = fixedTiers();

        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2027, 6, 10));
        Test.stopTest();

        System.assertEquals(5, load('Anniv7').Refresh_Leave_Days__c,
            '7 years exceeds every tier and must fall back to the highest one');
    }

    @isTest
    static void refreshGrantFallsBackToFeb28InNonLeapYears() {
        LeaveManagementController.ruleOverride = fixedTiers();

        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2027, 2, 28));
        Test.stopTest();

        System.assertEquals(3, load('LeapJoin').Refresh_Leave_Days__c,
            'a February 29 joiner has no anniversary in 2027, so February 28 stands in');
    }

    @isTest
    static void refreshGrantUsesFeb29InLeapYears() {
        LeaveManagementController.ruleOverride = fixedTiers();

        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2028, 2, 29));
        Test.stopTest();

        System.assertEquals(4, load('LeapJoin').Refresh_Leave_Days__c,
            '2028 is a leap year, so the real anniversary applies and tenure is 4 years');
    }

    @isTest
    static void refreshGrantIgnoresNonAnniversaryDays() {
        LeaveManagementController.ruleOverride = fixedTiers();

        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2027, 3, 16));
        Test.stopTest();

        System.assertEquals(null, load('Anniv3').Refresh_Leave_Granted_Year__c,
            'the day after the anniversary must not grant');
    }

    @isTest
    static void refreshGrantIsIdempotentWithinTheYear() {
        LeaveManagementController.ruleOverride = fixedTiers();

        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2027, 3, 15));
        User granted = load('Anniv3');
        update new User(Id = granted.Id, Refresh_Leave_Days__c = 1);
        LeaveManagementController.runDaily(Date.newInstance(2027, 3, 15));
        Test.stopTest();

        System.assertEquals(1, load('Anniv3').Refresh_Leave_Days__c,
            'a second run on the same anniversary must not re-grant');
    }

    // ---------------------------------------------------------------- LEAVE-9

    @isTest
    static void lapsedCarryOverIsZeroedAndCleared() {
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2027, 7, 1));
        Test.stopTest();

        User u = load('CarryLapsed');
        System.assertEquals(0, u.Carry_Over_Days__c, 'carry over is forfeited after June 30');
        System.assertEquals(null, u.Carry_Over_Expiry__c, 'the expiry date is cleared');
        System.assertEquals(12, u.Annual_Leave_Day__c, 'current year days are untouched by expiry');
    }

    @isTest
    static void carryOverSurvivesUpToItsExpiryDate() {
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2027, 6, 30));
        Test.stopTest();

        User u = load('CarryLapsed');
        System.assertEquals(4, u.Carry_Over_Days__c, 'the expiry date itself is still usable');
        System.assertEquals(Date.newInstance(2027, 6, 30), u.Carry_Over_Expiry__c, 'expiry date is retained');
    }

    @isTest
    static void lapsedRefreshLeaveIsZeroedAndCleared() {
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2027, 4, 16));
        Test.stopTest();

        User u = load('RefreshLapsed');
        System.assertEquals(0, u.Refresh_Leave_Days__c, 'refresh leave lapses once the window closes');
        System.assertEquals(null, u.Refresh_Leave_Expiry__c, 'the expiry date is cleared');
    }

    @isTest
    static void januaryGrantSurvivesTheSameRunsExpirySweep() {
        Test.startTest();
        LeaveManagementController.runDaily(Date.newInstance(2027, 1, 1));
        Test.stopTest();

        User u = load('Rollover');
        System.assertEquals(3, u.Carry_Over_Days__c,
            'the carry over written by this run must not be swept by the same run');
        System.assertEquals(Date.newInstance(2027, 6, 30), u.Carry_Over_Expiry__c,
            'the freshly written expiry date must survive the sweep');
        System.assertEquals(12, u.Annual_Leave_Day__c, 'the new allocation applies');
    }
}