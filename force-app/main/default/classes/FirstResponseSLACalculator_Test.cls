@isTest
private class FirstResponseSLACalculator_Test {

    @TestSetup
    static void setupTestData() {
        // Create test Case records
        List<Case> testCases = new List<Case>();
        testCases.add(new Case(
            Subject = 'Urgent Case Test',
            Status = 'New',
            Priority = 'Urgent'
            //CreatedDate = Datetime.newInstance(2025, 8, 6, 12, 0, 0) // Wednesday, 12:00
        ));
        testCases.add(new Case(
            Subject = 'Standard Case Test',
            Status = 'New',
            Priority = 'Other'
            //CreatedDate = Datetime.newInstance(2025, 8, 6, 12, 0, 0) // Wednesday, 12:00
        ));
        insert testCases;
    }

    @isTest
    static void testCalculateDueDateHappyPath() {
        // Fetch the default BusinessHours record for assertion logic.
        BusinessHours bh = [SELECT Id FROM BusinessHours WHERE IsDefault = true LIMIT 1];
        
        // Fetch test case IDs
        List<Case> cases = [SELECT Id FROM Case WHERE Subject LIKE '%Test%'];
        List<Id> caseIds = new List<Id>();
        for (Case c : cases) {
            caseIds.add(c.Id);
        }

        Test.startTest();

        FirstResponseSLACalculator.calculateFirstResponseDueDate(caseIds);

        Test.stopTest();

        List<Case> updatedCases = [SELECT Id, Priority, CreatedDate, First_Response_Due_Date__c FROM Case WHERE Id IN :caseIds ORDER BY Priority];
        
        for (Case c : updatedCases) {
            System.assertNotEquals(null, c.First_Response_Due_Date__c, 'Due date should have been calculated and not be null.');

            if (c.Priority == 'Urgent') {
                // Assert Urgent Case due date with continuous clock (addHours)
                Datetime expectedDueDate = c.CreatedDate.addHours(3);
                System.assertEquals(expectedDueDate, c.First_Response_Due_Date__c, 'Urgent case due date should be 3 hours later.');
            } else {
                // Assert Standard Case due date with business hours clock
                Datetime expectedDueDate = BusinessHours.add(bh.Id, c.CreatedDate, 48 * 60 * 60 * 1000L);
                System.assertEquals(expectedDueDate, c.First_Response_Due_Date__c, 'Standard case due date should be 48 hours later.');
            }
        }
    }
}