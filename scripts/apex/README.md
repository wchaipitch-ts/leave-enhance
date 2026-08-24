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
| 07 | `07_backfill_accrued_available.apex` | Fills `Accrued_Days__c` and `Available_Days__c` after LEAVE-51 recreated them as stored Number fields. A recreated field is blank on every existing row, and the approval guard reads a blank accrual as zero — so until this has run, nobody can have leave approved. Selects blank rows only, so it is safe to re-run and can be run repeatedly for an org larger than one transaction. **Dry run by default** — set `APPLY = true` to write. Part of the cutover below, not of the User-field migration.

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

After 03, compare `Leave_Balance__c.Accrued_Days__c` against
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

## LEAVE-51 cutover — Accrued and Available become stored fields

Separate from the six-step migration above, and only needed once per org.

`Accrued_Days__c` and `Available_Days__c` were formula fields. The rule now lives in
`LeaveAccrualService`, maintained by `LeaveBalanceTrigger` on every save and by
`LeaveAccrualService.sweep`, which `LeaveManagementController.runDaily` calls before the
grants.

Moving the rule was a refactor and changed nothing. **LEAVE-52 then changed one thing on
purpose**: an employee who joined in an earlier year is credited their monthly day on the
**1st** of the month rather than the last, so they gain a day roughly three weeks earlier
than before. Employees who joined during the leave year are unaffected. See *Verifying*
below for exactly which rows should move.

The fields, however, cannot simply be redeployed. Three platform rules bite at once:

1. A formula field **cannot be converted** to a Number field, in Setup or through the
   Metadata API. It has to be deleted and created again.
2. A custom field **cannot be deleted** while any Apex class or trigger references it.
3. A custom field **cannot be renamed** while any Apex class or trigger references it
   either — so there is no way to shuffle the name out of the way instead.

Six classes read these two fields today: `ApplicationItemTriggerLogic`,
`LeaveBalanceService`, `LeaveSplitService`, `LeaveConversionService`,
`LeaveManagementController` and `LeaveJobRunnerController`. All of them have to stop
doing so before the delete will go through, which is why this is three deploys and not
one.

### Deploy A — detach

Nothing in this release changes behaviour and nothing is degraded by it. Each of the six
classes stops **reading** the two fields and computes the same figures instead, from
columns it is already selecting:

```apex
// was:  zeroIfNull(bal.Accrued_Days__c)
LeaveAccrualService.accruedFor(startDate, bal.Leave_Year__c.intValue(),
                               bal.Accrual_Method__c, bal.Entitlement_Days__c,
                               LeaveAccrualService.asOfDate())

// was:  zeroIfNull(bal.Available_Days__c)
LeaveAccrualService.availableFor(accrued, bal.Carry_Over_Days__c, bal.Used_Days__c)
```

Deploy only the **pure** half of `LeaveAccrualService` in this release — `accruedFor`,
`availableFor` and `asOfDate`. `applyTo`, `recalculate` and `sweep` assign to the two
fields, and assigning to a formula field does not compile, so they cannot go out until
Deploy C. `LeaveBalanceTrigger` and `LeaveBalanceTriggerHandler` wait with them.

Also in this release: take both fields off the **All** list view, the **Leave Balance
Layout** and the `Leave_Management_Admin` permission set. Anything at all that names them
blocks the delete.

Verify nothing is left holding them — Setup ▸ Object Manager ▸ Leave Balance ▸ the
field ▸ **Where is this used?** must come back empty for both.

### Deploy B — delete

```bash
ALIAS=<alias>

# Snapshot first, so the figures can be compared after the cutover.
sf data query --target-org $ALIAS \
  -q "SELECT Id, External_Key__c, Leave_Year__c, Accrual_Method__c, Entitlement_Days__c, \
      Carry_Over_Days__c, Used_Days__c, Accrued_Days__c, Available_Days__c \
      FROM Leave_Balance__c" \
  --result-format csv > accrual_before.csv

sf project deploy start --target-org $ALIAS \
  --manifest manifest/leave-accrual-cutover/package.xml \
  --post-destructive-changes manifest/leave-accrual-cutover/destructiveChanges.xml
```

Then **empty the recycle bin** in Setup ▸ Deleted Fields. An API name cannot be reused
while a soft-deleted field still holds it, and Deploy C fails on a duplicate name until
it has been erased.

### Deploy C — recreate and reattach

```bash
# The Number fields, the trigger, the full service, and the six classes switched back
# to reading the stored columns.
sf project deploy start --target-org $ALIAS -d force-app

# Backfill. A recreated field is blank on every existing row, and the approval guard
# reads a blank accrual as zero — until this has run, nobody can have leave approved.
# Dry run first, then set APPLY = true inside the file.
sf apex run --file scripts/apex/07_backfill_accrued_available.apex --target-org $ALIAS

# Expect zero.
sf data query --target-org $ALIAS \
  -q "SELECT COUNT() FROM Leave_Balance__c WHERE Accrued_Days__c = NULL"
```

> ### ⚠️ Approvals are blocked between Deploy B and the backfill
>
> In that window the fields either do not exist or read blank on every row, and
> `ApplicationItemTriggerLogic` treats a blank accrual as zero — so every leave request
> is refused as overdrawn. **Run B, C and the backfill in one sitting, out of hours.**
> Deploy A can go out days earlier; it is safe on its own.

### Verifying

Re-run the snapshot query into `accrual_after.csv` and diff it against
`accrual_before.csv`. Exactly one group of rows should move, and it should move by
exactly one day:

| Rows | Expected change |
|---|---|
| `Accrual_Method__c = 'Monthly'`, current leave year, employee joined in an **earlier** year | `Accrued` and `Available` **+1**, on every day of the month except the last |
| The same rows, on the **last** day of a month | unchanged — month end and month start agree there |
| `Monthly`, employee joined **during** the leave year | unchanged |
| Every other row — `Upfront`, `Anniversary`, blank method, closed years, future years | unchanged |

Only Annual leave is configured `Monthly`, so in practice this is one row per continuing
employee. **Anything outside that table is a defect** in `LeaveAccrualService.accruedFor`,
not a new rule; the likeliest suspects are a row with a blank `Accrual_Method__c` and a
row for a future leave year.

Run the diff on a day that is **not** a month boundary. Both sides are measured against
the real clock, so a backfill that straddles midnight on the 1st or the 31st legitimately
credits a day on top of the change above and makes the comparison unreadable.

### What still reads the real date

The accrual is measured against `System.today()`, never against the effective date handed
to `runDaily`. That is what the `TODAY()` in the old formula did, and it is why replaying
a missed run for a past date does not rewind everybody's accrual. The Leave Job Runner
screen says as much on its warning banner, and it is still true.
