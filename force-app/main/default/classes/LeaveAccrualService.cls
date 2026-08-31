public with sharing class LeaveAccrualService {

    private static final String METHOD_MONTHLY = 'Monthly';

    // Test seam for the clock. Null means System.today(), which is what production uses.
    @TestVisible private static Date todayOverride;

    /*
     * Joining dates already resolved in this transaction. A balance save is almost
     * always several rows for one person, and a bulk upsert re-enters the trigger once
     * per 200 rows; without this the migration would spend a SOQL query on every chunk
     * re-reading the same handful of employees.
     */
    private static final Map<Id, Date> START_DATE_CACHE = new Map<Id, Date>();

    /** The date the accrual is measured against. */
    public static Date asOfDate() {
        return todayOverride != null ? todayOverride : System.today();
    }

    public static void simulateAsOf(Date asOf) {
        if (!Test.isRunningTest() && !isSandbox()) {
            throw new SecurityException(
                'The accrual clock can only be moved in a sandbox.');
        }
        todayOverride = asOf;
    }

    /** Puts the clock back. Callers must do this in a finally, not on the happy path. */
    public static void endSimulation() {
        todayOverride = null;
    }

    private static Boolean sandboxCache;
    private static Boolean isSandbox() {
        if (sandboxCache == null) {
            sandboxCache = [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
        }
        return sandboxCache;
    }

    public static Decimal accruedFor(Date startDate, Integer leaveYear, String accrualMethod,
                                     Decimal entitlementDays, Date asOf) {
        Decimal entitlement = zeroIfNull(entitlementDays);

        if (startDate == null || leaveYear == null || leaveYear > asOf.year()) {
            return 0;
        }
        if (leaveYear < asOf.year()) {
            return entitlement;
        }
        if (!METHOD_MONTHLY.equals(accrualMethod)) {
            return entitlement;
        }

        Integer monthsEarned = startDate.year() == leaveYear
            ? asOf.month() - startDate.month() + 1
            : asOf.month();

        Decimal earned = monthsEarned;
        if (earned > entitlement) earned = entitlement;
        if (earned < 0) earned = 0;
        return earned;
    }

    public static Decimal availableFor(Decimal accruedDays, Decimal carriedInDays, Decimal usedDays) {
        return zeroIfNull(accruedDays) + zeroIfNull(carriedInDays) - zeroIfNull(usedDays);
    }

    public static Boolean applyTo(Leave_Balance__c bal, Date startDate, Date asOf) {
        Integer leaveYear = bal.Leave_Year__c == null ? null : bal.Leave_Year__c.intValue();

        Decimal accrued = scaled(accruedFor(
            startDate, leaveYear, bal.Accrual_Method__c, bal.Entitlement_Days__c, asOf));
        Decimal available = scaled(availableFor(
            accrued, bal.Carry_Over_Days__c, bal.Used_Days__c));

        /*
         * A null counts as moved even when the computed figure is zero. These fields are
         * never legitimately blank once maintained, so a blank one is always wrong — and
         * treating it as zero would strand exactly the rows a backfill exists to fill:
         * a row whose correct accrual IS zero would read as unchanged and never be
         * written, leaving it null forever.
         */
        Boolean moved = bal.Accrued_To_Date__c == null
                     || bal.Available_Balance__c == null
                     || scaled(bal.Accrued_To_Date__c) != accrued
                     || scaled(bal.Available_Balance__c) != available;

        bal.Accrued_To_Date__c   = accrued;
        bal.Available_Balance__c = available;
        return moved;
    }

    /**
     * Recalculates a batch in place, resolving each employee's joining date once.
     *
     * @return the rows whose figures moved
     */
    public static List<Leave_Balance__c> recalculate(List<Leave_Balance__c> balances, Date asOf) {
        List<Leave_Balance__c> moved = new List<Leave_Balance__c>();
        if (balances == null || balances.isEmpty()) {
            return moved;
        }
        Map<Id, Date> startDates = startDatesFor(balances);
        for (Leave_Balance__c bal : balances) {
            if (applyTo(bal, startDates.get(bal.Employee__c), asOf)) {
                moved.add(bal);
            }
        }
        return moved;
    }

    public static Integer sweep(Date asOf) {
        /*
         * Every column applyTo reads. Selecting less than this does not fail — it
         * computes from nulls and writes zeroes over good figures — so the list is
         * spelled out here rather than trusted to a caller.
         *
         * Closed rows are left alone: the year is settled and nothing about it can
         * move again, so there is no reason to carry them through the sweep.
         */
        List<Leave_Balance__c> rows = [
            SELECT Id, Employee__c, Leave_Year__c, Accrual_Method__c, Entitlement_Days__c,
                   Carry_Over_Days__c, Used_Days__c, Accrued_To_Date__c, Available_Balance__c
            FROM Leave_Balance__c
            WHERE Status__c = 'Active'
            LIMIT 50000
        ];
        List<Leave_Balance__c> moved = recalculate(rows, asOf);
        if (!moved.isEmpty()) {
            update moved;
        }
        return moved.size();
    }

    // ------------------------------------------------------------------ helpers

    /*
     * Joining dates for a batch of balances. Employee__r.Start_Date__c cannot be reached
     * from Trigger.new — a before trigger holds no parent records — so the lookup is
     * resolved here rather than selected alongside the balance.
     */
    private static Map<Id, Date> startDatesFor(List<Leave_Balance__c> balances) {
        Set<Id> wanted = new Set<Id>();
        for (Leave_Balance__c bal : balances) {
            if (bal.Employee__c != null && !START_DATE_CACHE.containsKey(bal.Employee__c)) {
                wanted.add(bal.Employee__c);
            }
        }
        if (!wanted.isEmpty()) {
            for (User usr : [SELECT Id, Start_Date__c FROM User WHERE Id IN :wanted]) {
                START_DATE_CACHE.put(usr.Id, usr.Start_Date__c);
            }
            // Cache the misses too, so a balance pointing at a deleted or filtered-out
            // user does not send every later chunk back to the database for it.
            for (Id employeeId : wanted) {
                if (!START_DATE_CACHE.containsKey(employeeId)) {
                    START_DATE_CACHE.put(employeeId, null);
                }
            }
        }
        return START_DATE_CACHE;
    }

    /*
     * Both fields store one decimal place. Comparing at the stored scale is what keeps
     * the sweep honest: 6 and 6.0 are the same figure, and treating them as different
     * would mark every row as changed on every run.
     */
    private static Decimal scaled(Decimal value) {
        return zeroIfNull(value).setScale(1);
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}