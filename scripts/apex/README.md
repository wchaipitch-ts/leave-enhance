# Leave management migration scripts

Run in numeric order, against a sandbox first, and **snapshot before every step**.

> ### These are now callers, not implementations
>
> The logic lives in `LeaveMigrationService`. Each file here selects a step and prints the
> result; the **Leave Migration** tab runs the same class through
> `LeaveMigrationController`. A cutover that can be run two ways must not be able to
> behave two ways, so there is one implementation and two front doors.
>
> **Every script now dry-runs by default.** Set `APPLY = true` inside the file to write.
> Scripts 01 to 05 used to apply the moment you ran them; they no longer do.
>
> The screen is the easier route for a cutover: it previews each step, keeps the steps in
> order, downloads the User-field snapshot for you, and refuses to apply anything in a
> production org until the org's name has been typed back.

Scripts 01, 02 and 04 are safely re-runnable. **03 is not, once the system is live** —
and it no longer relies on you having read that. `LeaveMigrationService.blockReasonFor`
refuses it outright as soon as a single request carries `Balance_Applied_Days__c`, which
is the stamp written at approval and therefore proof that consumption has moved to
`Leave_Balance__c`. The refusal appears whether you run the script or press the button.

```bash
sf data query --target-org <alias> \
  -q "SELECT Id, Name, Start_Date__c, Annual_Leave_Allocated__c, Annual_Leave_Day__c, \
      Annual_Leave_Used__c, Carry_Over_Days__c, Carry_Over_Expiry__c, \
      Annual_Leave_Granted_Year__c, Refresh_Leave_Days__c, Sick_Leave_Allocated__c, \
      Personal_Leave_Allocated__c FROM User WHERE IsActive=true AND Start_Date__c != NULL" \
  --result-format csv > snapshot_before.csv

sf apex run --file scripts/apex/01_fix_grant_year_and_allocations.apex --target-org <alias>
```

> `sf data update bulk` fails on this org with `LineEnding is invalid on user data`
> regardless of CRLF conversion, which is why these are anonymous Apex rather than
> CSV loads.

| # | Script | What it does |
|---|---|---|
| 01 | `01_fix_grant_year_and_allocations.apex` | Resets `Annual_Leave_Granted_Year__c`, which a test run using `todayOverride` had set to a **future** year. Both `grantAnnualLeave` and `grantNewHireLeave` guard on this field, so the guard being ahead of the current year silently suppresses every grant. Also recomputes `Annual_Leave_Allocated__c` to the pro-rated `13 − start month` for joiners in the grant year. Does **not** touch `Annual_Leave_Used__c` or `Carry_Over_Days__c`. |
| 02 | `02_backfill_sick_personal_allocations.apex` | Fills `Sick_Leave_Allocated__c = 30` and `Personal_Leave_Allocated__c = 3` where null. Fills nulls only, so any deliberately different value survives. |
| 03 | `03_backfill_leave_balances.apex` | Creates one `Leave_Balance__c` per employee per active `Leave_Type_Policy__mdt` row for the target year, seeded from the User fields. Upserts on `External_Key__c`, and stamps `Granted_On__c`. Leaves the User fields untouched — they are the frozen fallback. |
| 04 | `04_stamp_granted_on.apex` | Backfills `Granted_On__c` on any row created before that field existed. Only needed where script 03 was run from a version that predates the field. Stamps blanks only, and deliberately leaves ungranted Refreshment rows blank so the anniversary grant can still fire. |
| 05 | `05_backfill_balance_lookup.apex` | Points `ApplicationItem__c.Leave_Balance__c` at the row each approved request drew from, so a later rejection knows what to give back. Sets the lookup only — it does **not** move `Used_Days__c`, because the balance already reflects those days. |
| 06 | `06_fix_expiry_dates.apex` | Corrects the expiry dates script 03 copied verbatim from the User fields instead of deriving them: `Carry_Over_Expiry__c` (30 June of the balance year) and `Expiry_Date__c` (`Granted_On__c` + the grant window). A wrong date means days lapse late; a **missing** carry-over date means they never lapse at all, because the June sweep matches on the date being present — so every Annual row carrying days is given one, whether it held a wrong date or none. **Dry run by default** — set `APPLY = true` to write. Idempotent. Verify with runbook case K9. |
| 07 | `07_backfill_accrued_available.apex` | Fills the stored `Accrued_To_Date__c` and `Available_Balance__c` after the LEAVE-51 deploy. A new field is blank on every existing row, and the approval guard reads a blank accrual as zero — so until this has run, nobody can have leave approved. Selects blank rows only, so it is safe to re-run and can be run repeatedly for an org larger than one transaction. **Dry run by default** — set `APPLY = true` to write. Part of the LEAVE-51 deploy below, not of the User-field migration.

> ### ⚠️ Script 03 is a one-way migration, not a repair tool
>
> It re-seeds `Used_Days__c` from the **frozen** User fields. Re-running it after
> employees have started taking leave under the new system will **revert their
> consumption** to whatever the old User fields hold. Safe only while the two are still
> in step — i.e. immediately after cutover, before any approval.
>
> ### Why `Granted_On__c` matters
>
> It is the grant engine's idempotency guard: blank means *not yet granted for this
> year*. A row without it makes the next January 1 run re-grant the whole year and reset
> `Used_Days__c` to zero, erasing everyone's consumption. Verify after running 03:
>
> ```bash
> sf data query --target-org <alias> \
>   -q "SELECT COUNT() FROM Leave_Balance__c WHERE Granted_On__c = NULL AND Leave_Type__c != 'Refresh Leave'"
> ```
>
> Expect **zero**. Refreshment rows are exempt — they stay blank until the anniversary.

## Prerequisites for script 03

`Leave_Type_Policy__mdt` records must exist first. **They cannot be deployed** — this
org returns `UNKNOWN_EXCEPTION` with zero components resolved for CustomMetadata
records, in both source and mdapi format, even for a single-field probe. Create them
by hand from the definitions in `force-app/main/default/customMetadata/`, which hold
the intended values.

Also assign the `Leave_Management_Admin` permission set before running 03. Custom
fields deployed via the Metadata API get **no field-level security**, so all but the
universally-required fields are invisible until a permission set grants them — Apex
will fail to compile with "Field does not exist" otherwise.

## Verifying

After 03, compare `Leave_Balance__c.Accrued_To_Date__c` against
`User.Accrued_Leave_Days__c`:

- **Employees who joined in an earlier year — the two now agree.** LEAVE-52 moved the
  monthly credit to the 1st, which is what the legacy formula's `MONTH(TODAY())` has
  always done. Before LEAVE-52 the balance row read one day lower for most of the month.
- **Employees who joined during the leave year — the balance still reads one day lower
  for part of each month.** That is expected, not a defect: the balance object earns the
  joining month at month end, while the legacy formula credits it immediately with its
  `+ 1`. Their entitlement is already pro-rated, so crediting in advance as well would
  pay for a month nobody worked.

The User formula is retired at cutover.




---

## LEAVE-51 / LEAVE-52 — the accrual moves into Apex

**Done in dev5-ts.** Recorded here because production still has to go through it.

`Accrued_Days__c` and `Available_Days__c` were formula fields. The rule now lives in
`LeaveAccrualService`, maintained by `LeaveBalanceTrigger` on every save and by
`LeaveAccrualService.sweep`, which `LeaveManagementController.runDaily` calls before the
grants.

### Why the stored figures are in NEW fields

The obvious move — convert the two formulas to Number fields — is impossible, and three
platform rules have to be understood together before the shape of this makes sense:

1. A formula field **cannot be converted** to a Number field. Confirmed by the org:
   *"Cannot update a field from a Formula to something else."*
2. A field **cannot be deleted** while any Apex references it.
3. A field **cannot be renamed** while any Apex references it either, so the name cannot
   be shuffled out of the way instead.

Twelve Apex classes reference the two fields — six consumers and **six test classes**,
which block a delete exactly as production classes do:

| `Accrued_Days__c` | `Available_Days__c` |
|---|---|
| ApplicationItemTriggerLogic | LeaveBalanceService |
| LeaveBalanceService | LeaveJobRunnerController |
| LeaveConversionService | LeaveManagementController |
| LeaveJobRunnerController | LeaveCascadeTest |
| LeaveManagementController | LeaveConversionTest |
| LeaveSplitService | LeaveDeductionTest |
| | LeaveManagementControllerTest |
| | LeaveReversalTest |
| | LeaveSplitTest |

Keeping the old names would have meant detaching all twelve, deleting, recreating, and
reattaching all twelve — every edit thrown away, and a window in which no leave could be
approved. New names cost twelve edits **once**, with no destructive step and no outage,
so that is what was done:

| Was (formula, kept) | Is now (stored, maintained) |
|---|---|
| `Accrued_Days__c` — relabelled *Accrued to Date (legacy formula)* | `Accrued_To_Date__c` |
| `Available_Days__c` — relabelled *Available Days (legacy formula)* | `Available_Balance__c` |

The legacy formulas are still in place, still correct against the OLD rule, and still
readable. Nothing in Apex reads them. They are the fallback until the new fields have
been trusted for a cycle.

### Running it

```bash
ALIAS=<alias>

# Snapshot, so the change can be checked afterwards.
sf data query --target-org $ALIAS \
  -q "SELECT Id, External_Key__c, Leave_Year__c, Accrual_Method__c, Entitlement_Days__c, \
      Carry_Over_Days__c, Used_Days__c, Accrued_Days__c, Available_Days__c \
      FROM Leave_Balance__c" --result-format csv > accrual_before.csv

# One deploy. No deletion, no outage, nothing to revert.
sf project deploy start --target-org $ALIAS -m CustomObject:Leave_Balance__c \
  -m ApexClass:LeaveAccrualService -m ApexClass:LeaveAccrualServiceTest \
  -m ApexClass:LeaveBalanceTriggerHandler -m ApexTrigger:LeaveBalanceTrigger \
  -m ApexClass:ApplicationItemTriggerLogic -m ApexClass:LeaveBalanceService \
  -m ApexClass:LeaveConversionService -m ApexClass:LeaveJobRunnerController \
  -m ApexClass:LeaveManagementController -m ApexClass:LeaveSplitService \
  -m ApexClass:LeaveCascadeTest -m ApexClass:LeaveConversionTest \
  -m ApexClass:LeaveDeductionTest -m ApexClass:LeaveManagementControllerTest \
  -m ApexClass:LeaveReversalTest -m ApexClass:LeaveSplitTest \
  -m ApexClass:LeaveReversalService -m ApexClass:EventTriggerTest \
  -m ApexClass:ApplicationItemTriggerTest \
  -m PermissionSet:Leave_Management_Admin -m Layout:"Leave_Balance__c-Leave Balance Layout"

# A new field is blank on every existing row, and the approval guard reads a blank
# accrual as zero. Dry run first, then set APPLY = true inside the file.
sf apex run --file scripts/apex/07_backfill_accrued_available.apex --target-org $ALIAS

# Expect zero.
sf data query --target-org $ALIAS \
  -q "SELECT COUNT() FROM Leave_Balance__c WHERE Accrued_To_Date__c = NULL"
```

Nobody can have leave approved between the deploy and the backfill, so keep them
together. Everything else about the deploy is reversible.

### Verifying

Compare the legacy formula against the stored figure — they are side by side on the same
row, which is the one real benefit of having kept the old fields:

```bash
sf data query --target-org $ALIAS \
  -q "SELECT Leave_Type__c, Accrual_Method__c, Entitlement_Days__c, \
      Accrued_Days__c, Accrued_To_Date__c, Available_Days__c, Available_Balance__c \
      FROM Leave_Balance__c WHERE Accrual_Method__c = 'Monthly'"
```

Exactly one group should differ, by exactly one day:

| Rows | Expected |
|---|---|
| `Monthly`, current year, joined in an **earlier** year | stored reads **+1** vs the legacy formula, every day except the last of the month |
| The same rows on the **last** day of a month | identical — month start and month end agree there |
| `Monthly`, joined **during** the leave year | identical |
| `Upfront`, `Anniversary`, blank method, closed years, future years | identical |

That +1 is LEAVE-52 and is the intended change. Anything else is a defect in
`LeaveAccrualService.accruedFor`. In dev5-ts on 2026-08-24 the Annual rows read
`Accrued_Days__c = 7` against `Accrued_To_Date__c = 8`, which is exactly this.

### Afterwards

Once reports and any saved list views have been moved onto the new fields, the two
legacy formulas can be dropped — nothing in Apex references them any more, so the delete
that was impossible before is now trivial:

```bash
sf project deploy start --target-org $ALIAS \
  --manifest manifest/leave-accrual-cutover/package.xml \
  --post-destructive-changes manifest/leave-accrual-cutover/destructiveChanges.xml
```

### What date the accrual is measured against

`System.today()`, normally — never the effective date handed to `runDaily`. That is what
the old `TODAY()` did, and it is why replaying a missed run for a past date does not
rewind everybody's accrual.

The one exception is the Leave Job Runner, which calls `LeaveAccrualService.simulateAsOf`
so the clock travels with the run. Without it a future-dated run is not just incomplete
but wrong: carry over is capped from the prior year's Available, and with the clock left
on today that year still reads part-accrued. Measured in dev5-ts before the fix, a
1 January 2027 preview carried the wrong number on **11 of 20** rows. `simulateAsOf`
refuses outside a sandbox, and the runner clears it in a `finally`.
