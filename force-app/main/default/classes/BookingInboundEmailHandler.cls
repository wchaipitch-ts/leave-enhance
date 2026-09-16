/**
 * Email Service handler for the appointment booking POC.
 *
 * Step 1 of the POC only proves the plumbing: an email the org sends out comes
 * back as a reply and Salesforce can see it. So this handler does one thing --
 * write everything it received to Inbound_Email_Log__c. Matching a reply to an
 * Appointment_Request__c and calling Gemini come later (BookingReplyHandler in
 * the spec); nothing here should grow into that.
 *
 * It never throws and always reports success, because an exception out of an
 * Email Service bounces the message back to the sender.
 */
global with sharing class BookingInboundEmailHandler implements Messaging.InboundEmailHandler {

    @TestVisible
    private static final Pattern REF_PATTERN = Pattern.compile('(?i)\\[Ref:\\s*(AR-\\d+)\\s*\\]');

    global Messaging.InboundEmailResult handleInboundEmail(
        Messaging.InboundEmail email,
        Messaging.InboundEnvelope envelope
    ) {
        Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();
        result.success = true;

        try {
            insert buildLog(email, envelope);
        } catch (Exception e) {
            // Losing the log is better than bouncing the contact's reply.
            System.debug(LoggingLevel.ERROR, 'Inbound email capture failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
        return result;
    }

    @TestVisible
    private static Inbound_Email_Log__c buildLog(Messaging.InboundEmail email, Messaging.InboundEnvelope envelope) {
        String headerText = flattenHeaders(email.headers);

        return new Inbound_Email_Log__c(
            From_Address__c   = truncate(email.fromAddress, 255),
            From_Name__c      = truncate(email.fromName, 255),
            To_Address__c     = truncate(envelope == null ? null : envelope.toAddress, 255),
            Subject__c        = truncate(email.subject, 255),
            Body_Plain__c     = truncate(email.plainTextBody, 131072),
            Body_Html__c      = truncate(email.htmlBody, 131072),
            Headers__c        = truncate(headerText, 131072),
            Received_At__c    = System.now(),
            Message_Id__c     = truncate(headerValue(email.headers, 'Message-ID'), 255),
            In_Reply_To__c    = truncate(headerValue(email.headers, 'In-Reply-To'), 255),
            Reference_Code__c = extractReference(email.subject),
            Is_Auto_Reply__c  = isAutoReply(email.headers)
        );
    }

    /** Pulls AR-00012 out of a subject like "Re: Meeting request [Ref:AR-00012]". */
    @TestVisible
    private static String extractReference(String subject) {
        if (String.isBlank(subject)) {
            return null;
        }
        Matcher m = REF_PATTERN.matcher(subject);
        return m.find() ? m.group(1).toUpperCase() : null;
    }

    /** Auto-reply headers per POC spec section 9. */
    @TestVisible
    private static Boolean isAutoReply(List<Messaging.InboundEmail.Header> headers) {
        if (headers == null) {
            return false;
        }
        for (Messaging.InboundEmail.Header h : headers) {
            String name = h.name == null ? '' : h.name.toLowerCase();
            String value = h.value == null ? '' : h.value.trim().toLowerCase();

            if (name == 'auto-submitted' && value != 'no') {
                return true;
            }
            if (name == 'x-autoreply' || name == 'x-autorespond') {
                return true;
            }
            if (name == 'precedence' && (value == 'auto_reply' || value == 'bulk' || value == 'junk')) {
                return true;
            }
        }
        return false;
    }

    private static String headerValue(List<Messaging.InboundEmail.Header> headers, String wanted) {
        if (headers == null) {
            return null;
        }
        for (Messaging.InboundEmail.Header h : headers) {
            if (h.name != null && h.name.equalsIgnoreCase(wanted)) {
                return h.value;
            }
        }
        return null;
    }

    private static String flattenHeaders(List<Messaging.InboundEmail.Header> headers) {
        if (headers == null || headers.isEmpty()) {
            return null;
        }
        List<String> lines = new List<String>();
        for (Messaging.InboundEmail.Header h : headers) {
            lines.add(h.name + ': ' + h.value);
        }
        return String.join(lines, '\n');
    }

    private static String truncate(String value, Integer max) {
        if (String.isBlank(value)) {
            return null;
        }
        return value.length() > max ? value.substring(0, max) : value;
    }
}
