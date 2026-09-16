@IsTest
private class BookingReferenceTest {

    @IsTest
    static void buildsTag() {
        System.assertEquals('[Ref:AR-00012]', BookingReference.tag('AR-00012'));
        System.assertEquals('[Ref:AR-00012]', BookingReference.tag('  ar-00012 '), 'Normalized to upper case');
    }

    @IsTest
    static void rejectsBlankRequestName() {
        try {
            BookingReference.tag('  ');
            System.assert(false, 'Expected an exception');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('requestName'), e.getMessage());
        }
    }

    @IsTest
    static void survivesWhateverMailClientsPrepend() {
        Map<String, String> subjects = new Map<String, String>{
            'Meeting request [Ref:AR-00012]'                => 'AR-00012',
            'Re: Meeting request [Ref:AR-00012]'             => 'AR-00012',
            'RE: RE: Fwd: Meeting request [Ref:AR-00012]'    => 'AR-00012',
            '転送: Meeting request [Ref:AR-00012]'            => 'AR-00012',
            'Meeting request [ref: ar-00012 ]'               => 'AR-00012',
            'Meeting request [Ref:AR-7]'                     => 'AR-7',
            'Automatic reply: Meeting request [Ref:AR-99999]' => 'AR-99999'
        };
        for (String subject : subjects.keySet()) {
            System.assertEquals(subjects.get(subject), BookingReference.extract(subject), 'Subject: ' + subject);
        }
    }

    @IsTest
    static void returnsNullWhenNoTokenPresent() {
        for (String subject : new List<String>{ null, '', 'Meeting request', 'Ref:AR-00012 without brackets', '[Ref:XX-00012]' }) {
            System.assertEquals(null, BookingReference.extract(subject), 'Subject: ' + subject);
            System.assertEquals(false, BookingReference.hasTag(subject), 'Subject: ' + subject);
        }
    }

    @IsTest
    static void roundTripsWhatTheSenderStamped() {
        String subject = 'Meeting request: Acme ' + BookingReference.tag('AR-04242');
        System.assertEquals('AR-04242', BookingReference.extract('Re: ' + subject));
        System.assertEquals(true, BookingReference.hasTag(subject));
    }
}
