@isTest
public class FlowApprovalActionTest {
    @isTest
    static void testApproveItems() {
        User user = [SELECT Id,Name,ProfileId ,Start_Date__c FROM User WHERE Profile.Name = 'EngineerGroupMember' AND isActive = true AND Start_Date__c != null ORDER BY LastLoginDate DESC][0];
        system.debug(user);
        // Step 1: Create a test record (use an object that has an approval process set up)
        List<ApplicationItem__c> leaveRequestList = new List<ApplicationItem__c>();
        // All day request
        leaveRequestList.add(new ApplicationItem__c(
                            Request_Type__c = 'Annual leave',
                            Period_Leave__c = 'All day',
                            Term_From__c = system.today(),
                            Remark__c = 'Test All day',
                            Status__c = 'Draft',
                            OwnerId = user.Id
                        ));
        insert leaveRequestList;

        // Step 2: Submit for Approval
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(leaveRequestList[0].Id);
        req.setSubmitterId(user.Id);
        req.setComments('Submitting for approval');
        Approval.ProcessResult result = Approval.process(req);
        System.assert(result.isSuccess(), 'Approval submission failed');

        // Step 3: Get Workitem ID
        List<Id> workItemIds = new List<Id>();
        for (ProcessInstanceWorkitem wi : [
            SELECT Id, ProcessInstance.TargetObjectId
            FROM ProcessInstanceWorkitem
            WHERE ProcessInstance.TargetObjectId = :leaveRequestList[0].Id
            LIMIT 1
        ]) {
            workItemIds.add(wi.Id);
        }

        // Step 4: Invoke the method
        Test.startTest();
        List<List<Id>> input = new List<List<Id>>{ workItemIds };
        List<String> resultMessages = FlowApprovalAction.approveItems(input);
        Test.stopTest();

        // Step 5: Assert result
        System.debug('Result: ' + resultMessages);
        System.assert(resultMessages.size() > 0, 'Result should not be empty');
        System.assert(resultMessages[0].contains('Success'), 'Approval should succeed');
    }
}