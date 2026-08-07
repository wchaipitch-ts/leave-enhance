@isTest
public with sharing class ManHoursInputControllerTest {

    @TestSetup
    static void prepareData(){

        // Prepare User data
        Profile profile = [SELECT Id FROM Profile WHERE Name='Standard User']; 
        User manager = new User(
            Alias = 'manager',
            Email='manageruser@test.com.dev1', 
            EmailEncodingKey='UTF-8',
            LastName='Testing Manager',
            LanguageLocaleKey='en_US', 
            LocaleSidKey='ja_JP',
            ProfileId = profile.Id, 
            TimeZoneSidKey='Asia/Bangkok',
            UserName='manageruser@test.com.dev1'
        );
        insert manager;
        User user = new User(
            Alias = 'standard',
            Email='standarduser1@test.com.dev1', 
            EmailEncodingKey='UTF-8',
            LastName='Testing',
            LanguageLocaleKey='en_US', 
            LocaleSidKey='ja_JP',
            ProfileId = profile.Id, 
            TimeZoneSidKey='Asia/Bangkok',
            UserName='standarduser1@test.com.dev1',
            Title='Test Title',
            Department='Test Department',
            ManagerId=manager.Id
        );
        insert user;

        // Prepare Project__c data
        Date startDate = Date.valueOf('2022-12-01');
        Date dueDate = Date.valueOf('2022-12-31');
        Project__c project = new Project__c(
            Project_Name__c='Test Project',
            Project_Status__c='Not Started',
            Project_Detail__c='Test Project',
            Start_Date__c=startDate,
            Due_Date__c=dueDate,
            Remark__c='Test Project'
        );
        insert project;

        // Prepare ProjectAssign__c data
        ProjectAssign__c projectAssign = new ProjectAssign__c(
            Project_No__c=project.Id,
            Assignee__c=user.Id,
            Start_Date__c=startDate,
            Due_Date__c=dueDate,
            Planning_Hours__c=1,
            Remark__c='Test ProjectAssign'
        );
        insert projectAssign;

        // Delete default Man_hour__c data
        List<Man_hour__c> manHours = [SELECT Id FROM Man_hour__c WHERE ProjectAssign_No__c=:projectAssign.Id];
        delete manHours;

        // Prepare Man_hour__c data
        Date performedDate1 = Date.valueOf('2022-12-01');
        Man_hour__c manHour = new Man_hour__c(
            ProjectAssign_No__c=projectAssign.Id,
            Work__c='Test ProjectAssign 01',
            Performed_Date__c=performedDate1,
            Performed_Hours__c=1,
            Remark__c='Test ProjectAssign'
        );
        insert manHour;
        Date performedDate2 = Date.valueOf('2022-12-02');
        Man_hour__c manHour2 = new Man_hour__c(
            ProjectAssign_No__c=projectAssign.Id,
            Work__c='Test ProjectAssign 02',
            Performed_Date__c=performedDate2,
            Performed_Hours__c=2,
            Remark__c='Test ProjectAssign'
        );
        insert manHour2;

    }

    @isTest
    static void getProjectListTest(){
        // Default parameter
        User user = [SELECT Id, UserName FROM User WHERE UserName LIKE 'standarduser1@test.com.dev1' LIMIT 1];
        Project__c project = [SELECT Id FROM Project__c WHERE Project_Name__c LIKE 'Test Project' LIMIT 1];
        ProjectAssign__c projectAssign = [SELECT Id, Name, Start_Date__c, Due_Date__c, OwnerId, Assignee__c FROM ProjectAssign__c WHERE Assignee__c=:user.Id LIMIT 1];

        // Testing
        Test.startTest();
        String testUserId = (String)user.Id;
        String testYear = '2022';
        String testMonth = '12';
        List<ProjectAssign__c> projectAssignList = ManHoursInputController.getProjectList(testUserId, testYear, testMonth);
        Test.stopTest();
        System.debug(projectAssignList);
        // Data Check
        System.assert(project.Id == projectAssignList.get(0).Project_No__c);
        System.assert(projectAssign.Start_Date__c == projectAssignList.get(0).Start_Date__c);
        System.assert(projectAssign.Due_Date__c == projectAssignList.get(0).Due_Date__c);

        System.assert(2 == projectAssignList.get(0).Man_hours__r.size());
        System.assert('Test ProjectAssign 01' == projectAssignList.get(0).Man_hours__r.get(0).Work__c);
        System.assert(Date.valueOf('2022-12-01') == projectAssignList.get(0).Man_hours__r.get(0).Performed_Date__c);
        System.assert(1 == projectAssignList.get(0).Man_hours__r.get(0).Performed_Hours__c);
        System.assert('Test ProjectAssign' == projectAssignList.get(0).Man_hours__r.get(0).Remark__c);

        System.assert('Test ProjectAssign 02' == projectAssignList.get(0).Man_hours__r.get(1).Work__c);
        System.assert(Date.valueOf('2022-12-02') == projectAssignList.get(0).Man_hours__r.get(1).Performed_Date__c);
        System.assert(2 == projectAssignList.get(0).Man_hours__r.get(1).Performed_Hours__c);
        System.assert('Test ProjectAssign' == projectAssignList.get(0).Man_hours__r.get(1).Remark__c);
    }

    @isTest
    static void getProjectListErrorTest(){
        // Testing
        Test.startTest();
        String testUserId = 'XXXXXXXXXXXXXXXXXX';
        String testYear = '2022';
        String testMonth = '12';
        List<ProjectAssign__c> projectAssignList = ManHoursInputController.getProjectList(testUserId, testYear, testMonth);
        Test.stopTest();

        // Data Check
        System.assert(0 == projectAssignList.size());
    }

    @isTest
    static void getManhourListTest(){
        // Default parameter
        User user = [SELECT Id, UserName FROM User WHERE UserName='standarduser1@test.com.dev1' LIMIT 1];
        Project__c project = [SELECT Id FROM Project__c WHERE Project_Name__c='Test Project' LIMIT 1];
        ProjectAssign__c testProjectAssign = [SELECT Id, Name, Start_Date__c, Due_Date__c, OwnerId, Assignee__c FROM ProjectAssign__c WHERE Assignee__c=:user.Id LIMIT 1];

        // Testing
        Test.startTest();
        String testProjectAssignId = (String)testProjectAssign.Id;
        String testDate = '2022-12-01';
        ProjectAssign__c projectAssign = ManHoursInputController.getManhourList(testProjectAssignId, testDate);
        Test.stopTest();

        // Data Check
        System.assert(1 == projectAssign.Man_hours__r.size());
        System.assert('Test ProjectAssign 01' == projectAssign.Man_hours__r.get(0).Work__c);
        System.assert(Date.valueOf('2022-12-01') == projectAssign.Man_hours__r.get(0).Performed_Date__c);
        System.assert(1 == projectAssign.Man_hours__r.get(0).Performed_Hours__c);
        System.assert('Test ProjectAssign' == projectAssign.Man_hours__r.get(0).Remark__c);
    }

    @isTest
    static void getManhourListErrorTest(){
        // Testing
        Test.startTest();
        String testProjectAssignId = 'XXXXXXXXXXXXXXXXXX';
        String testDate = '2022-12-01';
        ProjectAssign__c projectAssign = ManHoursInputController.getManhourList(testProjectAssignId, testDate);
        Test.stopTest();

        // Data Check
        System.assert(0 == projectAssign.Man_hours__r.size());
    }

    @isTest
    static void addManhourTest(){
        // Default parameter
        User user = [SELECT Id, UserName FROM User WHERE UserName='standarduser1@test.com.dev1' LIMIT 1];
        Project__c project = [SELECT Id FROM Project__c WHERE Project_Name__c='Test Project' LIMIT 1];
        ProjectAssign__c projectAssign = [SELECT Id, Name, Start_Date__c, Due_Date__c, OwnerId, Assignee__c FROM ProjectAssign__c WHERE Assignee__c=:user.Id LIMIT 1];

        // Testing
        Test.startTest();
        String testProjectAssignId = (String)projectAssign.Id;
        String testDate = '2022-12-03';
        List<Man_hour__c> manhourList = ManHoursInputController.addManhour(testProjectAssignId, testDate);
        Test.stopTest();

        // Data Check
        System.assert(1 == manhourList.size());
        System.assert(null == manhourList.get(0).Work__c);
        System.assert(Date.valueOf('2022-12-03') == manhourList.get(0).Performed_Date__c);
        System.assert(0 == manhourList.get(0).Performed_Hours__c);
        System.assert(null == manhourList.get(0).Remark__c);
    }

    // @isTest
    // static void addManhourErrorTest(){
    //     // Testing
    //     Test.startTest();
    //     String testProjectAssignId = 'XXXXXXXXXXXXXXXXXX';
    //     String testDate = '2022-12-03';
    //     List<Man_hour__c> manhourList = ManHoursInputController.addManhour(testProjectAssignId, testDate);
    //     Test.stopTest();

    //     // Data Check
    //     System.assert(0 == manhourList.size());
    // }

    @isTest
    static void editManhourTest(){
        // Default parameter
        User user = [SELECT Id, UserName FROM User WHERE UserName='standarduser1@test.com.dev1' LIMIT 1];
        Project__c project = [SELECT Id FROM Project__c WHERE Project_Name__c='Test Project' LIMIT 1];
        ProjectAssign__c projectAssign = [SELECT Id, Name, Start_Date__c, Due_Date__c, OwnerId, Assignee__c FROM ProjectAssign__c WHERE Assignee__c=:user.Id LIMIT 1];
        List<Man_hour__c> testManHourList = [SELECT Id,
                                            Name,
                                            Work__c,
                                            Performed_Date__c,
                                            Performed_Hours__c,
                                            Remark__c
                                        FROM Man_hour__c
                                        WHERE ProjectAssign_No__c =:projectAssign.Id AND Performed_Date__c =:Date.valueOf('2022-12-01')
                                        ORDER BY Performed_Date__c ASC];

        // Testing
        Test.startTest();
        for(Man_hour__c manHour :testManHourList) {
            manHour.Work__c = 'XXX-XXX';
            manHour.Remark__c = 'XXX-XXX';
            manHour.Performed_Hours__c = 5;
        }
        List<Man_hour__c> manhourList = ManHoursInputController.editManhour(testManHourList);
        Test.stopTest();

        // Data Check
        System.assert(1 == manhourList.size());
        System.assert('XXX-XXX' == manhourList.get(0).Work__c);
        System.assert(Date.valueOf('2022-12-01') == manhourList.get(0).Performed_Date__c);
        System.assert(5 == manhourList.get(0).Performed_Hours__c);
        System.assert('XXX-XXX' == manhourList.get(0).Remark__c); 
    }

    // @isTest
    // static void editManhourErrorTest(){
    //     // Default parameter
    //     Date performedDate = Date.valueOf('2022-12-01');
    //     Man_hour__c manHour = new Man_hour__c(
    //         Work__c='Test ProjectAssign 03',
    //         Performed_Date__c=performedDate,
    //         Performed_Hours__c=3,
    //         Remark__c='Test ProjectAssign'
    //     );
    //     List<Man_hour__c> testManHourList = new List<Man_hour__c>{manHour};

    //     // Testing
    //     Test.startTest();

    //     List<Man_hour__c> manhourList = ManHoursInputController.editManhour(testManHourList);
    //     Test.stopTest();

    //     // Data Check
    //     System.assert(0 == manhourList.size());
    // }

    @isTest
    static void deleteManhourTest(){ 
        // Default parameter
        User user = [SELECT Id, UserName FROM User WHERE UserName='standarduser1@test.com.dev1' LIMIT 1];
        Project__c project = [SELECT Id FROM Project__c WHERE Project_Name__c='Test Project' LIMIT 1];
        ProjectAssign__c projectAssign = [SELECT Id, Name, Start_Date__c, Due_Date__c, OwnerId, Assignee__c FROM ProjectAssign__c WHERE Assignee__c=:user.Id LIMIT 1];
        
        Date performedDate = Date.valueOf('2022-12-01');
        Man_hour__c manHour = new Man_hour__c(
            ProjectAssign_No__c=projectAssign.Id,
            Work__c='Test ProjectAssign 03',
            Performed_Date__c=performedDate,
            Performed_Hours__c=3,
            Remark__c='Test ProjectAssign'
        );
        insert manHour;
        List<Man_hour__c> testManHourList = [SELECT Id,
                                            Name,
                                            Work__c,
                                            Performed_Date__c,
                                            Performed_Hours__c,
                                            Remark__c
                                        FROM Man_hour__c
                                        WHERE ProjectAssign_No__c =:projectAssign.Id AND Work__c =:manHour.Work__c
                                        ORDER BY Performed_Date__c ASC];

        // Testing
        Test.startTest();
        List<Man_hour__c> manhourList = ManHoursInputController.deleteManhour(testManHourList);
        Test.stopTest();

        // Data Check
        System.assert(1 == manhourList.size());
        System.assert('Test ProjectAssign 01' == manhourList.get(0).Work__c);
        System.assert(Date.valueOf('2022-12-01') == manhourList.get(0).Performed_Date__c);
        System.assert(1 == manhourList.get(0).Performed_Hours__c);
        System.assert('Test ProjectAssign' == manhourList.get(0).Remark__c);
    }

    // @isTest
    // static void deleteManhourErrorTest(){
    //     // Default parameter
    //     Date performedDate = Date.valueOf('2022-12-01');
    //     Man_hour__c manHour = new Man_hour__c(
    //         Work__c='Test ProjectAssign 03',
    //         Performed_Date__c=performedDate,
    //         Performed_Hours__c=3,
    //         Remark__c='Test ProjectAssign'
    //     );
    //     List<Man_hour__c> testManHourList = new List<Man_hour__c>{manHour};

    //     // Testing
    //     Test.startTest();
    //     List<Man_hour__c> manhourList = ManHoursInputController.deleteManhour(testManHourList);
    //     Test.stopTest();

    //     // Data Check
    //     System.assert(0 == manhourList.size());
    // }

    @isTest
    static void getUserAvatarTest(){
        // Default parameter
        User testManager = [SELECT Id, UserName FROM User WHERE UserName='manageruser@test.com.dev1' LIMIT 1];
        User testUser = [SELECT Id, Name, Title, Department, Manager.Name, Manager.Id, MediumPhotoUrl FROM User WHERE UserName='standarduser1@test.com.dev1' LIMIT 1];


        // Testing
        Test.startTest();
        User user = ManHoursInputController.getUserAvatar(testUser.Id);
        Test.stopTest();

        // Data Check
        System.assert(testUser.Id == user.Id);
        System.assert(testUser.Name == user.Name);
        System.assert(testUser.Title == user.Title);
        System.assert(testUser.Department == user.Department);
        System.assert(testUser.Manager.Name == user.Manager.Name);
        System.assert(testUser.Manager.Id == user.Manager.Id);
    }

    @isTest
    static void getUserAvatarErrorTest(){

        // Testing
        Test.startTest();
        String testUserId = 'XXXXXXXXXXXXXXXXXX';
        User user = ManHoursInputController.getUserAvatar(testUserId);
        Test.stopTest();

        // Data Check
        System.assert(null == user);
    }
}