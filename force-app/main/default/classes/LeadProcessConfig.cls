public class LeadProcessConfig {
    public class Config {
        public String dummyEmail;
        public String dummyEmailLower;
        public Id dummyAccountId;
        public Integer maxErrorLogs;
    }

    private static Config cached;
    @TestVisible static Lead_Process_Config__mdt testCmdtOverride;

    public static Config get() {
        if (cached == null) {
            cached = load();
        }
        return cached;
    }

    @TestVisible static void clearCache() {
        cached = null;
    }

    @TestVisible
    public static void setForTest(Config overrideConfig) {
        // Allows tests to inject configuration without relying on CMDT DML
        cached = overrideConfig;
    }

    private static Config load() {
        Config config = new Config();
        Lead_Process_Config__mdt cmdt = (Test.isRunningTest() && testCmdtOverride != null)
            ? testCmdtOverride
            : Lead_Process_Config__mdt.getInstance('Default_Config');
        if (cmdt != null) {
            if (!String.isBlank(cmdt.Dummy_Email__c)) {
                config.dummyEmail = cmdt.Dummy_Email__c.trim();
            }
            if (!String.isBlank(cmdt.Dummy_Account_Id__c)) {
                try {
                    config.dummyAccountId = (Id)cmdt.Dummy_Account_Id__c.trim();
                } catch (Exception ex) {
                    System.debug(LoggingLevel.WARN, 'Invalid Dummy Account Id in Lead_Process_Config__mdt: ' + ex.getMessage());
                }
            }
            if (cmdt.Max_Error_Logs__c != null) {
                config.maxErrorLogs = Integer.valueOf(cmdt.Max_Error_Logs__c);
            }
        }

        if (String.isBlank(config.dummyEmail)) {
            config.dummyEmail = BulkLeadConvertBatch.getDefaultDummyEmail();
        }
        config.dummyEmailLower = config.dummyEmail != null ? config.dummyEmail.toLowerCase() : null;

        if (config.maxErrorLogs == null || config.maxErrorLogs <= 0) {
            config.maxErrorLogs = 50;
        }

        return config;
    }
}