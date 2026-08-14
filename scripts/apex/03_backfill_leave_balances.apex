/*
 * P2-1 backfill: seed Leave_Balance__c for 2026 from the existing User fields.
 * Upsert by External_Key__c, so re-running is safe.
 * The User fields are deliberately NOT modified - frozen fallback strategy.
 */
final Integer YR = 2026;

// Active policies drive which rows exist at all.
List<Leave_Type_Policy__mdt> policies = new List<Leave_Type_Policy__mdt>();
for (Leave_Type_Policy__mdt p : Leave_Type_Policy__mdt.getAll().values()) {
    if (p.Active__c == true) policies.add(p);
}

// Refresh tiers, for resolving Refreshment entitlement by tenure.
List<Refresh_Leave_Rule__mdt> tiers = Refresh_Leave_Rule__mdt.getAll().values();

List<User> emps = [SELECT Id, Name, Start_Date__c,
                          Annual_Leave_Allocated__c, Annual_Leave_Used__c,
                          Carry_Over_Days__c, Carry_Over_Expiry__c,
                          Sick_Leave_Allocated__c, Sick_Leave_Used__c,
                          Personal_Leave_Allocated__c, Personal_Leave_Used__c,
                          Refresh_Leave_Days__c, Refresh_Leave_Expiry__c, Refresh_Leave_Granted_Year__c
                   FROM User WHERE IsActive = TRUE AND Start_Date__c != NULL];

List<Leave_Balance__c> rows = new List<Leave_Balance__c>();
Integer seeded = 0;

for (User u : emps) {
    for (Leave_Type_Policy__mdt p : policies) {
        Decimal ent  = p.Entitlement_Days__c;
        Decimal used = 0;
        Date carryExp = null, expiry = null;
        Decimal carry = 0;

        /*
         * Granted_On__c is the grant engine's idempotency guard: blank means "not yet
         * granted for this year". Leaving it blank here would make the next January 1
         * run re-grant the whole year and reset Used_Days__c to zero, silently erasing
         * everyone's consumption. Record when the entitlement was granted, mirroring
         * what the engine itself would have written.
         */
        Date grantedOn = (u.Start_Date__c.year() == YR)
            ? u.Start_Date__c              // new-hire grant, on the joining date
            : Date.newInstance(YR, 1, 1);  // annual grant, on January 1

        if (p.Leave_Type__c == 'Annual leave') {
            ent      = u.Annual_Leave_Allocated__c;
            used     = u.Annual_Leave_Used__c == null ? 0 : u.Annual_Leave_Used__c;
            carry    = u.Carry_Over_Days__c == null ? 0 : u.Carry_Over_Days__c;
            carryExp = u.Carry_Over_Expiry__c;
            seeded++;
        } else if (p.Leave_Type__c == 'Sick leave') {
            ent  = u.Sick_Leave_Allocated__c;
            used = u.Sick_Leave_Used__c == null ? 0 : u.Sick_Leave_Used__c;
            seeded++;
        } else if (p.Leave_Type__c == 'Personal leave') {
            ent  = u.Personal_Leave_Allocated__c;
            used = u.Personal_Leave_Used__c == null ? 0 : u.Personal_Leave_Used__c;
            seeded++;
        } else if (p.Leave_Type__c == 'Refresh Leave') {
            // Only granted types carry an entitlement. Ungranted years stay at 0 and the
            // daily job fills them in on the anniversary.
            if (u.Refresh_Leave_Granted_Year__c == YR) {
                Integer years = YR - u.Start_Date__c.year();
                Refresh_Leave_Rule__mdt best = null;
                for (Refresh_Leave_Rule__mdt t : tiers) {
                    if (t.Active__c != true || t.Years_of_Service__c == null) continue;
                    if (t.Years_of_Service__c > years) continue;
                    if (best == null || t.Years_of_Service__c > best.Years_of_Service__c) best = t;
                }
                ent    = best == null ? 0 : best.Days_Granted__c;
                used   = ent - (u.Refresh_Leave_Days__c == null ? 0 : u.Refresh_Leave_Days__c);
                expiry = u.Refresh_Leave_Expiry__c;
                // Refreshment is granted on the anniversary, not January 1. February 29
                // joiners are granted on February 28 in a non-leap year.
                Integer annivDay = (u.Start_Date__c.month() == 2 && u.Start_Date__c.day() == 29
                                    && !Date.isLeapYear(YR)) ? 28 : u.Start_Date__c.day();
                grantedOn = Date.newInstance(YR, u.Start_Date__c.month(), annivDay);
                seeded++;
            } else {
                // Left blank on purpose so the anniversary grant can still fire.
                ent = 0;
                grantedOn = null;
            }
        }

        rows.add(new Leave_Balance__c(
            Employee__c                = u.Id,
            Leave_Type__c              = p.Leave_Type__c,
            Leave_Year__c              = YR,
            External_Key__c            = u.Id + '-' + p.Leave_Type__c + '-' + YR,
            Entitlement_Days__c        = ent,
            Accrual_Method__c          = p.Accrual_Method__c,
            Locked_During_Probation__c = p.Locked_During_Probation__c == true,
            Used_Days__c               = used,
            Pending_Days__c            = 0,
            Carry_Over_Days__c         = carry,
            Carry_Over_Expiry__c       = carryExp,
            Expiry_Date__c             = expiry,
            Granted_On__c              = grantedOn,
            Status__c                  = 'Active'
        ));
    }
}

System.debug('BACKFILL employees=' + emps.size() + ' policies=' + policies.size()
             + ' rows=' + rows.size() + ' seededFromUser=' + seeded);
upsert rows External_Key__c;
System.debug('BACKFILL upsert complete');
