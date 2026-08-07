@IsTest
private class ContentVersionLinkHandlerTest {
    @IsTest
    static void testLinkSuccessAndPartialFailure() {
        // Create a Case to link to
        Case c = new Case(Subject = 'Test Case', Status = 'New', Origin = 'Web');
        insert c;

        // Prepare two ContentVersions: one valid link, one invalid target
        Blob body = Blob.valueOf('unit test');
        ContentVersion goodCv = new ContentVersion(
            Title = 'good-cv',
            PathOnClient = 'good.txt',
            VersionData = body,
            IsMajorVersion = true
        );
        // Set the custom field dynamically to avoid compile dependency issues
        goodCv.put('Guest_Record_fileupload__c', c.Id);

        ContentVersion badCv = new ContentVersion(
            Title = 'bad-cv',
            PathOnClient = 'bad.txt',
            VersionData = body,
            IsMajorVersion = true
        );
        // Non-existent Case-like Id to force a CDL link error
        badCv.put('Guest_Record_fileupload__c', '500000000000000AAA');

        Test.startTest();
        insert new List<ContentVersion>{ goodCv, badCv };
        Test.stopTest();

        // Both ContentVersions should exist
        Map<String, ContentVersion> byTitle = new Map<String, ContentVersion>();
        for (ContentVersion cv : [SELECT Id, Title, ContentDocumentId FROM ContentVersion WHERE Title IN ('good-cv','bad-cv')]) {
            byTitle.put(cv.Title, cv);
        }
        System.assertEquals(true, byTitle.containsKey('good-cv'), 'good CV not found');
        System.assertEquals(true, byTitle.containsKey('bad-cv'), 'bad CV not found');

        Id goodDocId = byTitle.get('good-cv').ContentDocumentId;
        Id badDocId = byTitle.get('bad-cv').ContentDocumentId;
        System.assertNotEquals(null, goodDocId, 'good ContentDocumentId should be set');
        System.assertNotEquals(null, badDocId, 'bad ContentDocumentId should be set');

        // Only the valid one should be linked to the Case
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId, LinkedEntityId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :c.Id
        ];
        System.assertEquals(1, links.size(), 'Exactly one link should be created');
        System.assertEquals(goodDocId, links[0].ContentDocumentId, 'Valid document should be linked');

        // Ensure the bad document was not linked
        for (ContentDocumentLink l : links) {
            System.assertNotEquals(badDocId, l.ContentDocumentId, 'Invalid document should not be linked');
        }
    }
}