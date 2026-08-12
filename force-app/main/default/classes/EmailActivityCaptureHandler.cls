global class EmailActivityCaptureHandler implements Messaging.InboundEmailHandler {
    
    global Messaging.InboundEmailResult handleInboundEmail(Messaging.InboundEmail email, Messaging.InboundEnvelope envelope) {
        // Create the result object that tells Salesforce if the email was processed successfully
        Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();

        String senderFilter = Program_Constant__mdt.getInstance('SenderFilterEmailCreateContact').Value__c;
        String subjectFilter = Program_Constant__mdt.getInstance('SubjectFilterEmail').Value__c;
        List<String> senderFilterList = senderFilter.split(',');
        List<String> subjectFilterList = subjectFilter.split(',');

        try {
            //system.debug('email>>>>'+email);
            //system.debug('envelope>>>>'+envelope);
            // Step 1: Extract core details from the inbound email
            String senderEmail = email.fromAddress;
            String subject = email.subject;
            String senderName = email.fromName;
            // Use plainTextBody for simple activity logging. (email.htmlBody is also available)
            String textBody = email.plainTextBody; 

            List<String> subSenderEmail = senderEmail.split('@');
            List<String> subSenderName = senderName.split(' ');

            if (senderFilterList.contains(subSenderEmail[1])) {
                System.debug('Sender email is in the filter list. Ignoring email from: ' + senderEmail);
                result.success = true; // Mark as successful to avoid bounce
                return result;

            }

            if (subjectFilter.containsIgnoreCase(subject.toUpperCase())) {
                System.debug('Subject is in the filter list. Ignoring email with subject: ' + subject);
                result.success = true; // Mark as successful to avoid bounce
                return result;
            }
            
            // Step 2: Query Salesforce for a matching Account
            List<Account> matchingAccounts = [
                SELECT Id 
                FROM Account 
                WHERE Name LIKE :('%' + subSenderEmail[1] + '%')
                LIMIT 1
            ];
            
            Account acc = new Account();
            // Step 3: If an Account exists, log the email as a Task
            if (!matchingAccounts.isEmpty()) {
               
                System.debug('Activity logged successfully for Account ID: ' + matchingAccounts[0].Id);
                acc = matchingAccounts[0];
            } else {
                // If no account is found, you can optionally create a Lead here or just ignore it.
                System.debug('No matching Account found for sender: ' + subSenderEmail[1]);
                acc = new Account();
                acc.Name = subSenderEmail[1];
                insert acc;

            }

            Contact con = new Contact();
            con.Email = senderEmail;
            con.FirstName = subSenderName[0];
            con.LastName = subSenderName.size() > 1 ? subSenderName[1] : 'Contact';
            con.Title = 'VP';
            con.Department = 'Email';
            con.AccountId = acc.Id;
            insert con;

            system.debug('Contact created successfully for Email: ' + con);
            
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