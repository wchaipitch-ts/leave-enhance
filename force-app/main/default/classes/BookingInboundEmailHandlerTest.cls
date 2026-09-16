@IsTest
private class BookingInboundEmailHandlerTest {

    private static Messaging.InboundEmail.Header header(String name, String value) {
        Messaging.InboundEmail.Header h = new Messaging.InboundEmail.Header();
        h.name = name;
        h.value = value;
        return h;
    }

    private static Messaging.InboundEmail buildEmail() {
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'chaipitch6@gmail.com';
        email.fromName = 'Chaipitch W';
        email.subject = 'Re: Booking POC round-trip test [Ref:AR-00001]';
        email.plainTextBody = 'Option 2 works for me.\n\nOn Tue, someone wrote:\n> original';
        email.htmlBody = '<p>Option 2 works for me.</p>';
        email.headers = new List<Messaging.InboundEmail.Header>{
            header('Message-ID', '<abc123@mail.gmail.com>'),
            header('In-Reply-To', '<orig456@salesforce.com>')
        };
        return email;
    }

    private static Messaging.InboundEnvelope buildEnvelope() {
        Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();
        env.fromAddress = 'chaipitch6@gmail.com';
        env.toAddress = 'booking@example.apex.salesforce.com';
        return env;
    }

    @IsTest
    static void capturesReplyIntoLog() {
        Messaging.InboundEmailResult result;

        Test.startTest();
        result = new BookingInboundEmailHandler().handleInboundEmail(buildEmail(), buildEnvelope());
        Test.stopTest();

        System.assertEquals(true, result.success, 'Handler must never bounce the reply');

        Inbound_Email_Log__c log = [
            SELECT From_Address__c, From_Name__c, To_Address__c, Subject__c, Body_Plain__c,
                   Body_Html__c, Headers__c, Message_Id__c, In_Reply_To__c,
                   Reference_Code__c, Is_Auto_Reply__c, Received_At__c
            FROM Inbound_Email_Log__c
            LIMIT 1
        ];
        System.assertEquals('chaipitch6@gmail.com', log.From_Address__c);
        System.assertEquals('Chaipitch W', log.From_Name__c);
        System.assertEquals('booking@example.apex.salesforce.com', log.To_Address__c);
        System.assertEquals('AR-00001', log.Reference_Code__c, 'Reference code must survive the round trip');
        System.assertEquals('<abc123@mail.gmail.com>', log.Message_Id__c);
        System.assertEquals('<orig456@salesforce.com>', log.In_Reply_To__c);
        System.assertEquals(false, log.Is_Auto_Reply__c);
        System.assert(log.Body_Plain__c.contains('Option 2 works for me'), 'Plain body kept verbatim');
        System.assert(log.Headers__c.contains('Message-ID'), 'Headers flattened for debugging');
        System.assertNotEquals(null, log.Received_At__c);
    }

    @IsTest
    static void capturesEmailWithNoSubjectOrHeaders() {
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.fromAddress = 'someone@example.com';
        email.plainTextBody = 'no subject here';

        Test.startTest();
        Messaging.InboundEmailResult result =
            new BookingInboundEmailHandler().handleInboundEmail(email, null);
        Test.stopTest();

        System.assertEquals(true, result.success);
        Inbound_Email_Log__c log = [SELECT Reference_Code__c, Subject__c, To_Address__c, Headers__c FROM Inbound_Email_Log__c LIMIT 1];
        System.assertEquals(null, log.Reference_Code__c);
        System.assertEquals(null, log.Subject__c);
        System.assertEquals(null, log.To_Address__c);
        System.assertEquals(null, log.Headers__c);
    }

    @IsTest
    static void flagsAutoReplyHeaders() {
        Map<String, String> autoHeaders = new Map<String, String>{
            'Auto-Submitted' => 'auto-replied',
            'X-Autoreply' => 'yes',
            'X-Autorespond' => 'yes',
            'Precedence' => 'auto_reply'
        };

        for (String name : autoHeaders.keySet()) {
            Messaging.InboundEmail email = buildEmail();
            email.headers = new List<Messaging.InboundEmail.Header>{ header(name, autoHeaders.get(name)) };

            Messaging.InboundEmailResult result =
                new BookingInboundEmailHandler().handleInboundEmail(email, buildEnvelope());
            System.assertEquals(true, result.success);
        }

        for (Inbound_Email_Log__c log : [SELECT Is_Auto_Reply__c FROM Inbound_Email_Log__c]) {
            System.assertEquals(true, log.Is_Auto_Reply__c, 'Every auto-reply header must be flagged');
        }
        System.assertEquals(autoHeaders.size(), [SELECT COUNT() FROM Inbound_Email_Log__c]);
    }

    @IsTest
    static void treatsAutoSubmittedNoAsHumanReply() {
        Messaging.InboundEmail email = buildEmail();
        email.headers = new List<Messaging.InboundEmail.Header>{ header('Auto-Submitted', 'no') };

        new BookingInboundEmailHandler().handleInboundEmail(email, buildEnvelope());

        System.assertEquals(false, [SELECT Is_Auto_Reply__c FROM Inbound_Email_Log__c LIMIT 1].Is_Auto_Reply__c);
    }

    @IsTest
    static void truncatesOversizedFields() {
        Messaging.InboundEmail email = buildEmail();
        email.subject = 'x'.repeat(400) + ' [Ref:AR-00001]';

        new BookingInboundEmailHandler().handleInboundEmail(email, buildEnvelope());

        Inbound_Email_Log__c log = [SELECT Subject__c, Reference_Code__c FROM Inbound_Email_Log__c LIMIT 1];
        System.assertEquals(255, log.Subject__c.length(), 'Subject trimmed to field length');
        System.assertEquals('AR-00001', log.Reference_Code__c, 'Reference read from the full subject, not the trimmed one');
    }
}
