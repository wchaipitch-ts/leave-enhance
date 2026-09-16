/**
 * Step 1 harness for the appointment booking POC: send one outbound email that
 * a human can reply to, with Reply-To pointed at the Email Service address so
 * BookingInboundEmailHandler catches the answer.
 *
 * Run from Anonymous Apex, not from a trigger or Flow. This is scaffolding for
 * proving the round trip, not part of the real send path (EmailSender).
 *
 * The Reply-To is the one Email Service address for the whole org, the same for
 * every rep. Rep identity travels in the subject token, not in the address, so
 * this does not need one inbound address per rep.
 */
public with sharing class BookingEmailTester {

    /** Reference code stamped into the subject so the reply can be tied back. */
    public static final String TEST_REFERENCE = 'AR-00001';

    /**
     * @param toAddress      external mailbox that will reply, e.g. a Gmail address
     * @param replyToAddress the Email Service address (…@…apex.salesforce.com)
     * @return a one-line summary for the debug log
     */
    public static String sendTestEmail(String toAddress, String replyToAddress) {
        if (String.isBlank(toAddress)) {
            throw new IllegalArgumentException('toAddress is required');
        }
        if (String.isBlank(replyToAddress)) {
            throw new IllegalArgumentException('replyToAddress is required: use the Email Service address so the reply comes back to Salesforce');
        }

        User me = [SELECT Id, Name, Email FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];

        Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
        msg.setToAddresses(new List<String>{ toAddress });
        // Same builder the handler parses with, so the two halves cannot drift.
        msg.setSubject('Booking POC round-trip test ' + BookingReference.tag(TEST_REFERENCE));
        msg.setPlainTextBody(buildBody(me.Name));
        msg.setReplyTo(replyToAddress);
        msg.setSenderDisplayName(me.Name);
        msg.setSaveAsActivity(false);
        msg.setUseSignature(false);

        List<Messaging.SendEmailResult> results = Messaging.sendEmail(
            new List<Messaging.SingleEmailMessage>{ msg },
            false // allOrNone = false: report the failure instead of throwing
        );

        Messaging.SendEmailResult r = results[0];
        if (r.isSuccess()) {
            return 'Sent to ' + toAddress + ' from ' + me.Email + ', Reply-To ' + replyToAddress;
        }

        List<String> problems = new List<String>();
        for (Messaging.SendEmailError err : r.getErrors()) {
            problems.add(err.getStatusCode() + ': ' + err.getMessage());
        }
        return 'FAILED to send to ' + toAddress + ' -- ' + String.join(problems, ' | ');
    }

    private static String buildBody(String repName) {
        return String.join(new List<String>{
            'Hi,',
            '',
            'This is an automated test from the appointment booking POC.',
            'Please reply to this message with any text, for example "Option 2 works for me".',
            '',
            'Keep the subject line as is so the reference code survives the round trip.',
            '',
            'Best regards,',
            repName
        }, '\n');
    }
}
