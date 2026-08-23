/*
 * Step 05 of the leave migration. See the Leave Migration tab for the same steps with a
 * preview in front of each one.
 *
 * The logic lives in LeaveMigrationService, not here. It used to live in this file, and a
 * screen was later built over the same migration - two copies of a cutover that must not
 * be able to behave two different ways. The class is the single implementation and this
 * is a caller.
 *
 * DRY RUN by default. Set APPLY to true to write.
 */
Boolean APPLY = false;
Integer YEAR = 2026;

LeaveMigrationService.StepOutcome out = LeaveMigrationService.run('05', YEAR, APPLY);

for (String line : out.lines) {
    System.debug(line);
}
System.debug('--------------------------------------');
System.debug('STEP 05  ' + out.title);
if (out.blockedReason != null) {
    System.debug(out.blockedReason);
} else {
    System.debug(out.summary);
    if (!APPLY) {
        System.debug('DRY RUN — nothing written. Set APPLY = true to apply.');
    }
}
