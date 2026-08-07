@isTest
private class BulkLeadConvertBatchTest {

    @testSetup
    static void setupData() {
        Account dummyAccount = new Account(Name = 'Dummy Account', Normalized_Company_Name__c = 'dummyaccount');
        insert dummyAccount;
    }

    @isTest
    static void testNoEmailPathCreatesContactUnderDummyAccount() {
        LeadProcessConfig.clearCache();
        Account dummyAccount = [SELECT Id FROM Account WHERE Name = 'Dummy Account' LIMIT 1];
        // Inject config for test instead of CMDT DML
        LeadProcessConfig.Config cfg = new LeadProcessConfig.Config();
        cfg.dummyEmail = 'dummy@config.com';
        cfg.dummyEmailLower = 'dummy@config.com';
        cfg.dummyAccountId = dummyAccount.Id;
        cfg.maxErrorLogs = 5;
        LeadProcessConfig.setForTest(cfg);

        Lead leadRecord = new Lead(
            FirstName = 'No',
            LastName = 'Email',
            Email = 'dummy@config.com',
            Company = 'NoEmail Co',
            leadHasNoEmail__c = true,
            Status = 'Open - Not Contacted'
        );
        insert leadRecord;

        BulkLeadConvertBatch batch = new BulkLeadConvertBatch();
        Test.startTest();
        batch.execute(null, [SELECT Id, OwnerId, Email, Company, FirstName, LastName, LastModifiedDate, leadHasNoEmail__c FROM Lead WHERE Id = :leadRecord.Id]);
        Test.stopTest();

        Lead convertedLead = [SELECT IsConverted, ConvertedAccountId, ConvertedContactId FROM Lead WHERE Id = :leadRecord.Id];
        System.assertEquals(true, convertedLead.IsConverted, 'Lead should be converted');
        System.assertEquals(dummyAccount.Id, convertedLead.ConvertedAccountId, 'Lead should convert into dummy account');

        Contact createdContact = [SELECT AccountId, Original_Lead_Company__c FROM Contact WHERE Id = :convertedLead.ConvertedContactId];
        System.assertEquals(dummyAccount.Id, createdContact.AccountId, 'Contact should be under dummy account');
        System.assertEquals('NoEmail Co', createdContact.Original_Lead_Company__c, 'Original company should be stamped');
    }

    @isTest
    static void testLeadLeadMergeChunking() {
        LeadProcessConfig.clearCache();
        String email = 'chunk@test.com';
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 4; i++) {
            leads.add(new Lead(FirstName = 'Lead', LastName = 'Chunk' + i, Email = email, Company = 'Chunk Co', Status = 'Open - Not Contacted'));
        }
        insert leads;

        BulkLeadConvertBatch batch = new BulkLeadConvertBatch();
        Test.startTest();
        batch.execute(null, [SELECT Id, OwnerId, Email, Company, FirstName, LastName, LastModifiedDate, leadHasNoEmail__c FROM Lead WHERE Id IN :leads]);
        Test.stopTest();

        Integer mergedCount = 0;
        for (Integer size : batch.mergeChunkSizes) {
            System.assert(size <= 2, 'Each merge chunk should be of size two or less');
            mergedCount += size;
        }
        System.assertEquals(3, mergedCount, 'Three duplicate leads should be merged in total');

        List<Lead> postMergeLeads = [SELECT Id, IsDeleted FROM Lead WHERE Id IN :leads ALL ROWS];
        Integer deletedCount = 0;
        for (Lead leadRecord : postMergeLeads) {
            if (leadRecord.IsDeleted) {
                deletedCount++;
            }
        }
        System.assert(deletedCount >= 3, 'Duplicate leads should be removed after merge');
    }

    @isTest
    static void testSingleContactMergePath() {
        LeadProcessConfig.clearCache();
        Account accountRecord = new Account(Name = 'Acme Single', Normalized_Company_Name__c = 'acmesingle');
        insert accountRecord;
        String uniqueEmail = 'single-' + String.valueOf(Datetime.now().getTime()) + '@test.com';
        Contact contactRecord = new Contact(FirstName = 'Amy', LastName = 'Contact', Email = uniqueEmail, AccountId = accountRecord.Id);
        insert contactRecord;

        Lead leadRecord = new Lead(FirstName = 'Amy', LastName = 'Contact', Company = 'Acme Inc', Email = uniqueEmail, Status = 'Open - Not Contacted');
        // Avoid org duplicate rules blocking test data
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.allowSave = true;
        dml.DuplicateRuleHeader.runAsCurrentUser = true;
        Database.insert(leadRecord, dml);

        BulkLeadConvertBatch batch = new BulkLeadConvertBatch();
        Test.startTest();
        batch.execute(null, [SELECT Id, OwnerId, Email, Company, FirstName, LastName, LastModifiedDate, leadHasNoEmail__c FROM Lead WHERE Id = :leadRecord.Id]);
        Test.stopTest();

        Lead convertedLead = [SELECT IsConverted, IsDeleted, ConvertedContactId FROM Lead WHERE Id = :leadRecord.Id];
        System.assertEquals(true, convertedLead.IsConverted, 'Lead should convert. Errors: ' + String.join(batch.errorMessages, '; '));
        System.assertEquals(false, convertedLead.IsDeleted, 'Lead should not be deleted');

        Contact refreshedContact = [SELECT Duplicate_Contact_Id__c, Original_Lead_Company__c FROM Contact WHERE Id = :contactRecord.Id];
        System.assertEquals(null, refreshedContact.Duplicate_Contact_Id__c, 'Duplicate flag should remain empty for single match');
        System.assertEquals('Acme Inc', refreshedContact.Original_Lead_Company__c, 'Original company should be stamped on existing contact');
    }

    @isTest
    static void testMultipleContactsStopConversion() {
        LeadProcessConfig.clearCache();
        Account accountRecord = new Account(Name = 'Multi Contact Account', Normalized_Company_Name__c = 'multicontact');
        insert accountRecord;
        Contact contactOne = new Contact(FirstName = 'Sam', LastName = 'One', Email = 'multi@test.com', AccountId = accountRecord.Id);
        Contact contactTwo = new Contact(FirstName = 'Sam', LastName = 'Two', Email = 'multi@test.com', AccountId = accountRecord.Id);
        insert new List<Contact>{contactOne, contactTwo};

        Lead leadRecord = new Lead(FirstName = 'Sam', LastName = 'Lead', Company = 'Multi Co', Email = 'multi@test.com', Status = 'Open - Not Contacted');
        insert leadRecord;

        BulkLeadConvertBatch batch = new BulkLeadConvertBatch();
        Test.startTest();
        batch.execute(null, [SELECT Id, OwnerId, Email, Company, FirstName, LastName, LastModifiedDate, leadHasNoEmail__c FROM Lead WHERE Id = :leadRecord.Id]);
        Test.stopTest();

        Lead deletedLead = [SELECT Id, IsDeleted FROM Lead WHERE Id = :leadRecord.Id ALL ROWS];
        System.assertEquals(true, deletedLead.IsDeleted, 'Lead should be deleted when multiple contacts are found');

        List<Contact> contacts = [SELECT Id, Duplicate_Contact_Id__c FROM Contact WHERE Id IN :new List<Id>{contactOne.Id, contactTwo.Id}];
        Set<String> expectedIds = new Set<String>{String.valueOf(contactOne.Id), String.valueOf(contactTwo.Id)};
        for (Contact contactRecord : contacts) {
            System.assertNotEquals(null, contactRecord.Duplicate_Contact_Id__c, 'Duplicate contact field should be populated');
            Set<String> actualIds = new Set<String>(contactRecord.Duplicate_Contact_Id__c.split(','));
            System.assertEquals(expectedIds, actualIds, 'Duplicate contact field should contain all matching contact ids');
        }
    }

    @isTest
    static void testMultipleAccountCandidatesFlagged() {
        LeadProcessConfig.clearCache();
        // Create two accounts that normalize to the same company key via trigger
        Account accountOne = new Account(Name = 'Acme Co Ltd');
        Account accountTwo = new Account(Name = 'Acme Co Ltd');
        Database.DMLOptions accDml = new Database.DMLOptions();
        accDml.DuplicateRuleHeader.allowSave = true;
        accDml.DuplicateRuleHeader.runAsCurrentUser = true;
        Database.insert(new List<Account>{accountOne, accountTwo}, accDml);

        Lead leadRecord = new Lead(FirstName = 'Pat', LastName = 'Account', Company = 'Acme Co Ltd', Email = 'account@test.com', Status = 'Open - Not Contacted');
        insert leadRecord;

        BulkLeadConvertBatch batch = new BulkLeadConvertBatch();
        Test.startTest();
        batch.execute(null, [SELECT Id, OwnerId, Email, Company, FirstName, LastName, LastModifiedDate, leadHasNoEmail__c FROM Lead WHERE Id = :leadRecord.Id]);
        Test.stopTest();

        Lead convertedLead = [SELECT ConvertedAccountId, ConvertedContactId, IsConverted FROM Lead WHERE Id = :leadRecord.Id];
        System.assertEquals(true, convertedLead.IsConverted, 'Lead should convert');

        Contact convertedContact = [SELECT Original_Lead_Company__c FROM Contact WHERE Id = :convertedLead.ConvertedContactId];
        System.assertEquals('Acme Co Ltd', convertedContact.Original_Lead_Company__c, 'Contact should carry original company value');

        List<Account> accounts = [SELECT Id, Duplicate_Account_Id__c FROM Account WHERE Id IN :new List<Id>{accountOne.Id, accountTwo.Id}];
        Set<String> expectedIds = new Set<String>{String.valueOf(accountOne.Id), String.valueOf(accountTwo.Id)};
        for (Account accountRecord : accounts) {
            System.assertNotEquals(null, accountRecord.Duplicate_Account_Id__c, 'Duplicate account field should be populated');
            Set<String> actualIds = new Set<String>(accountRecord.Duplicate_Account_Id__c.split(','));
            System.assertEquals(expectedIds, actualIds, 'Duplicate account field should contain all candidate ids');
        }

        System.assertEquals(accountOne.Id, convertedLead.ConvertedAccountId, 'First candidate should be selected for conversion');
    }

    @isTest
    static void testErrorLogCapRespected() {
        // Configure error cap via test injection (no CMDT DML in tests)
        LeadProcessConfig.clearCache();
        LeadProcessConfig.Config cfg = new LeadProcessConfig.Config();
        cfg.dummyEmail = 'dummy@config.com';
        cfg.dummyEmailLower = 'dummy@config.com';
        cfg.dummyAccountId = null; // force missing dummy account to log an error
        cfg.maxErrorLogs = 1; // cap at 1
        LeadProcessConfig.setForTest(cfg);

        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 3; i++) {
            leads.add(new Lead(FirstName = 'Err', LastName = 'Lead' + i, Email = 'dummy@config.com', Company = 'Err Co', leadHasNoEmail__c = true, Status = 'Open - Not Contacted'));
        }
        insert leads;

        BulkLeadConvertBatch batch = new BulkLeadConvertBatch();
        Test.startTest();
        batch.execute(null, [SELECT Id, OwnerId, Email, Company, FirstName, LastName, LastModifiedDate, leadHasNoEmail__c FROM Lead WHERE Id IN :leads]);
        Test.stopTest();

        System.assertEquals(1, batch.errorMessages.size(), 'Error logging should respect the configured cap');
    }
}