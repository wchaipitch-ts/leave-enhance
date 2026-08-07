global class EmailActivityCaptureHandler implements Messaging.InboundEmailHandler {
    
    global Messaging.InboundEmailResult handleInboundEmail(Messaging.InboundEmail email, Messaging.InboundEnvelope envelope) {
        // Create the result object that tells Salesforce if the email was processed successfully
        Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();
        
        try {
            system.debug('email>>>>'+email);
            system.debug('envelope>>>>'+envelope);
            // Step 1: Extract core details from the inbound email
            String senderEmail = email.fromAddress;
            String subject = email.subject;
            // Use plainTextBody for simple activity logging. (email.htmlBody is also available)
            String textBody = email.plainTextBody; 
            
            // Step 2: Query Salesforce for a matching Contact
            List<Contact> matchingContacts = [
                SELECT Id 
                FROM Contact 
                WHERE Email = :senderEmail 
                LIMIT 1
            ];
            
            // Step 3: If a Contact exists, log the email as a Task
            if (!matchingContacts.isEmpty()) {
               
               
                System.debug('Activity logged successfully for Contact ID: ' + matchingContacts[0].Id);
            } else {
                // If no contact is found, you can optionally create a Lead here or just ignore it.
                System.debug('No matching Contact found for sender: ' + senderEmail);
                Contact con = new Contact();
                con.Email = senderEmail;
            }
            
            // Mark as successful so Salesforce doesn't bounce the email back to the sender
            result.success = true;
            
        } catch (Exception e) {
            System.debug('Error capturing email activity: ' + e.getMessage());
            // If false, Salesforce sends a bounce message to the sender
            result.success = false; 
        }
        
        return result;
    }
}