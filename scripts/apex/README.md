# Leave management migration scripts

Run in numeric order. Each is idempotent — re-running changes nothing once it has
succeeded. Run against a sandbox first and **snapshot before every step**:

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
| 03 | `03_backfill_leave_balances.apex` | Creates one `Leave_Balance__c` per employee per active `Leave_Type_Policy__mdt` row for the target year, seeded from the User fields. Upserts on `External_Key__c`. Leaves the User fields untouched — they are the frozen fallback. |

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
