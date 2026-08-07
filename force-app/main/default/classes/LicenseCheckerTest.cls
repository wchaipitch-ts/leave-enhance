@IsTest
private class LicenseCheckerTest {

    private static String generateKey(String orgId) {
        Blob targetBlob = Blob.valueOf(orgId + LicenseChecker.SHARED_SALT);
        Blob hashBlob = Crypto.generateDigest('SHA-256', targetBlob);
        return EncodingUtil.convertToHex(hashBlob);
    }

    @TestSetup
    static void setup() {
        OurPackageLicense__c lic = new OurPackageLicense__c(
            TargetOrgId__c = '00DTestOrg12345678',
            TargetOrgName__c = 'Test Org',
            BizCard_ExpirationDate__c = Date.today().addDays(365) // Future
        );
        insert lic;

        OurPackageLicense__c licExpired = new OurPackageLicense__c(
            TargetOrgId__c = '00DExpiredOrg12345',
            TargetOrgName__c = 'Expired Org',
            BizCard_ExpirationDate__c = Date.today().addDays(-1) // Past
        );
        insert licExpired;
        
        OurPackageLicense__c licNull = new OurPackageLicense__c(
            TargetOrgId__c = '00DNullOrg12345678',
            TargetOrgName__c = 'Null Date Org',
            BizCard_ExpirationDate__c = null // Null
        );
        insert licNull;
    }

    @IsTest
    static void testValidLicenseFutureDate() {
        String orgId = '00DTestOrg12345678';
        String key = generateKey(orgId);
        String jsonBody = JSON.serialize(new Map<String, Object>{
            'orgId' => orgId,
            'orgName' => 'Test Org',
            'key' => key,
            'appName' => 'BizCard'
        });

        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/lic-check';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(jsonBody);
        RestContext.request = req;

        LicenseChecker.AccessCheckResult res = LicenseChecker.check();
        
        System.assertEquals(true, res.available, 'Future date should be available');
    }

    @IsTest
    static void testExpiredLicense() {
        String orgId = '00DExpiredOrg12345';
        String key = generateKey(orgId);
        String jsonBody = JSON.serialize(new Map<String, Object>{
            'orgId' => orgId,
            'key' => key,
            'appName' => 'BizCard'
        });

        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(jsonBody);
        RestContext.request = req;

        LicenseChecker.AccessCheckResult res = LicenseChecker.check();
        
        System.assertEquals(false, res.available, 'Past date should be unavailable');
    }

    @IsTest
    static void testNullExpirationDate() {
        String orgId = '00DNullOrg12345678';
        String key = generateKey(orgId);
        String jsonBody = JSON.serialize(new Map<String, Object>{
            'orgId' => orgId,
            'key' => key,
            'appName' => 'BizCard'
        });

        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(jsonBody);
        RestContext.request = req;

        LicenseChecker.AccessCheckResult res = LicenseChecker.check();
        
        System.assertEquals(true, res.available, 'Null date should be available');
    }

    @IsTest
    static void testInvalidKey() {
        String orgId = '00DTestOrg12345678';
        String key = 'invalidhash';
        String jsonBody = JSON.serialize(new Map<String, Object>{
            'orgId' => orgId,
            'key' => key,
            'appName' => 'BizCard'
        });

        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(jsonBody);
        RestContext.request = req;

        LicenseChecker.AccessCheckResult res = LicenseChecker.check();
        
        System.assertEquals(false, res.available);
        System.assertEquals('Invalid Key', res.message);
    }

    @IsTest
    static void testLicenseNotFound() {
        String orgId = '00DUnknownOrg123456';
        String key = generateKey(orgId);
        String jsonBody = JSON.serialize(new Map<String, Object>{
            'orgId' => orgId,
            'key' => key,
            'appName' => 'BizCard'
        });

        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(jsonBody);
        RestContext.request = req;

        LicenseChecker.AccessCheckResult res = LicenseChecker.check();
        
        System.assertEquals(false, res.available);
        System.assertEquals('License not found', res.message);
    }

    @IsTest
    static void testUnknownApp() {
        String orgId = '00DTestOrg12345678';
        String key = generateKey(orgId);
        String jsonBody = JSON.serialize(new Map<String, Object>{
            'orgId' => orgId,
            'key' => key,
            // Unknown App Name
            'appName' => 'SuperUnknownApp' 
        });

        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(jsonBody);
        RestContext.request = req;

        LicenseChecker.AccessCheckResult res = LicenseChecker.check();
        
        System.assertEquals(false, res.available);
        System.assertEquals('Unknown Application', res.message);
    }
    
    @IsTest
    static void testMissingFields() {
        // Missing appName
        String jsonBody = JSON.serialize(new Map<String, Object>{
            'orgId' => '00DTestOrg12345678',
            'key' => 'somekey'
        });

        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(jsonBody);
        RestContext.request = req;

        LicenseChecker.AccessCheckResult res = LicenseChecker.check();
        
        System.assertEquals(false, res.available);
        System.assert(res.message.contains('Missing required fields'), 'Should complain about missing fields');
    }
}