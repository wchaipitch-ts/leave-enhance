@IsTest
private class BookingEmailTesterTest {

    @IsTest
    static void sendsWithReplyToAndReferenceInSubject() {
        String result;

        Test.startTest();
        result = BookingEmailTester.sendTestEmail('chaipitch6@gmail.com', 'booking@example.apex.salesforce.com');
        // Emails are not really sent in tests; Apex only records the invocation.
        System.assertEquals(1, Limits.getEmailInvocations(), 'One send attempt');
        Test.stopTest();

        System.assert(result.contains('chaipitch6@gmail.com'), 'Result names the recipient: ' + result);
        System.assert(result.contains('booking@example.apex.salesforce.com'), 'Result names the Reply-To: ' + result);
    }

    @IsTest
    static void rejectsMissingRecipient() {
        try {
            BookingEmailTester.sendTestEmail('', 'booking@example.apex.salesforce.com');
            System.assert(false, 'Expected an exception for a blank recipient');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('toAddress'), e.getMessage());
        }
    }

    @IsTest
    static void rejectsMissingReplyTo() {
        try {
            BookingEmailTester.sendTestEmail('chaipitch6@gmail.com', null);
            System.assert(false, 'Expected an exception for a blank Reply-To');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('replyToAddress'), e.getMessage());
        }
    }
}
