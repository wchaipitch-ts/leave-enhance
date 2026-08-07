public without sharing class ContentVersionLinkHandler {
    /**
     * Minimal, Qiita-style linker:
     * For each inserted ContentVersion, if Guest_Record_fileupload__c has a value,
     * link its ContentDocument to that record Id (Case Id in our use case).
     * No extra validation or Case query; relies on the LWC providing a valid Id.
     */
    public static void linkToCase(List<ContentVersion> newList) {
        if (newList == null || newList.isEmpty()) return;

        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (ContentVersion cv : newList) {
            if (cv == null || cv.ContentDocumentId == null) continue;
            Object raw = cv.get('Guest_Record_fileupload__c');
            String linkedId = raw == null ? null : String.valueOf(raw);
            if (String.isBlank(linkedId)) continue;

            links.add(new ContentDocumentLink(
                ContentDocumentId = cv.ContentDocumentId,
                LinkedEntityId    = linkedId,
                Visibility        = 'AllUsers',
                ShareType         = 'V'
            ));
        }

        if (!links.isEmpty()) {
            // Partial insert so one bad link does not roll back uploads
            Database.SaveResult[] results = Database.insert(links, false);

            // Aggregate errors by target Case Id (LinkedEntityId)
            Map<String, List<String>> caseIdToErrors = new Map<String, List<String>>();
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    String targetId = String.valueOf(links[i].LinkedEntityId);
                    if (!caseIdToErrors.containsKey(targetId)) {
                        caseIdToErrors.put(targetId, new List<String>());
                    }
                    for (Database.Error e : results[i].getErrors()) {
                        caseIdToErrors.get(targetId)
                            .add('docId=' + links[i].ContentDocumentId + ' error=' + e.getMessage());
                    }
                }
            }

            // Invoke an autolaunched Flow to notify (e.g., Slack) per Case
            if (!caseIdToErrors.isEmpty()) {
                for (String cid : caseIdToErrors.keySet()) {
                    try {
                        Map<String, Object> inputs = new Map<String, Object>();
                        inputs.put('CaseId', cid);
                        // Flow expects a single String variable 'Errors'
                        String errorText = String.join(caseIdToErrors.get(cid), '\n');
                        inputs.put('Errors', errorText);
                        // Dynamic interview with your flow API name
                        Flow.Interview interview = Flow.Interview.createInterview('Notify_Slack_FileLink_Error', inputs);
                        if (interview != null) {
                            interview.start();
                        }
                    } catch (Exception ex) {
                        // Swallow to avoid impacting transaction
                        System.debug('Notify flow failed for Case ' + cid + ': ' + ex.getMessage());
                    }
                }
            }
        }
    }
}