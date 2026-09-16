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

    @IsTest
    static void sendsThroughAnOrgWideEmailAddressWhenGivenOne() {
        // IsAllowAllProfiles matters: an OWEA is usable only by permitted
        // profiles, and a restricted one fails with INSUFFICIENT_ACCESS_OR_READONLY.
        // The thank-you email's run-as user has to clear this same gate.
        List<OrgWideEmailAddress> owea = [
            SELECT Id FROM OrgWideEmailAddress
            WHERE IsVerified = true AND IsAllowAllProfiles = true
            LIMIT 1
        ];
        if (owea.isEmpty()) {
            return; // org has none this profile may use; nothing to assert
        }
        String result;

        Test.startTest();
        result = BookingEmailTester.sendTestEmail(
            'chaipitch6@gmail.com',
            'booking@example.apex.salesforce.com',
            owea[0].Id
        );
        System.assertEquals(1, Limits.getEmailInvocations());
        Test.stopTest();

        System.assert(!result.startsWith('FAILED'), 'Send must succeed through a permitted OWEA: ' + result);
        System.assert(result.contains('OWEA'), 'Result names the sending identity: ' + result);
        System.assert(result.contains(owea[0].Id), result);
    }
}
