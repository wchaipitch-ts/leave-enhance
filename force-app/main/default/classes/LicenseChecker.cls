@RestResource(urlMapping='/lic-check/*')
global with sharing class LicenseChecker {

    @TestVisible
    private static final String SHARED_SALT = Label.OurPackageLicense_SALT; //カスタム表示ラベルに設定

    global class AccessCheckRequest {
        public String orgId;
        public String orgName; // Not used in logic but kept for logging/schema
        public String key;
        public String appName;
    }

    global class AccessCheckResult {
        public Boolean available;
        public String message;
        public String checkedAt; // ISO 8601 format: yyyy-MM-dd'T'HH:mm:ss'Z'

        public AccessCheckResult(Boolean available, String message) {
            this.available = available;
            this.message = message;
            this.checkedAt = DateTime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        }
    }

    private static final Map<String, String> APP_DATE_FIELD_MAP = new Map<String, String>{
        'BizCard' => 'BizCard_ExpirationDate__c'
    };

    /**
     * Generate hash for a given orgId
     * This is useful for creating test data and generating the correct 'key' value
     * @param orgId The organization ID to generate hash for
     * @return The SHA-256 hash in hexadecimal format
     */
    public static String generateHash(String orgId) {
        if (String.isBlank(orgId)) {
            throw new IllegalArgumentException('orgId cannot be blank');
        }
        
        String hashInput = orgId + SHARED_SALT;
        Blob targetBlob = Blob.valueOf(hashInput);
        Blob hashBlob = Crypto.generateDigest('SHA-256', targetBlob);
        return EncodingUtil.convertToHex(hashBlob);
    }

    @HttpPost
    global static AccessCheckResult check() {
        RestRequest req = RestContext.request;
        String requestBody = req.requestBody.toString();
        
        AccessCheckRequest request;
        try {
            request = (AccessCheckRequest)JSON.deserialize(requestBody, AccessCheckRequest.class);
        } catch (Exception e) {
            return new AccessCheckResult(false, 'Invalid JSON format');
        }

        if (String.isBlank(request.orgId) || String.isBlank(request.key) || String.isBlank(request.appName)) {
             return new AccessCheckResult(false, 'Missing required fields: orgId, key, appName');
        }

        // 0. Validate App Name early
        if (!APP_DATE_FIELD_MAP.containsKey(request.appName)) {
            return new AccessCheckResult(false, 'Unknown Application');
        }
        String dateField = APP_DATE_FIELD_MAP.get(request.appName);

        // 1. Verify Hash
        String expectedHash = generateHash(request.orgId);

        if (request.key != expectedHash) {
             return new AccessCheckResult(false, 'Invalid Key');
        }

        // 2. Query OurPackageLicense via LicenseDataService (without sharing)
        OurPackageLicense__c license = LicenseDataService.queryLicenseByOrgId(request.orgId, dateField);

        if (license == null) {
            return new AccessCheckResult(false, 'License not found');
        }

        // Update lastCheckedAt__c and TargetOrgName__c (if different) in a single DML operation
        String orgNameToUpdate = (String.isNotBlank(request.orgName) && license.TargetOrgName__c != request.orgName) 
                                 ? request.orgName 
                                 : null;
        LicenseDataService.updateOrgNameAndLastChecked(license.Id, orgNameToUpdate);

        // 3. Check App Expiration
        Date expirationDate = (Date)license.get(dateField);
        
        // Logic: 
        // Null -> True
        // Future (>= Today) -> True
        // Past (< Today) -> False
        
        if (expirationDate == null || expirationDate >= Date.today()) {
            return new AccessCheckResult(true, 'Valid license');
        } else {
            return new AccessCheckResult(false, 'License expired');
        }
    }
}