/*
 * LEAVE-44 — turning unpaid days back into Annual leave.
 *
 * LeaveSplitService cuts a request down to what the balance can afford and raises the
 * remainder as its own Unpaid leave record. That decision is made when the request is
 * saved, against the balance as it stood that day. Annual leave accrues monthly, so by
 * the time the absence is over the employee may well have the days they were short of.
 * Nothing until now could spend them: the unpaid record was settled and the balance it
 * would have drawn on was somebody else's problem.
 *
 * This is that correction, made deliberately by a person rather than by a trigger.
 * LeaveReversalService.promoteUnpaidSiblings already handles the automatic case — an
 * unapproved tail whose paid half was refused — and says why it stops where it does:
 * "turning them into paid days after the fact is a payroll correction somebody should
 * make deliberately". This class is where that deliberate act lives.
 *
 * WHAT A CONVERSION ACTUALLY IS
 *
 * Not a field edit. The converted days become an ordinary Annual leave request in
 * Draft, which the owner submits and an approver signs, exactly as if they had asked
 * for paid leave in the first place. That is the whole point: nothing here spends
 * Annual balance. deductLeaveBalance does, on approval, as it does for every other
 * request — so a conversion cannot quietly overdraw a balance that moved between the
 * conversion and the approval.
 *
 * Partial conversions are a cut in the dates, not a pair of counters. Converting 2 of
 * 5 unpaid days leaves an Unpaid record for 3 days and an Annual record for 2, each
 * measuring its own days and deducting its own balance — the model LEAVE-40 settled
 * on when it retired the LWOP fields. The earliest days convert first, mirroring the
 * date order LeaveSplitService consumes balance in.
 *
 * WHY AN APPROVED SOURCE IS REJECTED RATHER THAN SHORTENED
 *
 * Approved_Request_Is_Locked refuses every edit to an approved request except moving
 * it to Rejected, because editing one rewrote the day count without re-deducting. So
 * an approved unpaid record cannot be trimmed in place. It is rejected instead, which
 * runs LeaveReversalService: the unpaid days come back, the entitlement granted on use
 * unwinds with them, and the calendar entries and timesheet bookings go. What was
 * genuinely still unpaid is then re-raised already Approved, so days that were signed
 * for once are not sent round for signature again — only the converted days are, and
 * those are in Draft where the owner can see them before anyone else does.
 *
 * REVERTING
 *
 * A conversion is a decision, and decisions are made in error. Reverting revokes the
 * paid request the conversion produced and puts the days back as unpaid — as they were,
 * which is the whole meaning of the word. Converted_From_Status__c is what makes "as
 * they were" knowable: once the source has been rejected and replaced, nothing else on
 * the record says whether those days had been approved. Guessing would either re-grant
 * days nobody signed for or take away days somebody did.
 *
 * Revoking the paid request is a rejection, so the reversal of whatever it had spent —
 * Annual balance, calendar entries, man hours — is LeaveReversalService's, exactly as
 * it is everywhere else. Nothing is unwound here by hand.
 */
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

    /*
     * The writes refuse rather than going quiet, because unlike the card there is
     * nothing to hide behind: a caller reaching convert or revert has gone past the
     * missing card, and silence would read as success.
     */
    private static void assertPermitted() {
        if (!permitted()) {
            throw new AuraHandledException(
                'Converting unpaid leave to Annual leave is a manager action. You do not '
              + 'have permission to convert this request.');
        }
    }

    // ==================================================================== reading

    /**
     * The card's figures for one Unpaid leave request.
     *
     * Deliberately does not refuse an unpermitted caller. showsConversion comes back
     * false and the card removes itself, which is what an employee should see: nothing.
     * Throwing here would paint the error banner instead, which tells them at length
     * about a correction they are not the one to make.
     */
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

    // ==================================================================== converting

    /**
     * Turns `days` unpaid days on `requestId` into an Annual leave request in Draft.
     *
     * @param days how many whole days to convert; null converts everything convertible.
     * @return the card's figures again, read back after the conversion. Worth reading
     *         rather than assuming: an approved source is rejected and replaced, so the
     *         record the caller was looking at is not the record that survives.
     */
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

    // ==================================================================== reverting

    /**
     * Revokes the paid requests a conversion produced and puts the days back as unpaid.
     *
     * The paid request is rejected rather than deleted, so whatever it had spent comes
     * back the way it does everywhere else — LeaveReversalService, driven by the status
     * transition. A converted request still in Draft has spent nothing and simply stops
     * being asked for.
     *
     * The days then return as they were before the conversion, which is what
     * Converted_From_Status__c is for. Days that were approved unpaid come back approved
     * unpaid: they were taken, the absence happened, and asking somebody to sign for them
     * a second time because a correction was tried and undone would be an odd thing to
     * do to an employee.
     *
     * @param reason appended to the remark. It is the only record of why a conversion
     *               that somebody made deliberately was taken back.
     */
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

        /*
         * A Draft source was shortened rather than replaced when it was converted, so
         * the days can simply go back onto it and the absence is one record again — the
         * shape it had before anybody pressed anything. Anything else has to be raised
         * beside it: the source was rejected and replaced, and an approved record cannot
         * be widened in any case.
         */
        /*
         * Only when every record involved is a whole day. Widening a PM-leave record to
         * start on an earlier date would make a range carrying a half-day period, which
         * Leave_Request_Period_Single_Day_Only refuses and calculateLeaveDays would
         * miscount anyway. A half-day boundary is put back beside the record instead —
         * more records than the absence started with, which is the cost of the boundary
         * being two records in the first place.
         */
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

    /*
     * A record converted in place: this record IS the conversion, nothing was raised
     * beside it. A conversion now lands Approved, so it has spent Annual balance and
     * booked its days, and only a rejection gives those back — LeaveReversalService's
     * work, driven by the status transition as it is everywhere else.
     *
     * The Draft branch is for conversions made before they landed Approved. Those spent
     * nothing, so they can simply be turned back into what they were rather than being
     * rejected and re-raised. Nothing this class writes reaches it any more, but the
     * records it is for are sitting in the org, and rejecting one would take back an
     * Annual day it never spent.
     */
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
        /*
         * The balance as it stands, which is what the employee sees on the balance page
         * and what a conversion spends. Nothing is held back against conversions already
         * made from this record: they were approved as they were made, so the days they
         * took are out of Used_Days__c and out of this figure already.
         */
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
            // The piece's own period, not All day. Converting the morning of a boundary
            // day into a whole paid day would pay for an afternoon that was worked.
            Period_Leave__c          = piece.period,
            Term_From__c             = piece.startsOn,
            Term_To__c               = piece.endsOn,
            Remark__c                = remarkWith(src.Remark__c, convertedNote(src)),
            /*
             * Approved on insert. The manager doing the converting is the person who
             * would have approved it, so sending it back for a signature they have just
             * given is a round trip that buys nothing — and one the employee has to
             * complete, which is how days a manager believed were converted end up
             * sitting in a Draft nobody submitted while payroll pays out on them.
             *
             * The trigger treats an inserted Approved record as a fresh approval, as it
             * already does for the unpaid remainder beside it: deductLeaveBalance spends the
             * Annual balance in this same transaction and refuses an overdraw, so
             * nothing here can quietly pay for days that do not exist.
             */
            Status__c                = STATUS_APPROVED,
            OwnerId                  = src.OwnerId,
            Split_From__c            = src.Id,
            Converted_From_Unpaid__c = true,
            // What the days were before this, so reverting can put them back as they were.
            Converted_From_Status__c = src.Status__c,
            Converted_On__c          = System.today(),
            Converted_By__c          = UserInfo.getUserId()
        );
    }

    /*
     * The unpaid days of one revoked conversion, back as their own request. `made` is
     * the paid request being revoked — its dates are the days to restore, and the status
     * it recorded at conversion is the state to restore them to.
     */
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

    // ============================================================ half-day shaping

    /*
     * A morning or an afternoon of one working day, and the records a run of them
     * becomes.
     *
     * DUPLICATED FROM LeaveSplitService.halvesFor/piecesFor, which is the original and
     * the one to read for why any of it is shaped this way. The two must agree: the
     * split builds the tiling of an absence and a conversion re-cuts one it built, so a
     * boundary shaped differently here than there produces a family where some records
     * came from one rule and some from another. Change both, or extract them.
     *
     * Kept separate for now because this service uses only the shaping — it has no
     * overflow chain, no pools and no expiry windows, which is most of what that class
     * is — and pulling four private inner types out of a trigger-critical class is work
     * of its own.
     */
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

    /*
     * The request as half days, which is the unit a conversion is now cut in. A request
     * that is itself already a half day is one half and cannot be divided again — the
     * absence happened in that morning or that afternoon, and conversion is about who
     * pays for it, not when it fell.
     */
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

    /*
     * The records one run of halves becomes: at most the afternoon it starts on, the
     * whole days, and the morning it ends on.
     *
     * A boundary day has to be a record of its own because Period_Leave__c is the only
     * place a half day can be expressed and it means nothing on a range — refused there
     * by Leave_Request_Period_Single_Day_Only, and ignored by calculateLeaveDays, which
     * counts a range in whole days.
     *
     * The closing morning is built early and held back so it lands after the whole-day
     * range rather than before it, which is what keeps the records in date order.
     */
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

    /*
     * Anything unrecognised restores as a Draft. A record converted before this was
     * stamped has no recorded status, and asking for a signature on days that may not
     * have had one is the safe way round: the alternative grants unpaid days, and the
     * entitlement behind them, that nobody approved.
     */
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

    /*
     * Floored to the half day, which is the granularity a balance is held at and now the
     * granularity a conversion cuts at. Anything finer is rounded away because no balance
     * can hold it.
     *
     * Long division would truncate, so the halves go back through Decimal to be halved.
     */
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