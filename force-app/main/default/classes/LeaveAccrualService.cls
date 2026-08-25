/*
 * LEAVE-51 — accrual moves out of the Accrued_To_Date__c formula and into Apex.
 *
 * Accrued_To_Date__c and Available_Balance__c were formula fields. They were correct, and
 * being formulas they could never go stale, but neither could be reached by a unit
 * test except through a saved record and the real calendar, and the accrual rule was
 * a single nested IF that nobody could safely change. Both are now stored Number
 * fields and this class is the only thing that decides what goes in them.
 *
 * Moving the rule here was a refactor and changed nothing. LEAVE-52 then changed one
 * thing deliberately, and it is the only intended difference from the old formula:
 *
 *   The monthly day is credited on the FIRST of the month rather than the last, for
 *   EVERYONE on Monthly accrual. Nobody is made to wait until the 31st for a day they
 *   will certainly earn: a continuing employee opens January with a day in hand, and
 *   somebody who joins in July reads one day in July. This is what the legacy
 *   User.Accrued_Leave_Days__c formula has always done — MONTH(TODAY()) for a
 *   continuing employee, MONTH(TODAY()) - MONTH(Start_Date__c) + 1 for a joiner.
 *
 *   LEAVE-53: the joiner half of that was missed the first time round. Only the
 *   continuing branch was moved to month start, so a March joiner read 5 days on
 *   25 August where the formula field and the User formula both said 6. Crediting the
 *   month in progress is NOT paying a day ahead of the pro-rate: the entitlement is
 *   13 - joining month COUNTING the joining month, so a March joiner tops out at
 *   exactly 10 either way. The two rules only ever differed by a month of timing.
 *
 * Any OTHER movement is a bug in here, not a new rule.
 *
 * ---------------------------------------------------------------- what maintains it
 *
 * Two things write these fields, and between them they cover every way a figure can
 * move:
 *
 *   LeaveBalanceTrigger   before insert and before update, so ANY path that saves a
 *                         balance leaves it consistent — the approval deduction, the
 *                         reversal, the split, the conversion, the migration, the
 *                         grant job, and a person editing Used_Days__c by hand on the
 *                         record page. No service has to remember to call this.
 *
 *   sweep()               the calendar moving on its own, which is the one case no
 *                         trigger can catch: nobody saves anything on 31 March, yet
 *                         that is the day a month's accrual is credited. Run from
 *                         LeaveManagementController.runDaily, BEFORE the grants —
 *                         the January carry-over reads the prior year's Available and
 *                         must not read a figure left over from the last save.
 *
 * ------------------------------------------------------------------ "as of" is real
 *
 * The accrual is measured against the REAL clock, never against the effective date
 * handed to runDaily. That is deliberate and it is what the formula did: TODAY() does
 * not care which date the job was replayed for. Replaying a missed run for 30 June must
 * not rewind everybody's accrual to what it was in June.
 *
 * simulateAsOf is the single, sandbox-only exception, for the Leave Job Runner asking
 * what a date WOULD look like. todayOverride is the same seam a test drives.
 */
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

    /*
     * Moves the accrual clock for the REST OF THE TRANSACTION, so a what-if run can ask
     * what the figures would read on some other date.
     *
     * This exists for the Leave Job Runner, and it is the only thing that makes a
     * future-dated run mean anything. Travelling the grant date alone is not enough:
     * the January carry-over is capped from the PRIOR year's Available, and that year
     * only reads its full entitlement once the clock is past it. Run 1 January 2027 with
     * the clock still on today and every prior-year row still looks part-accrued, so the
     * carry over comes out short — measured in dev5-ts, wrong on 11 of 20 rows.
     *
     * It also has to be a static rather than a parameter threaded through runDaily,
     * because LeaveBalanceTrigger recalculates on every save the run performs and there
     * is no argument to hand it.
     *
     * Sandbox only, and guarded here as well as in the runner. A production caller that
     * moved this clock would write a whole org's balances as at the wrong date.
     */
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

    // ------------------------------------------------------------------ the rule

    /**
     * Entitlement earned so far.
     *
     * A future leave year has earned nothing, and an employee with no joining date
     * cannot be measured at all — both read zero, as the formula's outer IF did.
     *
     * A CLOSED year reads the full entitlement. It is not re-derived from the calendar:
     * the year is over, so whatever was granted was earned, and a monthly accrual that
     * stopped short would otherwise strand days the employee had already worked for.
     *
     * In the CURRENT year only Monthly accrues; everything else is granted up front and
     * reads its entitlement in full. Monthly credits one day a month and the day lands on
     * the FIRST of the month for everybody, so the month in progress is already earned.
     * All that differs is where the count starts:
     *
     *   Joined in an EARLIER year — count from January. The year opens with one day
     *   already available and the twelfth lands on 1 December rather than on New
     *   Year's Eve.
     *
     *   Joined DURING this year — count from the joining month, so the joining month
     *   itself reads one day. Their entitlement is pro-rated to 13 - joining month
     *   COUNTING that month, so this still tops out at exactly the entitlement: a March
     *   joiner is granted 10 and reaches 10 on 1 December.
     *
     * Months before the joining month come out negative and are floored at zero, so a row
     * created ahead of a joiner is never a debt.
     *
     * @param startDate       the employee's joining date; null means nothing is earned
     * @param leaveYear       the balance row's leave year
     * @param accrualMethod   Monthly, Upfront, Anniversary, or blank for no accrual
     * @param entitlementDays days granted for the year — the ceiling on the accrual
     * @param asOf            the date to measure against
     */
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

        /*
         * The current month is credited at its START, so it counts. A joiner counts from
         * the joining month and everybody else from January — the + 1 is what makes the
         * joining month itself earned, the same way asOf.month() already counts January
         * for a continuing employee. A month-end bump on top of either branch would pay
         * the same month twice and hand over next month's day on the 31st.
         */
        Integer monthsEarned = startDate.year() == leaveYear
            ? asOf.month() - startDate.month() + 1
            : asOf.month();

        Decimal earned = monthsEarned;
        if (earned > entitlement) earned = entitlement;
        if (earned < 0) earned = 0;
        return earned;
    }

    /**
     * Accrued + carried in - used.
     *
     * Availability is capped by what has ACCRUED, not by the full entitlement, which is
     * what stops somebody spending December's day in January. carriedIn is the figure
     * carried in at the January grant and is deliberately not decremented as days are
     * taken — see Carry_Over_Days__c for why the pair cancels at the June sweep.
     */
    public static Decimal availableFor(Decimal accruedDays, Decimal carriedInDays, Decimal usedDays) {
        return zeroIfNull(accruedDays) + zeroIfNull(carriedInDays) - zeroIfNull(usedDays);
    }

    // ------------------------------------------------------------------ applying it

    /**
     * Writes both figures onto one in-memory row.
     *
     * @return true when either figure actually moved, so a caller can update only the
     *         rows that changed. The sweep runs nightly across the whole org and on all
     *         but a month boundary changes nothing at all; without this it would rewrite
     *         every balance in the org every night for no reason.
     */
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

    /**
     * Brings every active balance up to date with the calendar and saves what moved.
     *
     * This is the half of the maintenance the trigger cannot do. On 31 March a monthly
     * accrual is credited without anybody touching a record, and on 1 January every
     * prior-year row goes from a partial accrual to its full entitlement — which the
     * annual grant then reads as the carry-over figure, so this has to have run first.
     *
     * Synchronous on purpose. The job runner previews a run inside a savepoint and rolls
     * it back; a Batchable would escape that savepoint and a "preview" would write for
     * real. The write stays small because only changed rows are saved, and on an ordinary
     * day that is none of them.
     *
     * @return how many rows were rewritten
     */
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