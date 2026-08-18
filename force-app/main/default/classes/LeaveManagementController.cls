public with sharing class LeaveManagementController implements Schedulable {

    /*
     * LEAVE-27 — the grant engine now maintains Leave_Balance__c rather than the
     * leave fields on User.
     *
     * Why this had to change: a missing Leave_Balance__c row blocks approval
     * (ApplicationItemTriggerLogic raises addError), and nothing else creates rows.
     * Before this, anyone hired after the initial backfill could never have leave
     * approved, and every nightly run wrote to User fields that nothing reads.
     *
     * The idempotency guards moved with it. Annual_Leave_Granted_Year__c and
     * Refresh_Leave_Granted_Year__c live on User, and User is a setup object —
     * writing one of them in the same transaction as a Leave_Balance__c row throws
     * MIXED_DML_OPERATION. Granted_On__c on the balance row replaces both.
     *
     * This class no longer performs any DML on User. That is what lets createLogFile
     * be synchronous: the @future existed only to dodge the same mixed DML problem.
     *
     * The User leave fields are left exactly as they are — frozen fallback. They are
     * no longer written and are retired at cutover.
     */

    private static final Decimal ANNUAL_ENTITLEMENT = 12;
    private static final Decimal CARRY_OVER_CAP     = 6;
    private static final String  TYPE_ANNUAL        = 'Annual leave';
    private static final String  ACCRUAL_ANNIVERSARY = 'Anniversary';

    // Test hooks. Tests drive the clock and the configuration through these rather
    // than depending on System.today() or the org's Custom Metadata rows.
    @TestVisible private static Date todayOverride;
    @TestVisible private static List<Refresh_Leave_Rule__mdt> ruleOverride;
    @TestVisible private static List<Leave_Type_Policy__mdt> policyOverride;

    public void execute(SchedulableContext sc) {
        runDaily();
    }

    public static void runDaily() {
        runDaily(todayOverride != null ? todayOverride : System.today());
    }

    /*
     * Runs the grants as at a specific date. Public so a missed run can be replayed
     * for the date it should have happened. Every grant is guarded by Granted_On__c,
     * so replaying a date that already ran changes nothing.
     */
    public static void runDaily(Date today) {
        // Rows are accumulated by External_Key__c so that two grants landing on the
        // same day mutate one instance rather than overwriting each other. Anything
        // added here must be read back from the map, not re-queried.
        Map<String, Leave_Balance__c> staged = new Map<String, Leave_Balance__c>();
        List<String> logDetails = new List<String>{
            'Run Date: ' + System.now(),
            'Effective Date: ' + today,
            '--------------------------------------'
        };

        try {
            if (today.month() == 1 && today.day() == 1) {
                grantAnnualLeave(today, staged, logDetails);
            }
            grantNewHireLeave(today, staged, logDetails);
            grantRefreshLeave(today, staged, logDetails);
            // Expiry runs last so it evaluates the dates this run has just written,
            // not the stale ones still in the database.
            expireLeave(today, staged, logDetails);

            if (!staged.isEmpty()) {
                upsert staged.values() External_Key__c;
                createLogFile(String.join(logDetails, '\n'));
            }
        } catch (Exception e) {
            System.debug('An unexpected error has occurred: ' + e.getMessage() + '\n' + e.getStackTraceString());
            // Rethrow in tests so logic and configuration errors surface instead of being swallowed.
            if (Test.isRunningTest()) throw e;
        }
    }

    // ------------------------------------------------------------------ grants

    /*
     * LEAVE-6 / LEAVE-27 — annual grant, January 1.
     *
     * Creates the full set of rows for the new year, not just the annual one: every
     * active leave type needs a row or its first request of the year cannot be
     * approved. Refreshment is the exception — it is granted on the anniversary, so
     * its row is created with no entitlement and no Granted_On__c.
     *
     * Carry over is MIN(6, the prior year's Available). Available is
     * Accrued + CarriedIn - Used, so at year end it is exactly what the employee had
     * left, which is the figure the policy caps.
     */
    private static void grantAnnualLeave(Date today, Map<String, Leave_Balance__c> staged,
                                         List<String> logDetails) {
        Integer yr = today.year();
        List<User> employees = employeesStartedBy(today);
        if (employees.isEmpty()) return;

        Map<String, Leave_Balance__c> existing = loadBalances(idsOf(employees), new Set<Integer>{ yr, yr - 1 });

        for (User usr : employees) {
            for (Leave_Type_Policy__mdt policy : activePolicies()) {
                Leave_Balance__c row = stage(staged, existing, usr.Id, policy, yr);
                if (ACCRUAL_ANNIVERSARY.equals(policy.Accrual_Method__c) || row.Granted_On__c != null) {
                    continue;
                }

                row.Entitlement_Days__c = policy.Entitlement_Days__c;
                row.Used_Days__c        = 0;
                row.Granted_On__c       = today;

                if (TYPE_ANNUAL.equals(policy.Leave_Type__c)) {
                    Leave_Balance__c prior = existing.get(balanceKey(usr.Id, TYPE_ANNUAL, yr - 1));
                    Decimal priorAvailable = prior == null ? 0 : zeroIfNull(prior.Available_Days__c);
                    if (priorAvailable < 0) priorAvailable = 0;
                    Decimal carryOver = priorAvailable > CARRY_OVER_CAP ? CARRY_OVER_CAP : priorAvailable;

                    row.Entitlement_Days__c  = ANNUAL_ENTITLEMENT;
                    row.Carry_Over_Days__c   = carryOver;
                    row.Carry_Over_Expiry__c = Date.newInstance(yr, 6, 30);

                    logDetails.add('ANNUAL  ' + usr.Name
                        + ' | start=' + usr.Start_Date__c
                        + ' | priorAvailable=' + priorAvailable
                        + ' | carryOver=' + carryOver);
                }
            }
        }
    }

    /*
     * LEAVE-7 / LEAVE-27 — new hire grant, on the joining date.
     *
     * Annual is 13 - joining month, i.e. one day for each month remaining in the
     * calendar year counting the joining month. Everything else takes the policy
     * entitlement in full; nothing in the policy pro-rates statutory leave.
     *
     * This is the path that gives a new employee their rows at all. Without it their
     * first leave request cannot be approved.
     */
    private static void grantNewHireLeave(Date today, Map<String, Leave_Balance__c> staged,
                                          List<String> logDetails) {
        Integer yr = today.year();
        List<User> newHires = [
            SELECT Id, Name, Start_Date__c
            FROM User
            WHERE IsActive = TRUE AND Start_Date__c = :today
        ];
        if (newHires.isEmpty()) return;

        Map<String, Leave_Balance__c> existing = loadBalances(idsOf(newHires), new Set<Integer>{ yr });

        for (User usr : newHires) {
            for (Leave_Type_Policy__mdt policy : activePolicies()) {
                Leave_Balance__c row = stage(staged, existing, usr.Id, policy, yr);
                if (ACCRUAL_ANNIVERSARY.equals(policy.Accrual_Method__c) || row.Granted_On__c != null) {
                    continue;
                }
                row.Entitlement_Days__c = TYPE_ANNUAL.equals(policy.Leave_Type__c)
                    ? 13 - usr.Start_Date__c.month()
                    : policy.Entitlement_Days__c;
                row.Used_Days__c  = 0;
                row.Granted_On__c = today;
            }
            logDetails.add('NEWHIRE ' + usr.Name
                + ' | start=' + usr.Start_Date__c
                + ' | annual=' + (13 - usr.Start_Date__c.month()));
        }
    }

    /*
     * LEAVE-8 / LEAVE-27 — refreshment grant, on the anniversary.
     * Tier by completed years of service; expires one month later and is then wiped.
     */
    private static void grantRefreshLeave(Date today, Map<String, Leave_Balance__c> staged,
                                          List<String> logDetails) {
        Integer yr = today.year();
        List<Refresh_Leave_Rule__mdt> rules = getRules();
        Leave_Type_Policy__mdt refreshPolicy = anniversaryPolicy();
        if (rules.isEmpty() || refreshPolicy == null) return;

        // The day is matched in Apex rather than SOQL so that February 29 joiners
        // can be caught on February 28 in non-leap years.
        List<User> candidates = [
            SELECT Id, Name, Start_Date__c
            FROM User
            WHERE IsActive = TRUE
              AND Start_Date__c != NULL
              AND Start_Date__c < :today
              AND CALENDAR_MONTH(Start_Date__c) = :today.month()
        ];
        if (candidates.isEmpty()) return;

        Map<String, Leave_Balance__c> existing = loadBalances(idsOf(candidates), new Set<Integer>{ yr });

        for (User usr : candidates) {
            if (!isAnniversary(usr.Start_Date__c, today)) continue;

            Leave_Balance__c row = stage(staged, existing, usr.Id, refreshPolicy, yr);
            if (row.Granted_On__c != null) continue;

            Integer years = usr.Start_Date__c.monthsBetween(today) / 12;
            Refresh_Leave_Rule__mdt rule = tierFor(rules, years);
            if (rule == null) continue;

            Integer window = rule.Grant_Window_Months__c == null ? 1 : rule.Grant_Window_Months__c.intValue();

            row.Entitlement_Days__c = rule.Days_Granted__c;
            row.Used_Days__c        = 0;
            row.Expiry_Date__c      = today.addMonths(window);
            row.Granted_On__c       = today;

            logDetails.add('REFRESH ' + usr.Name
                + ' | start=' + usr.Start_Date__c
                + ' | years=' + years
                + ' | granted=' + rule.Days_Granted__c
                + ' | expires=' + row.Expiry_Date__c);
        }
    }

    /*
     * LEAVE-9 / LEAVE-27 — expiry sweep, daily.
     *
     * Only the UNUSED portion lapses. Carry over is consumed before current-year
     * entitlement, so the consumed part is MIN(CarriedIn, Used) and that is what
     * survives; the rest is dropped. Availability is Accrued + CarriedIn - Used, so
     * reducing CarriedIn to the consumed amount removes exactly the unused days and
     * leaves the already-taken ones accounted for.
     *
     * Refreshment works the same way against Entitlement_Days__c: granted on the
     * anniversary, and whatever is not used within the window is wiped.
     *
     * Expiry_Date__c is deliberately NOT cleared once the window has closed: it is the
     * date the grant lapsed, and HR needs to see it on a zeroed row. Carry_Over_Expiry__c
     * is still cleared, so the two branches differ.
     *
     * Because the window date survives, this query keeps matching the row on every
     * later run. Nothing is staged on those runs — a row is only written when there is
     * an unused portion left to drop, which is false the moment the first sweep has
     * done its work. That conditional staging is what replaces the old null-out as the
     * re-processing guard; without it every lapsed row would be re-upserted nightly and
     * would keep writing a log file forever.
     *
     * Expired days are simply lost; nothing is paid out.
     */
    private static void expireLeave(Date today, Map<String, Leave_Balance__c> staged,
                                    List<String> logDetails) {
        List<Leave_Balance__c> candidates = [
            SELECT Id, External_Key__c, Employee__r.Name, Leave_Type__c, Leave_Year__c,
                   Entitlement_Days__c, Used_Days__c, Carry_Over_Days__c,
                   Carry_Over_Expiry__c, Expiry_Date__c, Granted_On__c,
                   Accrual_Method__c, Locked_During_Probation__c, Status__c
            FROM Leave_Balance__c
            WHERE Status__c = 'Active'
              AND ((Carry_Over_Expiry__c != NULL AND Carry_Over_Expiry__c < :today)
                OR (Expiry_Date__c != NULL AND Expiry_Date__c < :today))
        ];

        for (Leave_Balance__c queried : candidates) {
            // Read the staged instance where one exists: a grant earlier in this run
            // may have already replaced the expiry date the query matched on.
            Leave_Balance__c row = staged.containsKey(queried.External_Key__c)
                ? staged.get(queried.External_Key__c)
                : queried;

            Boolean carryExpired = row.Carry_Over_Expiry__c != null && row.Carry_Over_Expiry__c < today;
            Boolean windowExpired = row.Expiry_Date__c != null && row.Expiry_Date__c < today;
            if (!carryExpired && !windowExpired) continue;

            Boolean lapsed = false;

            if (carryExpired) {
                Decimal carriedIn = zeroIfNull(row.Carry_Over_Days__c);
                Decimal used      = zeroIfNull(row.Used_Days__c);
                Decimal consumed  = carriedIn < used ? carriedIn : used;
                if (carriedIn > consumed) {
                    logDetails.add('EXPIRE  ' + row.Employee__r.Name
                        + ' | carryOver lapsed=' + (carriedIn - consumed)
                        + ' of ' + carriedIn + ' on ' + row.Carry_Over_Expiry__c);
                }
                row.Carry_Over_Days__c   = consumed;
                row.Carry_Over_Expiry__c = null;
                lapsed = true;
            }

            if (windowExpired) {
                Decimal granted  = zeroIfNull(row.Entitlement_Days__c);
                Decimal used     = zeroIfNull(row.Used_Days__c);
                Decimal consumed = granted < used ? granted : used;
                // Already swept on an earlier run: nothing left to drop, so the row is
                // left alone and Expiry_Date__c keeps standing as the lapse date.
                if (granted > consumed) {
                    logDetails.add('EXPIRE  ' + row.Employee__r.Name
                        + ' | ' + row.Leave_Type__c + ' lapsed=' + (granted - consumed)
                        + ' of ' + granted + ' on ' + row.Expiry_Date__c);
                    row.Entitlement_Days__c = consumed;
                    lapsed = true;
                }
            }

            if (lapsed) staged.put(row.External_Key__c, row);
        }
    }

    // ------------------------------------------------------------------ helpers

    /*
     * The working instance for one employee, leave type and year. Reads the staged
     * map first so several grants on the same day accumulate onto one record, then
     * the database, then creates a new row from the policy.
     */
    private static Leave_Balance__c stage(Map<String, Leave_Balance__c> staged,
                                          Map<String, Leave_Balance__c> existing,
                                          Id employeeId, Leave_Type_Policy__mdt policy, Integer yr) {
        String key = balanceKey(employeeId, policy.Leave_Type__c, yr);
        if (staged.containsKey(key)) {
            return staged.get(key);
        }
        Leave_Balance__c row = existing.get(key);
        if (row == null) {
            row = new Leave_Balance__c(
                Employee__c                = employeeId,
                Leave_Type__c              = policy.Leave_Type__c,
                Leave_Year__c              = yr,
                External_Key__c            = key,
                Entitlement_Days__c        = policy.Entitlement_Days__c,
                Accrual_Method__c          = policy.Accrual_Method__c,
                Locked_During_Probation__c = policy.Locked_During_Probation__c == true,
                Used_Days__c               = 0,
                Pending_Days__c            = 0,
                Carry_Over_Days__c         = 0,
                Status__c                  = 'Active'
            );
        }
        staged.put(key, row);
        return row;
    }

    private static Map<String, Leave_Balance__c> loadBalances(Set<Id> employeeIds, Set<Integer> years) {
        Map<String, Leave_Balance__c> byKey = new Map<String, Leave_Balance__c>();
        List<Decimal> yearValues = new List<Decimal>();
        for (Integer y : years) yearValues.add(y);

        for (Leave_Balance__c bal : [
            SELECT Id, External_Key__c, Employee__c, Leave_Type__c, Leave_Year__c,
                   Entitlement_Days__c, Accrued_Days__c, Available_Days__c,
                   Used_Days__c, Carry_Over_Days__c, Carry_Over_Expiry__c,
                   Expiry_Date__c, Granted_On__c, Accrual_Method__c,
                   Locked_During_Probation__c, Pending_Days__c, Status__c
            FROM Leave_Balance__c
            WHERE Employee__c IN :employeeIds AND Leave_Year__c IN :yearValues
        ]) {
            byKey.put(bal.External_Key__c, bal);
        }
        return byKey;
    }

    private static List<User> employeesStartedBy(Date today) {
        // Start_Date__c <= today excludes future joiners, who receive the pro-rated
        // new-hire grant on their joining date instead of a full year's entitlement.
        return [
            SELECT Id, Name, Start_Date__c
            FROM User
            WHERE IsActive = TRUE
              AND Start_Date__c != NULL
              AND Start_Date__c <= :today
        ];
    }

    private static Set<Id> idsOf(List<User> users) {
        Set<Id> ids = new Set<Id>();
        for (User u : users) ids.add(u.Id);
        return ids;
    }

    /*
     * Must match ApplicationItemTriggerLogic.balanceKey and
     * scripts/apex/03_backfill_leave_balances.apex exactly.
     */
    private static String balanceKey(Id employeeId, String leaveType, Integer yr) {
        return employeeId + '-' + leaveType + '-' + yr;
    }

    @TestVisible
    private static List<Leave_Type_Policy__mdt> activePolicies() {
        List<Leave_Type_Policy__mdt> source = policyOverride != null
            ? policyOverride
            : Leave_Type_Policy__mdt.getAll().values();
        List<Leave_Type_Policy__mdt> active = new List<Leave_Type_Policy__mdt>();
        for (Leave_Type_Policy__mdt p : source) {
            if (p.Active__c == true) active.add(p);
        }
        return active;
    }

    /** The single type granted on an anniversary — Refreshment Leave. */
    private static Leave_Type_Policy__mdt anniversaryPolicy() {
        for (Leave_Type_Policy__mdt p : activePolicies()) {
            if (ACCRUAL_ANNIVERSARY.equals(p.Accrual_Method__c)) return p;
        }
        return null;
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

    @TestVisible
    private static List<Refresh_Leave_Rule__mdt> getRules() {
        return ruleOverride != null ? ruleOverride : Refresh_Leave_Rule__mdt.getAll().values();
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }

    /*
     * Synchronous now. This was @future only because the class used to update User,
     * a setup object, in the same transaction as Error_Log__c and ContentVersion.
     * It writes no User records any more, so there is no mixed DML to dodge.
     */
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