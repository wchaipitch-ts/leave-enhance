public with sharing class LeaveManagementController implements Schedulable {

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
        Map<String, Leave_Balance__c> staged = new Map<String, Leave_Balance__c>();
        List<String> logDetails = new List<String>{
            'Run Date: ' + System.now(),
            'Effective Date: ' + today,
            '--------------------------------------'
        };

        try {
            Integer resettled = LeaveAccrualService.sweep(LeaveAccrualService.asOfDate());
            if (resettled > 0) {
                logDetails.add('ACCRUAL ' + resettled + ' balance row(s) recalculated');
            }

            if (today.month() == 1 && today.day() == 1) {
                grantAnnualLeave(today, staged, logDetails);
            }
            grantNewHireLeave(today, staged, logDetails);
            grantRefreshLeave(today, staged, logDetails);
            // Expiry runs last so it evaluates the dates this run has just written,
            // not the stale ones still in the database.
            expireLeave(today, staged, logDetails);

            if (!staged.isEmpty()) {
                // The upsert re-enters LeaveBalanceTrigger, which recalculates the
                // accrual on every staged row — so a grant, a carry-over or an expiry
                // written above lands with its derived figures already correct.
                upsert staged.values() External_Key__c;
            }
            if (!staged.isEmpty() || resettled > 0) {
                createLogFile(String.join(logDetails, '\n'));
            }
        } catch (Exception e) {
            System.debug('An unexpected error has occurred: ' + e.getMessage() + '\n' + e.getStackTraceString());
            // Rethrow in tests so logic and configuration errors surface instead of being swallowed.
            if (Test.isRunningTest()) throw e;
        }
    }

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
                    Decimal priorAvailable = prior == null ? 0 : zeroIfNull(prior.Available_Balance__c);
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

    private static void grantRefreshLeave(Date today, Map<String, Leave_Balance__c> staged,
                                          List<String> logDetails) {
        Integer yr = today.year();
        List<Refresh_Leave_Rule__mdt> rules = getRules();
        Leave_Type_Policy__mdt refreshPolicy = anniversaryPolicy();
        if (rules.isEmpty() || refreshPolicy == null) return;

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
            /*
             * Entitlement is decided before the row is touched, because stage() does not
             * merely read — it puts the row in the staged map and everything there is
             * upserted. Staging first meant somebody in their joining month with no
             * completed year, who matches no tier, still had an empty Refresh Leave row
             * written for them. Harmless-looking, and it made the expiry sweep churn.
             */
            Integer years = usr.Start_Date__c.monthsBetween(today) / 12;
            Refresh_Leave_Rule__mdt rule = tierFor(rules, years);
            if (rule == null) continue;

            Leave_Balance__c row = stage(staged, existing, usr.Id, refreshPolicy, yr);
            if (row.Granted_On__c != null) continue;

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

            Decimal carriedIn = zeroIfNull(row.Carry_Over_Days__c);
            // An empty bucket has already been swept, or never had anything in it.
            // Either way there is nothing to do, and skipping keeps the row from
            // being re-staged every night for the rest of the year.
            if (carryExpired && carriedIn > 0) {
                Decimal used     = zeroIfNull(row.Used_Days__c);
                Decimal consumed = carriedIn < used ? carriedIn : used;

                logDetails.add('EXPIRE  ' + row.Employee__r.Name
                    + ' | carryOver lapsed=' + (carriedIn - consumed)
                    + ' of ' + carriedIn + ', spent=' + consumed
                    + ' on ' + row.Carry_Over_Expiry__c);

                row.Carry_Over_Days__c = 0;
                row.Used_Days__c       = used - consumed;
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
                   Entitlement_Days__c, Accrued_To_Date__c, Available_Balance__c,
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