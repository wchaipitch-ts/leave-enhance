public without sharing class LeaveDocumentPolicy {

    private static final String PERMISSION = 'Bypass_Leave_Request_Rules';
    private static final Set<String> LOCKED_STATUSES = new Set<String>{ 'Pending', 'Approved' };
    @TestVisible private static Boolean bypassOverride;
    @TestVisible private static Set<Id> requestsBeingDeleted = new Set<Id>();

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