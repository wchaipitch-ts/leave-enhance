// Corrective pass: reset the polluted Annual_Leave_Granted_Year__c guard (test run
// wrote 2027) and recompute 2026 allocations to the pro-rated new-hire figure.
// Deliberately does NOT touch Annual_Leave_Used__c, Carry_Over_Days__c or expiry dates.
Integer YR = 2026;
List<User> toUpdate = new List<User>();

for (User u : [SELECT Id, Name, Start_Date__c, Annual_Leave_Allocated__c,
                      Annual_Leave_Day__c, Annual_Leave_Used__c, Annual_Leave_Granted_Year__c
               FROM User
               WHERE IsActive = TRUE AND Start_Date__c != NULL]) {

    Decimal alloc = (u.Start_Date__c.year() < YR) ? 12 : (13 - u.Start_Date__c.month());
    Decimal used  = u.Annual_Leave_Used__c == null ? 0 : u.Annual_Leave_Used__c;

    u.Annual_Leave_Allocated__c    = alloc;
    u.Annual_Leave_Day__c          = alloc - used;
    u.Annual_Leave_Granted_Year__c = YR;
    toUpdate.add(u);

    System.debug(u.Name + ' | start=' + u.Start_Date__c + ' | alloc=' + alloc
                 + ' | used=' + used + ' | remaining=' + (alloc - used));
}

update toUpdate;
System.debug('UPDATED ' + toUpdate.size() + ' users');
