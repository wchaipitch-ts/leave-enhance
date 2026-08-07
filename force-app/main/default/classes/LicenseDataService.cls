/**
 * Data service class for OurPackageLicense__c operations
 * Uses 'without sharing' to allow Site Guest User access to license data
 * 
 * SECURITY NOTE: This class intentionally uses 'without sharing' to enable
 * Site Guest User access. All methods should validate input and only expose
 * necessary data. Do not add methods that expose sensitive information.
 */
public without sharing class LicenseDataService {
    
    /**
     * Query license record by Target Org ID
     * @param targetOrgId The organization ID to search for
     * @param dateFieldName The dynamic field name to include in the query (e.g., 'BizCard_ExpirationDate__c')
     * @return License record if found, null otherwise
     */
    public static OurPackageLicense__c queryLicenseByOrgId(String targetOrgId, String dateFieldName) {
        // Input validation
        if (String.isBlank(targetOrgId)) {
            throw new IllegalArgumentException('targetOrgId cannot be blank');
        }
        
        if (String.isBlank(dateFieldName)) {
            throw new IllegalArgumentException('dateFieldName cannot be blank');
        }
        
        // Validate field name to prevent SOQL injection
        // Only allow alphanumeric characters and underscores
        if (!Pattern.matches('^[a-zA-Z0-9_]+$', dateFieldName)) {
            throw new IllegalArgumentException('Invalid field name format');
        }
        
        // Dynamic SOQL with bind variable for security
        String query = 'SELECT Id, TargetOrgId__c, TargetOrgName__c, ' + 
                       String.escapeSingleQuotes(dateFieldName) + 
                       ' FROM OurPackageLicense__c WHERE TargetOrgId__c = :targetOrgId LIMIT 1';
        
        List<OurPackageLicense__c> licenses = Database.query(query);
        
        return licenses.isEmpty() ? null : licenses[0];
    }
    
    /**
     * Update both TargetOrgName__c and lastCheckedAt__c in a single DML operation
     * @param licenseId The ID of the license record to update
     * @param newOrgName The new organization name (can be null to skip OrgName update)
     * @return true if update succeeded, false otherwise
     */
    public static Boolean updateOrgNameAndLastChecked(Id licenseId, String newOrgName) {
        // Input validation
        if (licenseId == null) {
            throw new IllegalArgumentException('licenseId cannot be null');
        }
        
        try {
            OurPackageLicense__c license = new OurPackageLicense__c(
                Id = licenseId,
                lastCheckedAt__c = DateTime.now()
            );
            
            // Only update OrgName if provided
            if (String.isNotBlank(newOrgName)) {
                license.TargetOrgName__c = newOrgName;
            }
            
            update license;
            return true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to update license fields: ' + e.getMessage());
            return false;
        }
    }
}