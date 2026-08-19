/*
 * LEAVE-42 — the two rules a leave request has to satisfy before it can be submitted.
 *
 *   Personal leave is one day per request, and always needs a supporting document.
 *   Sick leave needs one once it reaches three days.
 *
 * Both are configuration: Max_Days_Per_Request__c and Document_Required_From_Days__c on
 * Leave_Type_Policy__mdt. Nothing here names a leave type.
 *
 * WHY THIS IS APEX RATHER THAN A VALIDATION RULE
 *
 * Submitting for approval does not set Status__c directly. The approval process matches
 * on Status__c = Draft and then runs a workflow field update to write Pending. Workflow
 * field updates re-fire before and after update triggers, but custom validation rules are
 * NOT re-evaluated - so a validation rule keyed on the transition into Pending would never
 * see the only path that actually produces it. A before-update trigger does, which is why
 * the document gate lives here.
 *
 * The day cap has no such constraint and could have been declarative. It is here anyway,
 * so that both rules read one Custom Metadata row and are proved by one test class; a
 * validation rule can only reference a NAMED metadata record, not look one up by the
 * request's own leave type, so the declarative version would have had to hardcode
 * 'Personal leave' and 1 into a formula.
 */
public without sharing class LeaveRequestGuard {

    private static final String STATUS_PENDING = 'Pending';

    /*
     * Runs in the before contexts, after ApplicationItemTriggerLogic.calculateLeaveDays -
     * both checks read Leave_Days__c, and on insert it does not exist until that has run.
     */
    public static void enforce(List<ApplicationItem__c> requests, Map<Id, ApplicationItem__c> oldMap) {
        if (requests.isEmpty() || LeaveDocumentPolicy.bypassed()) {
            return;
        }
        enforceDayCap(requests, oldMap);
        enforceDocumentOnSubmit(requests, oldMap);
    }

    /*
     * One day per request for Personal leave.
     *
     * Scoped to saves that create or reshape the request, so it cannot block an unrelated
     * edit to a record that predates the rule - somebody correcting a remark on last
     * year's three-day Personal leave request should not be made to fix its dates first.
     * Leave_Request_Probation_Block narrows itself the same way and for the same reason.
     */
    private static void enforceDayCap(List<ApplicationItem__c> requests, Map<Id, ApplicationItem__c> oldMap) {
        for (ApplicationItem__c appl : requests) {
            if (!isReshaped(appl, oldMap)) {
                continue;
            }
            Decimal cap = LeaveDocumentPolicy.maxDaysFor(appl.Request_Type__c);
            if (cap == null) {
                continue;
            }
            /*
             * Both measures, because neither alone is enough. The day count misses a
             * Saturday-to-Sunday request, which counts no working days at all and would
             * read as within any cap while covering two dates. The calendar span misses
             * nothing on its own but would refuse a week containing a public holiday for
             * a hypothetical five-day cap, so the two are checked together rather than
             * one standing in for the other.
             */
            if (zeroIfNull(appl.Leave_Days__c) > cap || calendarSpanOf(appl) > cap) {
                appl.addError(capMessage(appl, cap));
            }
        }
    }

    /*
     * The supporting document, checked as the request crosses from Draft into Pending.
     *
     * addError here rolls the whole submission back: no ProcessInstance, no lock, no mail
     * to the approver, and Status__c is still Draft. That is what lets the employee attach
     * the file and press the button again - the approval process sets allowRecall to
     * false, so a submission that half-succeeded and locked the record would need a
     * manager to reject it before the file could be added.
     */
    private static void enforceDocumentOnSubmit(List<ApplicationItem__c> requests,
                                                Map<Id, ApplicationItem__c> oldMap) {
        List<ApplicationItem__c> submitting = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : requests) {
            if (!STATUS_PENDING.equals(appl.Status__c)) {
                continue;
            }
            if (oldMap != null) {
                ApplicationItem__c prior = oldMap.get(appl.Id);
                if (prior == null || STATUS_PENDING.equals(prior.Status__c)) {
                    continue; // already pending; this save is something else
                }
            }
            if (LeaveDocumentPolicy.requiresDocument(appl)) {
                submitting.add(appl);
            }
        }
        if (submitting.isEmpty()) {
            return;
        }

        /*
         * Created already Pending. A file cannot be attached to a record that does not
         * exist yet, so there is nothing to look up and the answer is always no. Being
         * refused is the correct outcome and states the actual remedy: save it as a
         * Draft, attach the document, then submit.
         */
        if (oldMap == null) {
            for (ApplicationItem__c appl : submitting) {
                appl.addError(missingDocumentMessage(appl));
            }
            return;
        }

        Map<Id, Integer> held = LeaveDocumentPolicy.documentCountsFor(
            new Map<Id, ApplicationItem__c>(submitting).keySet());

        for (ApplicationItem__c appl : submitting) {
            Integer count = held.get(appl.Id);
            if (count == null || count == 0) {
                appl.addError(missingDocumentMessage(appl));
            }
        }
    }

    /*
     * True on insert, and on an update that changed what the request is asking for. The
     * same four fields LeaveSplitService re-splits on, for the same reason: these are what
     * can change how many days are involved.
     */
    private static Boolean isReshaped(ApplicationItem__c appl, Map<Id, ApplicationItem__c> oldMap) {
        if (oldMap == null) {
            return true;
        }
        ApplicationItem__c prior = oldMap.get(appl.Id);
        if (prior == null) {
            return false;
        }
        return prior.Term_From__c != appl.Term_From__c
            || prior.Term_To__c != appl.Term_To__c
            || prior.Request_Type__c != appl.Request_Type__c
            || prior.Period_Leave__c != appl.Period_Leave__c;
    }

    /** Calendar dates covered, inclusive. A request with no end date covers one. */
    private static Integer calendarSpanOf(ApplicationItem__c appl) {
        if (appl.Term_From__c == null) {
            return 0;
        }
        if (appl.Term_To__c == null || appl.Term_To__c <= appl.Term_From__c) {
            return 1;
        }
        return appl.Term_From__c.daysBetween(appl.Term_To__c) + 1;
    }

    private static String capMessage(ApplicationItem__c appl, Decimal cap) {
        String unit = plain(cap) + (cap == 1 ? ' day' : ' days');
        return appl.Request_Type__c + ' can cover at most ' + unit + ' per request. '
            + 'Clear the end date and raise a separate request for each day.';
    }

    private static String missingDocumentMessage(ApplicationItem__c appl) {
        Decimal threshold = LeaveDocumentPolicy.documentThresholdFor(appl.Request_Type__c);
        String scope = (threshold == null || threshold <= 0)
            ? appl.Request_Type__c
            : appl.Request_Type__c + ' of ' + plain(threshold) + ' days or more';
        return scope + ' requires a supporting document. Upload one in the Files section of '
            + 'this request, then submit it again. The request stays in Draft until you do.';
    }

    /** 1.0 reads as 1, which is what belongs in a sentence shown to an employee. */
    private static String plain(Decimal value) {
        return value.stripTrailingZeros().toPlainString();
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}
