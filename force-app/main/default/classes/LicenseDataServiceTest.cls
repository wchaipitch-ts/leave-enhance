@IsTest
private class LicenseDataServiceTest {
    
    @TestSetup
    static void setupTestData() {
        // Create test license record
        OurPackageLicense__c license = new OurPackageLicense__c(
            TargetOrgId__c = '00D000000000001EAA',
            TargetOrgName__c = 'Test Org',
            BizCard_ExpirationDate__c = Date.today().addDays(30)
        );
        insert license;
    }
    
    @IsTest
    static void testQueryLicenseByOrgId_Success() {
        // Arrange
        String testOrgId = '00D000000000001EAA';
        String dateField = 'BizCard_ExpirationDate__c';
        
        // Act
        Test.startTest();
        OurPackageLicense__c result = LicenseDataService.queryLicenseByOrgId(testOrgId, dateField);
        Test.stopTest();
        
        // Assert
        System.assertNotEquals(null, result, 'License should be found');
        System.assertEquals(testOrgId, result.TargetOrgId__c, 'OrgId should match');
        System.assertEquals('Test Org', result.TargetOrgName__c, 'OrgName should match');
    }
    
    @IsTest
    static void testQueryLicenseByOrgId_NotFound() {
        // Arrange
        String testOrgId = '00D999999999999EAA'; // Non-existent org
        String dateField = 'BizCard_ExpirationDate__c';
        
        // Act
        Test.startTest();
        OurPackageLicense__c result = LicenseDataService.queryLicenseByOrgId(testOrgId, dateField);
        Test.stopTest();
        
        // Assert
        System.assertEquals(null, result, 'License should not be found');
    }
    
    @IsTest
    static void testQueryLicenseByOrgId_BlankOrgId() {
        // Arrange
        String dateField = 'BizCard_ExpirationDate__c';
        
        // Act & Assert
        try {
            Test.startTest();
            LicenseDataService.queryLicenseByOrgId('', dateField);
            Test.stopTest();
            System.assert(false, 'Should have thrown IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('targetOrgId'), 'Error message should mention targetOrgId');
        }
    }
    
    @IsTest
    static void testQueryLicenseByOrgId_BlankDateField() {
        // Arrange
        String testOrgId = '00D000000000001EAA';
        
        // Act & Assert
        try {
            Test.startTest();
            LicenseDataService.queryLicenseByOrgId(testOrgId, '');
            Test.stopTest();
            System.assert(false, 'Should have thrown IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('dateFieldName'), 'Error message should mention dateFieldName');
        }
    }
    
    @IsTest
    static void testQueryLicenseByOrgId_InvalidFieldName() {
        // Arrange
        String testOrgId = '00D000000000001EAA';
        String invalidField = 'BizCard_ExpirationDate__c; DROP TABLE OurPackageLicense__c--'; // SOQL injection attempt
        
        // Act & Assert
        try {
            Test.startTest();
            LicenseDataService.queryLicenseByOrgId(testOrgId, invalidField);
            Test.stopTest();
            System.assert(false, 'Should have thrown IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('Invalid field name'), 'Error message should mention invalid field name');
        }
    }
    
    @IsTest
    static void testUpdateOrgNameAndLastChecked_Success() {
        // Arrange
        OurPackageLicense__c license = [SELECT Id, TargetOrgName__c, lastCheckedAt__c FROM OurPackageLicense__c LIMIT 1];
        String newOrgName = 'Updated Org Name';
        DateTime originalLastCheckedAt = license.lastCheckedAt__c;
        
        // Act
        Test.startTest();
        Boolean result = LicenseDataService.updateOrgNameAndLastChecked(license.Id, newOrgName);
        Test.stopTest();
        
        // Assert
        System.assertEquals(true, result, 'Update should succeed');
        
        OurPackageLicense__c updatedLicense = [SELECT TargetOrgName__c, lastCheckedAt__c FROM OurPackageLicense__c WHERE Id = :license.Id];
        System.assertEquals(newOrgName, updatedLicense.TargetOrgName__c, 'OrgName should be updated');
        System.assertNotEquals(null, updatedLicense.lastCheckedAt__c, 'lastCheckedAt should be set');
        System.assertNotEquals(originalLastCheckedAt, updatedLicense.lastCheckedAt__c, 'lastCheckedAt should be updated');
    }
    
    @IsTest
    static void testUpdateOrgNameAndLastChecked_NullOrgName() {
        // Arrange
        OurPackageLicense__c license = [SELECT Id, TargetOrgName__c, lastCheckedAt__c FROM OurPackageLicense__c LIMIT 1];
        String originalOrgName = license.TargetOrgName__c;
        DateTime originalLastCheckedAt = license.lastCheckedAt__c;
        
        // Act
        Test.startTest();
        Boolean result = LicenseDataService.updateOrgNameAndLastChecked(license.Id, null);
        Test.stopTest();
        
        // Assert
        System.assertEquals(true, result, 'Update should succeed even with null OrgName');
        
        OurPackageLicense__c updatedLicense = [SELECT TargetOrgName__c, lastCheckedAt__c FROM OurPackageLicense__c WHERE Id = :license.Id];
        System.assertEquals(originalOrgName, updatedLicense.TargetOrgName__c, 'OrgName should remain unchanged');
        System.assertNotEquals(null, updatedLicense.lastCheckedAt__c, 'lastCheckedAt should be set');
        System.assertNotEquals(originalLastCheckedAt, updatedLicense.lastCheckedAt__c, 'lastCheckedAt should be updated');
    }
    
    @IsTest
    static void testUpdateOrgNameAndLastChecked_NullId() {
        // Act & Assert
        try {
            Test.startTest();
            LicenseDataService.updateOrgNameAndLastChecked(null, 'Test Name');
            Test.stopTest();
            System.assert(false, 'Should have thrown IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('licenseId'), 'Error message should mention licenseId');
        }
    }
}