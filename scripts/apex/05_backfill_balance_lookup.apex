/*
 * Backfills ApplicationItem__c.Leave_Balance__c on requests approved before the field
 *
 * The lookup is what gives each Leave_Balance__c record its related list of the
 * requests that consumed it. Going forward, deductLeaveBalance stamps it at the moment
 * of approval; this fills in the history so the related lists are not misleadingly
 * empty for anything approved earlier.
 *
 * Matches on exactly the key the deduction uses - owner, leave type, and the year of
 * Term_From__c - so a backfilled link and a stamped one always mean the same thing.
 *
 * Only Approved requests are linked. A pending request has consumed nothing, and
 * showing it against a balance would overstate what has actually been drawn down.
 *
 * Idempotent: only rows with a blank lookup are touched.
 */
Map<String, Id> balanceByKey = new Map<String, Id>();
for (Leave_Balance__c bal : [SELECT Id, External_Key__c FROM Leave_Balance__c
                             WHERE External_Key__c != NULL]) {
    balanceByKey.put(bal.External_Key__c, bal.Id);
}

List<ApplicationItem__c> toLink = new List<ApplicationItem__c>();
Integer noBalance = 0;

for (ApplicationItem__c appl : [
    SELECT Id, OwnerId, Request_Type__c, Term_From__c
    FROM ApplicationItem__c
    WHERE Leave_Balance__c = NULL
      AND Status__c = 'Approved'
      AND Term_From__c != NULL
      AND Request_Type__c != NULL
      AND RecordType.DeveloperName != 'Overtime_Request'
]) {
    Id balanceId = balanceByKey.get(
        appl.OwnerId + '-' + appl.Request_Type__c + '-' + appl.Term_From__c.year());
    if (balanceId == null) {
        // A type that keeps no balance, or a year never granted. Nothing to point at.
        noBalance++;
        continue;
    }
    toLink.add(new ApplicationItem__c(Id = appl.Id, Leave_Balance__c = balanceId));
}

update toLink;
System.debug('LINKED ' + toLink.size() + ' approved requests to their balance row');
System.debug('NO MATCHING BALANCE for ' + noBalance + ' (expected for non-balance leave types)');
