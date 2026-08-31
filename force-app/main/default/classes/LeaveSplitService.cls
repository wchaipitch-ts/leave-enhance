public without sharing class LeaveSplitService {

    @TestVisible private static final String TYPE_UNPAID = 'Unpaid leave';
    private static final String STATUS_APPROVED = 'Approved';

    private static final String ALL_DAY  = 'All day';
    private static final String AM_LEAVE = 'AM leave';
    private static final String PM_LEAVE = 'PM leave';
    private static final Integer MAX_CHAIN_HOPS = 6;
    @TestVisible private static Set<Id> handled = new Set<Id>();
    private static Boolean rebuilding = false;

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

    public static void reevaluate(List<ApplicationItem__c> records) {
        evaluate(records, true, null);
    }

    public static void resplitOnEdit(List<ApplicationItem__c> records) {
        if (rebuilding) {
            return; // our own shortening update, not somebody moving the dates
        }
        List<ApplicationItem__c> candidates = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : records) {

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

            if (!poolByKey.containsKey(ApplicationItemTriggerLogic.balanceKey(
                    appl.OwnerId, appl.Request_Type__c, appl.Term_From__c.year()))) {
                continue;
            }

            List<Half> halves = halvesFor(appl, workingDays);
            List<Segment> segments =
                allocate(appl, chainByRecord.get(appl.Id), halves, poolByKey);

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

        if (cursor < total && !segments.isEmpty()) {
            segments[segments.size() - 1].halfCount += total - cursor;
        }
        return segments;
    }

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