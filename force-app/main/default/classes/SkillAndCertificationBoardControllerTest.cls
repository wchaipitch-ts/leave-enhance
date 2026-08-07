@isTest
public with sharing class SkillAndCertificationBoardControllerTest {
    @isTest
    static void testGetUserAvatarSuccessTest() {
        Profile profile = [SELECT Id FROM Profile WHERE Name='EngineerGroupMember']; 
        User user = new User(
            Alias = 'engineer',
            Email = 'engineeruser@test.com.dev1', 
            EmailEncodingKey = 'UTF-8',
            LastName = 'Engineer',
            LanguageLocaleKey = 'en_US', 
            LocaleSidKey = 'ja_JP',
            ProfileId = profile.Id, 
            TimeZoneSidKey = 'Asia/Bangkok',
            UserName = 'engineeruser@test.com.dev1'
        );
        insert user;

        Test.startTest();
        User actual = SkillAndCertificationBoardController.userAvatar(String.valueOf(user.Id));
        Test.stopTest();

        System.assertNotEquals(null, actual.MediumPhotoUrl);
    }

    @isTest
    static void testGetUserAvatarFailTest() {
        Test.startTest();
        User actual = SkillAndCertificationBoardController.userAvatar('DEF23r0#@$%321');
        Test.stopTest();

        System.assertEquals(null, actual);
    }

    @isTest
    static void getVertificationListSuccessTest() {
        Profile profile = [SELECT Id FROM Profile WHERE Name='EngineerGroupMember']; 
        User user = new User(
            Alias = 'engineer',
            Email = 'engineeruser@test.com.dev1', 
            EmailEncodingKey = 'UTF-8',
            LastName = 'Engineer',
            LanguageLocaleKey = 'en_US', 
            LocaleSidKey = 'ja_JP',
            ProfileId = profile.Id, 
            TimeZoneSidKey = 'Asia/Bangkok',
            UserName = 'engineeruser@test.com.dev1'
        );
        insert user;

        // Prepare Skill&Certifications record
        Skill_Certification__c certification1 = new Skill_Certification__c(
            Certification_Categories__c = 'Salesforce Administrator',
            Certification_Name__c = 'Administrator',
            OwnerId = user.Id,
            Scheduled_Examination_Date__c = Date.today(),
            Examination_Date__c = Date.today(),
            Status__c = 'Pass',
            Result__c = 'Yahoo'
        );
        insert certification1;

        // Prepare Skill&Certifications record
        Skill_Certification__c certification2 = new Skill_Certification__c(
            Certification_Categories__c = 'Salesforce Administrator',
            Certification_Name__c = 'Advanced Administrator',
            OwnerId = user.Id,
            Scheduled_Examination_Date__c = Date.today(),
            Examination_Date__c = Date.today(),
            Status__c = 'Pass',
            Result__c = 'Yahoooo'
        );
        insert certification2;

        Test.startTest();
        List<AggregateResult> actual = SkillAndCertificationBoardController.certificationList(user.Id);
        Test.stopTest();

        System.assertEquals(2, actual.size());
    }

    @isTest
    static void getVertificationListFailTest() {
        Test.startTest();
        List<AggregateResult> actual = SkillAndCertificationBoardController.certificationList(null);
        Test.stopTest();


        System.assertEquals(null, actual);
    }

    @isTest
    static void getAllCertificationTest() {
        Profile profile = [SELECT Id FROM Profile WHERE Name='EngineerGroupMember']; 
        User user1 = new User(
            Alias = 'enginer1',
            Email = 'engineeruser1@test.com.dev1', 
            EmailEncodingKey = 'UTF-8',
            LastName = 'Engineer1',
            LanguageLocaleKey = 'en_US', 
            LocaleSidKey = 'ja_JP',
            ProfileId = profile.Id, 
            TimeZoneSidKey = 'Asia/Bangkok',
            UserName = 'engineeruser1@test.com.dev1'
        );
        insert user1;

        User user2 = new User(
            Alias = 'enginer2',
            Email = 'engineeruser2@test.com.dev1', 
            EmailEncodingKey = 'UTF-8',
            LastName = 'Engineer2',
            LanguageLocaleKey = 'en_US', 
            LocaleSidKey = 'ja_JP',
            ProfileId = profile.Id, 
            TimeZoneSidKey = 'Asia/Bangkok',
            UserName = 'engineeruser2@test.com.dev1'
        );
        insert user2;

        // Prepare Skill&Certifications record
        Skill_Certification__c certification1 = new Skill_Certification__c(
            Certification_Categories__c = 'Salesforce Administrator',
            Certification_Name__c = 'Administrator',
            OwnerId = user1.Id,
            Scheduled_Examination_Date__c = Date.today(),
            Examination_Date__c = Date.today(),
            Status__c = 'Pass',
            Result__c = 'Yahoo'
        );
        insert certification1;

        // Prepare Skill&Certifications record
        Skill_Certification__c certification2 = new Skill_Certification__c(
            Certification_Categories__c = 'Salesforce Administrator',
            Certification_Name__c = 'Advanced Administrator',
            OwnerId = user2.Id,
            Scheduled_Examination_Date__c = Date.today(),
            Examination_Date__c = Date.today(),
            Status__c = 'Pass',
            Result__c = 'Yahoooo'
        );
        insert certification2;

        Test.startTest();
        String actual = SkillAndCertificationBoardController.getAllCertification();
        Test.stopTest();

        System.assertEquals(true, actual.contains('Engineer1'));
        System.assertEquals(true, actual.contains('Engineer2'));
    }

    @isTest
    static void getCertificationChartTest() {
        Profile profile = [SELECT Id FROM Profile WHERE Name='EngineerGroupMember']; 
        User user1 = new User(
            Alias = 'enginer1',
            Email = 'engineeruser1@test.com.dev1', 
            EmailEncodingKey = 'UTF-8',
            LastName = 'Engineer1',
            LanguageLocaleKey = 'en_US', 
            LocaleSidKey = 'ja_JP',
            ProfileId = profile.Id, 
            TimeZoneSidKey = 'Asia/Bangkok',
            UserName = 'engineeruser1@test.com.dev1'
        );
        insert user1;

        User user2 = new User(
            Alias = 'enginer2',
            Email = 'engineeruser2@test.com.dev1', 
            EmailEncodingKey = 'UTF-8',
            LastName = 'Engineer2',
            LanguageLocaleKey = 'en_US', 
            LocaleSidKey = 'ja_JP',
            ProfileId = profile.Id, 
            TimeZoneSidKey = 'Asia/Bangkok',
            UserName = 'engineeruser2@test.com.dev1'
        );
        insert user2;

        // Prepare Skill&Certifications record
        Skill_Certification__c certification1 = new Skill_Certification__c(
            Certification_Categories__c = 'Salesforce Administrator',
            Certification_Name__c = 'Administrator',
            OwnerId = user1.Id,
            Scheduled_Examination_Date__c = Date.today(),
            Examination_Date__c = Date.today(),
            Status__c = 'Pass',
            Result__c = 'Yahoo'
        );
        insert certification1;

        // Prepare Skill&Certifications record
        Skill_Certification__c certification2 = new Skill_Certification__c(
            Certification_Categories__c = 'Salesforce Administrator',
            Certification_Name__c = 'Advanced Administrator',
            OwnerId = user1.Id,
            Scheduled_Examination_Date__c = Date.today(),
            Examination_Date__c = Date.today(),
            Status__c = 'Pass',
            Result__c = 'Yahoooo'
        );
        insert certification2;

        // Prepare Skill&Certifications record
        Skill_Certification__c certification3 = new Skill_Certification__c(
            Certification_Categories__c = 'Salesforce Administrator',
            Certification_Name__c = 'Advanced Administrator',
            OwnerId = user2.Id,
            Scheduled_Examination_Date__c = Date.today(),
            Examination_Date__c = Date.today(),
            Status__c = 'Pass',
            Result__c = 'Yahoooo'
        );
        insert certification3;

        Test.startTest();
        String actual = SkillAndCertificationBoardController.certificationChart();
        Test.stopTest();

        System.assert(actual.contains('"topFiveName":["Advanced Administrator","Administrator"]'));
        System.assert(actual.contains('"topFiveAmount":[2,1]'));
        System.assert(actual.contains('maxCountCert":"2"'));
        System.assert(actual.contains('maxCertUser":"Engineer1"'));
        System.assert(actual.contains('"maxCertType":"Advanced Administrator"'));
        System.assert(actual.contains('"allCertPass":"3"'));
        System.assert(actual.contains('"allCertName":["Advanced Administrator","Administrator"]'));
        System.assert(actual.contains('"allCertAmount":[2,1]'));
    }

    // have exam is Applied recode
    @isTest
    private static void upcomingExamTest_01(){
        User user = [SELECT Id, Name FROM User WHERE Username = 'upcomingexam01@test.com.dev1'];
        Test.startTest();
        Skill_Certification__c cert = SkillAndCertificationBoardController.upcomingExam(user.Id);
        Test.stopTest();
        
        System.assertEquals('Administrator', cert.Certification_Name__c,'Certification Name should match Administrator');
        System.assertEquals(Date.today(), cert.Examination_Date__c,'Examination Date should match');
    }

    // not have exam is Applied recode
    @isTest
    private static void upcomingExamTest_02(){
        User user = [SELECT Id, Name FROM User WHERE Username = 'upcomingexam02@test.com.dev1'];
        Test.startTest();
        Skill_Certification__c cert = SkillAndCertificationBoardController.upcomingExam(user.Id);
        Test.stopTest(); 
        System.assertEquals(Null, cert,'cert should be null');  
    }

    @TestSetup
    private static void makeData(){
        Profile profile = [SELECT Id FROM Profile WHERE Name='EngineerGroupMember'];
        List<User> userList = new List<User>();
        userList.add(new User(
                        Alias = 'engineer',
                        Email = ' upcomingexam01@test.com.dev1', 
                        EmailEncodingKey = 'UTF-8',
                        LastName = 'Engineer',
                        LanguageLocaleKey = 'en_US', 
                        LocaleSidKey = 'ja_JP',
                        ProfileId = profile.Id, 
                        TimeZoneSidKey = 'Asia/Bangkok',
                        UserName = 'upcomingexam01@test.com.dev1'
                    ));
        userList.add(new User(
                        Alias = 'engineer',
                        Email = ' upcomingexam02@test.com.dev1', 
                        EmailEncodingKey = 'UTF-8',
                        LastName = 'Engineer',
                        LanguageLocaleKey = 'en_US', 
                        LocaleSidKey = 'ja_JP',
                        ProfileId = profile.Id, 
                        TimeZoneSidKey = 'Asia/Bangkok',
                        UserName = 'upcomingexam02@test.com.dev1'
                    ));
        insert userList;

        // Prepare Skill&Certifications record
        Skill_Certification__c certification1 = new Skill_Certification__c(
            Certification_Categories__c = 'Salesforce Administrator',
            Certification_Name__c = 'Administrator',
            OwnerId = userList[0].Id,
            Scheduled_Examination_Date__c = Date.today(),
            Examination_Date__c = Date.today(),
            Status__c = 'Applied'
        );
        insert certification1;
        
    }
}