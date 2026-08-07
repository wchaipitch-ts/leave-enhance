@isTest
public class createLeaveRecordQueueableTest {

    @isTest
    static void testQueueableExecution() {
         User user = new User(
                    ProfileId = [SELECT Id FROM Profile WHERE Name = 'EngineerGroupMember'].Id,
                    LastName = 'last',
                    Email = 'testuser@terrasky.co.th',
                    Username = 'testuser@terrasky.co.th' + System.currentTimeMillis(),
                    CompanyName = 'TEST',
                    Title = 'title',
                    Alias = 'alias',
                    TimeZoneSidKey = 'Asia/Bangkok',
                    EmailEncodingKey = 'UTF-8',
                    LanguageLocaleKey = 'th',
                    LocaleSidKey = 'th'
                );
        insert user;
        // All day request
        ApplicationItem__c leaveRequestList = new ApplicationItem__c();
    
        leaveRequestList.Request_Type__c = 'Annual leave';
        leaveRequestList.Period_Leave__c = 'All day';
        leaveRequestList.Term_From__c = system.today();
        leaveRequestList.Remark__c = 'Test All day';
        leaveRequestList.Status__c = 'Pending';
        leaveRequestList.OwnerId = user.Id;
        insert leaveRequestList;
        // Enqueue the job
        Test.startTest();
            System.enqueueJob(new createLeaveRecordQueueable(leaveRequestList));
        Test.stopTest();

    }
}