/**
 * Email Service handler: the front door for every reply a contact sends.
 *
 * It does one job -- write the message down -- and deliberately does no
 * matching, no cleaning and no Gemini call. Three reasons, all of which bite
 * once this is carrying real rep traffic:
 *
 *  - Apex cannot call out after uncommitted DML, and classification is a
 *    callout. Capture and classify must be separate transactions regardless.
 *  - An exception escaping an Email Service bounces the contact's mail back at
 *    them. The less that runs here, the less can bounce a real customer reply.
 *  - Salesforce may redeliver the same message. Capture is cheap to repeat;
 *    booking a calendar slot is not.
 *
 * So this writes an Inbound_Email_Log__c with Processing_Status__c = Received,
 * which is the work queue the classification job drains. Whose calendar gets
 * booked is decided from Reference_Code__c downstream, never here.
 */
global with sharing class BookingInboundEmailHandler implements Messaging.InboundEmailHandler {

    /** Long Text Area ceiling. Bodies past this are cut and flagged. */
    @TestVisible
    private static final Integer LONG_TEXT_MAX = 131072;

    private static final Integer TEXT_MAX = 255;

    global Messaging.InboundEmailResult handleInboundEmail(
        Messaging.InboundEmail email,
        Messaging.InboundEnvelope envelope
    ) {
        Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();
        result.success = true;

        try {
            Inbound_Email_Log__c log = buildLog(email, envelope);

            if (alreadyCaptured(log.Message_Id__c)) {
                // Redelivery. The first capture keeps its place in the queue and
                // its processing state; re-inserting would classify it twice.
                System.debug(LoggingLevel.WARN, 'Duplicate inbound message ignored: ' + log.Message_Id__c);
                return result;
            }
            insert log;

        } catch (Exception e) {
            // Losing the reply entirely is worse than losing its detail, so fall
            // back to a skeleton row that says a reply arrived and why it failed.
            captureFailure(email, e);
        }
        return result;
    }

    @TestVisible
    private static Inbound_Email_Log__c buildLog(Messaging.InboundEmail email, Messaging.InboundEnvelope envelope) {
        String plain = email.plainTextBody;
        String html = email.htmlBody;
        Boolean truncated = tooLong(plain) || tooLong(html);
        Boolean autoReply = isAutoReply(email.headers);
        Boolean empty = String.isBlank(plain) && String.isBlank(html);

        return new Inbound_Email_Log__c(
            From_Address__c      = normalizeAddress(email.fromAddress),
            From_Name__c         = truncate(email.fromName, TEXT_MAX),
            To_Address__c        = normalizeAddress(envelope == null ? null : envelope.toAddress),
            Subject__c           = truncate(email.subject, TEXT_MAX),
            Body_Plain__c        = truncate(plain, LONG_TEXT_MAX),
            Body_Html__c         = truncate(html, LONG_TEXT_MAX),
            Body_Truncated__c    = truncated,
            Headers__c           = truncate(flattenHeaders(email.headers), LONG_TEXT_MAX),
            Received_At__c       = System.now(),
            Message_Id__c        = truncate(headerValue(email.headers, 'Message-ID'), TEXT_MAX),
            In_Reply_To__c       = truncate(headerValue(email.headers, 'In-Reply-To'), TEXT_MAX),
            Reference_Code__c    = BookingReference.extract(email.subject),
            Is_Auto_Reply__c     = autoReply,
            // Spec section 9: header-flagged automation and empty bodies are
            // logged only. Filtering them here keeps them out of the Gemini
            // queue instead of paying for a classification that cannot be acted on.
            Processing_Status__c = (autoReply || empty) ? 'Ignored' : 'Received'
        );
    }

    /**
     * Message-ID is unique on the object, so this is belt and braces -- but it
     * turns a redelivery into a debug line instead of a DUPLICATE_VALUE that
     * would drop us into the failure path.
     */
    private static Boolean alreadyCaptured(String messageId) {
        if (String.isBlank(messageId)) {
            return false;
        }
        return ![SELECT Id FROM Inbound_Email_Log__c WHERE Message_Id__c = :messageId LIMIT 1].isEmpty();
    }

    private static void captureFailure(Messaging.InboundEmail email, Exception e) {
        String detail = e.getMessage() + '\n' + e.getStackTraceString();
        System.debug(LoggingLevel.ERROR, 'Inbound email capture failed: ' + detail);
        try {
            insert new Inbound_Email_Log__c(
                From_Address__c      = normalizeAddress(email == null ? null : email.fromAddress),
                Subject__c           = truncate(email == null ? null : email.subject, TEXT_MAX),
                Received_At__c       = System.now(),
                Processing_Status__c = 'Failed',
                Processing_Error__c  = truncate(detail, LONG_TEXT_MAX)
            );
        } catch (Exception nested) {
            System.debug(LoggingLevel.ERROR, 'Fallback capture also failed: ' + nested.getMessage());
        }
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

    /** Lower-cased and trimmed, so matching a reply to a Contact by address is a plain equality test. */
    private static String normalizeAddress(String address) {
        return String.isBlank(address) ? null : truncate(address.trim().toLowerCase(), TEXT_MAX);
    }

    private static Boolean tooLong(String value) {
        return value != null && value.length() > LONG_TEXT_MAX;
    }

    private static String truncate(String value, Integer max) {
        if (String.isBlank(value)) {
            return null;
        }
        return value.length() > max ? value.substring(0, max) : value;
    }
}
