/*
 * LEAVE-49 — a TEMPORARY test harness for the nightly leave job.
 *
 * ============================ DELETE THIS BEFORE PRODUCTION ============================
 *
 * The grant engine is the half of the leave system nobody can exercise from the UI. It
 * builds next year's balance rows on 1 January, carries unused annual days forward,
 * grants refreshment in the anniversary month and sweeps up what lapses on 30 June —
 * and every one of those is reachable only by running LeaveManagementController.runDaily
 * for a chosen date, which until now meant somebody writing Apex. That put the whole
 * yearly cycle out of reach of the people who most need to sign it off.
 *
 * This lets a BA pick a date, press a button, and read what moved.
 *
 * WHAT KEEPS IT SAFE
 *
 *   Sandbox only.       Refuses outright in a production org. runDaily writes to every
 *                       employee's balances, not just the one being watched, and that is
 *                       not something a button should be able to do to live payroll data.
 *   Permission gated.   Needs the Run Leave Job custom permission, or Modify All Data.
 *   Preview by default. The default run wraps everything in a savepoint and rolls it back,
 *                       so the BA sees exactly what WOULD change without changing it.
 *                       Committing is a separate, deliberate second press.
 *
 * The preview is the point. The job is idempotent by design, but it is still a bulk write
 * across the org, and being able to look before leaping is what makes it reasonable to
 * hand to somebody who is not going to read the Apex first.
 */
public with sharing class LeaveJobRunnerController {

    private static final String PERMISSION = 'Run_Leave_Job';

    /* One figure, before and after, already formatted for display. */
    public class Cell {
        @AuraEnabled public String label;
        @AuraEnabled public String value;      // "6 → 0" when it moved, "0" when it did not
        @AuraEnabled public Boolean changed;
        Cell(String label, Object before, Object after) {
            this.label = label;
            String b = plain(before);
            String a = plain(after);
            this.changed = b != a;
            this.value = this.changed ? b + ' → ' + a : a;
        }
    }

    public class BalanceRow {
        @AuraEnabled public String leaveType;
        @AuraEnabled public Boolean changed;
        @AuraEnabled public Boolean isNew;     // the run created this row
        @AuraEnabled public List<Cell> cells;
    }

    public class RunResult {
        @AuraEnabled public Boolean applied;          // false = previewed and rolled back
        @AuraEnabled public String runDate;
        @AuraEnabled public String employeeName;
        @AuraEnabled public Integer year;
        @AuraEnabled public Integer changedRows;
        @AuraEnabled public Integer orgWideChangedRows;
        @AuraEnabled public String summary;
        @AuraEnabled public List<BalanceRow> rows;
    }

    /*
     * Whether to render at all. The component shares the Leave Balance tab with the
     * employee-facing balance screen, so for everybody who is not testing the year-end
     * cycle it must be invisible rather than an error box - an ordinary employee opening
     * their own balances should never learn this exists.
     *
     * Returns false instead of throwing for the same reason.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean isAvailable() {
        try {
            assertAllowed();
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /** Active employees with a joining date, the only ones the job can act on. */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getEmployees() {
        assertAllowed();
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (User u : [
            SELECT Id, Name, Start_Date__c
            FROM User
            WHERE IsActive = TRUE AND Start_Date__c != NULL
            ORDER BY Name
            LIMIT 500
        ]) {
            out.add(new Map<String, Object>{
                'label' => u.Name + '  (joined ' + u.Start_Date__c.format() + ')',
                'value' => u.Id
            });
        }
        return out;
    }

    /**
     * Runs the nightly job as at runDate and reports what it did to one employee's rows.
     *
     * @param runDate     the date to run as of — 1 January, 1 July, an anniversary month
     * @param employeeId  whose balances to show; the job itself always runs org-wide
     * @param year        the leave year to display
     * @param commitRun   false previews and rolls back, true keeps the changes
     */
    @AuraEnabled
    public static RunResult run(Date runDate, Id employeeId, Integer year, Boolean commitRun) {
        assertAllowed();
        if (runDate == null) {
            throw new AuraHandledException('Pick a date to run as of.');
        }
        if (employeeId == null) {
            throw new AuraHandledException('Pick an employee whose balances you want to watch.');
        }
        Integer yr = year == null ? runDate.year() : year;

        Map<String, Leave_Balance__c> before = snapshot(employeeId, yr);
        Integer beforeOrgWide = countRows();

        RunResult result = new RunResult();
        result.applied = commitRun == true;
        result.runDate = runDate.format();
        result.year = yr;
        result.employeeName = [SELECT Name FROM User WHERE Id = :employeeId].Name;

        /*
         * The savepoint is taken even for a committed run. Nothing rolls back to it in
         * that case, but taking it unconditionally keeps the two paths identical up to
         * the single decision below, so a preview cannot diverge from what committing
         * would actually do.
         */
        Savepoint sp = Database.setSavepoint();
        Map<String, Leave_Balance__c> after;
        Integer afterOrgWide;
        try {
            LeaveManagementController.runDaily(runDate);
            after = snapshot(employeeId, yr);
            afterOrgWide = countRows();
        } finally {
            if (commitRun != true) {
                Database.rollback(sp);
            }
        }

        result.rows = compare(before, after);
        Integer changed = 0;
        for (BalanceRow r : result.rows) {
            if (r.changed) changed++;
        }
        result.changedRows = changed;
        result.orgWideChangedRows = afterOrgWide - beforeOrgWide;
        result.summary = summarise(result, changed);
        return result;
    }

    /* Balance rows for one employee and year, keyed by leave type. */
    private static Map<String, Leave_Balance__c> snapshot(Id employeeId, Integer yr) {
        Map<String, Leave_Balance__c> byType = new Map<String, Leave_Balance__c>();
        for (Leave_Balance__c b : [
            SELECT Leave_Type__c, Entitlement_Days__c, Accrued_Days__c, Carry_Over_Days__c,
                   Carry_Over_Remaining__c, Used_Days__c, Available_Days__c,
                   Granted_On__c, Carry_Over_Expiry__c, Expiry_Date__c
            FROM Leave_Balance__c
            WHERE Employee__c = :employeeId AND Leave_Year__c = :yr
            ORDER BY Leave_Type__c
        ]) {
            byType.put(b.Leave_Type__c, b);
        }
        return byType;
    }

    /*
     * Rows across the whole org, so the BA can see that a run touched other people too.
     * The job is not scoped to the employee being watched and the screen should not
     * pretend otherwise.
     */
    private static Integer countRows() {
        return [SELECT COUNT() FROM Leave_Balance__c];
    }

    private static List<BalanceRow> compare(Map<String, Leave_Balance__c> before,
                                            Map<String, Leave_Balance__c> after) {
        Set<String> types = new Set<String>();
        types.addAll(before.keySet());
        types.addAll(after.keySet());
        List<String> ordered = new List<String>(types);
        ordered.sort();

        List<BalanceRow> rows = new List<BalanceRow>();
        for (String t : ordered) {
            Leave_Balance__c b = before.get(t);
            Leave_Balance__c a = after.get(t);
            BalanceRow row = new BalanceRow();
            row.leaveType = t;
            row.isNew = (b == null);
            row.cells = new List<Cell>{
                new Cell('Entitlement',      num(b, 'Entitlement_Days__c'),      num(a, 'Entitlement_Days__c')),
                new Cell('Accrued',          num(b, 'Accrued_Days__c'),          num(a, 'Accrued_Days__c')),
                new Cell('Carried In',       num(b, 'Carry_Over_Days__c'),       num(a, 'Carry_Over_Days__c')),
                new Cell('Carry Over Left',  num(b, 'Carry_Over_Remaining__c'),  num(a, 'Carry_Over_Remaining__c')),
                new Cell('Used',             num(b, 'Used_Days__c'),             num(a, 'Used_Days__c')),
                new Cell('Available',        num(b, 'Available_Days__c'),        num(a, 'Available_Days__c')),
                new Cell('Granted On',       dat(b, 'Granted_On__c'),            dat(a, 'Granted_On__c')),
                new Cell('Carry Expiry',     dat(b, 'Carry_Over_Expiry__c'),     dat(a, 'Carry_Over_Expiry__c')),
                new Cell('Window Expiry',    dat(b, 'Expiry_Date__c'),           dat(a, 'Expiry_Date__c'))
            };
            row.changed = false;
            for (Cell c : row.cells) {
                if (c.changed) row.changed = true;
            }
            rows.add(row);
        }
        return rows;
    }

    private static String summarise(RunResult r, Integer changed) {
        String head = r.applied
            ? 'Applied. These changes are saved.'
            : 'Preview only — everything below was rolled back and nothing was saved.';
        if (changed == 0 && r.orgWideChangedRows == 0) {
            return head + ' The job ran and changed nothing for '
                + r.employeeName + ' on ' + r.runDate + '. That is usually right: every grant '
                + 'is stamped once and a repeat run is meant to be a no-op.';
        }
        String detail = ' ' + changed + ' of ' + r.rows.size() + ' balance rows moved for '
            + r.employeeName + '.';
        if (r.orgWideChangedRows > 0) {
            detail += ' The run also created ' + r.orgWideChangedRows
                + ' new balance row(s) across other employees — the job is org-wide, '
                + 'not scoped to the person you are watching.';
        }
        return head + detail;
    }

    private static Object num(Leave_Balance__c b, String field) {
        return b == null ? null : b.get(field);
    }

    private static Object dat(Leave_Balance__c b, String field) {
        return b == null ? null : b.get(field);
    }

    /* 1.0 reads as 1, and an empty figure reads as a dash rather than the word null. */
    private static String plain(Object value) {
        if (value == null) return '—';
        if (value instanceof Decimal) return ((Decimal) value).stripTrailingZeros().toPlainString();
        if (value instanceof Date) return ((Date) value).format();
        return String.valueOf(value);
    }

    /*
     * Two gates, and the sandbox one is not negotiable. runDaily rewrites entitlements
     * for every employee in the org; a screen that can do that to production is a
     * mistake waiting for a mis-click, however carefully it is permissioned.
     */
    @TestVisible
    private static void assertAllowed() {
        if (!isSandbox()) {
            throw new AuraHandledException(
                'This tool only runs in a sandbox. It rewrites leave balances across the '
                + 'whole org, which is not something to do from a button in production.');
        }
        /*
         * The custom permission and nothing else. An earlier version also let anyone with
         * edit access to Leave_Balance__c through, which is far too many people - object
         * access is granted broadly and says nothing about whether somebody should be able
         * to rewrite the whole org's entitlements from a button.
         */
        if (!FeatureManagement.checkPermission(PERMISSION)) {
            throw new AuraHandledException(
                'You need the Run Leave Job permission to use this. Ask an administrator '
                + 'for the Leave Job Runner permission set.');
        }
    }

    @TestVisible private static Boolean sandboxOverride;

    private static Boolean isSandbox() {
        if (sandboxOverride != null) {
            return sandboxOverride;
        }
        return [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
    }
}
