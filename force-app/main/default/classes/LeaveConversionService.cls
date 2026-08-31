public without sharing class LeaveConversionService {

    @TestVisible private static final String TYPE_UNPAID = 'Unpaid leave';
    @TestVisible private static final String TYPE_ANNUAL = 'Annual leave';

    private static final String PERMISSION = 'Convert_Unpaid_Leave';

    private static final String STATUS_DRAFT    = 'Draft';
    private static final String STATUS_PENDING  = 'Pending';
    private static final String STATUS_APPROVED = 'Approved';
    private static final String STATUS_REJECTED = 'Rejected';

    private static final String ALL_DAY  = 'All day';
    private static final String AM_LEAVE = 'AM leave';
    private static final String PM_LEAVE = 'PM leave';

    private static final String LABEL_OPEN        = 'Draft';
    private static final String LABEL_PARTIAL     = 'Partially Converted';
    private static final String LABEL_FULL        = 'Fully Converted';
    private static final String LABEL_UNAVAILABLE = 'Unavailable';

    // Remark__c is required at the schema level and capped at 255. The lineage note has
    // to fit inside that without pushing out what the employee wrote.
    private static final Integer REMARK_MAX = 255;

    /**
     * Everything the conversion card on an Unpaid leave record shows, and everything it
     * needs to decide what to enable.
     *
     * Every figure is derived on read — from this record, its converted children and
     * the Annual balance — rather than stored on the request. A stored "convertible
     * days" is wrong the moment anybody else's request is approved against the same
     * balance, and it would be the LWOP fields all over again.
     */
    public class ConversionView {
        @AuraEnabled public Id       requestId;
        @AuraEnabled public String   requestName;
        @AuraEnabled public String   requestType;
        @AuraEnabled public String   status;
        @AuraEnabled public Integer  leaveYear;
        /** Whole unpaid days on this record that the Annual balance could pay for now. */
        @AuraEnabled public Decimal  convertibleDays;
        /** Days already turned into Annual leave requests off this record. */
        @AuraEnabled public Decimal  convertedDays;
        /** What is still unpaid on this record. */
        @AuraEnabled public Decimal  remainingUnpaidDays;
        @AuraEnabled public Decimal  annualAvailable;
        @AuraEnabled public String   conversionStatus;
        @AuraEnabled public Boolean  canConvert;
        @AuraEnabled public Boolean  canRevert;
        /*
         * Whether this record has anything to do with unpaid conversion at all. False
         * on ordinary leave, and the card removes itself. True on an unpaid request and
         * on a paid one that a conversion produced — the second is how a conversion made
         * in error stays reachable rather than only being undoable by hand.
         */
        @AuraEnabled public Boolean  showsConversion;
        /** Why conversion is unavailable, in words fit to show the employee. */
        @AuraEnabled public String   blockedReason;
        /** Why there is nothing to revert. Null when the button is live. */
        @AuraEnabled public String   revertBlockedReason;
        /** The Annual requests this conversion produced, oldest first. */
        @AuraEnabled public List<ConvertedRequest> convertedRequests;
    }

    /*
     * Enough of a converted request to name it and link to it. The card has to be able
     * to reach the Draft it made: nobody is paid for these days until the owner submits
     * it, and a number on a card the owner cannot click through is how that gets
     * forgotten.
     */
    public class ConvertedRequest {
        @AuraEnabled public Id      recordId;
        @AuraEnabled public String  name;
        @AuraEnabled public Decimal days;
        @AuraEnabled public String  status;
    }

    // ==================================================================== permission

    /*
     * Test hook. FeatureManagement reads the running user's assignments, and granting a
     * permission set to yourself mid-transaction needs System.runAs gymnastics that
     * obscure what is actually being tested. Mirrors OvertimeRequestGuard.
     */
    @TestVisible private static Boolean permittedOverride;

    /** True when the running user may convert somebody's unpaid days to Annual leave. */
    @TestVisible
    private static Boolean permitted() {
        if (permittedOverride != null) {
            return permittedOverride;
        }
        return FeatureManagement.checkPermission(PERMISSION);
    }

    private static void assertPermitted() {
        if (!permitted()) {
            throw new AuraHandledException(
                'Converting unpaid leave to Annual leave is a manager action. You do not '
              + 'have permission to convert this request.');
        }
    }

    public static ConversionView view(Id requestId) {
        ApplicationItem__c src = load(requestId);
        /*
         * Asked, not asserted. ApplicationItem__c is Public Read, so colleagues open one
         * another's requests routinely, and assertCanView would throw at every one of
         * them — which the card renders as a red banner reading "You do not have
         * permission to view another employee's leave balance."
         *
         * That banner is worse than useless. Nobody reading it was trying to see a
         * balance; they opened a leave request. What belongs on a record whose
         * conversion is none of your business is nothing at all.
         *
         * convert() and revert() still assert, because a caller reaching them is acting
         * rather than looking.
         */
        if (!permitted() || !LeaveBalanceService.canView(src.OwnerId)) {
            return hiddenView(src);
        }
        return buildView(src);
    }

    /*
     * Enough of a view for the card to take itself off the page, and nothing else. The
     * figures are deliberately absent rather than zeroed-and-populated: this caller is
     * not entitled to them, and a zero is still an answer.
     */
    private static ConversionView hiddenView(ApplicationItem__c src) {
        ConversionView v = new ConversionView();
        v.requestId           = src.Id;
        v.showsConversion     = false;
        v.canConvert          = false;
        v.canRevert           = false;
        v.convertibleDays     = 0;
        v.convertedDays       = 0;
        v.remainingUnpaidDays = 0;
        v.annualAvailable     = 0;
        v.convertedRequests   = new List<ConvertedRequest>();
        return v;
    }

    public static ConversionView convert(Id requestId, Decimal days) {
        assertPermitted();
        ApplicationItem__c src = load(requestId);
        LeaveBalanceService.assertCanView(src.OwnerId);

        ConversionView before = buildView(src);
        if (before.canConvert != true) {
            throw new AuraHandledException(before.blockedReason);
        }

        Integer wanted = halfDaysRequested(days, before);
        List<Date> workingDays = ApplicationItemTriggerLogic.workingDaysFor(
            src, ApplicationItemTriggerLogic.holidaysForBatch(new List<ApplicationItem__c>{ src }));
        List<Half> halves = halvesFor(src, workingDays);

        /*
         * The day count comes from Leave_Days__c and the dates from workingDaysFor, and
         * both are the same calculation — but Leave_Days__c is stored and could have been
         * written when a different Holiday calendar was in force. Cutting on a figure the
         * dates do not support would put the boundary in the wrong place, so the dates win.
         */
        if (halves.size() < wanted) {
            wanted = halves.size();
        }
        if (wanted <= 0) {
            throw new AuraHandledException('This request covers no working day that could be converted.');
        }
        Boolean whole = wanted >= halves.size();

        try {
            if (STATUS_APPROVED.equals(src.Status__c)) {
                convertApproved(src, halves, wanted, whole);
            } else {
                convertDraft(src, halves, wanted, whole);
            }
        } catch (DmlException e) {
            // The validation rules carry the message the user needs — the probation
            // block above all, since Annual leave is the type being created here.
            throw new AuraHandledException(e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage());
        }

        return buildView(load(requestId));
    }

    /*
     * A Draft has spent nothing and booked nothing, so it can be edited in place.
     * Converting all of it is a change of type — the period rides along untouched, so a
     * half-day absence stays the half day it was. Converting part of it narrows the
     * record to the first of what is still unpaid and raises the rest beside it.
     *
     * The remainder can be more than one record now: half a boundary day cannot share a
     * record with the whole days after it, so Wednesday afternoon and Thursday-to-Friday
     * are two, not one.
     */
    private static void convertDraft(ApplicationItem__c src, List<Half> halves,
                                     Integer wanted, Boolean whole) {
        if (whole) {
            update new ApplicationItem__c(
                Id                       = src.Id,
                Request_Type__c          = TYPE_ANNUAL,
                // Approved for the same reason the raised records are, and in the same
                // breath as the type change: an Annual request left in Draft here is a
                // conversion that never reaches the balance.
                Status__c                = STATUS_APPROVED,
                Remark__c                = remarkWith(src.Remark__c, convertedNote(src)),
                Converted_From_Unpaid__c = true,
                Converted_From_Status__c = src.Status__c,
                Converted_On__c          = System.today(),
                Converted_By__c          = UserInfo.getUserId()
            );
            return;
        }
        List<Piece> converted = piecesFor(halves, 0, wanted);
        List<Piece> remainder = piecesFor(halves, wanted, halves.size() - wanted);

        // Shortened first, so no two records claim the same half day at any point.
        Piece head = remainder[0];
        update new ApplicationItem__c(
            Id              = src.Id,
            Term_From__c    = head.startsOn,
            Term_To__c      = head.endsOn,
            Period_Leave__c = head.period
        );

        List<ApplicationItem__c> raised = new List<ApplicationItem__c>();
        for (Integer i = 1; i < remainder.size(); i++) {
            raised.add(unpaidPiece(src, remainder[i], src.Status__c));
        }
        for (Piece piece : converted) {
            raised.add(convertedRequest(src, piece));
        }
        insert raised;
    }

    /*
     * An approved source cannot be trimmed, so it is reversed whole and rebuilt. The
     * rejection is what gives the unpaid days back and clears the bookings; both are
     * LeaveReversalService's work, driven by the status transition rather than repeated
     * here, so a conversion cannot restore a balance differently from a rejection.
     */
    private static void convertApproved(ApplicationItem__c src, List<Half> halves,
                                        Integer wanted, Boolean whole) {
        update new ApplicationItem__c(
            Id        = src.Id,
            Status__c = STATUS_REJECTED,
            Remark__c = remarkWith(src.Remark__c, convertedNote(src))
        );

        List<ApplicationItem__c> raised = new List<ApplicationItem__c>();
        for (Piece piece : piecesFor(halves, 0, wanted)) {
            raised.add(convertedRequest(src, piece));
        }
        if (!whole) {
            /*
             * Raised already Approved, which the trigger treats as a fresh approval: it
             * re-deducts the unpaid balance for these days and re-books their calendar
             * entries and man hours. Nobody is asked to sign a second time for days that
             * were approved as unpaid and are staying unpaid.
             */
            for (Piece piece : piecesFor(halves, wanted, halves.size() - wanted)) {
                raised.add(unpaidPiece(src, piece, STATUS_APPROVED));
            }
        }
        insert raised;
    }

    public static ConversionView revert(Id requestId, String reason) {
        assertPermitted();
        ApplicationItem__c src = load(requestId);
        LeaveBalanceService.assertCanView(src.OwnerId);

        List<ApplicationItem__c> made = convertedChildrenOf(src.Id);
        Boolean isItselfConverted = src.Converted_From_Unpaid__c == true
                                    && !STATUS_REJECTED.equals(src.Status__c);
        if (made.isEmpty() && !isItselfConverted) {
            throw new AuraHandledException(revertBlockedReasonFor(src, null));
        }

        try {
            if (!made.isEmpty()) {
                revertChildren(src, made, reason);
            } else {
                revertInPlace(src, reason);
            }
        } catch (DmlException e) {
            throw new AuraHandledException(e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage());
        }

        return buildView(load(requestId));
    }

    /*
     * The ordinary case: this record is the unpaid absence, and the conversion raised
     * paid requests beside it.
     */
    private static void revertChildren(ApplicationItem__c src, List<ApplicationItem__c> made,
                                       String reason) {
        List<ApplicationItem__c> toReject = new List<ApplicationItem__c>();
        Date earliest;
        for (ApplicationItem__c one : made) {
            toReject.add(new ApplicationItem__c(
                Id        = one.Id,
                Status__c = STATUS_REJECTED,
                Remark__c = remarkWith(one.Remark__c, revertedNote(reason))
            ));
            if (earliest == null || one.Term_From__c < earliest) {
                earliest = one.Term_From__c;
            }
        }
        // Before the days are put back, so no two records claim the same dates.
        update toReject;

        if (STATUS_REJECTED.equals(src.Status__c) && TYPE_UNPAID.equals(src.Request_Type__c)) {
            revertOntoSource(src, reason);
            return;
        }

        Boolean absorb = TYPE_UNPAID.equals(src.Request_Type__c)
                      && STATUS_DRAFT.equals(src.Status__c)
                      && src.Term_From__c != null
                      && earliest != null
                      && earliest < src.Term_From__c
                      && ALL_DAY.equals(src.Period_Leave__c)
                      && allWholeDays(made);
        if (absorb) {
            update new ApplicationItem__c(Id = src.Id, Term_From__c = earliest);
            return;
        }

        List<ApplicationItem__c> restored = new List<ApplicationItem__c>();
        for (ApplicationItem__c one : made) {
            restored.add(restoredUnpaid(src, one));
        }
        insert restored;
    }

    private static void revertOntoSource(ApplicationItem__c src, String reason) {
        List<ApplicationItem__c> standingIn = new List<ApplicationItem__c>();
        for (ApplicationItem__c one : [
            SELECT Id, Remark__c FROM ApplicationItem__c
            WHERE Split_From__c = :src.Id
              AND Request_Type__c = :TYPE_UNPAID
              AND Converted_From_Unpaid__c = false
              AND Status__c != :STATUS_REJECTED
        ]) {
            standingIn.add(new ApplicationItem__c(
                Id        = one.Id,
                Status__c = STATUS_REJECTED,
                Remark__c = remarkWith(one.Remark__c, revertedNote(reason))
            ));
        }
        if (!standingIn.isEmpty()) {
            update standingIn;
        }

        update new ApplicationItem__c(
            Id        = src.Id,
            Status__c = STATUS_APPROVED,
            Remark__c = remarkWith(src.Remark__c, revertedNote(reason))
        );
    }

    private static void revertInPlace(ApplicationItem__c src, String reason) {
        if (STATUS_DRAFT.equals(src.Status__c)) {
            update new ApplicationItem__c(
                Id                       = src.Id,
                Request_Type__c          = TYPE_UNPAID,
                Status__c                = statusOrDraft(src.Converted_From_Status__c),
                Remark__c                = remarkWith(src.Remark__c, revertedNote(reason)),
                Converted_From_Unpaid__c = false,
                Converted_From_Status__c = null,
                Converted_On__c          = null,
                Converted_By__c          = null
            );
            return;
        }
        update new ApplicationItem__c(
            Id        = src.Id,
            Status__c = STATUS_REJECTED,
            Remark__c = remarkWith(src.Remark__c, revertedNote(reason))
        );
        insert restoredUnpaid(src, src);
    }

    // ==================================================================== the view

    private static ConversionView buildView(ApplicationItem__c src) {
        ConversionView v = new ConversionView();
        v.requestId    = src.Id;
        v.requestName  = src.Name;
        v.requestType  = src.Request_Type__c;
        v.status       = src.Status__c;
        v.leaveYear    = src.Term_From__c == null ? null : src.Term_From__c.year();

        /*
         * A record this conversion produced, rather than one it was produced from. It is
         * a paid request now, so none of the unpaid arithmetic below applies to it — what
         * the card offers on it is the way back.
         */
        Boolean isItselfConverted = src.Converted_From_Unpaid__c == true
                                    && !STATUS_REJECTED.equals(src.Status__c);
        v.showsConversion = permitted()
                            && !ApplicationItemTriggerHandler.isOvertimeRequest(src)
                            && (TYPE_UNPAID.equals(src.Request_Type__c) || isItselfConverted);

        v.convertedRequests = new List<ConvertedRequest>();
        Decimal converted = 0;
        for (ApplicationItem__c child : [
            SELECT Id, Name, Leave_Days__c, Status__c
            FROM ApplicationItem__c
            WHERE Split_From__c = :src.Id AND Converted_From_Unpaid__c = true
            ORDER BY CreatedDate
        ]) {
            // A converted request that was then rejected gave its days back to nobody:
            // they are unpaid again on the record they came from, so they do not count
            // as converted here either.
            if (STATUS_REJECTED.equals(child.Status__c)) {
                continue;
            }
            converted += zeroIfNull(child.Leave_Days__c);

            ConvertedRequest made   = new ConvertedRequest();
            made.recordId           = child.Id;
            made.name               = child.Name;
            made.days               = zeroIfNull(child.Leave_Days__c);
            made.status             = child.Status__c;
            v.convertedRequests.add(made);
        }
        /*
         * A record converted in place is its own converted days: the conversion did not
         * raise anything beside it, so counting only children would report a fully
         * converted absence as having converted nothing.
         */
        v.convertedDays = isItselfConverted && converted == 0
            ? zeroIfNull(src.Leave_Days__c)
            : converted;

        Boolean stillCounts = !STATUS_REJECTED.equals(src.Status__c)
                              && TYPE_UNPAID.equals(src.Request_Type__c);
        v.remainingUnpaidDays = stillCounts ? zeroIfNull(src.Leave_Days__c) : 0;

        Leave_Balance__c annual = annualBalanceFor(src);

        v.annualAvailable = annual == null ? 0 : availableOn(annual);

        v.blockedReason   = blockedReasonFor(src, annual, v);
        v.canConvert      = v.blockedReason == null;
        v.convertibleDays = v.canConvert
            ? halfDays(min(v.remainingUnpaidDays, v.annualAvailable))
            : 0;
        v.revertBlockedReason = revertBlockedReasonFor(src, v.convertedRequests);
        v.canRevert           = v.revertBlockedReason == null;
        v.conversionStatus    = statusLabel(v);
        return v;
    }

    /*
     * Revert revokes the paid requests a conversion produced, so what stops it is having
     * produced none — or none that are still standing.
     */
    private static String revertBlockedReasonFor(ApplicationItem__c src,
                                                 List<ConvertedRequest> made) {
        if (!permitted()) {
            return 'Reverting a conversion is a manager action.';
        }
        if (ApplicationItemTriggerHandler.isOvertimeRequest(src)) {
            return 'An overtime claim has no conversion to revert.';
        }
        if (made != null && !made.isEmpty()) {
            return null;
        }
        if (src.Converted_From_Unpaid__c == true) {
            return STATUS_REJECTED.equals(src.Status__c)
                ? 'This converted request has already been rejected.'
                : null;
        }
        return 'Nothing has been converted from this request, so there is nothing to revert.';
    }

    /*
     * Ordered from "this is the wrong kind of record" to "the right record, but not
     * today", so the message the employee reads is about the first thing genuinely in
     * the way rather than the last one checked.
     */
    private static String blockedReasonFor(ApplicationItem__c src, Leave_Balance__c annual,
                                           ConversionView v) {
        // Before anything about the record, so canConvert can never come back true for
        // somebody convert() would refuse. The card is already hidden from them, but a
        // view object that contradicts the service it describes is a trap for the next
        // screen built on it.
        if (!permitted()) {
            return 'Converting unpaid leave to Annual leave is a manager action.';
        }
        if (ApplicationItemTriggerHandler.isOvertimeRequest(src)) {
            return 'An overtime claim has no unpaid days to convert.';
        }
        if (!TYPE_UNPAID.equals(src.Request_Type__c)) {
            return 'Only an Unpaid leave request can be converted to Annual leave.';
        }
        if (STATUS_REJECTED.equals(src.Status__c)) {
            return 'This request was rejected, so its days are not being taken unpaid.';
        }
        if (STATUS_PENDING.equals(src.Status__c)) {
            return 'This request is with an approver. It has to be approved or rejected '
                 + 'before its unpaid days can be converted.';
        }
        if (src.Term_From__c == null) {
            return 'This request has no start date, so there are no days to convert.';
        }
        if (v.remainingUnpaidDays < 0.5) {
            return 'There is no unpaid day left on this request to convert.';
        }
        if (annual == null) {
            return 'No Annual leave balance exists for ' + src.Term_From__c.year()
                 + '. Balances are created by the daily leave job.';
        }
        if (annual.Is_Locked__c == true) {
            return String.isBlank(annual.Lock_Reason__c)
                ? 'The Annual leave balance for ' + src.Term_From__c.year() + ' is locked.'
                : annual.Lock_Reason__c;
        }
        if (availableOn(annual) < 0.5) {
            return 'There is no Annual leave day available in ' + src.Term_From__c.year()
                 + ' to convert these days into.';
        }
        return null;
    }

    private static String statusLabel(ConversionView v) {
        if (v.convertedDays > 0) {
            return v.remainingUnpaidDays > 0 ? LABEL_PARTIAL : LABEL_FULL;
        }
        return v.canConvert == true ? LABEL_OPEN : LABEL_UNAVAILABLE;
    }

    // ==================================================================== plumbing

    /*
     * The Annual balance for the year the absence falls in, not the year it is being
     * corrected in. A December absence converted in January spends the December year's
     * days, because that is the year deductLeaveBalance will bill when the Draft is
     * approved — balanceKey is what both of them agree on.
     */
    private static Leave_Balance__c annualBalanceFor(ApplicationItem__c src) {
        if (src.Term_From__c == null) {
            return null;
        }
        String key = ApplicationItemTriggerLogic.balanceKey(
            src.OwnerId, TYPE_ANNUAL, src.Term_From__c.year());
        List<Leave_Balance__c> found = [
            SELECT Id, Accrued_To_Date__c, Carry_Over_Days__c, Used_Days__c,
                   Is_Locked__c, Lock_Reason__c
            FROM Leave_Balance__c WHERE External_Key__c = :key LIMIT 1
        ];
        return found.isEmpty() ? null : found[0];
    }

    /** Available_Balance__c by hand, so this reads the same figures the deduction locks. */
    private static Decimal availableOn(Leave_Balance__c bal) {
        return zeroIfNull(bal.Accrued_To_Date__c) + zeroIfNull(bal.Carry_Over_Days__c)
             - zeroIfNull(bal.Used_Days__c);
    }

    /** How many half days were asked for. Halves, because that is what a balance holds. */
    private static Integer halfDaysRequested(Decimal days, ConversionView before) {
        Decimal wanted = days == null ? before.convertibleDays : days;
        if (wanted == null || wanted <= 0) {
            throw new AuraHandledException('Enter how many days to convert.');
        }
        Decimal halves = wanted * 2;
        if (halves != halves.round(System.RoundingMode.DOWN)) {
            throw new AuraHandledException('Unpaid days convert in whole or half days only.');
        }
        if (wanted > before.convertibleDays) {
            throw new AuraHandledException('Only ' + plain(before.convertibleDays)
                + ' of the ' + plain(before.remainingUnpaidDays) + ' unpaid day(s) on this '
                + 'request can be converted right now.');
        }
        return Integer.valueOf(halves);
    }

    private static ApplicationItem__c convertedRequest(ApplicationItem__c src, Piece piece) {
        return new ApplicationItem__c(
            RecordTypeId             = src.RecordTypeId,
            Request_Type__c          = TYPE_ANNUAL,
            Period_Leave__c          = piece.period,
            Term_From__c             = piece.startsOn,
            Term_To__c               = piece.endsOn,
            Remark__c                = remarkWith(src.Remark__c, convertedNote(src)),
            Status__c                = STATUS_APPROVED,
            OwnerId                  = src.OwnerId,
            Split_From__c            = src.Id,
            Converted_From_Unpaid__c = true,
            Converted_From_Status__c = src.Status__c,
            Converted_On__c          = System.today(),
            Converted_By__c          = UserInfo.getUserId()
        );
    }

    private static ApplicationItem__c restoredUnpaid(ApplicationItem__c src, ApplicationItem__c made) {
        return new ApplicationItem__c(
            RecordTypeId    = src.RecordTypeId,
            Request_Type__c = TYPE_UNPAID,
            /*
             * The revoked request's own period. Restoring half a day as a whole one
             * would grant an unpaid day, and the entitlement behind it, for a morning
             * the employee worked.
             */
            Period_Leave__c = made.Period_Leave__c,
            Term_From__c    = made.Term_From__c,
            Term_To__c      = made.Term_To__c,
            Remark__c       = remarkWith(src.Remark__c, ' [unpaid days restored from ' + made.Name + ']'),
            Status__c       = statusOrDraft(made.Converted_From_Status__c),
            OwnerId         = src.OwnerId,
            // The absence this belongs to, unless the revoked request was the absence.
            Split_From__c   = src.Id == made.Id ? src.Split_From__c : src.Id
        );
    }

    private class Half {
        Date day;
        Boolean isMorning;
        Half(Date day, Boolean isMorning) {
            this.day = day;
            this.isMorning = isMorning;
        }
    }

    private class Piece {
        Date startsOn;
        Date endsOn;
        String period;
        Piece(Date startsOn, Date endsOn, String period) {
            this.startsOn = startsOn;
            this.endsOn = endsOn;
            this.period = period;
        }
    }

    private static List<Half> halvesFor(ApplicationItem__c src, List<Date> workingDays) {
        List<Half> halves = new List<Half>();
        if (workingDays.size() == 1 && isHalfDay(src.Period_Leave__c)) {
            halves.add(new Half(workingDays[0], AM_LEAVE.equals(src.Period_Leave__c)));
            return halves;
        }
        for (Date day : workingDays) {
            halves.add(new Half(day, true));
            halves.add(new Half(day, false));
        }
        return halves;
    }

    private static List<Piece> piecesFor(List<Half> halves, Integer first, Integer count) {
        List<Piece> pieces = new List<Piece>();
        Integer last = first + count - 1;

        if (!halves[first].isMorning) {
            pieces.add(new Piece(halves[first].day, halves[first].day, PM_LEAVE));
            first++;
        }
        Piece closing = (first <= last && halves[last].isMorning)
            ? new Piece(halves[last].day, halves[last].day, AM_LEAVE)
            : null;
        if (closing != null) {
            last--;
        }
        if (first <= last) {
            pieces.add(new Piece(halves[first].day, halves[last].day, ALL_DAY));
        }
        if (closing != null) {
            pieces.add(closing);
        }
        return pieces;
    }

    private static Boolean allWholeDays(List<ApplicationItem__c> records) {
        for (ApplicationItem__c one : records) {
            if (isHalfDay(one.Period_Leave__c)) {
                return false;
            }
        }
        return true;
    }

    private static Boolean isHalfDay(String period) {
        return AM_LEAVE.equals(period) || PM_LEAVE.equals(period);
    }

    private static List<ApplicationItem__c> convertedChildrenOf(Id parentId) {
        return [
            SELECT Id, Name, Term_From__c, Term_To__c, Status__c, Remark__c,
                   Leave_Days__c, Period_Leave__c, Converted_From_Status__c
            FROM ApplicationItem__c
            WHERE Split_From__c = :parentId
              AND Converted_From_Unpaid__c = true
              AND Status__c != :STATUS_REJECTED
            ORDER BY Term_From__c
        ];
    }

    private static String statusOrDraft(String status) {
        return STATUS_APPROVED.equals(status) ? STATUS_APPROVED : STATUS_DRAFT;
    }

    private static String revertedNote(String reason) {
        return String.isBlank(reason)
            ? ' [conversion reverted]'
            : ' [conversion reverted: ' + reason.trim() + ']';
    }

    /** One stretch of what stays unpaid, in the state those days are meant to be in. */
    private static ApplicationItem__c unpaidPiece(ApplicationItem__c src, Piece piece, String status) {
        return new ApplicationItem__c(
            RecordTypeId    = src.RecordTypeId,
            Request_Type__c = TYPE_UNPAID,
            Period_Leave__c = piece.period,
            Term_From__c    = piece.startsOn,
            Term_To__c      = piece.endsOn,
            Remark__c       = remarkWith(src.Remark__c, ' [unpaid remainder of ' + src.Name + ']'),
            Status__c       = status,
            OwnerId         = src.OwnerId,
            Split_From__c   = src.Id
        );
    }

    private static String convertedNote(ApplicationItem__c src) {
        return ' [converted from unpaid on ' + src.Name + ']';
    }

    /** The employee's own words first; the note is trimmed into what is left of 255. */
    private static String remarkWith(String base, String note) {
        String text = base == null ? '' : base;
        if (text.endsWith(note)) {
            return text; // already carries this note
        }
        Integer room = REMARK_MAX - note.length();
        return (text.length() > room ? text.substring(0, room) : text) + note;
    }

    private static ApplicationItem__c load(Id requestId) {
        if (requestId == null) {
            throw new AuraHandledException('A request Id is required.');
        }
        List<ApplicationItem__c> found = [
            SELECT Id, Name, OwnerId, RecordTypeId, Request_Type__c, Period_Leave__c,
                   Status__c, Term_From__c, Term_To__c, Leave_Days__c, Remark__c,
                   Split_From__c, Balance_Applied_Days__c, Leave_Balance__c,
                   Converted_From_Unpaid__c, Converted_From_Status__c
            FROM ApplicationItem__c WHERE Id = :requestId LIMIT 1
        ];
        if (found.isEmpty()) {
            throw new AuraHandledException('That request no longer exists.');
        }
        return found[0];
    }

    /** 2.0 reads as 2, which is what belongs in a sentence shown to an employee. */
    private static String plain(Decimal value) {
        return value == null ? '0' : value.stripTrailingZeros().toPlainString();
    }

    private static Decimal halfDays(Decimal value) {
        if (value == null || value <= 0) {
            return 0;
        }
        Long halves = (value * 2).round(System.RoundingMode.DOWN);
        return Decimal.valueOf(halves) / 2;
    }

    private static Decimal min(Decimal a, Decimal b) {
        return a < b ? a : b;
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}