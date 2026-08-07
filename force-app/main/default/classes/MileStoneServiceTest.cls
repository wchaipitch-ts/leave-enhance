/**
 * This class contains unit tests for validating the behavior of Apex classes
 * and triggers.
 *
 * Unit tests are class methods that verify whether a particular piece
 * of code is working properly. Unit test methods take no arguments,
 * commit no data to the database, and are flagged with the testMethod
 * keyword in the method definition.
 *
 * All test methods in an org are executed whenever Apex code is deployed
 * to a production org to confirm correctness, ensure code
 * coverage, and prevent regressions. All Apex classes are
 * required to have at least 75% code coverage in order to be deployed
 * to a production org. In addition, all triggers must have some code coverage.
 * 
 * The @isTest class annotation indicates this class only contains test
 * methods. Classes defined with the @isTest annotation do not count against
 * the org size limit for all Apex scripts.
 *
 * See the Apex Language Reference for more information about Testing and Code Coverage.
 */
@isTest
private class MileStoneServiceTest {
    
    @isTest static void testHandleNewRecord() {
        // Create Business Hours record (normally there will be a default one in Salesforce)
        BusinessHours bh = [SELECT Id FROM BusinessHours WHERE IsDefault = TRUE LIMIT 1];
        
        // Create mock Entitlement and Milestone record WITHOUT setting Name
        Entitlement_and_Milestone__c entitlement = new Entitlement_and_Milestone__c(
            Case_Priority__c = 'Critical',
            Case_Type__c = 'System Errors/System Down',
            Products__c = 'Salesforce'
        );
        insert entitlement;
        
        // Create Entitlement Details
        List<Entitlement_and_Milestone_Detail__c> details = new List<Entitlement_and_Milestone_Detail__c>{
            new Entitlement_and_Milestone_Detail__c(
                Entitlement_and_Milestone__c = entitlement.Id,
                Milestone__c = 'Case Response',
                Max_Duration_Hrs__c = 2
            ),
            new Entitlement_and_Milestone_Detail__c(
                Entitlement_and_Milestone__c = entitlement.Id,
                Milestone__c = 'Wait for Customer Response',
                Max_Duration_Hrs__c = 4
            ),
            new Entitlement_and_Milestone_Detail__c(
                Entitlement_and_Milestone__c = entitlement.Id,
                Milestone__c = 'Case Resolution',
                Max_Duration_Hrs__c = 6
            ),
            new Entitlement_and_Milestone_Detail__c(
                Entitlement_and_Milestone__c = entitlement.Id,
                Milestone__c = 'Case Escalation',
                Max_Duration_Hrs__c = 8
            ),
            new Entitlement_and_Milestone_Detail__c(
                Entitlement_and_Milestone__c = entitlement.Id,
                Milestone__c = 'Customer Feedback',
                Max_Duration_Hrs__c = 10
            )
        };
        insert details;

        // Create mock Case record
        Case caseRecord = new Case(
            Priority = 'Critical',
            Type = 'System Errors/System Down',
            Related_Product__c = 'Salesforce',
            Status = 'Open'
        );
        insert caseRecord;

        // Call the method with the Case Id
        Test.startTest();
        MileStoneService.handleNewRecord(new List<Id>{ caseRecord.Id });
        Test.stopTest();

        // Reload Case to validate updates
        Case updatedCase = [SELECT Max_Waiting_Time__c, Max_Case_Response_Time__c, Max_Case_Resolution_Time__c, 
                                   Max_Case_Escalation_Time__c, Max_Client_Feedback_Time__c, 
                                   Entitlement_and_Milestone__c 
                            FROM Case WHERE Id = :caseRecord.Id];

        // Assertions
        System.assertNotEquals(null, updatedCase.Max_Case_Response_Time__c, 'Max_Case_Response_Time__c should be set');
        System.assertNotEquals(null, updatedCase.Max_Waiting_Time__c, 'Max_Waiting_Time__c should be set');
        System.assertNotEquals(null, updatedCase.Max_Case_Resolution_Time__c, 'Max_Case_Resolution_Time__c should be set');
        System.assertNotEquals(null, updatedCase.Max_Case_Escalation_Time__c, 'Max_Case_Escalation_Time__c should be set');
        System.assertNotEquals(null, updatedCase.Max_Client_Feedback_Time__c, 'Max_Client_Feedback_Time__c should be set');
        System.assertEquals(entitlement.Id, updatedCase.Entitlement_and_Milestone__c, 'Entitlement should be linked');
    }

    @isTest static void testMultipleCasesAndScenarios() {
        // Create Entitlement & Milestone for Standard Priority
        Entitlement_and_Milestone__c entitlementStandard = new Entitlement_and_Milestone__c(
            Case_Priority__c = 'Standard',
            Case_Type__c = 'Inquiry',
            Products__c = 'Salesforce'
        );
        insert entitlementStandard;
        
        // Create Milestone Details for Standard
        insert new List<Entitlement_and_Milestone_Detail__c>{
            new Entitlement_and_Milestone_Detail__c(
                Entitlement_and_Milestone__c = entitlementStandard.Id,
                Milestone__c = 'Case Response',
                Max_Duration_Hrs__c = 3
            ),
            new Entitlement_and_Milestone_Detail__c(
                Entitlement_and_Milestone__c = entitlementStandard.Id,
                Milestone__c = 'Wait for Customer Response',
                Max_Duration_Hrs__c = 5
            ),
            new Entitlement_and_Milestone_Detail__c(
                Entitlement_and_Milestone__c = entitlementStandard.Id,
                Milestone__c = 'Case Resolution',
                Max_Duration_Hrs__c = 5
            ),
            new Entitlement_and_Milestone_Detail__c(
                Entitlement_and_Milestone__c = entitlementStandard.Id,
                Milestone__c = 'Case Escalation',
                Max_Duration_Hrs__c = 5
            ),
            new Entitlement_and_Milestone_Detail__c(
                Entitlement_and_Milestone__c = entitlementStandard.Id,
                Milestone__c = 'Customer Feedback',
                Max_Duration_Hrs__c = 5
            )
            
        };
    
        // Create a Case with "Standard" priority
        Case caseStandard = new Case(
            Priority = 'Standard',
            Type = 'Inquiry',
            Related_Product__c = 'Salesforce',
            Status = 'Wait for Customer\'s Info'
        );
        insert caseStandard;
    
        // Create a Case that won’t match any entitlement (negative scenario)
        Case caseNoEntitlement = new Case(
            Priority = 'Low',
            Type = 'Inquiry',
            Related_Product__c = 'Salesforce',
            Status = 'Open'
        );
        insert caseNoEntitlement;
    
        Test.startTest();
        // Bulk test with multiple cases
        MileStoneService.handleNewRecord(new List<Id>{ caseStandard.Id, caseNoEntitlement.Id });
        Test.stopTest();
    
        // Validate Standard Case was updated
        Case updatedStandard = [SELECT Max_Waiting_Time__c, Max_Case_Response_Time__c, Max_Case_Resolution_Time__c, 
                                       Entitlement_and_Milestone__c 
                                FROM Case WHERE Id = :caseStandard.Id];
    
        System.assertNotEquals(null, updatedStandard.Max_Case_Response_Time__c, 'Standard case response time should be set');
        System.assertNotEquals(null, updatedStandard.Max_Waiting_Time__c, 'Standard waiting time should be set');
        System.assertEquals(entitlementStandard.Id, updatedStandard.Entitlement_and_Milestone__c, 'Standard case entitlement should be linked');
    
        // Validate Case with no matching entitlement was not updated
        Case updatedNoEntitlement = [SELECT Max_Case_Response_Time__c FROM Case WHERE Id = :caseNoEntitlement.Id];
        System.assertEquals(null, updatedNoEntitlement.Max_Case_Response_Time__c, 'No entitlement, so no milestone dates');
    }
    
    @isTest static void testMissingCaseEscalationAndCustomerFeedback() {
        // Prepare Entitlement & Milestone with missing 'Case Escalation' and 'Customer Feedback'
        Entitlement_and_Milestone__c entitlement = new Entitlement_and_Milestone__c(
            Case_Priority__c = 'Critical',
            Case_Type__c = 'System Errors/System Down',
            Products__c = 'Salesforce'
        );
        insert entitlement;
    
        // Only insert partial milestone details (leave out 'Case Escalation' and 'Customer Feedback')
        insert new List<Entitlement_and_Milestone_Detail__c>{
            new Entitlement_and_Milestone_Detail__c(
                Entitlement_and_Milestone__c = entitlement.Id,
                Milestone__c = 'Case Response',
                Max_Duration_Hrs__c = 2
            ),
            new Entitlement_and_Milestone_Detail__c(
                Entitlement_and_Milestone__c = entitlement.Id,
                Milestone__c = 'Wait for Customer Response',
                Max_Duration_Hrs__c = 4
            ),
            new Entitlement_and_Milestone_Detail__c(
                Entitlement_and_Milestone__c = entitlement.Id,
                Milestone__c = 'Case Resolution',
                Max_Duration_Hrs__c = 6
            )
        };
    
        // Create Case
        Case caseRecord = new Case(
            Priority = 'Critical',
            Type = 'System Errors/System Down',
            Related_Product__c = 'Salesforce',
            Status = 'Open'
        );
        insert caseRecord;
    
        Test.startTest();
        MileStoneService.handleNewRecord(new List<Id>{ caseRecord.Id });
        Test.stopTest();
    
        // Reload Case
        Case updatedCase = [SELECT Max_Case_Response_Time__c, Max_Waiting_Time__c, Max_Case_Resolution_Time__c, 
                                    Max_Case_Escalation_Time__c, Max_Client_Feedback_Time__c 
                            FROM Case WHERE Id = :caseRecord.Id];
    
        // Now test that fallback was used (escalation time = resolution time and feedback time = escalation time)
        System.assertEquals(updatedCase.Max_Case_Resolution_Time__c, updatedCase.Max_Case_Escalation_Time__c, 
            'Case Escalation time should fallback to Case Resolution time');
        System.assertEquals(updatedCase.Max_Case_Escalation_Time__c, updatedCase.Max_Client_Feedback_Time__c, 
            'Customer Feedback time should fallback to Case Escalation time');
    }
    


}