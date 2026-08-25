/*
 * LEAVE-46 — splitting a request that runs past the balance, down a chain of pools.
 *
 * Replaces the LWOP fields and the two-stage approval gate that preceded it. Instead of
 * one record carrying "20 days, 12 of them unpaid" across six extra fields, the request
 * becomes two or three ordinary records:
 *
 *     Refresh Leave 7-9 Sep    3 days  -> the Refresh balance
 *     Annual leave  10-15 Sep  4 days  -> the Annual balance
 *     Unpaid leave  16-18 Sep  3 days  -> the Unpaid balance
 *
 * Everything after that is the engine that already existed. Each record counts its own
 * days, deducts its own balance, books its own Man_hour__c and goes through its own
 * approval. There is no gate to enforce and no bespoke unpaid arithmetic, because unpaid
 * leave is now just a leave type like any other.
 *
 * THE CHAIN
 *
 * Which pool is tried next is configuration, not code: Leave_Type_Policy__mdt.
 * Overflow_To__c names it. Refresh Leave overflows into Annual leave, and Annual, Sick
 * and Personal leave into Unpaid leave, so a Refresh Leave request that outruns both
 * paid pools walks two hops. A blank Overflow_To__c ends the chain and means the type
 * never splits at all, which is right for Unpaid leave and for the statutory types that
 * grant their entitlement as it is used.
 *
 * The chain replaced Counts_Toward_LWOP_Check__c as the gate here. That flag said both
 * "may be split" and "splits into unpaid", and Refresh Leave needed the first without
 * the second — with the flag off it was split by nothing and refused by nothing, and an
 * over-long request simply drove the balance negative.
 *
 * The split runs on INSERT, not on approval. The employee finds out what will and will
 * not be paid at the moment they save, rather than discovering it after someone signs.
 *
 * Balance is consumed in date order, so the days come off the pools in the order the
 * chain names them: earliest days from the requested type, latest from the end of the
 * chain.
 *
 * HALF DAYS AT THE BOUNDARY
 *
 * LEAVE-54: a pool is spent to the half day, because that is the granularity a balance
 * is held at. With 3.5 days of Annual left and five requested, the boundary day is
 * halved:
 *
 *     Annual leave  Mon-Wed   3 days    All day
 *     Annual leave  Thu       0.5 days  AM leave
 *     Unpaid leave  Thu       0.5 days  PM leave
 *     Unpaid leave  Fri       1 day     All day
 *
 * Four records where two would do for a whole-day boundary, and that is the cost of it.
 * The alternative was what this did before: fund three days, pass two on, and leave the
 * half in the pool until the year ended and it lapsed unused.
 *
 * The boundary day has to be two records because Period_Leave__c is the only place a
 * half day can be expressed and it is meaningless on a range — refused there by
 * Leave_Request_Period_Single_Day_Only, and ignored by calculateLeaveDays, which counts
 * a range in whole days. Nothing downstream needed changing for it: deduction, the
 * calendar Event and Man_hour__c all read one record at a time and all already
 * understood AM and PM.
 *
 * EXPIRING GRANTS
 *
 * A Refresh Leave grant is only good for a month (Granted_On__c to Expiry_Date__c on the
 * balance row). Days that fall outside that window cannot be funded by it, so the run
 * stops at the first one that does and the remainder cascades on to Annual leave in the
 * ordinary way. Only balances that actually carry an Expiry_Date__c are constrained;
 * Annual and Sick have none and behave exactly as before.
 */
public without sharing class LeaveSplitService {

    @TestVisible private static final String TYPE_UNPAID = 'Unpaid leave';
    private static final String STATUS_APPROVED = 'Approved';

    private static final String ALL_DAY  = 'All day';
    private static final String AM_LEAVE = 'AM leave';
    private static final String PM_LEAVE = 'PM leave';

    /*
     * A mis-configured Overflow_To__c pointing back up its own chain cannot spin the
     * walk: chainFor stops on a repeat, and this bounds it even if the rows form a
     * chain longer than anyone intended.
     */
    private static final Integer MAX_CHAIN_HOPS = 6;

    /*
     * Records this run has already split, or created by splitting. Shortening the
     * original is a DML on the same object from its own trigger, so without this the
     * update re-enters and reconsiders a record that is now, by construction, exactly
     * within its balance.
     */
    @TestVisible private static Set<Id> handled = new Set<Id>();

    /*
     * True while this class is performing its own DML. Shortening the parent and
     * inserting the continuations both re-enter the trigger, and the shortening in
     * particular looks exactly like somebody editing the end date. Without this, an
     * edit-driven re-split would treat the split's own writes as a fresh edit.
     */
    private static Boolean rebuilding = false;

    /*
     * Half a working day: the unit balance is actually held in, and so the unit it is
     * consumed in. Measuring in whole days is what used to strand the half — with 3.5
     * days left and 5 requested, three were funded and the .5 sat in the pool until the
     * year ended.
     */
    private class Half {
        Date day;
        Boolean isMorning;
        Half(Date day, Boolean isMorning) {
            this.day = day;
            this.isMorning = isMorning;
        }
    }

    /** One contiguous run of half days, funded by one pool. */
    private class Segment {
        String leaveType;
        Integer firstHalf;  // index into the request's half days
        Integer halfCount;
        Segment(String leaveType, Integer firstHalf, Integer halfCount) {
            this.leaveType = leaveType;
            this.firstHalf = firstHalf;
            this.halfCount = halfCount;
        }
    }

    /*
     * One record to be written for a segment: a run of whole days, or a single half day
     * at either end of it.
     *
     * A segment needs more than one record only because Period_Leave__c means nothing on
     * a range — Leave_Request_Period_Single_Day_Only refuses AM or PM there, and
     * calculateLeaveDays would count the boundary day as a whole one anyway. So the day a
     * pool runs out on becomes a single-day record of its own on each side of the
     * boundary, and the whole days stay in one range record between them.
     */
    private class Piece {
        String leaveType;
        Date startsOn;
        Date endsOn;
        String period;
        Piece(String leaveType, Date startsOn, Date endsOn, String period) {
            this.leaveType = leaveType;
            this.startsOn = startsOn;
            this.endsOn = endsOn;
            this.period = period;
        }
    }

    /* What one balance row can fund, and between which dates. */
    private class Pool {
        Decimal available;
        Date closesOn;      // null for a balance that does not expire
        Date opensOn;
    }

    /**
     * Splits any newly created leave request whose days run past the balance.
     * Runs after insert, because the continuations have to point back at a saved parent.
     */
    public static void splitOverBalance(List<ApplicationItem__c> newRecords) {
        evaluate(newRecords, false);
    }

    /*
     * Re-measures a record that was itself a continuation of an earlier split and has
     * just been promoted back up the chain, because the segment above it was refused
     * and gave its balance back. The Split_From__c guard is lifted for this path only —
     * on insert it is what stops a continuation splitting the moment it is created.
     */
    public static void reevaluate(List<ApplicationItem__c> records) {
        evaluate(records, true, null);
    }

    /**
     * Re-splits a request whose shape changed after it was saved.
     *
     * The split used to run on insert alone, so a request saved with no end date and
     * widened afterwards - which is what filling the form in two passes gives you -
     * kept its recalculated day count and never grew a continuation. It could then
     * never be approved either: deductLeaveBalance refused it for exceeding the
     * balance and told the approver to have it split, which nothing would do.
     *
     * Where a split already happened, the continuations it produced are superseded
     * rather than left beside new ones. That deletion is deliberately not performed
     * here: evaluate removes a parent's continuations only if it goes on to build
     * replacements, so an edit that no longer needs splitting cannot silently drop the
     * days that were already agreed.
     */
    public static void resplitOnEdit(List<ApplicationItem__c> records) {
        if (rebuilding) {
            return; // our own shortening update, not somebody moving the dates
        }
        List<ApplicationItem__c> candidates = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : records) {
            /*
             * A deliberate edit supersedes any split already performed on the record in
             * this transaction, so the re-entry guard is lifted for it. What stops the
             * split's own writes coming back round is `rebuilding`, above.
             */
            handled.remove(appl.Id);
            if (isSplittable(appl, false)) {
                candidates.add(appl);
            }
        }
        if (candidates.isEmpty()) {
            return;
        }

        Map<Id, List<ApplicationItem__c>> supersededByParent = new Map<Id, List<ApplicationItem__c>>();
        Set<Id> hasApprovedTail = new Set<Id>();
        for (ApplicationItem__c sib : [
            SELECT Id, Split_From__c, Status__c
            FROM ApplicationItem__c
            WHERE Split_From__c IN :new Map<Id, ApplicationItem__c>(candidates).keySet()
        ]) {
            /*
             * An approved continuation has already spent balance and booked its days.
             * Rebuilding it would unpick both behind the approver's back, so the whole
             * family is left alone and the edit is refused at approval instead.
             */
            if (STATUS_APPROVED.equals(sib.Status__c)) {
                hasApprovedTail.add(sib.Split_From__c);
                continue;
            }
            if (!supersededByParent.containsKey(sib.Split_From__c)) {
                supersededByParent.put(sib.Split_From__c, new List<ApplicationItem__c>());
            }
            supersededByParent.get(sib.Split_From__c).add(sib);
        }

        List<ApplicationItem__c> toEvaluate = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : candidates) {
            if (!hasApprovedTail.contains(appl.Id)) {
                toEvaluate.add(appl);
            }
        }
        if (!toEvaluate.isEmpty()) {
            evaluate(toEvaluate, false, supersededByParent);
        }
    }

    /**
     * Collapses what is left of a split family back onto one record and measures it
     * again from the top of the chain.
     *
     * Called when a segment is refused and hands its balance back. With a single hop
     * there was only ever one continuation to promote; with a chain there can be two,
     * and each has to move up a place rather than the tail jumping straight to the head
     * of the chain. Rebuilding is the only way to get that right in every shape, so the
     * survivors are merged into the earliest of them and re-split from scratch.
     *
     * `keep` is re-typed and widened to cover `discard` as well, which is then deleted.
     * Both DML statements run under the rebuilding guard so the widening cannot be read
     * as somebody editing the dates.
     */
    public static void rebuildFrom(List<ApplicationItem__c> keep, List<ApplicationItem__c> discard) {
        if (keep.isEmpty()) {
            return;
        }
        Boolean wasRebuilding = rebuilding;
        rebuilding = true;
        try {
            if (discard != null && !discard.isEmpty()) {
                delete discard;
            }
            update keep;
        } finally {
            rebuilding = wasRebuilding;
        }

        Set<Id> ids = new Map<Id, ApplicationItem__c>(keep).keySet();
        handled.removeAll(new List<Id>(ids));
        // Re-read rather than reuse: the update above recalculated Leave_Days__c, which
        // is the figure the walk measures against the pools.
        reevaluate([
            SELECT Id, OwnerId, Request_Type__c, Status__c, Term_From__c, Term_To__c,
                   Leave_Days__c, Split_From__c, RecordTypeId, Remark__c, Period_Leave__c
            FROM ApplicationItem__c WHERE Id IN :ids
        ]);
    }

    private static void evaluate(List<ApplicationItem__c> newRecords, Boolean allowTails) {
        evaluate(newRecords, allowTails, null);
    }

    private static void evaluate(List<ApplicationItem__c> newRecords, Boolean allowTails,
                                 Map<Id, List<ApplicationItem__c>> supersededByParent) {
        List<ApplicationItem__c> candidates = new List<ApplicationItem__c>();
        Map<Id, List<String>> chainByRecord = new Map<Id, List<String>>();
        Set<String> keys = new Set<String>();

        for (ApplicationItem__c appl : newRecords) {
            if (!isSplittable(appl, allowTails)) {
                continue;
            }
            List<String> chain = chainFor(appl.Request_Type__c);
            if (chain.size() < 2) {
                continue; // nowhere to overflow to
            }
            candidates.add(appl);
            chainByRecord.put(appl.Id, chain);
            // Every pool the request could reach, not only the one it asked for.
            for (String leaveType : chain) {
                keys.add(ApplicationItemTriggerLogic.balanceKey(
                    appl.OwnerId, leaveType, appl.Term_From__c.year()));
            }
        }
        if (candidates.isEmpty()) {
            return;
        }

        Map<String, Pool> poolByKey = poolsFor(keys);
        Set<Date> holidays = ApplicationItemTriggerLogic.holidaysForBatch(candidates);

        List<ApplicationItem__c> toUpdate = new List<ApplicationItem__c>();
        List<ApplicationItem__c> continuations = new List<ApplicationItem__c>();
        // Continuations from an earlier split of a parent being rebuilt below. Only the
        // ones whose parent actually gets replacements are collected.
        List<ApplicationItem__c> superseded = new List<ApplicationItem__c>();

        for (ApplicationItem__c appl : candidates) {
            List<Date> workingDays = ApplicationItemTriggerLogic.workingDaysFor(appl, holidays);
            if (workingDays.isEmpty()) {
                continue;
            }

            List<Half> halves = halvesFor(appl, workingDays);
            List<Segment> segments =
                allocate(appl, chainByRecord.get(appl.Id), halves, poolByKey);

            /*
             * No segments means no pool in the chain could be measured at all — a
             * missing balance row, which deductLeaveBalance reports precisely at
             * approval. Splitting on a guess would hide it behind a plausible record.
             *
             * One segment of the type that was asked for means the request fits and
             * there is nothing to do. One segment of a DIFFERENT type does not: the
             * requested pool funded nothing and the whole request moves down the chain,
             * so the record still has to be rewritten.
             */
            if (segments.isEmpty()
                || (segments.size() == 1 && segments[0].leaveType.equals(appl.Request_Type__c))) {
                continue;
            }

            List<Piece> pieces = new List<Piece>();
            for (Segment seg : segments) {
                pieces.addAll(piecesFor(seg, halves));
            }
            if (pieces.isEmpty()) {
                continue;
            }

            /*
             * The first record keeps the request's own start and the last keeps its own
             * end, so a range that opens or closes on a weekend covers the same calendar
             * dates after the split as before it. Only the interior boundaries land on
             * working days.
             *
             * A half day cannot carry a weekend edge with it — it is a single-day record
             * by construction — so it keeps the working day it actually falls on. In
             * practice only the head can be affected: the last type in the chain absorbs
             * every remaining half, so the final record always ends on a whole day.
             */
            Date rangeEnd = appl.Term_To__c == null ? appl.Term_From__c : appl.Term_To__c;
            if (ALL_DAY.equals(pieces[0].period)) {
                pieces[0].startsOn = appl.Term_From__c;
            }
            Piece tail = pieces[pieces.size() - 1];
            if (ALL_DAY.equals(tail.period)) {
                tail.endsOn = rangeEnd;
            }

            for (Integer i = 0; i < pieces.size(); i++) {
                Piece piece = pieces[i];
                if (i == 0) {
                    ApplicationItem__c head = new ApplicationItem__c(Id = appl.Id);
                    /*
                     * The requested pool funded nothing, so the request itself becomes
                     * the first type that can fund it. Creating an empty record beside a
                     * full one helps nobody, and the employee still gets exactly the days
                     * they asked for on exactly the dates they asked for.
                     */
                    if (!piece.leaveType.equals(appl.Request_Type__c)) {
                        head.Request_Type__c = piece.leaveType;
                    }
                    head.Term_From__c = piece.startsOn;
                    head.Term_To__c = piece.endsOn;
                    head.Period_Leave__c = piece.period;
                    toUpdate.add(head);
                } else {
                    continuations.add(continuationOf(appl, piece));
                }
            }

            addSuperseded(superseded, supersededByParent, appl.Id);
            handled.add(appl.Id);
        }

        // Saved and restored rather than simply cleared, so a nested evaluate cannot
        // lift the guard while an outer one is still writing.
        Boolean wasRebuilding = rebuilding;
        rebuilding = true;
        try {
            // Before the replacements, so an old continuation and a new one never
            // occupy the same dates.
            if (!superseded.isEmpty()) {
                delete superseded;
            }
            if (!toUpdate.isEmpty()) {
                update toUpdate;
            }
            if (!continuations.isEmpty()) {
                insert continuations;
            }
        } finally {
            rebuilding = wasRebuilding;
        }
    }

    /*
     * The request as half days, which is the unit the walk below consumes balance in.
     *
     * A request that is itself already a half day is one half and cannot be divided
     * again: it either fits a pool or moves down the chain whole. Everything else is two
     * halves per working day, morning first, so the walk runs in date order.
     */
    private static List<Half> halvesFor(ApplicationItem__c appl, List<Date> workingDays) {
        List<Half> halves = new List<Half>();
        if (workingDays.size() == 1 && isHalfDay(appl.Period_Leave__c)) {
            halves.add(new Half(workingDays[0], AM_LEAVE.equals(appl.Period_Leave__c)));
            return halves;
        }
        for (Date day : workingDays) {
            halves.add(new Half(day, true));
            halves.add(new Half(day, false));
        }
        return halves;
    }

    /*
     * Walks the chain, handing each pool as many of the remaining half days as it can
     * fund, in date order. The last type in the chain carries whatever is left
     * regardless of its balance — that is Unpaid leave, which grants its entitlement as
     * it is used and so can always absorb the remainder.
     *
     * Returns one segment when the request fits in the pool it asked for, and an empty
     * list when nothing in the chain could fund a single half day, which leaves the
     * record alone rather than rewriting it on no information.
     */
    private static List<Segment> allocate(ApplicationItem__c appl, List<String> chain,
                                          List<Half> halves, Map<String, Pool> poolByKey) {
        List<Segment> segments = new List<Segment>();
        Integer total = halves.size();
        Integer cursor = 0;
        Integer yr = appl.Term_From__c.year();

        for (Integer i = 0; i < chain.size() && cursor < total; i++) {
            Boolean isLast = (i == chain.size() - 1);
            Integer take = isLast
                ? total - cursor
                : capacityOf(poolByKey.get(
                      ApplicationItemTriggerLogic.balanceKey(appl.OwnerId, chain[i], yr)),
                      halves, cursor, total);
            if (take > 0) {
                segments.add(new Segment(chain[i], cursor, take));
                cursor += take;
            }
        }

        /*
         * The chain ran out with days still unallocated, which means its final type had
         * no active policy row of its own. The days stay on the last segment rather than
         * disappearing off the end of the request; approval then refuses the overdraw
         * and says so, which is a better failure than a request quietly losing dates.
         */
        if (cursor < total && !segments.isEmpty()) {
            segments[segments.size() - 1].halfCount += total - cursor;
        }
        return segments;
    }

    /*
     * The records one segment becomes.
     *
     * A pool can run out in the middle of a day at either end of a segment, and that
     * boundary day has to be a record of its own: Period_Leave__c is the only place a
     * half day can be expressed, and it is meaningless on a range — refused there by
     * Leave_Request_Period_Single_Day_Only, and ignored by calculateLeaveDays, which
     * would count the day as whole. So a segment is at most three records: the afternoon
     * it starts on, the whole days, and the morning it ends on.
     *
     * With 3.5 days of Annual left and Monday to Friday requested, that gives Mon-Wed
     * paid, Thursday morning paid, Thursday afternoon unpaid and Friday unpaid. The half
     * day is spent rather than stranded in the pool until the year ends.
     */
    private static List<Piece> piecesFor(Segment seg, List<Half> halves) {
        List<Piece> pieces = new List<Piece>();
        Integer first = seg.firstHalf;
        Integer last  = first + seg.halfCount - 1;

        if (!halves[first].isMorning) {
            pieces.add(new Piece(seg.leaveType, halves[first].day, halves[first].day, PM_LEAVE));
            first++;
        }
        // Held back rather than added here, so the whole days below stay in date order
        // between the two half days.
        Piece closing = (first <= last && halves[last].isMorning)
            ? new Piece(seg.leaveType, halves[last].day, halves[last].day, AM_LEAVE)
            : null;
        if (closing != null) {
            last--;
        }
        if (first <= last) {
            pieces.add(new Piece(seg.leaveType, halves[first].day, halves[last].day, ALL_DAY));
        }
        if (closing != null) {
            pieces.add(closing);
        }
        return pieces;
    }

    /*
     * How many half days this pool can fund, counting from the cursor.
     *
     * Measured in halves rather than whole days, because that is the granularity a
     * balance is actually held at. Rounding the day figure down instead — which is what
     * this did before — funded three days out of 3.5 and left the half in the pool, where
     * it stayed until the year ended. Anything finer than a half day is still rounded
     * away, but no balance can hold it.
     *
     * An expiring balance stops at the first working day outside its window rather than
     * skipping over it, because a continuation has to be a contiguous range of dates. A
     * refresh grant with three days left but two of them falling after the expiry funds
     * two days, and the rest cascades on. Both halves of a day carry the same date, so
     * the window can only ever cut between days, never through one.
     */
    private static Integer capacityOf(Pool pool, List<Half> halves,
                                      Integer cursor, Integer total) {
        if (pool == null || pool.available == null || pool.available <= 0) {
            return 0;
        }
        Integer affordable = (Integer) (pool.available * 2).round(System.RoundingMode.DOWN);
        if (affordable > total - cursor) {
            affordable = total - cursor;
        }
        if (pool.closesOn == null) {
            return affordable; // a balance that does not expire funds any date
        }
        Integer usable = 0;
        while (usable < affordable) {
            Date day = halves[cursor + usable].day;
            if (day > pool.closesOn || (pool.opensOn != null && day < pool.opensOn)) {
                break;
            }
            usable++;
        }
        return usable;
    }

    private static Map<String, Pool> poolsFor(Set<String> keys) {
        Map<String, Pool> pools = new Map<String, Pool>();
        for (Leave_Balance__c bal : [
            SELECT External_Key__c, Accrued_To_Date__c, Carry_Over_Days__c, Used_Days__c,
                   Granted_On__c, Expiry_Date__c
            FROM Leave_Balance__c
            WHERE External_Key__c IN :keys
        ]) {
            Pool pool = new Pool();
            pool.available = zeroIfNull(bal.Accrued_To_Date__c) + zeroIfNull(bal.Carry_Over_Days__c)
                           - zeroIfNull(bal.Used_Days__c);
            pool.closesOn = bal.Expiry_Date__c;
            pool.opensOn = bal.Granted_On__c;
            pools.put(bal.External_Key__c, pool);
        }
        return pools;
    }

    /**
     * The pools a request may draw on, in order, starting with the one it asked for.
     * A type whose policy row is missing ends the chain, as does a repeat — a cycle in
     * Overflow_To__c is a configuration mistake, not a reason to hang.
     */
    @TestVisible
    private static List<String> chainFor(String leaveType) {
        List<String> chain = new List<String>();
        Set<String> seen = new Set<String>();
        String cursor = leaveType;
        while (String.isNotBlank(cursor) && !seen.contains(cursor)
               && chain.size() < MAX_CHAIN_HOPS) {
            Leave_Type_Policy__mdt policy = ApplicationItemTriggerLogic.policyFor(cursor);
            if (policy == null) {
                break;
            }
            chain.add(cursor);
            seen.add(cursor);
            cursor = policy.Overflow_To__c;
        }
        return chain;
    }

    /*
     * A later stretch of the original, as its own request. Mirrors the parent's status
     * so a draft splits into drafts and a submitted request into submitted ones, and the
     * whole family travels through approval together.
     */
    private static ApplicationItem__c continuationOf(ApplicationItem__c parent, Piece piece) {
        return new ApplicationItem__c(
            RecordTypeId    = parent.RecordTypeId,
            Request_Type__c = piece.leaveType,
            Period_Leave__c = piece.period,
            Term_From__c    = piece.startsOn,
            Term_To__c      = piece.endsOn,
            Remark__c       = continuationRemark(parent, piece),
            Status__c       = parent.Status__c,
            OwnerId         = parent.OwnerId,
            Split_From__c   = parent.Id
        );
    }

    /*
     * Half of a boundary day is described as such rather than as a continuation of
     * another type, because it usually is not one: the morning that finishes off the
     * Annual balance carries the same type as the request it came from, and calling it
     * an "annual leave continuation of Annual leave" would tell the employee nothing.
     */
    private static String continuationRemark(ApplicationItem__c parent, Piece piece) {
        String suffix = isHalfDay(piece.period)
            ? ' [' + piece.period.toLowerCase() + ', ' + piece.leaveType.toLowerCase()
                   + ', split from ' + parent.Request_Type__c + ']'
            : ' [' + piece.leaveType.toLowerCase() + ' continuation of '
                   + parent.Request_Type__c + ']';
        String base = parent.Remark__c == null ? '' : parent.Remark__c;
        Integer room = 255 - suffix.length();
        return (base.length() > room ? base.substring(0, room) : base) + suffix;
    }

    /*
     * ApplicationItemTriggerLogic has the same check, but private. Duplicated rather
     * than widened: it is two string comparisons, and the alternative is opening a
     * detail of the day count to every caller of that class.
     */
    private static Boolean isHalfDay(String periodLeave) {
        return AM_LEAVE.equals(periodLeave) || PM_LEAVE.equals(periodLeave);
    }

    private static Boolean isSplittable(ApplicationItem__c appl, Boolean allowTails) {
        if (handled.contains(appl.Id)) {
            return false;
        }
        // A continuation of an earlier split. On insert it never splits again; after a
        // promotion it must, which is what allowTails is for.
        if (appl.Split_From__c != null && !allowTails) {
            return false;
        }
        if (appl.Term_From__c == null || zeroIfNull(appl.Leave_Days__c) <= 0) {
            return false;
        }
        if (ApplicationItemTriggerHandler.isOvertimeRequest(appl)) {
            return false;
        }
        Leave_Type_Policy__mdt policy = ApplicationItemTriggerLogic.policyFor(appl.Request_Type__c);
        return policy != null && String.isNotBlank(policy.Overflow_To__c);
    }

    private static void addSuperseded(List<ApplicationItem__c> collector,
                                      Map<Id, List<ApplicationItem__c>> byParent, Id parentId) {
        if (byParent != null && byParent.containsKey(parentId)) {
            collector.addAll(byParent.get(parentId));
        }
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}