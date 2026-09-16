/**
 * The reference token that ties a reply back to its Appointment_Request__c.
 *
 * This is the only durable join between an outbound proposal and whatever the
 * contact sends back, and therefore the only way the reply pipeline knows whose
 * Google Calendar to book. Every rep's proposal leaves from the same Email
 * Service address, so the address cannot identify the rep -- the token can.
 *
 * Both halves of the round trip go through here so the format cannot drift:
 * the sender stamps subjects with tag(), the Email Service handler reads them
 * with extract().
 */
public with sharing class BookingReference {

    /** Matches "[Ref:AR-00012]" tolerantly: any case, stray spaces, any digit count. */
    private static final Pattern REF_PATTERN = Pattern.compile('(?i)\\[\\s*Ref\\s*:\\s*(AR-\\d+)\\s*\\]');

    /** Builds the token to append to an outbound subject. */
    public static String tag(String requestName) {
        if (String.isBlank(requestName)) {
            throw new IllegalArgumentException('requestName is required to build a reference tag');
        }
        return '[Ref:' + requestName.trim().toUpperCase() + ']';
    }

    /**
     * Reads the request name out of a reply subject, surviving whatever the
     * contact's mail client prepends -- "Re:", "Fwd:", "RE: RE:", "Re: 転送:".
     *
     * @return e.g. 'AR-00012', or null when the subject carries no token
     */
    public static String extract(String subject) {
        if (String.isBlank(subject)) {
            return null;
        }
        Matcher m = REF_PATTERN.matcher(subject);
        return m.find() ? m.group(1).toUpperCase() : null;
    }

    /** True when the subject carries a token this org can act on. */
    public static Boolean hasTag(String subject) {
        return extract(subject) != null;
    }
}
