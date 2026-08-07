@isTest
public class JobApplicationsCtrlTest {
    @IsTest(SeeAllData=true)
    static void testGetManagedContentByTopicsAndContentKeys() {
        Test.startTest();
        List<JobApplicationsCtrl.ContentType> contentList = JobApplicationsCtrl.getManagedContentByTopicsAndContentKeys();
        Test.stopTest();
        
    }

    @isTest
    static void testUploadFileToSalesforce() {
        String fileName = 'testFile.txt';
        String base64Data = EncodingUtil.base64Encode(Blob.valueOf('Sample file content'));
        
        Test.startTest();
        String contentDocumentId = JobApplicationsCtrl.uploadFileToSalesforce(fileName, base64Data);
        Test.stopTest();
        
    }

    @isTest
    static void testCreateJobApplication() {
        String applicantName = 'Test Applicant';
        String applicantEmail = 'test@example.com';
        String applicantPhone = '1234567890';
        String applicantPositionApplied = 'Software Engineer';
        String applicantCoverLetter = 'This is a cover letter.';
        String applicantEmailLinkedIn = 'linkedin.com/test';
        
        Test.startTest();
        Id jobAppId = JobApplicationsCtrl.createJobApplication(applicantName, applicantEmail, applicantPhone, applicantPositionApplied, applicantCoverLetter, applicantEmailLinkedIn);
        Test.stopTest();
        Job_Application__c jobApp = [SELECT Id, Name FROM Job_Application__c WHERE Id = :jobAppId];
    }
}