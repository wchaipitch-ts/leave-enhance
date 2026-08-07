public without sharing class JobApplicationsCtrl {
    @AuraEnabled(cacheable=true)
    public static List<ContentType> getManagedContentByTopicsAndContentKeys() {
        // try {
            String communityId = Network.getNetworkId();
            communityId = [SELECT Id FROM Network LIMIT 1].Id;
            List<ManagedContent> mcList = [SELECT Id, ContentKey, AuthoredManagedContentSpaceId, ApiName, ContentTypeFullyQualifiedName FROM ManagedContent WHERE NOT( ContentTypeFullyQualifiedName LIKE '%sfdc_cms%')];
            List<String> contentIds = new List<String>();
            for(ManagedContent mc : mcList){
                if(mc.ContentTypeFullyQualifiedName == 'Career'){
                    contentIds.add(mc.Id);
                }
            }
            // contentIds.add('20YA2000000SeSMMA0');
            // contentIds.add('20YA2000000SeaPMAS');
            // contentIds.add('20YA2000000SeSLMA0');
            ConnectApi.ManagedContentVersionCollection managedContentVersionCollection = ConnectApi.ManagedContent.getManagedContentByIds(
            communityId,
            contentIds,
            0,
            20,
            'en_US',
            'Career'
        );
            return getCMSContent(managedContentVersionCollection);
        // }catch(Exception e) {
        //     throw new AuraHandledException(e.getMessage());
        // }
    }
    private static List<ContentType> getCMSContent(ConnectApi.ManagedContentVersionCollection managedContentVersionCollection) {
        // try {
            List<ConnectApi.ManagedContentVersion> managedContentVersions = managedContentVersionCollection.items;
            List<ContentType> contentTypes = new List<ContentType>();
            for(ConnectApi.ManagedContentVersion managedContentVersion : managedContentVersions){
                ContentType contentTypeObj = new ContentType();
                contentTypeObj.key = managedContentVersion.contentKey;
                contentTypeObj.title = managedContentVersion.contentNodes.get('Title');
                contentTypeObj.jobDetail = managedContentVersion.contentNodes.get('Job_Detail');
                contentTypeObj.openDate = managedContentVersion.contentNodes.get('Open_Date');
                contentTypeObj.closeDate = managedContentVersion.contentNodes.get('Closed_Date');
                contentTypeObj.workingHours = managedContentVersion.contentNodes.get('Working_Hours');
                contentTypeObj.level = managedContentVersion.contentNodes.get('Level');
                contentTypeObj.highlightDetail = managedContentVersion.contentNodes.get('Short_Detail');
                contentTypeObj.location = managedContentVersion.contentNodes.get('Location');
                contentTypeObj.isActive = managedContentVersion.contentNodes.get('isActive');
                contentTypeObj.publishedDate = managedContentVersion.publishedDate;

                ConnectApi.ManagedContentTextNodeValue isActiveValue = (ConnectApi.ManagedContentTextNodeValue) managedContentVersion.contentNodes.get('isActive');
                ConnectApi.ManagedContentDateNodeValue openDate = (ConnectApi.ManagedContentDateNodeValue) managedContentVersion.contentNodes.get('Open_Date');
                ConnectApi.ManagedContentDateNodeValue closeDate = (ConnectApi.ManagedContentDateNodeValue) managedContentVersion.contentNodes.get('Closed_Date');
                System.debug('isActive : '+isActiveValue.value);
                System.debug('today :'+Date.today());
                System.debug('openDate : '+ Date.valueOf(openDate.value));
                System.debug('closeDate : '+closeDate.value);
                if (Boolean.valueOf(isActiveValue.value) 
                    && openDate.value != null && openDate.value <= Date.today() 
                    && closeDate.value != null && closeDate.value >= Date.today()) {
                    contentTypes.add(contentTypeObj);
                }
            }
            return contentTypes;
        // }catch(Exception e) {
        //     throw new AuraHandledException(e.getMessage());
        // }
    }
    public class ContentType {
        @AuraEnabled public string key {get; set;}
        @AuraEnabled public ConnectApi.ManagedContentNodeValue closeDate {get; set;}
        @AuraEnabled public ConnectApi.ManagedContentNodeValue jobDetail {get; set;}
        @AuraEnabled public ConnectApi.ManagedContentNodeValue openDate {get; set;}
        @AuraEnabled public ConnectApi.ManagedContentNodeValue title {get; set;}
        @AuraEnabled public ConnectApi.ManagedContentNodeValue isActive {get; set;}
        @AuraEnabled public ConnectApi.ManagedContentNodeValue level {get; set;}
        @AuraEnabled public ConnectApi.ManagedContentNodeValue highlightDetail {get; set;}
        @AuraEnabled public ConnectApi.ManagedContentNodeValue location {get; set;}
        @AuraEnabled public ConnectApi.ManagedContentNodeValue workingHours {get; set;}
        @AuraEnabled public Datetime publishedDate {get; set;}
    }
    @AuraEnabled
    public static String uploadFileToSalesforce(String fileName, String base64Data) {
        try {
            // Create a ContentVersion record
            ContentVersion cv = new ContentVersion();
            cv.Title = fileName;
            cv.PathOnClient = fileName;
            cv.VersionData = EncodingUtil.base64Decode(base64Data); // Convert base64 string to binary data
            insert cv;

            // Return the ContentDocumentId associated with the ContentVersion
            return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].ContentDocumentId;
        } catch (Exception e) {
            throw new AuraHandledException('Error uploading file: ' + e.getMessage());
        }
    }
    @AuraEnabled
    public static Id createJobApplication(String applicantName ,String applicantEmail, String applicantPhone, String applicantPositionApplied, String applicantCoverLetter, String applicantEmailLinkedIn) {
        Job_Application__c newJobApp = new Job_Application__c();
        newJobApp.Name = applicantName;
        newJobApp.Email__c = applicantEmail;
        newJobApp.Phone__c = applicantPhone;
        newJobApp.Position_Applied__c = applicantPositionApplied;
        newJobApp.Cover_Letter__c = applicantCoverLetter;
        // newJobApp.LinkedIn_Profile__c = applicantEmailLinkedIn;
        newJobApp.Applicant_Name__c = applicantName;
        insert newJobApp;
        return newJobApp.Id;
        
        
    }
}