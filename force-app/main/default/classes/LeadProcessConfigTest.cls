@IsTest
private class LeadProcessConfigTest {

    @IsTest
    static void testGetReturnsInjectedValues() {
        Account dummy = new Account(Name = 'Dummy A');
        insert dummy;

        LeadProcessConfig.clearCache();
        LeadProcessConfig.Config injected = new LeadProcessConfig.Config();
        injected.dummyEmail = 'dummy@config.com';
        injected.dummyEmailLower = 'dummy@config.com';
        injected.dummyAccountId = dummy.Id;
        injected.maxErrorLogs = 7;
        LeadProcessConfig.setForTest(injected);

        LeadProcessConfig.Config cfg = LeadProcessConfig.get();
        System.assertEquals('dummy@config.com', cfg.dummyEmail, 'Should use injected dummy email');
        System.assertEquals('dummy@config.com', cfg.dummyEmailLower, 'Lower variant should match');
        System.assertEquals(dummy.Id, cfg.dummyAccountId, 'Should use injected Dummy Account Id');
        System.assertEquals(7, cfg.maxErrorLogs, 'Should use injected Max_Error_Logs__c');
    }

    @IsTest
    static void testFallbacksWhenNoCmdtConfigured() {
        // With no CMDT and no injection, fallbacks should apply
        LeadProcessConfig.clearCache();

        LeadProcessConfig.Config cfg = LeadProcessConfig.get();
        System.assertEquals(BulkLeadConvertBatch.getDefaultDummyEmail(), cfg.dummyEmail, 'Should fall back to batch default dummy email');
        System.assertEquals(BulkLeadConvertBatch.getDefaultDummyEmail().toLowerCase(), cfg.dummyEmailLower, 'Lower variant should reflect fallback');
        System.assertEquals(null, cfg.dummyAccountId, 'No Dummy Account Id when not set');
        System.assertEquals(50, cfg.maxErrorLogs, 'Should default to 50 when null/<=0');
    }

    @IsTest
    static void testCacheBehaviorClearAndReload() {
        // First load uses fallbacks
        LeadProcessConfig.clearCache();
        LeadProcessConfig.Config first = LeadProcessConfig.get();
        System.assertNotEquals(null, first, 'Config should load');
        // Inject a different config and verify get() returns the injected values
        LeadProcessConfig.Config injected = new LeadProcessConfig.Config();
        injected.dummyEmail = 'override@test.com';
        injected.dummyEmailLower = 'override@test.com';
        injected.dummyAccountId = null;
        injected.maxErrorLogs = 7;
        LeadProcessConfig.setForTest(injected);
        LeadProcessConfig.Config second = LeadProcessConfig.get();
        System.assertEquals('override@test.com', second.dummyEmail, 'Cache should return injected values');
        System.assertEquals(7, second.maxErrorLogs, 'Cache should reflect injected cap');
        // Clear and ensure a new load occurs (falling back again)
        LeadProcessConfig.clearCache();
        LeadProcessConfig.Config third = LeadProcessConfig.get();
        System.assertEquals(BulkLeadConvertBatch.getDefaultDummyEmail(), third.dummyEmail, 'After clear, should reload fallbacks');
        System.assertEquals(50, third.maxErrorLogs, 'After clear, should default max error logs');
    }

    @IsTest(SeeAllData=true)
    static void testReadsFromCmdtIfPresent() {
        // This test increases coverage for the metadata-read path when a Default_Config record exists.
        LeadProcessConfig.clearCache();
        Lead_Process_Config__mdt record = Lead_Process_Config__mdt.getInstance('Default_Config');
        LeadProcessConfig.Config cfg = LeadProcessConfig.get();
        if (record != null) {
            // When CMDT is present, values should be sourced from the record (when provided)
            if (record.Dummy_Email__c != null && record.Dummy_Email__c.trim() != '') {
                System.assertEquals(record.Dummy_Email__c.trim(), cfg.dummyEmail, 'dummyEmail should come from CMDT');
                System.assertEquals(record.Dummy_Email__c.trim().toLowerCase(), cfg.dummyEmailLower, 'lower should match');
            }
            if (record.Max_Error_Logs__c != null) {
                System.assertEquals(Integer.valueOf(record.Max_Error_Logs__c), cfg.maxErrorLogs, 'maxErrorLogs should come from CMDT');
            }
            // For Dummy_Account_Id__c we can only assert when the value is a valid 18-char id
            if (record.Dummy_Account_Id__c != null && record.Dummy_Account_Id__c.length() == 18) {
                System.assertEquals((Id)record.Dummy_Account_Id__c, cfg.dummyAccountId, 'dummyAccountId should come from CMDT when valid');
            }
        } else {
            // If CMDT is not present in this org, at least assert the fallback path produces sane values
            System.assertNotEquals(null, cfg.dummyEmail, 'fallback dummyEmail should not be null');
            System.assertEquals(cfg.dummyEmail.toLowerCase(), cfg.dummyEmailLower, 'lower should match fallback');
            System.assert(cfg.maxErrorLogs > 0, 'maxErrorLogs should default to a positive number');
        }
    }

    @IsTest
    static void testCmdtOverrideBranchCovered() {
        // Cover the metadata-read branch without relying on org data
        Account a = new Account(Name = 'Config Holder');
        insert a;

        Lead_Process_Config__mdt fake = new Lead_Process_Config__mdt(
            DeveloperName = 'Default_Config',
            MasterLabel = 'Default Config (Test)',
            Dummy_Email__c = 'cmdt@test.com',
            Dummy_Account_Id__c = a.Id,
            Max_Error_Logs__c = 12
        );

        // Inject test override and reload
        LeadProcessConfig.testCmdtOverride = fake;
        LeadProcessConfig.clearCache();
        LeadProcessConfig.Config cfg = LeadProcessConfig.get();

        System.assertEquals('cmdt@test.com', cfg.dummyEmail, 'dummyEmail should be sourced from override');
        System.assertEquals('cmdt@test.com', cfg.dummyEmailLower, 'lower should reflect override');
        System.assertEquals(a.Id, cfg.dummyAccountId, 'dummyAccountId should parse from override');
        System.assertEquals(12, cfg.maxErrorLogs, 'maxErrorLogs should be taken from override');

        // Clean up override to avoid leaking into other tests
        LeadProcessConfig.testCmdtOverride = null;
        LeadProcessConfig.clearCache();
    }
}