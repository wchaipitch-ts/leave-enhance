public with sharing class MileStoneService {
    @InvocableMethod(label='MileStoneService' description='Processes a newly created record')
    public static void handleNewRecord(List<Id> recordIds) {
        // Validate input
        if (recordIds == null || recordIds.isEmpty() || recordIds[0] == null) {
            System.debug('No valid record ID provided.');
            return;
        }

        // Fetch Business Hours
        BusinessHours bh;
        try {
            bh = [SELECT Id, TimeZoneSidKey FROM BusinessHours WHERE IsDefault = TRUE LIMIT 1];
        } catch (Exception e) {
            System.debug('Error fetching Business Hours: ' + e.getMessage());
            return;
        }

        // Fetch Case record
        Case caseRecord;
        try {
            caseRecord = [ 
                SELECT Id, CreatedDate, Priority, Type, Related_Product__c, Status, 
                       Max_Waiting_Time__c, Max_Case_Response_Time__c, Max_Case_Resolution_Time__c, 
                       Max_Case_Escalation_Time__c, Max_Client_Feedback_Time__c
                FROM Case 
                WHERE Id = :recordIds[0] 
                LIMIT 1
            ];
        } catch (Exception e) {
            System.debug('Error fetching Case record: ' + e.getMessage());
            return;
        }

        // if (caseRecord == null) {
        //     System.debug('No case found.');
        //     return;
        // }

        System.debug('Processing Case: ' + caseRecord.Id);

        // Fetch Entitlement Records
        String casePriority = (caseRecord.Priority == 'Critical') ? 'Critical' : 'Standard';

        List<Entitlement_and_Milestone__c> entitlements = [
            SELECT Id, Name, Case_Priority__c, Case_Type__c, Products__c 
            FROM Entitlement_and_Milestone__c
            WHERE Case_Priority__c = :casePriority
            AND Case_Type__c = :caseRecord.Type 
            AND Products__c = :caseRecord.Related_Product__c 
        ];

        if (entitlements.isEmpty()) {
            System.debug('No matching Entitlements found.');
            return;
        }

        System.debug('Total Entitlements Found: ' + entitlements.size());

        // Fetch Entitlement Details
        List<Id> entitlementIds = new List<Id>();
        for (Entitlement_and_Milestone__c ent : entitlements) {
            entitlementIds.add(ent.Id);
        }

        if (entitlementIds.isEmpty()) {
            System.debug('No entitlement IDs found.');
            return;
        }

        List<Entitlement_and_Milestone_Detail__c> entitlementsDetail = [
            SELECT Id, Name, Milestone__c, Max_Duration_Hrs__c
            FROM Entitlement_and_Milestone_Detail__c
            WHERE Entitlement_and_Milestone__c IN :entitlementIds
        ];

        if (entitlementsDetail.isEmpty()) {
            System.debug('No entitlement details found.');
            return;
        }

        System.debug('Total Entitlement Details Found: ' + entitlementsDetail.size());

        Map<String, Decimal> milestoneDurationMap = new Map<String, Decimal>();
        for (Entitlement_and_Milestone_Detail__c detail : entitlementsDetail) {
            if (detail.Milestone__c != null && detail.Max_Duration_Hrs__c != null) {
                milestoneDurationMap.put(detail.Milestone__c, detail.Max_Duration_Hrs__c);
            }
        }

        // Corrected BusinessHours.add with proper Long value for duration
        caseRecord.Max_Case_Response_Time__c = BusinessHours.add(bh.Id, caseRecord.CreatedDate, (milestoneDurationMap.get('Case Response') * 3600 * 1000).longValue());

        if(caseRecord.Status == 'Wait for Customer\'s Info') {
            caseRecord.Max_Waiting_Time__c = BusinessHours.add(bh.Id, caseRecord.Max_Case_Response_Time__c, (milestoneDurationMap.get('Wait for Customer Response') * 3600 * 1000).longValue());
        }
        else {
            caseRecord.Max_Waiting_Time__c = caseRecord.Max_Case_Response_Time__c;
        }
        
        caseRecord.Max_Case_Resolution_Time__c = BusinessHours.add(bh.Id, caseRecord.Max_Waiting_Time__c, (milestoneDurationMap.get('Case Resolution') * 3600 * 1000).longValue());


        if (milestoneDurationMap.get('Case Escalation') == Null) { 
            caseRecord.Max_Case_Escalation_Time__c = caseRecord.Max_Case_Resolution_Time__c ;
        } else  {
            caseRecord.Max_Case_Escalation_Time__c = BusinessHours.add(bh.Id, caseRecord.Max_Case_Resolution_Time__c, (milestoneDurationMap.get('Case Escalation') * 3600 * 1000).longValue());
        }
        // System.debug('Max_Client_Feedback_Time__c'+caseRecord.Max_Client_Feedback_Time__c);
        // System.debug('Max_Case_Escalation_Time__c'+caseRecord.Max_Case_Escalation_Time__c);

        if (milestoneDurationMap.get('Customer Feedback') == Null) { 
            caseRecord.Max_Client_Feedback_Time__c = caseRecord.Max_Case_Escalation_Time__c ;
        } else  {
            caseRecord.Max_Client_Feedback_Time__c = BusinessHours.add(bh.Id, caseRecord.Max_Case_Escalation_Time__c, (milestoneDurationMap.get('Customer Feedback') * 3600 * 1000).longValue());
            
        }


        caseRecord.Entitlement_and_Milestone__c = entitlements[0].Id;

        // Bulk-safe update
        try {
            update caseRecord;
            System.debug('Case record successfully updated.');
        } catch (Exception e) {
            System.debug('Error updating Case: ' + e.getMessage());
        }
    }
}