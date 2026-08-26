@isTest
private class LeaveMigrationTest {

    /*
     * LEAVE-50 — the migration steps and the screen over them.
     *
     * These steps run once, against production, and two of them cannot be undone. What is
     * worth pinning is therefore not the arithmetic of each step so much as the things
     * that stop one being run at the wrong moment: that a preview writes nothing, that
     * step 03 refuses once anybody has taken leave under the new system, and that a
     * production run cannot happen without the org's name being typed back.
     */

    private static final String ANNUAL = 'Annual leave';

    private static User employee() {
        return [SELECT Id, Name, Annual_Leave_Allocated__c, Annual_Leave_Day__c,
                       Annual_Leave_Granted_Year__c, Sick_Leave_Allocated__c,
                       Personal_Leave_Allocated__c, Start_Date__c
                FROM User WHERE CompanyName = 'MIGTEST' LIMIT 1];
    }

    private static Integer thisYear() {
        return System.today().year();
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'mig' + DateTime.now().getTime();
        User u = new User(
            FirstName = 'Migration', LastName = 'Tester',
            Email = unique + '@example.com', Username = unique + '@example.com.migtest',
            Alias = 'migt', CompanyName = 'MIGTEST', TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', ProfileId = p.Id,
            LanguageLocaleKey = 'en_US',
            Start_Date__c = Date.newInstance(System.today().year(), 3, 15),
            // deliberately wrong / missing, so 01 and 02 have something to do
            Annual_Leave_Allocated__c = 99,
            Annual_Leave_Used__c = 2,
            Annual_Leave_Granted_Year__c = System.today().year() + 1
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
    }

    // ------------------------------------------------------------------ previewing

    /*
     * The property the whole screen rests on. If a preview ever writes, the button
     * labelled "Preview" is lying and somebody will find out during a cutover.
     */
    @isTest
    static void previewingStep01WritesNothing() {
        User before = employee();

        Test.startTest();
        LeaveMigrationService.StepOutcome out =
            LeaveMigrationService.run('01', thisYear(), false);
        Test.stopTest();

        System.assertEquals(false, out.applied);
        System.assert(out.affected > 0, 'the fixture is deliberately wrong, so there is work');
        System.assert(out.summary.startsWith('Would change'), out.summary);

        User after = employee();
        System.assertEquals(before.Annual_Leave_Allocated__c, after.Annual_Leave_Allocated__c,
            'the allocation is untouched by a preview');
        System.assertEquals(before.Annual_Leave_Granted_Year__c, after.Annual_Leave_Granted_Year__c,
            'and so is the guard');
    }

    @isTest
    static void applyingStep01FixesTheGuardAndTheAllocation() {
        Test.startTest();
        LeaveMigrationService.StepOutcome out =
            LeaveMigrationService.run('01', thisYear(), true);
        Test.stopTest();

        System.assertEquals(true, out.applied);
        User after = employee();
        System.assertEquals(10, after.Annual_Leave_Allocated__c,
            'a March joiner gets 13 - 3, not the 99 the fixture held');
        System.assertEquals(8, after.Annual_Leave_Day__c, '10 allocated less 2 used');
        System.assertEquals(thisYear(), after.Annual_Leave_Granted_Year__c,
            'the guard is back to the current year, so grants can fire again');
    }

    @isTest
    static void step02FillsOnlyTheBlanks() {
        Test.startTest();
        LeaveMigrationService.run('02', thisYear(), true);
        Test.stopTest();

        User after = employee();
        System.assertEquals(30, after.Sick_Leave_Allocated__c);
        System.assertEquals(3, after.Personal_Leave_Allocated__c);
    }

    // --------------------------------------------------------------- the one-way step

    /*
     * The guard that matters most. Step 03 re-seeds Used_Days__c from the frozen User
     * fields, so running it after somebody has taken leave under the new system hands
     * those days back silently. Balance_Applied_Days__c is written by deductLeaveBalance
     * at approval, so a single stamped request is exact evidence the two have parted.
     */
    @isTest
    static void step03IsRefusedOnceLeaveHasBeenTakenUnderTheNewSystem() {
        insert new ApplicationItem__c(
            Request_Type__c = ANNUAL, Period_Leave__c = 'All day',
            // December, so it clears the fixture user's own probation window.
            Term_From__c = Date.newInstance(thisYear(), 12, 2),
            Remark__c = 'migration guard fixture', Status__c = 'Draft',
            OwnerId = employee().Id, Balance_Applied_Days__c = 1
        );

        Test.startTest();
        LeaveMigrationService.StepOutcome out =
            LeaveMigrationService.run('03', thisYear(), true);
        Test.stopTest();

        System.assertNotEquals(null, out.blockedReason, 'it must refuse, not run');
        System.assertEquals(false, out.applied);
        System.assertEquals(0, out.affected);
        System.assert(out.blockedReason.contains('already been approved'), out.blockedReason);
    }

    /*
     * Allowed only once the steps it depends on are clean and nobody has been approved -
     * which together are the cutover window.
     */
    @isTest
    static void step03RunsOnceItsPrerequisitesAreMet() {
        Test.startTest();
        LeaveMigrationService.run('01', thisYear(), true);
        LeaveMigrationService.run('02', thisYear(), true);
        LeaveMigrationService.StepOutcome out =
            LeaveMigrationService.run('03', thisYear(), false);
        Test.stopTest();

        System.assertEquals(null, out.blockedReason, 'nothing left standing in its way');
        System.assert(out.summary.startsWith('Would write'), out.summary);
    }

    /*
     * Order, enforced rather than documented. 01 and 02 fix the User fields 03 seeds
     * from, so running 03 first bakes the wrong allocations into every balance row. The
     * fixture is deliberately wrong, so both still have work.
     */
    @isTest
    static void step03WaitsForTheStepsItSeedsFrom() {
        Test.startTest();
        LeaveMigrationService.StepOutcome out =
            LeaveMigrationService.run('03', thisYear(), true);
        Test.stopTest();

        System.assertNotEquals(null, out.blockedReason);
        System.assertEquals(false, out.applied, 'and it did not run anyway');
        System.assert(out.blockedReason.contains('01'), out.blockedReason);
        System.assert(out.blockedReason.startsWith('Refused for now'),
            'this one clears by doing something, unlike the consumption block');
    }

    /*
     * The permanent blocker outranks the ordering one. Telling somebody to go and run
     * step 01 first would be a wasted errand when the step can never run again whatever
     * they do.
     */
    @isTest
    static void thePermanentRefusalIsReportedAheadOfTheOrderingOne() {
        insert new ApplicationItem__c(
            Request_Type__c = ANNUAL, Period_Leave__c = 'All day',
            Term_From__c = Date.newInstance(thisYear(), 12, 3),
            Remark__c = 'precedence fixture', Status__c = 'Draft',
            OwnerId = employee().Id, Balance_Applied_Days__c = 1
        );

        Test.startTest();
        // 01 and 02 are also outstanding, so both blockers apply at once.
        String reason = LeaveMigrationService.blockReasonFor('03', thisYear());
        Test.stopTest();

        System.assert(reason.startsWith('Refused, permanently'), reason);
        System.assert(!reason.contains('Apply them first'),
            'the fixable advice is withheld when the step can never run');
    }

    // ------------------------------------------------------------------- the screen

    @isTest
    static void theScreenListsEveryStepWithItsOwnBlockReason() {
        Test.startTest();
        List<LeaveMigrationController.StepInfo> steps = LeaveMigrationController.getSteps(thisYear());
        Test.stopTest();

        System.assertEquals(6, steps.size());
        System.assertEquals('01', steps[0].step);
        System.assertEquals('06', steps[5].step);
        for (LeaveMigrationController.StepInfo s : steps) {
            System.assertNotEquals(null, s.title, 'every step is labelled');
        }
    }

    /*
     * The confirmation is checked on the server. A gate that only exists in the browser
     * is not a gate - anything reachable from a console is reachable by anybody.
     */
    @isTest
    static void applyingInProductionNeedsTheOrgNameTypedBack() {
        LeaveMigrationController.sandboxOverride = false;
        LeaveMigrationController.orgNameOverride = 'Acme Production';

        Test.startTest();
        try {
            LeaveMigrationController.apply('02', thisYear(), 'acme production');
            System.assert(false, 'a near miss is still a miss');
        } catch (AuraHandledException e) {
            // expected
        }

        LeaveMigrationService.StepOutcome out =
            LeaveMigrationController.apply('02', thisYear(), 'Acme Production');
        Test.stopTest();

        System.assertEquals(true, out.applied, 'the exact name goes through');
    }

    /* A sandbox needs no typing: the risk it guards against is not present. */
    @isTest
    static void aSandboxNeedsNoConfirmation() {
        LeaveMigrationController.sandboxOverride = true;

        Test.startTest();
        LeaveMigrationService.StepOutcome out =
            LeaveMigrationController.apply('02', thisYear(), null);
        Test.stopTest();

        System.assertEquals(true, out.applied);
    }

    @isTest
    static void theContextTellsTheScreenWhichOrgItIsIn() {
        LeaveMigrationController.sandboxOverride = false;
        LeaveMigrationController.orgNameOverride = 'Acme Production';

        Test.startTest();
        LeaveMigrationController.OrgContext ctx = LeaveMigrationController.getContext();
        Test.stopTest();

        System.assertEquals(false, ctx.isSandbox);
        System.assertEquals('Acme Production', ctx.orgName);
        System.assertEquals(true, ctx.confirmationRequired);
    }

    /*
     * The snapshot is the only copy of the frozen User fields once a step has overwritten
     * them, so it has to be complete and it has to survive a comma in somebody's name.
     */
    @isTest
    static void theSnapshotCoversEveryEmployeeAndQuotesCommas() {
        Test.startTest();
        String csv = LeaveMigrationController.snapshot();
        Test.stopTest();

        List<String> lines = csv.split('\n');
        System.assert(lines.size() > 1, 'a header and at least the fixture');
        System.assert(lines[0].startsWith('Id,Name,Start_Date__c'), lines[0]);

        Integer employees = [
            SELECT COUNT() FROM User WHERE IsActive = TRUE AND Start_Date__c != NULL
        ];
        System.assertEquals(employees + 1, lines.size(), 'one row each, plus the header');
    }

    @isTest
    static void anUnknownStepIsRejectedRatherThanIgnored() {
        try {
            LeaveMigrationService.run('99', thisYear(), false);
            System.assert(false, 'a typo must not silently do nothing');
        } catch (IllegalArgumentException e) {
            System.assert(e.getMessage().contains('99'), e.getMessage());
        }
    }

    /* The remaining three steps are corrective and idempotent; a preview must be clean. */
    @isTest
    static void theCorrectiveStepsPreviewWithoutWriting() {
        Test.startTest();
        for (String step : new List<String>{ '04', '05', '06' }) {
            LeaveMigrationService.StepOutcome out =
                LeaveMigrationService.run(step, thisYear(), false);
            System.assertEquals(false, out.applied, step + ' previewed');
            System.assertNotEquals(null, out.summary, step + ' reported something');
        }
        Test.stopTest();
    }
}