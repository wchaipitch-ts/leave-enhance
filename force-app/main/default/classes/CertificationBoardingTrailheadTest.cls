@isTest
public with sharing class CertificationBoardingTrailheadTest {
    @isTest
    static void searchBadgesAndTrailmixTest_trailmixes_match_case() {
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

        // Prepare trailmix record
        trailheadapp__Trailmix__c trailmix1 = new trailheadapp__Trailmix__c(
            Name = 'Architect Journey: Identity and Access Management',
            trailheadapp__URL__c = 'https://test.url',
            trailheadapp__Created_By_Profile__c = 'https://test.url',
            trailheadapp__Slug__c = 'architect-identity-and-access-management',
            trailheadapp__External_Id__c = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
            OwnerId = user.Id
        );
        insert trailmix1;

        // Prepare trailmix record
        trailheadapp__Trailmix__c trailmix2 = new trailheadapp__Trailmix__c(
            Name = 'Architect Journey: Mobile Solutions Architecture',
            trailheadapp__URL__c = 'https://test.url',
            trailheadapp__Created_By_Profile__c = 'https://test.url',
            trailheadapp__Slug__c = 'architect-identity-and-access-management',
            trailheadapp__External_Id__c = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
            OwnerId = user.Id
        );
        insert trailmix2;

        Id [] fixedSearchResults = new Id[2];
        fixedSearchResults[0] = trailmix1.Id;
        fixedSearchResults[1] = trailmix2.Id;

        String searchText = 'Journey';

        Test.startTest();
        Test.setFixedSearchResults(fixedSearchResults);
        CertificationBoardingTrailhead.BadgeAndTrailInformation actual = CertificationBoardingTrailhead.searchBadgesAndTrail(searchText);
        Test.stopTest();

        System.assertEquals(0, actual.badges.size());
        System.assertEquals(2, actual.trailmixes.size());      
    }

    @isTest
    static void searchBadgesAndTrailmixTest_badges_match_case() {
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

        // Prepare Badges record
        trailheadapp__Badge__c badge1 = new trailheadapp__Badge__c(
            Name = 'Quick Start: Visualforce',
            trailheadapp__Description__c = 'Build your first Visualforce page.',
            trailheadapp__Namespace__c = 'learn',
            trailheadapp__URL__c = 'https://test.url',
            trailheadapp__Icon__c = 'https://test.url',
            trailheadapp__API_Name__c = 'quickstart-visualforce',
            OwnerId = user.Id
        );
        insert badge1;

        // Prepare Badges record
        trailheadapp__Badge__c badge2 = new trailheadapp__Badge__c(
            Name = 'Quick Start: Apex Coding for Admins',
            trailheadapp__Description__c = 'Add Apex to your toolkit and build complex business processes with code.',
            trailheadapp__Namespace__c = 'learn',
            trailheadapp__URL__c = 'https://test.url',
            trailheadapp__Icon__c = 'https://test.url',
            trailheadapp__API_Name__c = 'quick-start-apex-coding-for-admins',
            OwnerId = user.Id
        );
        insert badge2;

        Id [] fixedSearchResults = new Id[2];
        fixedSearchResults[0] = badge1.Id;
        fixedSearchResults[1] = badge2.Id;

        String searchText = 'Quick';

        Test.startTest();
        Test.setFixedSearchResults(fixedSearchResults);
        CertificationBoardingTrailhead.BadgeAndTrailInformation actual = CertificationBoardingTrailhead.searchBadgesAndTrail(searchText);
        Test.stopTest();

        System.assertEquals(2, actual.badges.size());
        System.assertEquals(0, actual.trailmixes.size());
    }

    @isTest()
    static void saveBadgesAndTrailmixesSuccessTest() {
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
        Skill_Certification__c certification = new Skill_Certification__c(
            Certification_Categories__c = 'Salesforce Administrator',
            Certification_Name__c = 'Administrator',
            OwnerId = user.Id,
            Scheduled_Examination_Date__c = Date.today(),
            Status__c = 'Planning'
        );
        insert certification;

        // Prepare Badges record
        trailheadapp__Badge__c badge1 = new trailheadapp__Badge__c(
            Name = 'Strategies for Positive Environmental Impact',
            trailheadapp__Description__c = 'Learn about climate change and how to adopt Salesforce’s sustainable approach.',
            trailheadapp__Namespace__c = 'learn',
            trailheadapp__URL__c = 'https://test.url',
            trailheadapp__Icon__c = 'https://test.url',
            trailheadapp__API_Name__c = 'positive-environmental-impact',
            OwnerId = user.Id
        );
        insert badge1;

        // Prepare trailmix record
        trailheadapp__Trailmix__c trailmix1 = new trailheadapp__Trailmix__c(
            Name = 'Architect Journey: Identity and Access Management',
            trailheadapp__URL__c = 'https://test.url',
            trailheadapp__Created_By_Profile__c = 'https://test.url',
            trailheadapp__Slug__c = 'architect-identity-and-access-management',
            trailheadapp__External_Id__c = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
            OwnerId = user.Id
        );
        insert trailmix1;

        List<CertificationBoardingTrailhead.BadgeAndTrailSaveData> saveDataList = new List<CertificationBoardingTrailhead.BadgeAndTrailSaveData>();
        CertificationBoardingTrailhead.BadgeAndTrailSaveData saveData1 = new CertificationBoardingTrailhead.BadgeAndTrailSaveData();
        saveData1.id = badge1.Id;
        saveData1.dueDate = Date.today().addDays(10);
        saveData1.externalId = 'HelloId';
        saveData1.type = 'badge';
        
        
        CertificationBoardingTrailhead.BadgeAndTrailSaveData saveData2 = new CertificationBoardingTrailhead.BadgeAndTrailSaveData();
        saveData2.id = trailmix1.Id;
        saveData2.dueDate = Date.today().addDays(10);
        saveData2.externalId = 'HelloId2';
        saveData2.type = 'trailmix';

        saveDataList.add(saveData1);
        saveDataList.add(saveData2);

        Test.startTest();
        Boolean actual = CertificationBoardingTrailhead.saveBadgeAndTrail(saveDataList, certification.Id);
        Test.stopTest();

        System.assertEquals(true, actual);
    }

    @isTest()
    static void saveBadgesAndTrailmixesFailTest() {
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
        Skill_Certification__c certification = new Skill_Certification__c(
            Certification_Categories__c = 'Salesforce Administrator',
            Certification_Name__c = 'Administrator',
            OwnerId = user.Id,
            Scheduled_Examination_Date__c = Date.today(),
            Status__c = 'Planning'
        );
        insert certification;

        // Prepare Badges record
        trailheadapp__Badge__c badge1 = new trailheadapp__Badge__c(
            Name = 'Strategies for Positive Environmental Impact',
            trailheadapp__Description__c = 'Learn about climate change and how to adopt Salesforce’s sustainable approach.',
            trailheadapp__Namespace__c = 'learn',
            trailheadapp__URL__c = 'https://test.url',
            trailheadapp__Icon__c = 'https://test.url',
            trailheadapp__API_Name__c = 'positive-environmental-impact',
            OwnerId = user.Id
        );
        insert badge1;

        List<CertificationBoardingTrailhead.BadgeAndTrailSaveData> saveDataList = new List<CertificationBoardingTrailhead.BadgeAndTrailSaveData>();
        CertificationBoardingTrailhead.BadgeAndTrailSaveData saveData1 = new CertificationBoardingTrailhead.BadgeAndTrailSaveData();
        saveData1.id = badge1.Id;
        saveData1.dueDate = Date.today().addDays(10);
        saveData1.externalId = 'HelloId';
        saveData1.type = 'badge';
        saveDataList.add(saveData1);
        
        CertificationBoardingTrailhead.BadgeAndTrailSaveData saveData2 = new CertificationBoardingTrailhead.BadgeAndTrailSaveData();
        saveDataList.add(saveData2);

        Test.startTest();
        Boolean actual = CertificationBoardingTrailhead.saveBadgeAndTrail(saveDataList, certification.Id);
        Test.stopTest();

        System.assertEquals(false, actual);
    }
}