public with sharing class ApplicationItemNumberServiceHandler { // <-- FIXED: Added the missing '{' here
    
    // Method to handle the auto-number generation logic based on Record Type.
    // INPUT: newList - A list of ApplicationItem__c records in the 'before insert' trigger context.
    public static void processAutoNumber(List<ApplicationItem__c> newList) {
        
        // Retrieve Record Type IDs dynamically from the schema to avoid SOQL queries.
        // Using DeveloperName is a best practice because it remains constant across sandbox and production.
        Id leaveReqRtId = Schema.SObjectType.ApplicationItem__c.getRecordTypeInfosByDeveloperName().get('Leave_Request').getRecordTypeId();
        Id overtimeReqRtId = Schema.SObjectType.ApplicationItem__c.getRecordTypeInfosByDeveloperName().get('Overtime_Request').getRecordTypeId();

        // Create empty lists to separate records by their Record Type.
        List<ApplicationItem__c> leaveRequests = new List<ApplicationItem__c>();
        List<ApplicationItem__c> overtimeRequests = new List<ApplicationItem__c>();

        // Loop through the incoming records and distribute them into the correct list.
        for (ApplicationItem__c item : newList) {
            if (item.RecordTypeId == leaveReqRtId) {
                leaveRequests.add(item);
            } else if (item.RecordTypeId == overtimeReqRtId) {
                overtimeRequests.add(item);
            }
        }

        // Call the helper method to generate numbers only if the list is not empty.
        if (!leaveRequests.isEmpty()) {
            generateNumber(leaveRequests, 'LR');
        }

        if (!overtimeRequests.isEmpty()) {
            generateNumber(overtimeRequests, 'OR');
        }
    }

    // Helper method to query the latest sequence number from the database and assign new numbers.
    // INPUT: records - List of records needing auto-numbers.
    // INPUT: prefix - The string prefix (e.g., 'LR' or 'OR') used to find and format the number.
    private static void generateNumber(List<ApplicationItem__c> records, String prefix) {
        // Construct the search string for the LIKE operator in SOQL (e.g., 'LR-%').
        String likePattern = prefix + '-%';
        Integer nextNumber = 1;

        // Query the database to find the single most recent record matching the prefix.
        // LIMIT 1 and ORDER BY Name DESC ensures we only get the highest number.
        List<ApplicationItem__c> latestItems = [
            SELECT Name 
            FROM ApplicationItem__c 
            WHERE Name LIKE :likePattern 
            ORDER BY Name DESC 
            LIMIT 1
        ];

        // If we found an existing record, extract its number to determine the next sequence.
        if (!latestItems.isEmpty() && latestItems[0].Name != null) {
            try {
                // Split the string into two parts. Example 'LR-00005' becomes parts[0]='LR', parts[1]='00005'
                List<String> parts = latestItems[0].Name.split('-');
                if (parts.size() == 2) {
                    // Convert the string number to an Integer and add 1
                    nextNumber = Integer.valueOf(parts[1]) + 1;
                }
            } catch (Exception e) {
                // If the old data is not a valid number, we catch the error so the code doesn't crash.
                // It will just default back to nextNumber = 1.
                System.debug('Failed to parse the latest auto-number. Starting from 1. Error: ' + e.getMessage());
            }
        }

        // Iterate through the records currently being saved and assign the newly calculated names.
        for (ApplicationItem__c item : records) {
            // Convert the integer back to a string and pad it with zeros up to 5 characters (e.g., '1' -> '00001').
            item.Name = prefix + '-' + String.valueOf(nextNumber).leftPad(5, '0');
            // Increment the counter for the next record in the loop (crucial for bulk inserts).
            nextNumber++;
        }
    }
}