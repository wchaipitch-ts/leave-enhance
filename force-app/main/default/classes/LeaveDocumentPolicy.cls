/*
 * LEAVE-42 — supporting documents on leave requests.
 *
 * Two rules meet here. A request of a type that needs evidence cannot be submitted for
 * approval without a file attached, and once it has been submitted that file cannot be
 * taken away again. Both read the same Custom Metadata, so a new leave type needing a
 * certificate is a Leave_Type_Policy__mdt row rather than a deployment - the same reason
 * Deducts_Balance__c replaced the hardcoded type sets in ApplicationItemTriggerLogic.
 *
 * The requirement is judged PER RECORD, on the day count the record is left holding.
 * A sick request that LeaveSplitService cut down to two paid days plus an unpaid tail is
 * two days as far as this class is concerned, so a four-day absence taken against a
 * two-day balance submits without a certificate. That is a decided trade rather than an
 * oversight: judging the whole split family costs another query and still cannot see
 * through the paidDays == 0 conversion, which overwrites Request_Type__c in place and
 * leaves nothing behind saying the request was ever sick leave.
 */
public without sharing class LeaveDocumentPolicy {

    /*
     * One key rather than three. HR entering leave on somebody else's behalf, or purging a
     * medical certificate uploaded to the wrong request, needs the day cap, the submit gate
     * and the removal lock lifted together, and a single override is easier to audit than a
     * matrix of them. It is correspondingly broad, which is why it ships on its own
     * permission set rather than on Leave_Management_Admin - assign it to the few people who
     * genuinely need it.
     */
    private static final String PERMISSION = 'Bypass_Leave_Request_Rules';

    /*
     * A request whose balance is spent or whose approver is looking at it right now.
     * Draft and Rejected are left alone: nothing has been decided on the strength of the
     * document yet, so the employee can still tidy up.
     */
    private static final Set<String> LOCKED_STATUSES = new Set<String>{ 'Pending', 'Approved' };

    // Test hook. FeatureManagement reads the running user's assignments, and a test
    // cannot assign a permission set to itself mid-transaction without System.runAs
    // gymnastics that obscure what is being tested.
    @TestVisible private static Boolean bypassOverride;

    /*
     * Requests being deleted in this transaction, noted by the ApplicationItem trigger
     * before the delete runs.
     *
     * Deleting an approved request is supported - LEAVE-34 built the whole reversal path
     * for it - and the platform takes the ContentDocumentLinks with it. Without this the
     * removal lock would look at those cascaded links, see an approved request losing its
     * last certificate, and refuse the delete the reversal depends on.
     */
    @TestVisible private static Set<Id> requestsBeingDeleted = new Set<Id>();

    /** True when the running user holds the override. */
    public static Boolean bypassed() {
        if (bypassOverride != null) {
            return bypassOverride;
        }
        return FeatureManagement.checkPermission(PERMISSION);
    }

    public static Decimal documentThresholdFor(String requestType) {
        Leave_Type_Policy__mdt policy = ApplicationItemTriggerLogic.policyFor(requestType);
        return policy == null ? null : policy.Document_Required_From_Days__c;
    }

    public static Decimal maxDaysFor(String requestType) {
        Leave_Type_Policy__mdt policy = ApplicationItemTriggerLogic.policyFor(requestType);
        return policy == null ? null : policy.Max_Days_Per_Request__c;
    }

    /*
     * Whether this request needs a file before it can be submitted.
     *
     * A blank threshold means the type never needs one. Zero means it always does, which
     * is what makes a half-day Personal leave request need a document: Leave_Days__c is
     * 0.5 and 0.5 >= 0.
     */
    public static Boolean requiresDocument(ApplicationItem__c appl) {
        Decimal threshold = documentThresholdFor(appl.Request_Type__c);
        if (threshold == null) {
            return false;
        }
        return zeroIfNull(appl.Leave_Days__c) >= threshold;
    }

    /** How many documents each request currently holds. Requests with none are absent. */
    public static Map<Id, Integer> documentCountsFor(Set<Id> requestIds) {
        Map<Id, Integer> counts = new Map<Id, Integer>();
        if (requestIds.isEmpty()) {
            return counts;
        }
        for (ContentDocumentLink link : [
            SELECT LinkedEntityId FROM ContentDocumentLink WHERE LinkedEntityId IN :requestIds
        ]) {
            Integer seen = counts.get(link.LinkedEntityId);
            counts.put(link.LinkedEntityId, seen == null ? 1 : seen + 1);
        }
        return counts;
    }

    /*
     * Noted in the before-delete context, because by the after-delete context the links
     * this needs to excuse have already gone.
     */
    public static void noteRequestsBeingDeleted(List<ApplicationItem__c> oldList) {
        for (ApplicationItem__c appl : oldList) {
            requestsBeingDeleted.add(appl.Id);
        }
    }

    /*
     * ContentDocument before delete — the path the Files related list takes. Deleting the
     * document takes every link with it, and a cascade does not fire the link trigger, so
     * this is the one that actually has to work.
     *
     * Fires on every file deletion anywhere in the org, including the run logs
     * LeaveManagementController.createLogFile writes, so it gives up as early as it can.
     */
    public static void blockDocumentRemoval(List<ContentDocument> docs) {
        if (docs == null || docs.isEmpty() || bypassed()) {
            return;
        }

        Map<Id, Set<Id>> requestsByDoc = requestsLinkedTo(new Map<Id, ContentDocument>(docs).keySet());
        if (requestsByDoc.isEmpty()) {
            return;
        }

        Set<Id> stripped = requestsLosingTheirLastDocument(requestsByDoc);
        for (ContentDocument doc : docs) {
            if (touchesAny(requestsByDoc.get(doc.Id), stripped)) {
                doc.addError(removalMessage());
            }
        }
    }

    /*
     * ContentDocumentLink before delete — unlinking a file from the request without
     * deleting the file itself, which is the API route rather than anything the Files
     * related list offers.
     */
    public static void blockLinkRemoval(List<ContentDocumentLink> links) {
        if (links == null || links.isEmpty() || bypassed()) {
            return;
        }

        Map<Id, Set<Id>> requestsByDoc = new Map<Id, Set<Id>>();
        for (ContentDocumentLink link : links) {
            if (!isLeaveRequestLink(link.LinkedEntityId) || link.ContentDocumentId == null) {
                continue;
            }
            addTo(requestsByDoc, link.ContentDocumentId, link.LinkedEntityId);
        }
        if (requestsByDoc.isEmpty()) {
            return;
        }

        Set<Id> stripped = requestsLosingTheirLastDocument(requestsByDoc);
        for (ContentDocumentLink link : links) {
            if (stripped.contains(link.LinkedEntityId)) {
                link.addError(removalMessage());
            }
        }
    }

    /*
     * The requests that would be left with nothing.
     *
     * Removal is refused only where it breaks the invariant - a submitted request of a
     * type that needs evidence, holding evidence. Taking one of several files away is
     * allowed, and so is replacing one via Upload New Version, which deletes nothing.
     * That matters because the approval process sets allowRecall to false: a blanket ban
     * would strand a certificate uploaded to the wrong request until somebody rejected it.
     */
    private static Set<Id> requestsLosingTheirLastDocument(Map<Id, Set<Id>> requestsByDoc) {
        Map<Id, Set<Id>> docsByRequest = new Map<Id, Set<Id>>();
        for (Id docId : requestsByDoc.keySet()) {
            for (Id requestId : requestsByDoc.get(docId)) {
                if (requestsBeingDeleted.contains(requestId)) {
                    continue;
                }
                addTo(docsByRequest, requestId, docId);
            }
        }
        if (docsByRequest.isEmpty()) {
            return new Set<Id>();
        }

        Set<Id> guarded = new Set<Id>();
        for (ApplicationItem__c appl : [
            SELECT Id, Request_Type__c, Leave_Days__c, Status__c
            FROM ApplicationItem__c
            WHERE Id IN :docsByRequest.keySet() AND Status__c IN :LOCKED_STATUSES
        ]) {
            if (requiresDocument(appl)) {
                guarded.add(appl.Id);
            }
        }
        if (guarded.isEmpty()) {
            return guarded;
        }

        Map<Id, Integer> held = documentCountsFor(guarded);
        Set<Id> stripped = new Set<Id>();
        for (Id requestId : guarded) {
            Integer remaining = zeroIfNull(held.get(requestId)) - docsByRequest.get(requestId).size();
            if (remaining <= 0) {
                stripped.add(requestId);
            }
        }
        return stripped;
    }

    /** Leave requests each of these documents is attached to, and nothing else. */
    private static Map<Id, Set<Id>> requestsLinkedTo(Set<Id> docIds) {
        Map<Id, Set<Id>> requestsByDoc = new Map<Id, Set<Id>>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId, LinkedEntityId
            FROM ContentDocumentLink
            WHERE ContentDocumentId IN :docIds
        ]) {
            if (isLeaveRequestLink(link.LinkedEntityId)) {
                addTo(requestsByDoc, link.ContentDocumentId, link.LinkedEntityId);
            }
        }
        return requestsByDoc;
    }

    private static Boolean isLeaveRequestLink(Id linkedEntityId) {
        return linkedEntityId != null
            && linkedEntityId.getSObjectType() == ApplicationItem__c.SObjectType;
    }

    private static Boolean touchesAny(Set<Id> candidates, Set<Id> stripped) {
        if (candidates == null || stripped.isEmpty()) {
            return false;
        }
        for (Id candidate : candidates) {
            if (stripped.contains(candidate)) {
                return true;
            }
        }
        return false;
    }

    private static void addTo(Map<Id, Set<Id>> target, Id key, Id value) {
        if (!target.containsKey(key)) {
            target.put(key, new Set<Id>());
        }
        target.get(key).add(value);
    }

    private static String removalMessage() {
        return 'This document is the supporting evidence for a leave request that has '
            + 'already been submitted, so it cannot be removed. Upload a replacement first '
            + 'and then remove this one, or use Upload New Version to correct it in place.';
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }

    private static Integer zeroIfNull(Integer value) {
        return value == null ? 0 : value;
    }
}
