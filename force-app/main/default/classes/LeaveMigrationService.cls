/*
 * LEAVE-50 — the six migration steps, as one implementation.
 *
 * These began as six anonymous Apex files under scripts/apex/. They are now here, and
 * those files call into this class rather than carrying their own copy of the logic.
 * A migration that can be run two ways must not be able to behave two ways: a button
 * and a script that had drifted apart would be worse than either on its own.
 *
 * Every step takes an `apply` flag. False computes the whole change set and reports it
 * without writing anything, which is the only honest way to let somebody decide whether
 * to run a migration against production.
 *
 * ORDER MATTERS. 01 and 02 fix the User fields that 03 seeds from; 04, 05 and 06 correct
 * what 03 produced. Running 03 before 01 seeds the wrong allocations.
 *
 * STEP 03 IS ONE-WAY. It re-seeds Used_Days__c from the frozen User fields, so running it
 * after anybody has taken leave under the new system reverts their consumption. That is
 * not a warning in a README here — canRun refuses it outright once a single request
 * carries Balance_Applied_Days__c, which is the stamp deductLeaveBalance writes on
 * approval and therefore exact evidence that the two sides have parted company.
 */
public with sharing class LeaveMigrationService {

    private static final String TYPE_ANNUAL   = 'Annual leave';
    private static final String TYPE_SICK     = 'Sick leave';
    private static final String TYPE_PERSONAL = 'Personal leave';
    private static final String TYPE_REFRESH  = 'Refresh Leave';

    /* Detail lines are for a human reading a screen, not an audit log. */
    private static final Integer MAX_LINES = 200;

    public class StepOutcome {
        @AuraEnabled public String step;
        @AuraEnabled public String title;
        @AuraEnabled public Boolean applied;
        @AuraEnabled public Integer inspected;
        @AuraEnabled public Integer affected;
        @AuraEnabled public String summary;
        @AuraEnabled public String blockedReason;   // non-null means nothing ran
        @AuraEnabled public List<String> lines;
        StepOutcome(String step, String title) {
            this.step = step;
            this.title = title;
            this.applied = false;
            this.inspected = 0;
            this.affected = 0;
            this.lines = new List<String>();
        }
        void log(String line) {
            if (lines.size() < MAX_LINES) {
                lines.add(line);
            } else if (lines.size() == MAX_LINES) {
                lines.add('… and more. Only the first ' + MAX_LINES + ' are listed.');
            }
        }
    }

    public static final Map<String, String> TITLES = new Map<String, String>{
        '01' => 'Reset the grant-year guard and recompute annual allocations',
        '02' => 'Fill missing sick and personal allocations',
        '03' => 'Create the balance rows from the User fields',
        '04' => 'Stamp Granted On where it is blank',
        '05' => 'Point approved requests at the balance they drew from',
        '06' => 'Correct the expiry dates'
    };

    public static List<String> stepsInOrder() {
        return new List<String>{ '01', '02', '03', '04', '05', '06' };
    }

    /**
     * Runs one step.
     *
     * @param step  '01' through '06'
     * @param yr    the leave year being migrated
     * @param apply false reports what would change and writes nothing
     */
    public static StepOutcome run(String step, Integer yr, Boolean apply) {
        Boolean write = (apply == true);
        if ('01'.equals(step)) return stepFixGrantYear(yr, write);
        if ('02'.equals(step)) return stepBackfillAllocations(write);
        if ('03'.equals(step)) return stepBackfillBalances(yr, write);
        if ('04'.equals(step)) return stepStampGrantedOn(write);
        if ('05'.equals(step)) return stepLinkBalances(write);
        if ('06'.equals(step)) return stepFixExpiryDates(write);
        throw new IllegalArgumentException('Unknown migration step: ' + step);
    }

    /*
     * Why step 03 may not be run. Balance_Applied_Days__c is written by
     * deductLeaveBalance the moment a request is approved, so a single stamped request
     * is proof that consumption now lives on Leave_Balance__c and no longer matches the
     * frozen User fields 03 would seed from.
     */
    public static String blockReasonFor(String step) {
        return blockReasonFor(step, System.today().year());
    }

    public static String blockReasonFor(String step, Integer yr) {
        if (!'03'.equals(step)) {
            return null;
        }

        /*
         * Checked first because it is the only one that can never be cleared.
         * Balance_Applied_Days__c is written by deductLeaveBalance the moment a request
         * is approved, so a single stamped request is proof that consumption now lives on
         * Leave_Balance__c and no longer matches the frozen User fields 03 would seed
         * from. Telling somebody to go and run step 01 first, when the step can never run
         * again whatever they do, would be a wasted errand.
         */
        Integer consumed = [
            SELECT COUNT() FROM ApplicationItem__c WHERE Balance_Applied_Days__c != NULL
        ];
        if (consumed > 0) {
            return 'Refused, permanently. ' + consumed + ' request(s) have already been '
                + 'approved under the new system, so the balances hold consumption the old '
                + 'User fields know nothing about. Re-seeding from those fields would revert '
                + 'it and quietly give those days back. This step is only safe before the '
                + 'first approval, and that moment has passed in this org.';
        }

        /*
         * Nothing to build against. Step 03 iterates active policy rows, so with none
         * present it creates nothing, writes nothing and reports success - a green box
         * saying "0 balance rows across 0 active leave types", which reads like a
         * completed step rather than a missing prerequisite. The custom metadata records
         * have to exist first, and they cannot be deployed into this org.
         */
        Integer active = 0;
        for (Leave_Type_Policy__mdt policy : Leave_Type_Policy__mdt.getAll().values()) {
            if (policy.Active__c == true) active++;
        }
        if (active == 0) {
            return 'Refused. There are no active Leave Type Policy records, so this step '
                + 'would create no balance rows at all and report success while doing it. '
                + 'Create the policy records in Setup first — they cannot be deployed.';
        }

        /*
         * Order, and the only one of the three that clears by doing something. 01 and 02
         * fix the User fields 03 seeds from, so running 03 first bakes the wrong
         * allocations into every balance row and the only way back is the snapshot. Both
         * are measured rather than remembered: if either still has outstanding work, it
         * has not been run.
         */
        List<String> outstanding = new List<String>();
        if (run('01', yr, false).affected > 0) outstanding.add('01');
        if (run('02', yr, false).affected > 0) outstanding.add('02');
        if (!outstanding.isEmpty()) {
            return 'Refused for now. Step(s) ' + String.join(outstanding, ' and ') + ' still '
                + 'have changes outstanding, and they fix the User fields this step seeds '
                + 'from. Running out of order bakes the wrong allocations into every balance '
                + 'row, and the only way back is the snapshot. Apply them first.';
        }

        return null;
    }

    // ------------------------------------------------------------------------ 01

    /*
     * Resets Annual_Leave_Granted_Year__c, which a test run using todayOverride had set
     * to a future year. Both grants guard on it, so a guard ahead of the current year
     * suppresses every grant silently. Also recomputes the pro-rated allocation.
     *
     * Deliberately does NOT touch Annual_Leave_Used__c or Carry_Over_Days__c.
     */
    private static StepOutcome stepFixGrantYear(Integer yr, Boolean apply) {
        StepOutcome out = new StepOutcome('01', TITLES.get('01'));
        List<User> toUpdate = new List<User>();

        for (User u : [
            SELECT Id, Name, Start_Date__c, Annual_Leave_Allocated__c,
                   Annual_Leave_Day__c, Annual_Leave_Used__c, Annual_Leave_Granted_Year__c
            FROM User
            WHERE IsActive = TRUE AND Start_Date__c != NULL
        ]) {
            out.inspected++;
            Decimal alloc = (u.Start_Date__c.year() < yr) ? 12 : (13 - u.Start_Date__c.month());
            Decimal used = zeroIfNull(u.Annual_Leave_Used__c);

            Boolean changes = u.Annual_Leave_Allocated__c != alloc
                || u.Annual_Leave_Day__c != (alloc - used)
                || u.Annual_Leave_Granted_Year__c != yr;

            u.Annual_Leave_Allocated__c    = alloc;
            u.Annual_Leave_Day__c          = alloc - used;
            u.Annual_Leave_Granted_Year__c = yr;
            toUpdate.add(u);

            if (changes) {
                out.affected++;
                out.log(u.Name + ' | start=' + u.Start_Date__c + ' | alloc=' + alloc
                    + ' | used=' + used + ' | remaining=' + (alloc - used));
            }
        }

        if (apply && !toUpdate.isEmpty()) {
            update toUpdate;
            out.applied = true;
        }
        out.summary = phrase(out, 'user record');
        return out;
    }

    // ------------------------------------------------------------------------ 02

    /* Fills nulls only, so a deliberately different value survives. */
    private static StepOutcome stepBackfillAllocations(Boolean apply) {
        StepOutcome out = new StepOutcome('02', TITLES.get('02'));
        List<User> toUpdate = new List<User>();

        for (User u : [
            SELECT Id, Name, Sick_Leave_Allocated__c, Personal_Leave_Allocated__c
            FROM User WHERE IsActive = TRUE AND Start_Date__c != NULL
        ]) {
            out.inspected++;
            Boolean changed = false;
            if (u.Sick_Leave_Allocated__c == null)     { u.Sick_Leave_Allocated__c = 30; changed = true; }
            if (u.Personal_Leave_Allocated__c == null) { u.Personal_Leave_Allocated__c = 3; changed = true; }
            if (changed) {
                toUpdate.add(u);
                out.affected++;
                out.log(u.Name + ' | sick and personal allocations filled');
            }
        }

        if (apply && !toUpdate.isEmpty()) {
            update toUpdate;
            out.applied = true;
        }
        out.summary = phrase(out, 'user record');
        return out;
    }

    // ------------------------------------------------------------------------ 03

    /*
     * One Leave_Balance__c per employee per active policy, seeded from the User fields.
     * Upserts on External_Key__c. The User fields are deliberately left untouched — they
     * are the frozen fallback.
     */
    private static StepOutcome stepBackfillBalances(Integer yr, Boolean apply) {
        StepOutcome out = new StepOutcome('03', TITLES.get('03'));

        String blocked = blockReasonFor('03', yr);
        if (blocked != null) {
            out.blockedReason = blocked;
            out.summary = blocked;
            return out;
        }

        List<Leave_Type_Policy__mdt> policies = new List<Leave_Type_Policy__mdt>();
        for (Leave_Type_Policy__mdt p : Leave_Type_Policy__mdt.getAll().values()) {
            if (p.Active__c == true) policies.add(p);
        }
        List<Refresh_Leave_Rule__mdt> tiers = Refresh_Leave_Rule__mdt.getAll().values();

        Set<String> existingKeys = new Set<String>();
        for (Leave_Balance__c b : [
            SELECT External_Key__c FROM Leave_Balance__c WHERE Leave_Year__c = :yr
        ]) {
            existingKeys.add(b.External_Key__c);
        }

        List<Leave_Balance__c> rows = new List<Leave_Balance__c>();
        Integer seeded = 0;
        Integer employees = 0;

        for (User u : [
            SELECT Id, Name, Start_Date__c,
                   Annual_Leave_Allocated__c, Annual_Leave_Used__c,
                   Carry_Over_Days__c, Carry_Over_Expiry__c,
                   Sick_Leave_Allocated__c, Sick_Leave_Used__c,
                   Personal_Leave_Allocated__c, Personal_Leave_Used__c,
                   Refresh_Leave_Days__c, Refresh_Leave_Expiry__c, Refresh_Leave_Granted_Year__c
            FROM User WHERE IsActive = TRUE AND Start_Date__c != NULL
        ]) {
            employees++;
            for (Leave_Type_Policy__mdt p : policies) {
                Decimal ent = p.Entitlement_Days__c;
                Decimal used = 0;
                Date carryExp = null, expiry = null;
                Decimal carry = 0;

                /*
                 * Granted_On__c is the engine's idempotency guard: blank means "not yet
                 * granted this year". Leaving it blank would make the next January run
                 * re-grant everything and zero Used_Days__c.
                 */
                Date grantedOn = (u.Start_Date__c.year() == yr)
                    ? u.Start_Date__c
                    : Date.newInstance(yr, 1, 1);

                if (TYPE_ANNUAL.equals(p.Leave_Type__c)) {
                    ent      = u.Annual_Leave_Allocated__c;
                    used     = zeroIfNull(u.Annual_Leave_Used__c);
                    carry    = zeroIfNull(u.Carry_Over_Days__c);
                    carryExp = u.Carry_Over_Expiry__c;
                    seeded++;
                } else if (TYPE_SICK.equals(p.Leave_Type__c)) {
                    ent  = u.Sick_Leave_Allocated__c;
                    used = zeroIfNull(u.Sick_Leave_Used__c);
                    seeded++;
                } else if (TYPE_PERSONAL.equals(p.Leave_Type__c)) {
                    ent  = u.Personal_Leave_Allocated__c;
                    used = zeroIfNull(u.Personal_Leave_Used__c);
                    seeded++;
                } else if (TYPE_REFRESH.equals(p.Leave_Type__c)) {
                    if (u.Refresh_Leave_Granted_Year__c == yr) {
                        Integer years = yr - u.Start_Date__c.year();
                        Refresh_Leave_Rule__mdt best = null;
                        for (Refresh_Leave_Rule__mdt t : tiers) {
                            if (t.Active__c != true || t.Years_of_Service__c == null) continue;
                            if (t.Years_of_Service__c > years) continue;
                            if (best == null || t.Years_of_Service__c > best.Years_of_Service__c) {
                                best = t;
                            }
                        }
                        ent    = best == null ? 0 : best.Days_Granted__c;
                        used   = ent - zeroIfNull(u.Refresh_Leave_Days__c);
                        expiry = u.Refresh_Leave_Expiry__c;
                        // February 29 joiners are granted on the 28th in a common year.
                        Integer annivDay = (u.Start_Date__c.month() == 2
                                            && u.Start_Date__c.day() == 29
                                            && !Date.isLeapYear(yr)) ? 28 : u.Start_Date__c.day();
                        grantedOn = Date.newInstance(yr, u.Start_Date__c.month(), annivDay);
                        seeded++;
                    } else {
                        // Blank on purpose so the anniversary grant can still fire.
                        ent = 0;
                        grantedOn = null;
                    }
                }

                String key = u.Id + '-' + p.Leave_Type__c + '-' + yr;
                if (!existingKeys.contains(key)) {
                    out.affected++;
                    out.log('NEW  ' + u.Name + ' | ' + p.Leave_Type__c
                        + ' | entitlement=' + ent + ' used=' + used);
                }
                rows.add(new Leave_Balance__c(
                    Employee__c                = u.Id,
                    Leave_Type__c              = p.Leave_Type__c,
                    Leave_Year__c              = yr,
                    External_Key__c            = key,
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

        out.inspected = rows.size();
        if (apply && !rows.isEmpty()) {
            upsert rows External_Key__c;
            out.applied = true;
        }
        out.summary = (apply ? 'Wrote ' : 'Would write ') + rows.size() + ' balance row(s) for '
            + employees + ' employee(s) across ' + policies.size() + ' active leave type(s), '
            + out.affected + ' of them new. ' + seeded + ' seeded from the User fields; '
            + 'the rest start at the policy entitlement.';
        return out;
    }

    // ------------------------------------------------------------------------ 04

    /* Stamps blanks only, and leaves ungranted Refreshment rows blank on purpose. */
    private static StepOutcome stepStampGrantedOn(Boolean apply) {
        StepOutcome out = new StepOutcome('04', TITLES.get('04'));
        List<Leave_Balance__c> toStamp = new List<Leave_Balance__c>();
        Integer skippedRefresh = 0;

        for (Leave_Balance__c bal : [
            SELECT Id, Leave_Type__c, Leave_Year__c, Entitlement_Days__c, Granted_On__c,
                   Employee__r.Name, Employee__r.Start_Date__c
            FROM Leave_Balance__c
            WHERE Granted_On__c = NULL AND Employee__r.Start_Date__c != NULL
        ]) {
            out.inspected++;
            Integer yr = bal.Leave_Year__c.intValue();
            Date started = bal.Employee__r.Start_Date__c;
            Date stamp;

            if (TYPE_REFRESH.equals(bal.Leave_Type__c)) {
                if (bal.Entitlement_Days__c == null || bal.Entitlement_Days__c <= 0) {
                    skippedRefresh++;
                    continue;
                }
                Integer day = started.day();
                if (started.month() == 2 && day == 29 && !Date.isLeapYear(yr)) {
                    day = 28;
                }
                stamp = Date.newInstance(yr, started.month(), day);
            } else {
                stamp = (started.year() == yr) ? started : Date.newInstance(yr, 1, 1);
            }

            toStamp.add(new Leave_Balance__c(Id = bal.Id, Granted_On__c = stamp));
            out.affected++;
            out.log(bal.Employee__r.Name + ' | ' + bal.Leave_Type__c + ' ' + yr
                + ' | granted on ' + stamp.format());
        }

        if (apply && !toStamp.isEmpty()) {
            update toStamp;
            out.applied = true;
        }
        out.summary = phrase(out, 'balance row')
            + ' ' + skippedRefresh + ' ungranted Refreshment row(s) left blank on purpose, '
            + 'so the anniversary grant can still fire.';
        return out;
    }

    // ------------------------------------------------------------------------ 05

    /* Approved requests only: a pending one has consumed nothing. */
    private static StepOutcome stepLinkBalances(Boolean apply) {
        StepOutcome out = new StepOutcome('05', TITLES.get('05'));

        Map<String, Id> balanceByKey = new Map<String, Id>();
        for (Leave_Balance__c bal : [
            SELECT Id, External_Key__c FROM Leave_Balance__c WHERE External_Key__c != NULL
        ]) {
            balanceByKey.put(bal.External_Key__c, bal.Id);
        }

        List<ApplicationItem__c> toLink = new List<ApplicationItem__c>();
        Integer noBalance = 0;

        for (ApplicationItem__c appl : [
            SELECT Id, Name, OwnerId, Request_Type__c, Term_From__c
            FROM ApplicationItem__c
            WHERE Leave_Balance__c = NULL
              AND Status__c = 'Approved'
              AND Term_From__c != NULL
              AND Request_Type__c != NULL
              AND RecordType.DeveloperName != 'Overtime_Request'
        ]) {
            out.inspected++;
            Id balanceId = balanceByKey.get(
                appl.OwnerId + '-' + appl.Request_Type__c + '-' + appl.Term_From__c.year());
            if (balanceId == null) {
                noBalance++;
                continue;
            }
            toLink.add(new ApplicationItem__c(Id = appl.Id, Leave_Balance__c = balanceId));
            out.affected++;
            out.log(appl.Name + ' | ' + appl.Request_Type__c + ' '
                + appl.Term_From__c.year() + ' | linked');
        }

        if (apply && !toLink.isEmpty()) {
            update toLink;
            out.applied = true;
        }
        out.summary = phrase(out, 'approved request')
            + ' ' + noBalance + ' had no matching balance row, which is expected for leave '
            + 'types that keep no balance.';
        return out;
    }

    // ------------------------------------------------------------------------ 06

    /*
     * Corrects the two dates 03 copied verbatim from the User fields instead of deriving
     * them, and arms any Annual row that carries days with no carry-over expiry at all —
     * the June sweep matches on the date being present, so without one those days never
     * lapse.
     */
    private static StepOutcome stepFixExpiryDates(Boolean apply) {
        StepOutcome out = new StepOutcome('06', TITLES.get('06'));

        Integer defaultWindow = 1;
        for (Refresh_Leave_Rule__mdt r : [
            SELECT Grant_Window_Months__c FROM Refresh_Leave_Rule__mdt WHERE Active__c = TRUE
        ]) {
            if (r.Grant_Window_Months__c != null) {
                defaultWindow = r.Grant_Window_Months__c.intValue();
                break;
            }
        }

        List<Leave_Balance__c> toFix = new List<Leave_Balance__c>();

        for (Leave_Balance__c b : [
            SELECT Id, Employee__r.Name, Leave_Type__c, Leave_Year__c, Granted_On__c,
                   Carry_Over_Days__c, Carry_Over_Expiry__c, Expiry_Date__c
            FROM Leave_Balance__c
            WHERE Carry_Over_Expiry__c != NULL
               OR Expiry_Date__c != NULL
               OR (Leave_Type__c = :TYPE_ANNUAL AND Carry_Over_Days__c > 0)
        ]) {
            out.inspected++;
            Boolean changed = false;
            Leave_Balance__c fix = new Leave_Balance__c(Id = b.Id);

            Boolean needsCarryExpiry = b.Leave_Year__c != null
                && (b.Carry_Over_Expiry__c != null
                    || (b.Carry_Over_Days__c != null && b.Carry_Over_Days__c > 0));

            if (needsCarryExpiry) {
                Date correct = Date.newInstance(b.Leave_Year__c.intValue(), 6, 30);
                if (b.Carry_Over_Expiry__c != correct) {
                    out.log((b.Carry_Over_Expiry__c == null ? 'ARM   ' : 'CARRY ')
                        + b.Employee__r.Name + ' ' + b.Leave_Type__c + ' ' + b.Leave_Year__c
                        + ': ' + b.Carry_Over_Expiry__c + ' → ' + correct);
                    fix.Carry_Over_Expiry__c = correct;
                    changed = true;
                }
            }

            if (b.Expiry_Date__c != null && b.Granted_On__c != null) {
                Date correct = b.Granted_On__c.addMonths(defaultWindow);
                if (b.Expiry_Date__c != correct) {
                    out.log('WINDOW ' + b.Employee__r.Name + ' ' + b.Leave_Type__c + ' '
                        + b.Leave_Year__c + ': ' + b.Expiry_Date__c + ' → ' + correct);
                    fix.Expiry_Date__c = correct;
                    changed = true;
                }
            }

            if (changed) {
                toFix.add(fix);
                out.affected++;
            }
        }

        if (apply && !toFix.isEmpty()) {
            update toFix;
            out.applied = true;
        }
        out.summary = phrase(out, 'balance row with an expiry date');
        return out;
    }

    // --------------------------------------------------------------------- helpers

    private static String phrase(StepOutcome out, String noun) {
        String plural = out.affected == 1 ? noun : noun + 's';
        return (out.applied ? 'Changed ' : 'Would change ') + out.affected + ' ' + plural
            + ' of ' + out.inspected + ' inspected.';
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}