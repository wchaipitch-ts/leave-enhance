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
 */
public without sharing class LeaveConversionService {

    @TestVisible private static final String TYPE_UNPAID = 'Unpaid leave';
    @TestVisible private static final String TYPE_ANNUAL = 'Annual leave';

    private static final String STATUS_DRAFT    = 'Draft';
    private static final String STATUS_PENDING  = 'Pending';
    private static final String STATUS_APPROVED = 'Approved';
    private static final String STATUS_REJECTED = 'Rejected';

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
        @AuraEnabled public Boolean  canReject;
        /** Why conversion is unavailable, in words fit to show the employee. */
        @AuraEnabled public String   blockedReason;
        /** The Annual requests this conversion produced, newest last. */
        @AuraEnabled public List<Id> convertedRequestIds;
    }

    // ==================================================================== reading

    /** The card's figures for one Unpaid leave request. */
    public static ConversionView view(Id requestId) {
        ApplicationItem__c src = load(requestId);
        LeaveBalanceService.assertCanView(src.OwnerId);
        return buildView(src);
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
        ApplicationItem__c src = load(requestId);
        LeaveBalanceService.assertCanView(src.OwnerId);

        ConversionView before = buildView(src);
        if (before.canConvert != true) {
            throw new AuraHandledException(before.blockedReason);
        }

        Integer wanted = wholeDaysRequested(days, before);
        List<Date> workingDays = ApplicationItemTriggerLogic.workingDaysFor(
            src, ApplicationItemTriggerLogic.holidaysForBatch(new List<ApplicationItem__c>{ src }));

        /*
         * The day count comes from Leave_Days__c and the dates from workingDaysFor, and
         * both are the same calculation — but Leave_Days__c is stored and could have been
         * written when a different Holiday calendar was in force. Cutting on a figure the
         * dates do not support would put the boundary in the wrong place, so the dates win.
         */
        if (workingDays.size() < wanted) {
            wanted = workingDays.size();
        }
        if (wanted <= 0) {
            throw new AuraHandledException('This request covers no working day that could be converted.');
        }
        Boolean whole = wanted >= workingDays.size();

        try {
            if (STATUS_APPROVED.equals(src.Status__c)) {
                convertApproved(src, workingDays, wanted, whole);
            } else {
                convertDraft(src, workingDays, wanted, whole);
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
     * Converting all of it is a change of type; converting part of it moves the start
     * date past the converted days and raises the paid ones beside it.
     */
    private static void convertDraft(ApplicationItem__c src, List<Date> workingDays,
                                     Integer wanted, Boolean whole) {
        if (whole) {
            update new ApplicationItem__c(
                Id                       = src.Id,
                Request_Type__c          = TYPE_ANNUAL,
                Remark__c                = remarkWith(src.Remark__c, convertedNote(src)),
                Converted_From_Unpaid__c = true,
                Converted_On__c          = System.now(),
                Converted_By__c          = UserInfo.getUserId()
            );
            return;
        }
        // Shortened first, so the two records never claim the same dates at any point.
        update new ApplicationItem__c(Id = src.Id, Term_From__c = workingDays[wanted]);
        insert convertedRequest(src, workingDays[0], workingDays[wanted - 1]);
    }

    /*
     * An approved source cannot be trimmed, so it is reversed whole and rebuilt. The
     * rejection is what gives the unpaid days back and clears the bookings; both are
     * LeaveReversalService's work, driven by the status transition rather than repeated
     * here, so a conversion cannot restore a balance differently from a rejection.
     */
    private static void convertApproved(ApplicationItem__c src, List<Date> workingDays,
                                        Integer wanted, Boolean whole) {
        update new ApplicationItem__c(
            Id        = src.Id,
            Status__c = STATUS_REJECTED,
            Remark__c = remarkWith(src.Remark__c, convertedNote(src))
        );

        List<ApplicationItem__c> raised = new List<ApplicationItem__c>{
            convertedRequest(src, workingDays[0], workingDays[wanted - 1])
        };
        if (!whole) {
            /*
             * Raised already Approved, which the trigger treats as a fresh approval: it
             * re-deducts the unpaid balance for these days and re-books their calendar
             * entries and man hours. The employee is not asked to submit days that were
             * approved as unpaid and are staying unpaid — only the converted ones need a
             * decision, and they are the Draft above.
             */
            raised.add(unpaidRemainder(src, workingDays[wanted]));
        }
        insert raised;
    }

    // ==================================================================== rejecting

    /**
     * Rejects the request and reverses everything its approval did — the balance, the
     * calendar entries, the timesheet bookings. All of that is LeaveReversalService,
     * reached through the status transition; nothing is undone here by hand.
     *
     * @param reason appended to the remark. Optional, but it is the only record of why
     *               a settled absence was taken back.
     */
    public static ConversionView reject(Id requestId, String reason) {
        ApplicationItem__c src = load(requestId);
        LeaveBalanceService.assertCanView(src.OwnerId);

        if (STATUS_REJECTED.equals(src.Status__c)) {
            throw new AuraHandledException('This request has already been rejected.');
        }
        if (ApplicationItemTriggerHandler.isOvertimeRequest(src)) {
            throw new AuraHandledException('This is an overtime claim, not a leave request.');
        }

        try {
            update new ApplicationItem__c(
                Id        = src.Id,
                Status__c = STATUS_REJECTED,
                Remark__c = String.isBlank(reason)
                            ? src.Remark__c
                            : remarkWith(src.Remark__c, ' [reverted: ' + reason.trim() + ']')
            );
        } catch (DmlException e) {
            throw new AuraHandledException(e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage());
        }

        return buildView(load(requestId));
    }

    // ==================================================================== the view

    private static ConversionView buildView(ApplicationItem__c src) {
        ConversionView v = new ConversionView();
        v.requestId    = src.Id;
        v.requestName  = src.Name;
        v.requestType  = src.Request_Type__c;
        v.status       = src.Status__c;
        v.leaveYear    = src.Term_From__c == null ? null : src.Term_From__c.year();
        v.canReject    = !STATUS_REJECTED.equals(src.Status__c)
                         && !ApplicationItemTriggerHandler.isOvertimeRequest(src);

        v.convertedRequestIds = new List<Id>();
        Decimal converted = 0;
        Decimal awaitingApproval = 0;
        for (ApplicationItem__c child : [
            SELECT Id, Leave_Days__c, Status__c
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
            v.convertedRequestIds.add(child.Id);
            /*
             * A converted request in Draft or Pending has not spent the balance yet —
             * the approval will. Counting it as spent anyway is what stops the card
             * offering the same two days a second time and letting the employee raise
             * more paid leave than exists, only for the second approval to be refused
             * by deductLeaveBalance long after they thought it was settled.
             */
            if (!STATUS_APPROVED.equals(child.Status__c)) {
                awaitingApproval += zeroIfNull(child.Leave_Days__c);
            }
        }
        v.convertedDays = converted;

        Boolean stillCounts = !STATUS_REJECTED.equals(src.Status__c)
                              && TYPE_UNPAID.equals(src.Request_Type__c);
        v.remainingUnpaidDays = stillCounts ? zeroIfNull(src.Leave_Days__c) : 0;

        Leave_Balance__c annual = annualBalanceFor(src);
        // The balance as it stands, which is what the employee sees on the balance page.
        v.annualAvailable = annual == null ? 0 : availableOn(annual);
        // What is left of it once this record's own unapproved conversions are counted.
        Decimal spendable = floorAtZero(v.annualAvailable - awaitingApproval);

        v.blockedReason   = blockedReasonFor(src, annual, v, spendable);
        v.canConvert      = v.blockedReason == null;
        v.convertibleDays = v.canConvert
            ? wholeDays(min(v.remainingUnpaidDays, spendable))
            : 0;
        v.conversionStatus = statusLabel(v);
        return v;
    }

    /*
     * Ordered from "this is the wrong kind of record" to "the right record, but not
     * today", so the message the employee reads is about the first thing genuinely in
     * the way rather than the last one checked.
     */
    private static String blockedReasonFor(ApplicationItem__c src, Leave_Balance__c annual,
                                           ConversionView v, Decimal spendable) {
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
        if (v.remainingUnpaidDays < 1) {
            /*
             * Half days are the case that lands here with days still on the record. The
             * split leaves a part day in the balance rather than rounding it away, and
             * conversion follows it: half a day of Annual leave for half a day unpaid
             * would have to be raised by hand.
             */
            return 'There is no whole unpaid day left on this request to convert.';
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
        if (spendable < 1) {
            return availableOn(annual) >= 1
                ? 'The Annual leave days left in ' + src.Term_From__c.year() + ' are already '
                  + 'claimed by a converted request from this absence that is waiting for '
                  + 'approval. Submit it, or reject it to release them.'
                : 'There is no whole Annual leave day available in ' + src.Term_From__c.year()
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
            SELECT Id, Accrued_Days__c, Carry_Over_Days__c, Used_Days__c,
                   Is_Locked__c, Lock_Reason__c
            FROM Leave_Balance__c WHERE External_Key__c = :key LIMIT 1
        ];
        return found.isEmpty() ? null : found[0];
    }

    /** Available_Days__c by hand, so this reads the same figures the deduction locks. */
    private static Decimal availableOn(Leave_Balance__c bal) {
        return zeroIfNull(bal.Accrued_Days__c) + zeroIfNull(bal.Carry_Over_Days__c)
             - zeroIfNull(bal.Used_Days__c);
    }

    private static Integer wholeDaysRequested(Decimal days, ConversionView before) {
        Decimal wanted = days == null ? before.convertibleDays : days;
        if (wanted == null || wanted <= 0) {
            throw new AuraHandledException('Enter how many days to convert.');
        }
        if (wanted != wanted.round(System.RoundingMode.DOWN)) {
            throw new AuraHandledException('Unpaid days convert in whole days only.');
        }
        if (wanted > before.convertibleDays) {
            throw new AuraHandledException('Only ' + plain(before.convertibleDays)
                + ' of the ' + plain(before.remainingUnpaidDays) + ' unpaid day(s) on this '
                + 'request can be converted right now.');
        }
        return Integer.valueOf(wanted);
    }

    private static ApplicationItem__c convertedRequest(ApplicationItem__c src, Date startDay, Date endDay) {
        return new ApplicationItem__c(
            RecordTypeId             = src.RecordTypeId,
            Request_Type__c          = TYPE_ANNUAL,
            Period_Leave__c          = 'All day',
            Term_From__c             = startDay,
            Term_To__c               = endDay,
            Remark__c                = remarkWith(src.Remark__c, convertedNote(src)),
            // Draft on purpose: the owner submits it, and the approval is what spends
            // the Annual balance. Nothing here deducts anything.
            Status__c                = STATUS_DRAFT,
            OwnerId                  = src.OwnerId,
            Split_From__c            = src.Id,
            Converted_From_Unpaid__c = true,
            Converted_On__c          = System.now(),
            Converted_By__c          = UserInfo.getUserId()
        );
    }

    private static ApplicationItem__c unpaidRemainder(ApplicationItem__c src, Date startDay) {
        return new ApplicationItem__c(
            RecordTypeId    = src.RecordTypeId,
            Request_Type__c = TYPE_UNPAID,
            Period_Leave__c = 'All day',
            Term_From__c    = startDay,
            Term_To__c      = src.Term_To__c,
            Remark__c       = remarkWith(src.Remark__c, ' [unpaid remainder of ' + src.Name + ']'),
            Status__c       = STATUS_APPROVED,
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
                   Split_From__c, Balance_Applied_Days__c, Leave_Balance__c
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

    private static Decimal wholeDays(Decimal value) {
        return value <= 0 ? 0 : value.round(System.RoundingMode.DOWN);
    }

    private static Decimal min(Decimal a, Decimal b) {
        return a < b ? a : b;
    }

    private static Decimal floorAtZero(Decimal value) {
        return value < 0 ? 0 : value;
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}
