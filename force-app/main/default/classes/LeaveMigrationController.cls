/*
 * LEAVE-50 — the screen in front of LeaveMigrationService.
 *
 * Unlike LeaveJobRunnerController this is NOT sandbox-only: running the cutover is the
 * whole point, and it has to work in production. Everything else here exists because of
 * that.
 *
 *   Permission gated.   Run Leave Migration, and nothing else. Object access is not
 *                       accepted as a substitute.
 *   Preview always.     Every step reports its full change set before it can be applied.
 *                       There is no path that writes without having shown its work.
 *   Typed confirmation. Outside a sandbox, applying requires the caller to type the org's
 *                       name back. A migration that reverts consumption should take more
 *                       than one mis-click, and a confirm dialog is one click.
 *   Snapshot first.     The User leave fields can be pulled as CSV before anything runs.
 *                       They are the frozen fallback the whole migration seeds from, and
 *                       once overwritten there is nothing to go back to.
 */
public with sharing class LeaveMigrationController {

    private static final String PERMISSION = 'Run_Leave_Migration';

    /* Tests cannot make an org stop being a sandbox, so the production path is driven here. */
    @TestVisible private static Boolean sandboxOverride;
    @TestVisible private static String orgNameOverride;

    public class OrgContext {
        @AuraEnabled public Boolean isSandbox;
        @AuraEnabled public String orgName;
        @AuraEnabled public String instanceName;
        @AuraEnabled public Boolean confirmationRequired;
        @AuraEnabled public Integer defaultYear;
    }

    public class StepInfo {
        @AuraEnabled public String step;
        @AuraEnabled public String title;
        @AuraEnabled public String blockedReason;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean isAvailable() {
        try {
            assertAllowed();
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    @AuraEnabled(cacheable=true)
    public static OrgContext getContext() {
        assertAllowed();
        Organization org = [SELECT Name, IsSandbox, InstanceName FROM Organization LIMIT 1];
        OrgContext ctx = new OrgContext();
        ctx.isSandbox = isSandbox(org);
        ctx.orgName = orgName(org);
        ctx.instanceName = org.InstanceName;
        ctx.confirmationRequired = !isSandbox(org);
        ctx.defaultYear = System.today().year();
        return ctx;
    }

    /** The six steps in order, each carrying its own reason for being unavailable. */
    @AuraEnabled
    public static List<StepInfo> getSteps(Integer year) {
        assertAllowed();
        List<StepInfo> out = new List<StepInfo>();
        for (String s : LeaveMigrationService.stepsInOrder()) {
            StepInfo info = new StepInfo();
            info.step = s;
            info.title = LeaveMigrationService.TITLES.get(s);
            info.blockedReason = LeaveMigrationService.blockReasonFor(s, resolveYear(year));
            out.add(info);
        }
        return out;
    }

    @AuraEnabled
    public static LeaveMigrationService.StepOutcome preview(String step, Integer year) {
        assertAllowed();
        return LeaveMigrationService.run(step, resolveYear(year), false);
    }

    /**
     * Applies one step for real.
     *
     * @param confirmation outside a sandbox this must equal the org's name, exactly. It
     *                     is checked server-side because a client-side check protects
     *                     nobody — anything reachable from a browser console is not a
     *                     control.
     */
    @AuraEnabled
    public static LeaveMigrationService.StepOutcome apply(String step, Integer year,
                                                          String confirmation) {
        assertAllowed();
        Organization org = [SELECT Name, IsSandbox FROM Organization LIMIT 1];
        if (!isSandbox(org) && !orgName(org).equals(confirmation)) {
            throw new AuraHandledException(
                'This is not a sandbox. Type the org name exactly — "' + orgName(org)
                + '" — to confirm you mean to write to it.');
        }
        return LeaveMigrationService.run(step, resolveYear(year), true);
    }

    /*
     * The frozen User fields, as CSV, for keeping before anything is written. Every step
     * either reads from these or corrects something derived from them, and nothing
     * recreates them once they have been overwritten.
     */
    @AuraEnabled
    public static String snapshot() {
        assertAllowed();
        List<String> rows = new List<String>{
            'Id,Name,Start_Date__c,Annual_Leave_Allocated__c,Annual_Leave_Day__c,'
            + 'Annual_Leave_Used__c,Carry_Over_Days__c,Carry_Over_Expiry__c,'
            + 'Annual_Leave_Granted_Year__c,Refresh_Leave_Days__c,Refresh_Leave_Expiry__c,'
            + 'Refresh_Leave_Granted_Year__c,Sick_Leave_Allocated__c,Sick_Leave_Used__c,'
            + 'Personal_Leave_Allocated__c,Personal_Leave_Used__c'
        };
        for (User u : [
            SELECT Id, Name, Start_Date__c, Annual_Leave_Allocated__c, Annual_Leave_Day__c,
                   Annual_Leave_Used__c, Carry_Over_Days__c, Carry_Over_Expiry__c,
                   Annual_Leave_Granted_Year__c, Refresh_Leave_Days__c, Refresh_Leave_Expiry__c,
                   Refresh_Leave_Granted_Year__c, Sick_Leave_Allocated__c, Sick_Leave_Used__c,
                   Personal_Leave_Allocated__c, Personal_Leave_Used__c
            FROM User
            WHERE IsActive = TRUE AND Start_Date__c != NULL
            ORDER BY Name
        ]) {
            rows.add(String.join(new List<String>{
                u.Id, csv(u.Name), s(u.Start_Date__c),
                s(u.Annual_Leave_Allocated__c), s(u.Annual_Leave_Day__c),
                s(u.Annual_Leave_Used__c), s(u.Carry_Over_Days__c), s(u.Carry_Over_Expiry__c),
                s(u.Annual_Leave_Granted_Year__c), s(u.Refresh_Leave_Days__c),
                s(u.Refresh_Leave_Expiry__c), s(u.Refresh_Leave_Granted_Year__c),
                s(u.Sick_Leave_Allocated__c), s(u.Sick_Leave_Used__c),
                s(u.Personal_Leave_Allocated__c), s(u.Personal_Leave_Used__c)
            }, ','));
        }
        return String.join(rows, '\n');
    }

    private static Boolean isSandbox(Organization org) {
        return sandboxOverride != null ? sandboxOverride : org.IsSandbox;
    }

    private static String orgName(Organization org) {
        return orgNameOverride != null ? orgNameOverride : org.Name;
    }

    private static Integer resolveYear(Integer year) {
        return year == null ? System.today().year() : year;
    }

    private static String s(Object value) {
        return value == null ? '' : String.valueOf(value);
    }

    /* A name with a comma in it would otherwise shift every later column. */
    private static String csv(String value) {
        if (value == null) return '';
        return value.contains(',') || value.contains('"')
            ? '"' + value.replace('"', '""') + '"'
            : value;
    }

    @TestVisible
    private static void assertAllowed() {
        if (!FeatureManagement.checkPermission(PERMISSION)) {
            throw new AuraHandledException(
                'You need the Run Leave Migration permission to use this. It is deliberately '
                + 'narrow: these steps rewrite leave data for every employee.');
        }
    }
}