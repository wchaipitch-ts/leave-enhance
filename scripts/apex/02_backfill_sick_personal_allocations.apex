// P0-1: standardise sick and personal entitlements.
// Fills nulls only - does not clobber any deliberately different value.
List<User> toUpdate = new List<User>();
for (User u : [SELECT Id, Name, Sick_Leave_Allocated__c, Personal_Leave_Allocated__c
               FROM User WHERE IsActive = TRUE AND Start_Date__c != NULL]) {
    Boolean changed = false;
    if (u.Sick_Leave_Allocated__c == null)     { u.Sick_Leave_Allocated__c = 30; changed = true; }
    if (u.Personal_Leave_Allocated__c == null) { u.Personal_Leave_Allocated__c = 3; changed = true; }
    if (changed) { toUpdate.add(u); System.debug('BACKFILL ' + u.Name); }
}
update toUpdate;
System.debug('BACKFILL updated ' + toUpdate.size() + ' of 19');
