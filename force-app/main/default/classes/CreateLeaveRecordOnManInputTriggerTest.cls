@isTest
public class CreateLeaveRecordOnManInputTriggerTest {
    @isTest
    static void testCreateLeaveRecord() {
        // Create test data
        Date startDate = System.today().toStartOfMonth();
        Date endDate = startDate.addMonths(1).addDays(-1);
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

        Project__c testProject = new Project__c(
            Project_Name__c = 'Leave FY25'
        );
        insert testProject;

        ProjectAssign__c testProjectAssign = new ProjectAssign__c(
            Assignee__c = user.Id,
            Project_No__c = testProject.Id,
            Start_Date__c = startDate,
            Due_Date__c = endDate
          //  Start_Date__c = 2024-08-01,
          //  Due_Date__c = 024-08-31
     	
        );
        system.debug('Debuggggg:'+ testProjectAssign);
        insert testProjectAssign;

        ApplicationItem__c testApplicationItem = new ApplicationItem__c(
            Status__c = 'Pending',
            OwnerId = user.Id,
            Term_From__c = startDate,
            Period_Leave__c = 'AM leave',
            Request_Type__c = 'Sick Leave',
            Remark__c = 'Test Remark'
        );
        insert testApplicationItem;

        // Inserted as Pending so the after-insert trigger added by  does not
        // also process it. Flipped in memory only, to exercise the logic class alone.
        testApplicationItem.Status__c = 'Approved';

        // Create an instance of the logic class
        CreateLeaveRecordOnManInputTriggerLogic logic = new CreateLeaveRecordOnManInputTriggerLogic();

        // Call the method to be tested
        Test.startTest();
        logic.createLeaveRecord(testApplicationItem);
        Test.stopTest();

        // Verify the results
        List<Man_hour__c> manHourRecords = [SELECT Id FROM Man_hour__c];
        //System.assertEquals(1, manHourRecords.size(), 'Man Hour record should have been created');
        Assert.areEqual(1, manHourRecords.size(), 'Man Hour record should have been created'); // Succeeds
    }

    @isTest
    static void testCreateLeaveRecordWithOutProject(){
        //create Test Data
        Date startDate = System.today().toStartOfMonth();
        Date endDate = startDate.addMonths(1).addDays(-1);
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

        ApplicationItem__c testApplicationItem = new ApplicationItem__c(
            Status__c = 'Pending',
            OwnerId = user.Id,
            Term_From__c = startDate,
            Period_Leave__c = 'AM leave',
            Request_Type__c = 'Sick Leave',
            Remark__c = 'Test Remark'
        );
        insert testApplicationItem;

        // Inserted as Pending so the after-insert trigger added by  does not
        // also process it. Flipped in memory only, to exercise the logic class alone.
        testApplicationItem.Status__c = 'Approved';

        // Create an instance of the logic class
        CreateLeaveRecordOnManInputTriggerLogic logic = new CreateLeaveRecordOnManInputTriggerLogic();

        // Call the method to be tested
        Test.startTest();
        logic.createLeaveRecord(testApplicationItem);
        Test.stopTest();

        // Verify the results
        List<Man_hour__c> manHourRecords = [SELECT Id FROM Man_hour__c];
        System.assertEquals(1, manHourRecords.size(), 'Man Hour record should have been created');
    }

    @isTest
    static void testCreateLeaveRecordWithOutProjectAssign(){
         //create Test Data
         Date startDate = System.today().toStartOfMonth();
         Date endDate = startDate.addMonths(1).addDays(-1);
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
 
        Project__c testProject = new Project__c(
            Project_Name__c = 'Leave '+ DateTime.now().format('yy'));

        insert testProject;

        ApplicationItem__c testApplicationItem = new ApplicationItem__c(
            Status__c = 'Pending',
            OwnerId = user.Id,
            Term_From__c = startDate,
            Period_Leave__c = 'AM leave',
            Request_Type__c = 'Sick Leave',
            Remark__c = 'Test Remark'
        );
        insert testApplicationItem;

        // Inserted as Pending so the after-insert trigger added by  does not
        // also process it. Flipped in memory only, to exercise the logic class alone.
        testApplicationItem.Status__c = 'Approved';

                // Create an instance of the logic class
                CreateLeaveRecordOnManInputTriggerLogic logic = new CreateLeaveRecordOnManInputTriggerLogic();

                // Call the method to be tested
                Test.startTest();
                logic.createLeaveRecord(testApplicationItem);
                Test.stopTest();
        
                // Verify the results
                List<Man_hour__c> manHourRecords = [SELECT Id FROM Man_hour__c];
                System.assertEquals(1, manHourRecords.size(), 'Man Hour record should have been created');
    }
   @isTest
    static void testCreateLeaveRecordWithOutProject2(){
        //create Test Data
        Date startDate = System.today().toStartOfMonth();
        Date endDate = startDate.addMonths(1).addDays(-1);
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
        Project__c testProject = new Project__c(
            Project_Name__c = 'Leave FY25'
        );
        insert testProject;
        ApplicationItem__c testApplicationItem = new ApplicationItem__c(
            Status__c = 'Pending',
            OwnerId = user.Id,
            Term_From__c = startDate,
            Period_Leave__c = 'AM leave',
            Request_Type__c = 'Sick Leave',
            Remark__c = 'Test Remark'
        );
        insert testApplicationItem;

        // Inserted as Pending so the after-insert trigger added by  does not
        // also process it. Flipped in memory only, to exercise the logic class alone.
        testApplicationItem.Status__c = 'Approved';
        // Create an instance of the logic class
        CreateLeaveRecordOnManInputTriggerLogic logic = new CreateLeaveRecordOnManInputTriggerLogic();
        // Call the method to be tested
        Test.startTest();
        logic.createLeaveRecord(testApplicationItem);
        Test.stopTest();
        // Verify the results
        List<Man_hour__c> manHourRecords = [SELECT Id FROM Man_hour__c];
        System.assertEquals(1, manHourRecords.size(), 'Man Hour record should have been created');
    }
}