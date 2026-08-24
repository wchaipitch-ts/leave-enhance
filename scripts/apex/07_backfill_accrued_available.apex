/*
 * Step 07 — fills the newly stored Accrued_Days__c and Available_Days__c.
 *
 * LEAVE-51 moved the accrual out of a formula and into LeaveAccrualService. Salesforce
 * cannot convert a formula field to a Number field in place, so both fields are dropped
 * and recreated — and a recreated field starts out blank on every existing row. Until
 * this has run, every balance in the org reads a null accrual and a null availability,
 * which the approval guard treats as zero and will refuse leave on.
 *
 * RUN THIS IMMEDIATELY AFTER THE FIELDS ARE RECREATED, before anybody requests leave.
 * See scripts/apex/README.md for where it sits in the cutover.
 *
 * The arithmetic is not repeated here. This selects rows and hands them to
 * LeaveAccrualService.recalculate — the same call the trigger and the nightly sweep make,
 * so a backfilled figure cannot disagree with a maintained one.
 *
 * Blank rows only, so this is safe to run again: a row it has already filled is not
 * selected a second time. That is also what makes it chunkable. An org with more than
 * BATCH balance rows simply needs the script run repeatedly until it reports 0 remaining.
 *
 * Closed rows are included, unlike the nightly sweep. The sweep skips them because a
 * settled year cannot move; a backfill has to visit them precisely because they are blank.
 *
 * DRY RUN by default. Set APPLY to true to write.
 */
Boolean APPLY = false;

// Under the 10,000 DML rows a single transaction allows, with room for the trigger.
Integer BATCH = 9000;

List<Leave_Balance__c> blank = [
    SELECT Id, Employee__c, Leave_Year__c, Accrual_Method__c, Entitlement_Days__c,
           Carry_Over_Days__c, Used_Days__c, Accrued_Days__c, Available_Days__c
    FROM Leave_Balance__c
    WHERE Accrued_Days__c = NULL OR Available_Days__c = NULL
    LIMIT :BATCH
];

Integer remaining = [
    SELECT COUNT() FROM Leave_Balance__c
    WHERE Accrued_Days__c = NULL OR Available_Days__c = NULL
];

// Fills the figures in memory so the dry run can show what would be written. The save
// below re-enters LeaveBalanceTrigger, which computes the same answer again — this is
// here for the preview, not because the update depends on it.
LeaveAccrualService.recalculate(blank, LeaveAccrualService.asOfDate());

for (Integer i = 0; i < Math.min(blank.size(), 20); i++) {
    Leave_Balance__c b = blank[i];
    System.debug(b.Id + '  year=' + b.Leave_Year__c + '  method=' + b.Accrual_Method__c
        + '  entitlement=' + b.Entitlement_Days__c
        + '  -> accrued=' + b.Accrued_Days__c + ', available=' + b.Available_Days__c);
}
if (blank.size() > 20) {
    System.debug('… and ' + (blank.size() - 20) + ' more.');
}

if (APPLY && !blank.isEmpty()) {
    update blank;
}

System.debug('--------------------------------------');
System.debug('STEP 07  Backfill the stored accrual figures');
System.debug('As of date        : ' + LeaveAccrualService.asOfDate());
System.debug('Blank rows found  : ' + remaining);
System.debug('Filled this run   : ' + blank.size());
if (!APPLY) {
    System.debug('DRY RUN — nothing written. Set APPLY = true to apply.');
} else if (remaining > blank.size()) {
    System.debug('MORE TO DO — ' + (remaining - blank.size())
        + ' row(s) still blank. Run this script again.');
} else {
    System.debug('Complete. Re-run with APPLY = false to confirm 0 blank rows remain.');
}
