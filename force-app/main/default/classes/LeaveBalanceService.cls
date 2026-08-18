/*
 * LEAVE-32 — serves Leave_Balance__c to the UI.
 *
 * Until now nothing did. Balances moved off the User object in LEAVE-25, but the
 * timesheet card kept reading User.Annual_Leave_Day__c, a field no code has written
 * since. It is a frozen pre-migration snapshot that drifts further with every
 * approval, so the card has been quietly overstating people's leave. This class is
 * what the card and the Leave Balance page should read instead.
 *
 * Deliberately "without sharing". Leave_Balance__c has a Private sharing model and the
 * employee is a lookup, not the owner — the rows are owned by whoever ran the grant
 * job. Under "with sharing" an ordinary employee would therefore see nothing at all,
 * including their own balance. Access is instead decided explicitly in assertCanView,
 * which is narrower than sharing would be and, unlike sharing, is visible in one place.
 */
public without sharing class LeaveBalanceService {

    /*
     * Viewing somebody else's balance reuses the permission the timesheet already
     * gates its user picker on, so the two screens cannot disagree about who may look
     * at whom. Leave Management Admin is accepted as well for HR and support.
     */
    private static final Set<String> VIEW_OTHERS_PERMISSION_SETS = new Set<String>{
        'Time_Sheet_Management_Screen_Permission',
        'Leave_Management_Admin'
    };

    // Resettable so a test can switch running user inside one transaction.
    @TestVisible private static Boolean canViewOthersCache;

    /** One row of the Leave Balance page, or one figure on the timesheet card. */
    public class LeaveBalanceView {
        @AuraEnabled public String leaveType;
        @AuraEnabled public Decimal entitlement;
        @AuraEnabled public Decimal accrued;
        @AuraEnabled public Decimal carriedIn;
        @AuraEnabled public Decimal used;
        @AuraEnabled public Decimal pending;
        @AuraEnabled public Decimal available;
        @AuraEnabled public Boolean isLocked;
        @AuraEnabled public String lockReason;
        @AuraEnabled public Date expiryDate;
        @AuraEnabled public Date carryOverExpiry;
        /*
         * When the entitlement was handed over. Refreshment leave lives for a month from
         * this date, so a card showing the expiry needs the start of the window too.
         */
        @AuraEnabled public Date grantedOn;
        /*
         * False when the type is configured to show but the grant job has not created
         * a row yet. The row still comes back, at zero, so a missing entitlement shows
         * up on the page as a zero instead of vanishing from it.
         */
        @AuraEnabled public Boolean hasRecord;
    }

    /**
     * Every leave type configured to appear on the balance page, in policy sort order.
     *
     * @param employeeId whose balances; null means the running user
     * @param year       the leave year
     */
    @AuraEnabled(cacheable=true)
    public static List<LeaveBalanceView> getBalances(Id employeeId, Integer year) {
        Id target = resolveAndAuthorise(employeeId);
        if (year == null) {
            throw new AuraHandledException('A leave year is required.');
        }

        Map<String, Leave_Balance__c> rowByType = new Map<String, Leave_Balance__c>();
        for (Leave_Balance__c bal : [
            SELECT Leave_Type__c, Entitlement_Days__c, Accrued_Days__c, Carry_Over_Days__c,
                   Used_Days__c, Available_Days__c, Is_Locked__c, Lock_Reason__c,
                   Expiry_Date__c, Carry_Over_Expiry__c, Granted_On__c
            FROM Leave_Balance__c
            WHERE Employee__c = :target AND Leave_Year__c = :year
        ]) {
            rowByType.put(bal.Leave_Type__c, bal);
        }

        Map<String, Decimal> pendingByType = pendingDaysByType(target, year);

        List<LeaveBalanceView> views = new List<LeaveBalanceView>();
        for (Leave_Type_Policy__mdt policy : visiblePolicies()) {
            views.add(viewFor(policy, rowByType.get(policy.Leave_Type__c),
                              pendingByType.get(policy.Leave_Type__c)));
        }
        return views;
    }

    /**
     * A single figure, for the timesheet card. Replaces User.Annual_Leave_Day__c.
     * Returns zero rather than null when no row exists, so a card can render it.
     */
    @AuraEnabled(cacheable=true)
    public static Decimal getAvailableDays(Id employeeId, String leaveType, Integer year) {
        Id target = resolveAndAuthorise(employeeId);
        if (String.isBlank(leaveType) || year == null) {
            throw new AuraHandledException('A leave type and a leave year are required.');
        }
        for (Leave_Balance__c bal : [
            SELECT Available_Days__c FROM Leave_Balance__c
            WHERE Employee__c = :target AND Leave_Year__c = :year AND Leave_Type__c = :leaveType
            LIMIT 1
        ]) {
            return zeroIfNull(bal.Available_Days__c);
        }
        return 0;
    }

    /**
     * The years this employee actually has balances for, newest first — the year
     * picker on the Leave Balance page. Derived from the rows rather than from a fixed
     * range, so it cannot offer a year with nothing behind it.
     */
    @AuraEnabled(cacheable=true)
    public static List<Integer> getAvailableYears(Id employeeId) {
        Id target = resolveAndAuthorise(employeeId);
        Set<Integer> years = new Set<Integer>();
        for (Leave_Balance__c bal : [
            SELECT Leave_Year__c FROM Leave_Balance__c
            WHERE Employee__c = :target AND Leave_Year__c != NULL
        ]) {
            years.add(bal.Leave_Year__c.intValue());
        }
        List<Integer> sorted = new List<Integer>(years);
        sorted.sort();
        List<Integer> newestFirst = new List<Integer>();
        for (Integer i = sorted.size() - 1; i >= 0; i--) {
            newestFirst.add(sorted[i]);
        }
        return newestFirst;
    }

    // ------------------------------------------------------------------ internals

    private static LeaveBalanceView viewFor(Leave_Type_Policy__mdt policy,
                                            Leave_Balance__c bal,
                                            Decimal pending) {
        LeaveBalanceView view = new LeaveBalanceView();
        view.leaveType = policy.Leave_Type__c;
        view.pending = zeroIfNull(pending);
        view.hasRecord = bal != null;

        if (bal == null) {
            view.entitlement = 0;
            view.accrued = 0;
            view.carriedIn = 0;
            view.used = 0;
            view.available = 0;
            view.isLocked = false;
            return view;
        }

        view.entitlement     = zeroIfNull(bal.Entitlement_Days__c);
        view.accrued         = zeroIfNull(bal.Accrued_Days__c);
        view.carriedIn       = zeroIfNull(bal.Carry_Over_Days__c);
        view.used            = zeroIfNull(bal.Used_Days__c);
        view.available       = zeroIfNull(bal.Available_Days__c);
        view.isLocked        = bal.Is_Locked__c == true;
        view.lockReason      = bal.Lock_Reason__c;
        view.expiryDate      = bal.Expiry_Date__c;
        view.carryOverExpiry = bal.Carry_Over_Expiry__c;
        view.grantedOn       = bal.Granted_On__c;
        return view;
    }

    /*
     * Days already requested but not yet approved.
     *
     * Computed from the requests rather than read from Leave_Balance__c.Pending_Days__c,
     * which no code has ever written. A stored counter would have to be maintained on
     * submit, withdraw, reject and delete, and would be wrong the first time one of
     * those was missed; counting the requests cannot drift.
     *
     * Available_Days__c deliberately does NOT subtract this — it is shown alongside so
     * somebody can see they have asked for more than is left.
     */
    private static Map<String, Decimal> pendingDaysByType(Id employeeId, Integer year) {
        Map<String, Decimal> byType = new Map<String, Decimal>();
        Date yearStart = Date.newInstance(year, 1, 1);
        Date yearEnd = Date.newInstance(year, 12, 31);

        for (AggregateResult row : [
            SELECT Request_Type__c type, SUM(Leave_Days__c) days
            FROM ApplicationItem__c
            WHERE OwnerId = :employeeId
              AND RecordType.DeveloperName != 'Overtime_Request'
              AND Status__c IN ('Draft', 'Pending')
              AND Term_From__c >= :yearStart
              AND Term_From__c <= :yearEnd
            GROUP BY Request_Type__c
        ]) {
            byType.put((String) row.get('type'), (Decimal) row.get('days'));
        }
        return byType;
    }

    /** Active policies flagged for the balance page, in their configured order. */
    private static List<Leave_Type_Policy__mdt> visiblePolicies() {
        List<Leave_Type_Policy__mdt> visible = new List<Leave_Type_Policy__mdt>();
        for (Leave_Type_Policy__mdt policy : Leave_Type_Policy__mdt.getAll().values()) {
            if (policy.Active__c == true && policy.Show_On_Balance_Page__c == true) {
                visible.add(policy);
            }
        }
        // getAll() has no ordering guarantee, so Sort_Order__c is applied here. Small
        // fixed list, so an insertion sort costs nothing and avoids a Comparable class.
        for (Integer i = 1; i < visible.size(); i++) {
            Leave_Type_Policy__mdt current = visible[i];
            Integer j = i - 1;
            while (j >= 0 && sortKey(visible[j]) > sortKey(current)) {
                visible[j + 1] = visible[j];
                j--;
            }
            visible[j + 1] = current;
        }
        return visible;
    }

    /** Unsorted policies fall to the end rather than jumping to the front. */
    private static Decimal sortKey(Leave_Type_Policy__mdt policy) {
        return policy.Sort_Order__c == null ? 9999 : policy.Sort_Order__c;
    }

    /**
     * LEAVE-39. Resolves whose figures are being asked for and refuses if the caller may
     * not see them. Returns the resolved employee, so a caller can use it in place of
     * working the target out for itself.
     *
     * Public so another entry point can be gated on the same rule explicitly, rather
     * than relying on a balance call happening to run first and throw on its way past.
     * The permission-set list lives here and only here; a second copy elsewhere would
     * drift the first time one of them was changed.
     */
    public static Id assertCanView(Id employeeId) {
        return resolveAndAuthorise(employeeId);
    }

    private static Id resolveAndAuthorise(Id employeeId) {
        Id target = employeeId == null ? UserInfo.getUserId() : employeeId;
        if (target != UserInfo.getUserId() && !canViewOthers()) {
            throw new AuraHandledException(
                'You do not have permission to view another employee\'s leave balance.');
        }
        return target;
    }

    private static Boolean canViewOthers() {
        if (canViewOthersCache == null) {
            canViewOthersCache = ![
                SELECT Id FROM PermissionSetAssignment
                WHERE AssigneeId = :UserInfo.getUserId()
                  AND PermissionSet.Name IN :VIEW_OTHERS_PERMISSION_SETS
                LIMIT 1
            ].isEmpty();
        }
        return canViewOthersCache;
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}