# Leave management migration scripts

Run in numeric order, against a sandbox first, and **snapshot before every step**.

Scripts 01, 02 and 04 are safely re-runnable. **03 is not, once the system is live** —
see the warning under its row.

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

After 03, `Leave_Balance__c.Accrued_Days__c` will read one day lower than
`User.Accrued_Leave_Days__c` for part of each month. That is expected, not a defect:
the balance object credits accrual at **month end** per the agreed policy, while the
legacy User formula credits at month start. The User formula is retired at cutover.
