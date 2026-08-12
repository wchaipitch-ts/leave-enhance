public with sharing class LeaveManagementController implements Schedulable {

    /*
     * LEAVE-5: reworked to the January 1st granting model.
     *
     * Removed in that pass:
     *   - the 3/6/8/10 tenure ladder (annual leave is now a flat 12 days)
     *   - the Anniversary / CalendarYear mode fork and the Leave_Calculation_Mode label
     *   - the "skip if tenure < 6 months" guard, which excluded mid-year hires
     *   - the Annual_Leave_Day__c = Annual_Leave_Allocated__c sync, which reset
     *     consumption on every run
     *
     * The job now runs daily and decides for itself what is due today.
     *
     * Every SOQL below selects the same field set on purpose. stage() can hand one
     * grant an sObject that a previous grant queried, and reading a field that the
     * earlier query did not select throws SObjectException at runtime.
     */

    // Test hooks. Tests drive the clock and the refresh-leave tiers through these
    // rather than depending on System.today() or the org's Custom Metadata rows.
    @TestVisible private static Date todayOverride;
    @TestVisible private static List<Refresh_Leave_Rule__mdt> ruleOverride;

    public void execute(SchedulableContext sc) {
        runDaily();
    }

    public static void runDaily() {
        runDaily(todayOverride != null ? todayOverride : System.today());
    }

    /*
     * Runs the grants as at a specific date. Public so a missed run can be replayed
     * for the date it should have happened, and so the January 1 path can be
     * exercised by hand outside a test context. Every grant is guarded by a
     * granted-year field, so replaying a date that already ran changes nothing.
     */
    public static void runDaily(Date today) {
        // Users are accumulated by Id so that two grants landing on the same day
        // mutate one sObject instance rather than overwriting each other. Anything
        // added here must be read back from the map, not re-queried.
        Map<Id, User> toUpdate = new Map<Id, User>();
        List<String> logDetails = new List<String>{
            'Run Date: ' + System.now(),
            'Effective Date: ' + today,
            '--------------------------------------'
        };

        try {
            if (today.month() == 1 && today.day() == 1) {
                grantAnnualLeave(today, toUpdate, logDetails);
            }
            grantNewHireLeave(today, toUpdate, logDetails);
            grantRefreshLeave(today, toUpdate, logDetails);
            // Expiry runs last so it evaluates the dates this run has just written,
            // not the stale ones still in the database.
            expireLeave(today, toUpdate, logDetails);

            if (!toUpdate.isEmpty()) {
                update toUpdate.values();
                createLogFile(String.join(logDetails, '\n'));
            }
        } catch (Exception e) {
            System.debug('An unexpected error has occurred: ' + e.getMessage() + '\n' + e.getStackTraceString());
            // Rethrow in tests so logic and configuration errors surface instead of being swallowed.
            if (Test.isRunningTest()) throw e;
        }
    }

    /*
     * Returns the working instance for a user. If an earlier grant already staged
     * this user, that instance is returned so both grants accumulate onto one
     * record; a freshly queried copy would silently discard the earlier changes.
     */
    private static User stage(Map<Id, User> toUpdate, User queried) {
        if (toUpdate.containsKey(queried.Id)) {
            return toUpdate.get(queried.Id);
        }
        toUpdate.put(queried.Id, queried);
        return queried;
    }

    /*
     * LEAVE-6 — annual leave grant, January 1. See spec §3.1.
     * Flat 12 days; carry over MIN(6, Annual_Leave_Day__c) with expiry June 30.
     * Guarded by Annual_Leave_Granted_Year__c.
     *
     * §3.1 also specifies a waiver of the 6-day cap for anyone whose probation
     * ends inside the grant year. It is deliberately not implemented: it cannot
     * fire. Probation ends in the grant year only for September-to-December
     * joiners, and the new-hire grant gives them 13 - month, so at most four
     * days — always under the cap. Reinstate it only if a cutover migrates a
     * larger legacy balance onto someone still serving probation.
     */
    private static void grantAnnualLeave(Date today, Map<Id, User> toUpdate, List<String> logDetails) {
        Integer yr = today.year();

        // Start_Date__c <= today excludes future joiners, who must receive the
        // pro-rated new-hire grant on their joining date instead of a full 12 days.
        List<User> candidates = [
            SELECT Id, Name, Start_Date__c,
                   Annual_Leave_Allocated__c, Annual_Leave_Day__c, Annual_Leave_Used__c,
                   Carry_Over_Days__c, Carry_Over_Expiry__c,
                   Annual_Leave_Granted_Year__c,
                   Refresh_Leave_Days__c, Refresh_Leave_Expiry__c, Refresh_Leave_Granted_Year__c
            FROM User
            WHERE IsActive = TRUE
              AND Start_Date__c != NULL
              AND Start_Date__c <= :today
              AND (Annual_Leave_Granted_Year__c = NULL OR Annual_Leave_Granted_Year__c != :yr)
        ];

        for (User queried : candidates) {
            User usr = stage(toUpdate, queried);
            if (usr.Annual_Leave_Granted_Year__c == yr) continue;

            Decimal balance = usr.Annual_Leave_Day__c == null ? 0 : usr.Annual_Leave_Day__c;
            Decimal carryOver = balance > 6 ? 6 : balance;

            usr.Annual_Leave_Allocated__c = 12;
            usr.Annual_Leave_Day__c = 12;
            usr.Carry_Over_Days__c = carryOver;
            usr.Carry_Over_Expiry__c = Date.newInstance(yr, 6, 30);
            usr.Annual_Leave_Used__c = 0;
            usr.Annual_Leave_Granted_Year__c = yr;

            logDetails.add('ANNUAL  ' + usr.Name
                + ' | start=' + usr.Start_Date__c
                + ' | priorBalance=' + balance
                + ' | carryOver=' + carryOver);
        }
    }

    /*
     * LEAVE-7 — new hire grant, on the joining date. See spec §3.2.
     * days = 13 - Start_Date__c.month(), i.e. one day for each month remaining in
     * the calendar year, counting the joining month. Guarded by Annual_Leave_Granted_Year__c.
     */
    private static void grantNewHireLeave(Date today, Map<Id, User> toUpdate, List<String> logDetails) {
        Integer yr = today.year();

        List<User> newHires = [
            SELECT Id, Name, Start_Date__c,
                   Annual_Leave_Allocated__c, Annual_Leave_Day__c, Annual_Leave_Used__c,
                   Carry_Over_Days__c, Carry_Over_Expiry__c,
                   Annual_Leave_Granted_Year__c,
                   Refresh_Leave_Days__c, Refresh_Leave_Expiry__c, Refresh_Leave_Granted_Year__c
            FROM User
            WHERE IsActive = TRUE
              AND Start_Date__c = :today
              AND (Annual_Leave_Granted_Year__c = NULL OR Annual_Leave_Granted_Year__c != :yr)
        ];

        for (User queried : newHires) {
            User usr = stage(toUpdate, queried);
            // A January 1 joiner is picked up by grantAnnualLeave first. That grant is
            // staged but not yet committed, so the guard has to be re-checked here
            // against the staged instance rather than trusted from the query.
            if (usr.Annual_Leave_Granted_Year__c == yr) continue;

            Decimal days = 13 - usr.Start_Date__c.month();

            usr.Annual_Leave_Allocated__c = days;
            usr.Annual_Leave_Day__c = days;
            usr.Annual_Leave_Granted_Year__c = yr;

            logDetails.add('NEWHIRE ' + usr.Name
                + ' | start=' + usr.Start_Date__c
                + ' | granted=' + days);
        }
    }

    /*
     * LEAVE-8 — refresh leave grant, on the anniversary. See spec §3.3.
     * Guarded by Refresh_Leave_Granted_Year__c.
     */
    private static void grantRefreshLeave(Date today, Map<Id, User> toUpdate, List<String> logDetails) {
        Integer yr = today.year();
        List<Refresh_Leave_Rule__mdt> rules = getRules();
        if (rules.isEmpty()) return;

        // The day is matched in Apex rather than SOQL so that February 29 joiners
        // can be caught on February 28 in non-leap years.
        List<User> candidates = [
            SELECT Id, Name, Start_Date__c,
                   Annual_Leave_Allocated__c, Annual_Leave_Day__c, Annual_Leave_Used__c,
                   Carry_Over_Days__c, Carry_Over_Expiry__c,
                   Annual_Leave_Granted_Year__c,
                   Refresh_Leave_Days__c, Refresh_Leave_Expiry__c, Refresh_Leave_Granted_Year__c
            FROM User
            WHERE IsActive = TRUE
              AND Start_Date__c != NULL
              AND Start_Date__c < :today
              AND CALENDAR_MONTH(Start_Date__c) = :today.month()
              AND (Refresh_Leave_Granted_Year__c = NULL OR Refresh_Leave_Granted_Year__c != :yr)
        ];

        for (User queried : candidates) {
            User usr = stage(toUpdate, queried);
            if (usr.Refresh_Leave_Granted_Year__c == yr) continue;
            if (!isAnniversary(usr.Start_Date__c, today)) continue;

            Integer years = usr.Start_Date__c.monthsBetween(today) / 12;
            Refresh_Leave_Rule__mdt rule = tierFor(rules, years);
            if (rule == null) continue;

            Integer window = rule.Grant_Window_Months__c == null ? 1 : rule.Grant_Window_Months__c.intValue();

            usr.Refresh_Leave_Days__c = rule.Days_Granted__c;
            usr.Refresh_Leave_Expiry__c = today.addMonths(window);
            usr.Refresh_Leave_Granted_Year__c = yr;

            logDetails.add('REFRESH ' + usr.Name
                + ' | start=' + usr.Start_Date__c
                + ' | years=' + years
                + ' | granted=' + rule.Days_Granted__c
                + ' | expires=' + usr.Refresh_Leave_Expiry__c);
        }
    }

    /*
     * True when today is the anniversary of startDate. A February 29 joiner has no
     * anniversary in a non-leap year, so February 28 stands in for it.
     */
    private static Boolean isAnniversary(Date startDate, Date today) {
        if (startDate.month() == today.month() && startDate.day() == today.day()) {
            return true;
        }
        return startDate.month() == 2 && startDate.day() == 29
            && today.month() == 2 && today.day() == 28
            && !Date.isLeapYear(today.year());
    }

    /*
     * The highest active tier at or below the employee's completed years of service.
     * Refresh_Leave_Rule__mdt carries no "max tier" flag, so tenure beyond the last
     * configured row simply keeps matching that row — 7 years lands on the 5-year
     * tier without any configuration change.
     */
    private static Refresh_Leave_Rule__mdt tierFor(List<Refresh_Leave_Rule__mdt> rules, Integer years) {
        Refresh_Leave_Rule__mdt best = null;
        for (Refresh_Leave_Rule__mdt r : rules) {
            if (r.Active__c != true || r.Years_of_Service__c == null) continue;
            if (r.Years_of_Service__c > years) continue;
            if (best == null || r.Years_of_Service__c > best.Years_of_Service__c) {
                best = r;
            }
        }
        return best;
    }

    /*
     * LEAVE-9 — expiry sweep, daily. See spec §3.4.
     * Expired days are simply lost; nothing is paid out.
     */
    private static void expireLeave(Date today, Map<Id, User> toUpdate, List<String> logDetails) {
        List<User> candidates = [
            SELECT Id, Name, Start_Date__c,
                   Annual_Leave_Allocated__c, Annual_Leave_Day__c, Annual_Leave_Used__c,
                   Carry_Over_Days__c, Carry_Over_Expiry__c,
                   Annual_Leave_Granted_Year__c,
                   Refresh_Leave_Days__c, Refresh_Leave_Expiry__c, Refresh_Leave_Granted_Year__c
            FROM User
            WHERE IsActive = TRUE
              AND ((Carry_Over_Expiry__c != NULL AND Carry_Over_Expiry__c < :today)
                OR (Refresh_Leave_Expiry__c != NULL AND Refresh_Leave_Expiry__c < :today))
        ];

        for (User queried : candidates) {
            // Read the staged instance where one exists: a grant earlier in this run
            // may have already replaced the expiry date the query matched on.
            User usr = toUpdate.containsKey(queried.Id) ? toUpdate.get(queried.Id) : queried;

            Boolean carryExpired = usr.Carry_Over_Expiry__c != null && usr.Carry_Over_Expiry__c < today;
            Boolean refreshExpired = usr.Refresh_Leave_Expiry__c != null && usr.Refresh_Leave_Expiry__c < today;
            if (!carryExpired && !refreshExpired) continue;

            usr = stage(toUpdate, usr);

            if (carryExpired) {
                logDetails.add('EXPIRE  ' + usr.Name
                    + ' | carryOver=' + usr.Carry_Over_Days__c
                    + ' lapsed on ' + usr.Carry_Over_Expiry__c);
                usr.Carry_Over_Days__c = 0;
                usr.Carry_Over_Expiry__c = null;
            }

            if (refreshExpired) {
                logDetails.add('EXPIRE  ' + usr.Name
                    + ' | refresh=' + usr.Refresh_Leave_Days__c
                    + ' lapsed on ' + usr.Refresh_Leave_Expiry__c);
                usr.Refresh_Leave_Days__c = 0;
                usr.Refresh_Leave_Expiry__c = null;
            }
        }
    }

    /*
     * Refresh leave tiers. getAll() consumes no SOQL query or row limits.
     */
    @TestVisible
    private static List<Refresh_Leave_Rule__mdt> getRules() {
        return ruleOverride != null ? ruleOverride : Refresh_Leave_Rule__mdt.getAll().values();
    }

    /*
     * Async because User is a setup object and Error_Log__c / ContentVersion are not:
     * writing both in one transaction throws MIXED_DML_OPERATION.
     */
    @future
    private static void createLogFile(String logDetails) {
        try {
            Error_Log__c log = new Error_Log__c();
            log.Process_Type__c = 'Annual Leave Calculation';
            insert log;

            ContentVersion cv = new ContentVersion();
            cv.Title = 'Leave_Calculation_Log_' + System.now().format('yyyyMMdd_HHmmss');
            cv.PathOnClient = 'Log_' + System.now().format('yyyyMMdd_HHmmss') + '.txt';
            cv.VersionData = Blob.valueOf(logDetails);
            cv.FirstPublishLocationId = log.Id;
            insert cv;
        } catch (Exception e) {
            System.debug('Failed to create log file: ' + e.getMessage());
        }
    }
}