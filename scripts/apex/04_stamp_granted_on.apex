/*
 * Backfills Granted_On__c on Leave_Balance__c rows created before that field existed.
 *
 * Why this matters. LeaveManagementController guards every grant on Granted_On__c: a
 * blank value means "not yet granted for this year". The original backfill
 * (03_backfill_leave_balances.apex) predates the field, so every row it created reads
 * as ungranted. The next January 1 run would therefore re-grant the whole year and
 * reset Used_Days__c to zero, silently erasing everyone's consumption.
 *
 * The stamp records when the entitlement was granted, mirroring what the engine itself
 * would have written:
 *
 *   - joined during the leave year  -> their joining date (the new-hire grant)
 *   - joined earlier                -> January 1 of the leave year (the annual grant)
 *   - Refreshment Leave             -> the anniversary IN that year, but ONLY where
 *                                      entitlement was actually granted. Rows still at
 *                                      zero are left blank on purpose so the
 *                                      anniversary grant can still fire.
 *
 * Idempotent: only rows with a blank Granted_On__c are touched.
 */
final String TYPE_REFRESH = 'Refresh Leave';

List<Leave_Balance__c> toStamp = new List<Leave_Balance__c>();
Integer skippedRefresh = 0;

for (Leave_Balance__c bal : [
    SELECT Id, Leave_Type__c, Leave_Year__c, Entitlement_Days__c, Granted_On__c,
           Employee__r.Start_Date__c
    FROM Leave_Balance__c
    WHERE Granted_On__c = NULL AND Employee__r.Start_Date__c != NULL
]) {
    Integer yr = bal.Leave_Year__c.intValue();
    Date started = bal.Employee__r.Start_Date__c;
    Date stamp;

    if (TYPE_REFRESH.equals(bal.Leave_Type__c)) {
        // Ungranted refreshment stays blank so the anniversary grant still runs.
        if (bal.Entitlement_Days__c == null || bal.Entitlement_Days__c <= 0) {
            skippedRefresh++;
            continue;
        }
        // February 29 joiners have no anniversary in a non-leap year; the engine
        // grants them on February 28, so record that date.
        Integer day = started.day();
        if (started.month() == 2 && day == 29 && !Date.isLeapYear(yr)) {
            day = 28;
        }
        stamp = Date.newInstance(yr, started.month(), day);
    } else {
        stamp = (started.year() == yr) ? started : Date.newInstance(yr, 1, 1);
    }

    toStamp.add(new Leave_Balance__c(Id = bal.Id, Granted_On__c = stamp));
}

update toStamp;
System.debug('STAMPED ' + toStamp.size() + ' rows');
System.debug('LEFT BLANK ' + skippedRefresh + ' ungranted Refreshment rows (correct - awaiting anniversary)');
