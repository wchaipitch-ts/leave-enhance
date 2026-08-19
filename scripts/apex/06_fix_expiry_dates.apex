/*
 * 06 — corrects expiry dates that script 03 copied from the User fields.
 *
 * Script 03 seeds a balance row from the frozen User leave fields, and for two
 * dates it copied them verbatim instead of deriving them the way the grant engine
 * does. Both were observed wrong in dev5:
 *
 *     Carry_Over_Expiry__c   2027-06-30  should be 30 June of the balance year
 *     Expiry_Date__c         2027-04-15  should be Granted_On__c + the grant window
 *
 * Neither is visible until something lapses. Both mean days that should expire
 * simply do not: carry over survives past 30 June and a refreshment window stays
 * open for a year instead of a month, and the balance page shows them as available
 * the whole time.
 *
 * Rows created by LeaveManagementController are already right, so this only
 * rewrites where the stored value disagrees with the derived one. Idempotent —
 * a second run finds nothing.
 *
 * DRY RUN by default. Set APPLY to true to write.
 */

Boolean APPLY = false;

Map<Decimal, Decimal> windowByYears = new Map<Decimal, Decimal>();
for (Refresh_Leave_Rule__mdt r : [
    SELECT Years_of_Service__c, Grant_Window_Months__c FROM Refresh_Leave_Rule__mdt
    WHERE Active__c = TRUE
]) {
    windowByYears.put(r.Years_of_Service__c,
        r.Grant_Window_Months__c == null ? 1 : r.Grant_Window_Months__c);
}
// Every configured rule uses the same window today; take it as the default rather
// than re-deriving each employee's tier, which the grant already decided.
Integer defaultWindow = windowByYears.isEmpty()
    ? 1 : (Integer) windowByYears.values()[0];

List<Leave_Balance__c> toFix = new List<Leave_Balance__c>();
Integer checked = 0;

for (Leave_Balance__c b : [
    SELECT Id, Employee__r.Name, Leave_Type__c, Leave_Year__c, Granted_On__c,
           Carry_Over_Days__c, Carry_Over_Expiry__c, Expiry_Date__c
    FROM Leave_Balance__c
    WHERE Carry_Over_Expiry__c != NULL OR Expiry_Date__c != NULL
]) {
    checked++;
    Boolean changed = false;
    Leave_Balance__c fix = new Leave_Balance__c(Id = b.Id);

    if (b.Carry_Over_Expiry__c != null && b.Leave_Year__c != null) {
        Date correct = Date.newInstance(b.Leave_Year__c.intValue(), 6, 30);
        if (b.Carry_Over_Expiry__c != correct) {
            System.debug('CARRY  ' + b.Employee__r.Name + ' ' + b.Leave_Type__c
                + ' ' + b.Leave_Year__c + ': ' + b.Carry_Over_Expiry__c + ' -> ' + correct);
            fix.Carry_Over_Expiry__c = correct;
            changed = true;
        }
    }

    if (b.Expiry_Date__c != null && b.Granted_On__c != null) {
        Date correct = b.Granted_On__c.addMonths(defaultWindow);
        if (b.Expiry_Date__c != correct) {
            System.debug('WINDOW ' + b.Employee__r.Name + ' ' + b.Leave_Type__c
                + ' ' + b.Leave_Year__c + ': ' + b.Expiry_Date__c + ' -> ' + correct
                + ' (granted ' + b.Granted_On__c + ' + ' + defaultWindow + 'm)');
            fix.Expiry_Date__c = correct;
            changed = true;
        }
    }

    if (changed) toFix.add(fix);
}

System.debug('--------------------------------------');
System.debug('rows with an expiry date : ' + checked);
System.debug('rows needing correction  : ' + toFix.size());

if (!APPLY) {
    System.debug('DRY RUN — nothing written. Set APPLY = true to apply.');
} else if (toFix.isEmpty()) {
    System.debug('nothing to do.');
} else {
    update toFix;
    System.debug('corrected ' + toFix.size() + ' row(s).');
}
