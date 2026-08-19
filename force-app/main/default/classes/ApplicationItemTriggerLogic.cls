public class ApplicationItemTriggerLogic {

    private static final Integer WORKDAY_START_HOUR = 8;
    private static final Integer WORKDAY_START_MIN  = 30;
    private static final Integer LUNCH_END_HOUR     = 13;
    private static final Integer MORNING_END_HOUR   = 12;
    private static final Integer WORKDAY_END_HOUR   = 17;

    private static final String AM_LEAVE = 'AM leave';
    private static final String PM_LEAVE = 'PM leave';

    // The only type with a carry-over bucket, so the only one needing attribution.
    private static final String TYPE_ANNUAL = 'Annual leave';

    // 1900-01-01 was a Monday, so days-since gives 0=Mon .. 5=Sat, 6=Sun.
    private static final Date MONDAY_EPOCH = Date.newInstance(1900, 1, 1);

    // A request cannot span a calendar year (validation rule), so 366 is a hard
    // ceiling. The guard exists so a bad date can never spin the loop.
    private static final Integer MAX_RANGE_DAYS = 366;

    // Test hook. Custom Metadata cannot be inserted by DML and tests see the org's
    // real rows, so classification is overridden here rather than in the database.
    @TestVisible private static List<Leave_Type_Policy__mdt> policyOverride;
    private static Map<String, Leave_Type_Policy__mdt> policyCache;

    /*
     * active policies by leave type.
     *
     * Replaces the hardcoded deducting / non-deducting sets. Classifying a new leave
     * type is now a Custom Metadata row, not a deployment. getAll() consumes no SOQL
     * query or row limits.
     */
    private static Map<String, Leave_Type_Policy__mdt> policies() {
        if (policyCache != null) {
            return policyCache;
        }
        policyCache = new Map<String, Leave_Type_Policy__mdt>();
        List<Leave_Type_Policy__mdt> source = policyOverride != null
            ? policyOverride
            : Leave_Type_Policy__mdt.getAll().values();
        for (Leave_Type_Policy__mdt p : source) {
            if (p.Active__c == true) {
                policyCache.put(p.Leave_Type__c, p);
            }
        }
        return policyCache;
    }

    /** The active policy for a leave type, or null if it has none. */
    public static Leave_Type_Policy__mdt policyFor(String leaveType) {
        return policies().get(leaveType);
    }

    /** True for the types LeaveSplitService may cut down: currently Annual and Sick. */
    private static Boolean countsTowardSplit(ApplicationItem__c appl) {
        Leave_Type_Policy__mdt policy = policyFor(appl.Request_Type__c);
        return policy != null && policy.Counts_Toward_LWOP_Check__c == true;
    }

    /*
     * day count for a date range. Runs in the before contexts on every
     * leave request, not only approved ones, so the figure is right from Draft onward.
     *
     * Term_To__c blank means a single-day request, which is what every record created
     * before the field existed looks like.
     *
     * Period_Leave__c only applies to a single day: AM or PM across a range is
     * meaningless and is rejected by a validation rule.
     */
    public void calculateLeaveDays(List<ApplicationItem__c> requests) {
        if (requests.isEmpty()) {
            return;
        }

        Set<Date> holidays = holidaysForBatch(requests);

        for (ApplicationItem__c appl : requests) {
            if (appl.Term_From__c == null) {
                continue;
            }
            Date startDay = appl.Term_From__c;
            Date endDay = endDateOf(appl);
            if (endDay < startDay) {
                continue; // reported by the end-before-start validation rule
            }
            appl.Leave_Days__c = (startDay == endDay)
                ? (isHalfDay(appl.Period_Leave__c) ? 0.5 : 1.0)
                : workingDaysFor(appl, holidays).size();
        }
    }

    /*
     * the days a request actually consumes. Shared by the day count, the
     * calendar Events and the Man_hour__c records so the three cannot disagree.
     *
     * A single-day request is taken at face value, weekend or not: that is what the
     * behaviour was before ranges existed, and refusing a deliberately chosen date
     * belongs in a validation rule rather than in silent day counting. A range is
     * expanded, skipping weekends and dated Holiday records.
     */
    public static List<Date> workingDaysFor(ApplicationItem__c appl, Set<Date> holidays) {
        List<Date> days = new List<Date>();
        if (appl.Term_From__c == null) {
            return days;
        }
        Date startDay = appl.Term_From__c;
        Date endDay = endDateOf(appl);
        if (endDay < startDay) {
            return days;
        }
        if (startDay == endDay) {
            days.add(startDay);
            return days;
        }
        Date cursor = startDay;
        Integer guard = 0;
        while (cursor <= endDay && guard++ < MAX_RANGE_DAYS) {
            if (!isWeekend(cursor) && !holidays.contains(cursor)) {
                days.add(cursor);
            }
            cursor = cursor.addDays(1);
        }
        return days;
    }

    /*
     * hours claimed by an overtime request. Runs on every save, not only
     * approved ones, so the approver sees the figure they are signing off.
     *
     * Deliberately separate from the leave day count. Leave measures whole and half
     * days against an entitlement; overtime measures a clock window, and the two have
     * no arithmetic in common.
     */
    public void calculateOvertimeHours(List<ApplicationItem__c> requests) {
        for (ApplicationItem__c appl : requests) {
            appl.Overtime_Hours__c = overtimeHoursPerDay(appl) * overtimeDatesFor(appl).size();
        }
    }

    /*
     * The OT window in hours. Zero when either end is missing or the window is
     * inverted — both are reported by validation rules, and a negative number here
     * would quietly subtract from a monthly total.
     */
    public static Decimal overtimeHoursPerDay(ApplicationItem__c appl) {
        if (appl.OT_Start__c == null || appl.OT_End__c == null) {
            return 0;
        }
        Integer minutes = (appl.OT_End__c.hour() * 60 + appl.OT_End__c.minute())
                        - (appl.OT_Start__c.hour() * 60 + appl.OT_Start__c.minute());
        return minutes <= 0 ? 0 : Decimal.valueOf(minutes).divide(60, 2);
    }

    /*
     * Every calendar day an overtime request covers.
     *
     * Unlike workingDaysFor, this skips nothing. A weekend or a public holiday is
     * exactly when overtime tends to be worked, and dropping those days would pay
     * people for fewer hours than they put in.
     */
    public static List<Date> overtimeDatesFor(ApplicationItem__c appl) {
        List<Date> days = new List<Date>();
        if (appl.Term_From__c == null) {
            return days;
        }
        Date endDay = endDateOf(appl);
        if (endDay < appl.Term_From__c) {
            return days;
        }
        Date cursor = appl.Term_From__c;
        Integer guard = 0;
        while (cursor <= endDay && guard++ < MAX_RANGE_DAYS) {
            days.add(cursor);
            cursor = cursor.addDays(1);
        }
        return days;
    }

    /** The span a batch of requests covers, for a single Holiday query. */
    public static Set<Date> holidaysForBatch(List<ApplicationItem__c> requests) {
        Date rangeStart, rangeEnd;
        for (ApplicationItem__c appl : requests) {
            if (appl.Term_From__c == null) {
                continue;
            }
            Date endDay = endDateOf(appl);
            if (rangeStart == null || appl.Term_From__c < rangeStart) rangeStart = appl.Term_From__c;
            if (rangeEnd == null || endDay > rangeEnd) rangeEnd = endDay;
        }
        return rangeStart == null ? new Set<Date>() : holidaysBetween(rangeStart, rangeEnd);
    }

    /*
     * balance deduction on approval. Rewritten from the User-field version.
     *
     * Balances now live on Leave_Balance__c, an ordinary custom object, so this runs
     * in the same transaction as the approval. The @future split is gone: it existed
     * only because User is a setup object, and its failure mode left a request
     * approved with the balance never moved and nothing on the record saying so.
     * If the balance write fails now, the approval fails with it.
     *
     * Still runs in a before context so Carry_Over_Days_Used__c lands on the in-flight
     * record without a second DML on ApplicationItem__c.
     *
     * very request is deducted in full again. A request that ran past the
     * balance was already cut down to what it could afford at insert, by
     * LeaveSplitService, and the remainder now exists as its own Unpaid leave record
     * deducting its own balance. There is nothing left here to split.
     */
    public void deductLeaveBalance(List<ApplicationItem__c> approvedList) {
        if (approvedList.isEmpty()) {
            return;
        }

        Map<String, Leave_Type_Policy__mdt> policyByType = policies();
        List<ApplicationItem__c> deductible = new List<ApplicationItem__c>();
        Set<String> keys = new Set<String>();

        for (ApplicationItem__c appl : approvedList) {
            appl.Carry_Over_Days_Used__c = 0;

            Leave_Type_Policy__mdt policy = policyByType.get(appl.Request_Type__c);
            if (policy == null) {
                // Fail loudly rather than silently deducting from the wrong place or
                // nothing at all. A new picklist value needs a policy row first.
                appl.addError('Leave type "' + appl.Request_Type__c + '" has no active '
                    + 'Leave Type Policy record. Add one before this request can be approved.');
                continue;
            }
            if (policy.Deducts_Balance__c != true || appl.Term_From__c == null) {
                continue; // recorded and approved, but moves no balance
            }

            deductible.add(appl);
            keys.add(balanceKey(appl.OwnerId, appl.Request_Type__c, appl.Term_From__c.year()));
        }
        if (deductible.isEmpty()) {
            return;
        }

        // FOR UPDATE locks the rows for the rest of the transaction, so two approvals
        // for the same person and type cannot read the same figure and both write it.
        Map<String, Leave_Balance__c> balanceByKey = new Map<String, Leave_Balance__c>();
        for (Leave_Balance__c bal : [
            SELECT Id, External_Key__c, Entitlement_Days__c, Accrued_Days__c,
                   Carry_Over_Days__c, Used_Days__c
            FROM Leave_Balance__c
            WHERE External_Key__c IN :keys
            FOR UPDATE
        ]) {
            balanceByKey.put(bal.External_Key__c, bal);
        }

        Map<Id, Leave_Balance__c> touched = new Map<Id, Leave_Balance__c>();

        for (ApplicationItem__c appl : deductible) {
            // Non-null for everything in `deductible`: the loop above refuses a request
            // whose type has no active policy before it can get this far.
            Leave_Type_Policy__mdt policy = policyByType.get(appl.Request_Type__c);
            String key = balanceKey(appl.OwnerId, appl.Request_Type__c, appl.Term_From__c.year());
            Leave_Balance__c bal = balanceByKey.get(key);
            if (bal == null) {
                appl.addError('No ' + appl.Request_Type__c + ' balance exists for '
                    + appl.Term_From__c.year() + '. Balances are created by the daily leave job.');
                continue;
            }

            Decimal payable = zeroIfNull(appl.Leave_Days__c);
            if (payable <= 0) {
                continue;
            }

            // The row this request drew on, so every balance carries a related list of
            // what consumed it. Set in the before context, so it costs no extra DML.
            appl.Leave_Balance__c = bal.Id;

            /*
             * ckstop. The split is calculated when the request is saved, so
             * it reflects the balance at that moment. If two requests were raised while
             * both looked affordable and the other one was approved first, this one is
             * now too big and its unpaid half was never created.
             *
             * Used_Days__c is the running in-transaction figure, so this also catches
             * two such approvals arriving in the same batch. Refusing is the point:
             * the alternative is a balance quietly going negative.
             */
            Decimal available = zeroIfNull(bal.Accrued_Days__c)
                              + zeroIfNull(bal.Carry_Over_Days__c)
                              - zeroIfNull(bal.Used_Days__c);
            if (countsTowardSplit(appl) && payable > available) {
                appl.addError(appl.Request_Type__c + ': only ' + available
                    + ' day(s) remain but this request is for ' + payable + '. Raise it '
                    + 'unapproved first so the days beyond the balance are separated out '
                    + 'into an Unpaid leave request, then approve both.');
                continue;
            }

            /*
             * Carry over is consumed before the current year because it expires on
             * June 30. It does not reduce Carry_Over_Days__c: that field holds the
             * amount carried IN and stays fixed for the year, which is what makes
             * Available = Accrued + CarriedIn - Used come out right.
             *
             * The attribution recorded here is what lets the June 30 sweep work out
             * how much carry over went unused: lapse = MAX(0, CarriedIn - Used).
             */
            if (TYPE_ANNUAL.equals(appl.Request_Type__c)) {
                Decimal carryRemaining = zeroIfNull(bal.Carry_Over_Days__c) - zeroIfNull(bal.Used_Days__c);
                if (carryRemaining < 0) {
                    carryRemaining = 0;
                }
                appl.Carry_Over_Days_Used__c = payable <= carryRemaining ? payable : carryRemaining;
            }

            bal.Used_Days__c = zeroIfNull(bal.Used_Days__c) + payable;

            /*
             * hat was actually taken, recorded on the request. Reversal
             * gives back this figure rather than recomputing from Leave_Days__c, which
             * can be edited after approval and then no longer matches the deduction.
             */
            appl.Balance_Applied_Days__c = payable;

            /*
             * grant on use. Some types have no annual pool to draw down:
             * unpaid leave, and the statutory types that are an entitlement per occasion
             * rather than an allowance. Deducting one of those alone would drive
             * Available_Days__c negative and the balance page would read "-12 available",
             * which means nothing. Raising the entitlement by the same amount keeps
             * Available at zero and turns the row into what it actually is: a count of
             * the days taken.
             *
             * Decided by the policy rather than by a hardcoded Unpaid leave check, so
             * classifying a new type stays a Custom Metadata row rather than a
             * deployment — the same reason Deducts_Balance__c replaced the old
             * NON_DEDUCTING_TYPES set.
             */
            if (policy.Grants_On_Use__c == true) {
                bal.Entitlement_Days__c = zeroIfNull(bal.Entitlement_Days__c) + payable;
            }

            touched.put(bal.Id, bal);
        }

        if (!touched.isEmpty()) {
            update touched.values();
        }
    }

    /*
     * ne Event per working day of the range. Events are
     * collected and inserted once — the insert used to sit inside the loop, so 150
     * approvals in one transaction exhausted the DML statement limit.
     *
     * Callers pass records that have just crossed into Approved; the status
     * transition is decided in ApplicationItemTriggerHandler.
     */
    public void setLeaveDateTime(List<ApplicationItem__c> approvedList) {
        if (approvedList.isEmpty()) {
            return;
        }

        Set<Date> holidays = holidaysForBatch(approvedList);
        List<Event> events = new List<Event>();

        for (ApplicationItem__c appl : approvedList) {
            if (appl.Term_From__c == null) {
                continue;
            }
            Boolean singleDay = (appl.Term_From__c == endDateOf(appl));
            for (Date d : workingDaysFor(appl, holidays)) {
                events.add(buildEvent(appl, d, singleDay));
            }
        }

        if (!events.isEmpty()) {
            insert events;
        }
    }

    private static Event buildEvent(ApplicationItem__c appl, Date d, Boolean singleDay) {
        Boolean am = singleDay && AM_LEAVE == appl.Period_Leave__c;
        Boolean pm = singleDay && PM_LEAVE == appl.Period_Leave__c;

        Datetime startDateTime = pm
            ? DateTime.newInstance(d.year(), d.month(), d.day(), LUNCH_END_HOUR, 0, 0)
            : DateTime.newInstance(d.year(), d.month(), d.day(), WORKDAY_START_HOUR, WORKDAY_START_MIN, 0);

        Datetime endDateTime = am
            ? DateTime.newInstance(d.year(), d.month(), d.day(), MORNING_END_HOUR, 0, 0)
            : DateTime.newInstance(d.year(), d.month(), d.day(), WORKDAY_END_HOUR, 0, 0);

        return new Event(
            WhatId        = appl.Id,
            Subject       = appl.Request_Type__c,
            OwnerId       = appl.OwnerId,
            StartDateTime = startDateTime,
            EndDateTime   = endDateTime,
            Description   = singleDay ? appl.Period_Leave__c : 'All day'
        );
    }

    /*
     * Recurring Holiday rows carry a null ActivityDate and are not matched here, so a
     * recurring company holiday inside a range still counts as a leave day. Same
     * limitation as TimesheetController.getHolidays.
     */
    public static Set<Date> holidaysBetween(Date rangeStart, Date rangeEnd) {
        Set<Date> result = new Set<Date>();
        for (Holiday h : [
            SELECT ActivityDate FROM Holiday
            WHERE ActivityDate >= :rangeStart AND ActivityDate <= :rangeEnd
        ]) {
            result.add(h.ActivityDate);
        }
        return result;
    }


    private static Boolean isWeekend(Date d) {
        return Math.mod(MONDAY_EPOCH.daysBetween(d), 7) >= 5;
    }

    private static Date endDateOf(ApplicationItem__c appl) {
        return appl.Term_To__c == null ? appl.Term_From__c : appl.Term_To__c;
    }

    private static Boolean isHalfDay(String periodLeave) {
        return AM_LEAVE == periodLeave || PM_LEAVE == periodLeave;
    }

    /*
     * Must match the format written by the backfill and the grant engine exactly —
     * see scripts/apex/03_backfill_leave_balances.apex.
     */
    public static String balanceKey(Id ownerId, String leaveType, Integer year) {
        return ownerId + '-' + leaveType + '-' + year;
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}