# Leave Policy Rework — Implementation Plan

Rework of Annual Leave and Refresh Leave to a **January 1st granting model**.

**Constraints agreed for this build:**
- No new custom objects.
- No new Apex classes — modify existing files only.
- One new Custom Metadata Type (`Refresh_Leave_Rule__mdt`) for refresh leave configuration.
- New custom fields and validation rules are in scope.

---

## 1. Background — what exists today

| Piece | File | Role |
|---|---|---|
| Grant engine | `force-app/main/default/classes/LeaveManagementController.cls` | Writes `Annual_Leave_Allocated__c` / `Annual_Leave_Day__c` on User |
| Scheduler | `force-app/main/default/classes/ScheduleAdjustLeaveManagement.cls` | Cron `0 0 0 1 * ?` — 1st of every month |
| Leave request | `ApplicationItem__c` | Fields: `Term_From__c`, `Period_Leave__c`, `Request_Type__c`, `Status__c`, `No_of_Days__c` |
| Approval side-effects | `force-app/main/default/classes/ApplicationItemTriggerHandler.cls` | Creates calendar `Event` + enqueues a `Man_hour__c` "Leave FY" record |
| Balance display | `force-app/main/default/lwc/timesheetManagementScreen/` | Shows `Annual_Leave_Day__c` as "Annual Leave" |

Current grant rules (`LeaveManagementController.cls` lines 86–125): skip if tenure < 6 months; 6 months → 3 days; 12–35 months → 6; 36–71 → 8; 72+ → 10. Two modes exist — **Anniversary** (default) and **CalendarYear** (gated by the custom label `Leave_Calculation_Mode`).

### Known defects being fixed as part of this work

1. **No deduction exists.** Nothing in the repository decrements a leave balance when an `ApplicationItem__c` is approved. The approval path only creates an `Event` and a `Man_hour__c` record.
2. **`LeaveManagementController.cls:140`** — `usr.Annual_Leave_Day__c = usr.Annual_Leave_Allocated__c;` resets consumed days back to full allocation on every grant run.
3. **`LeaveManagementController.cls:86`** — `if (monthsWorked < 6) continue;` excludes the mid-year hires the new policy grants leave to on their joining date.
4. **`ApplicationItemTriggerHandler.cls:9-12`** — enqueues one Queueable per record inside a loop; breaks past 50 records.
5. **`ApplicationItemTriggerLogic.cls:25`** — `insert event` inside a for loop.
6. **`ApplicationItemTrigger.trigger:3`** — wired for `after update` only, so a record created already-Approved is never processed.

### Accepted limitations of the fields-only approach

These are deliberate trade-offs, not oversights:

- Refresh leave grants a **day count**; it does not auto-schedule N consecutive business days from the anniversary date. Employees pick their dates within the grant window.
- The "3 **business** days" lead-time tier becomes 3 **calendar** days (a validation rule cannot do holiday-aware date maths).
- Company Designated Holidays are stored as standard **`Holiday`** records rather than a dedicated object.
- Point-in-time balance reconstruction is not possible. Field History Tracking is the mitigation.

---

## 2. Data model changes

### 2.1 Custom Metadata Type — `Refresh_Leave_Rule__mdt`

| Field | Type | Notes |
|---|---|---|
| `Years_of_Service__c` | Number(2,0) | Tenure this row applies to |
| `Days_Granted__c` | Number(3,1) | |
| `Grant_Window_Months__c` | Number(2,0) | Default `1` — "within one month of the anniversary" |
| `Is_Encashable__c` | Checkbox | Default `false` |
| `Is_Max_Tier__c` | Checkbox | Row applies to all higher tenures — this is how 6+ years is handled without a code change |
| `Active__c` | Checkbox | Default `true` |

Rows to create:

| DeveloperName | Years | Days | Window | Encashable | Max Tier | Active |
|---|---|---|---|---|---|---|
| `Year_1` | 1 | 1 | 1 | false | false | true |
| `Year_2` | 2 | 2 | 1 | false | false | true |
| `Year_3` | 3 | 3 | 1 | false | false | true |
| `Year_4` | 4 | 4 | 1 | false | false | true |
| `Year_5` | 5 | 5 | 1 | false | **true** | true |

Read with `Refresh_Leave_Rule__mdt.getAll()` — this does **not** consume SOQL query or row limits.

> **Testing note:** Custom Metadata records cannot be inserted by Apex DML, and test methods see the org's real rows. Access them through a `@TestVisible` override so tests are not coupled to org configuration.

### 2.2 New fields — `User`

| Field | Type | Default | Purpose |
|---|---|---|---|
| `Carry_Over_Days__c` | Number(4,1) | 0 | Carried-in balance, consumed first |
| `Carry_Over_Expiry__c` | Date | | June 30 of the carry-over year |
| `First_Year_Carry_Over__c` | Number(3,1) | 0 | Probation-crossing days, exempt from the 6-day cap |
| `Refresh_Leave_Days__c` | Number(3,1) | 0 | Anniversary special leave remaining |
| `Refresh_Leave_Expiry__c` | Date | | Anniversary + `Grant_Window_Months__c` |
| `Annual_Leave_Used__c` | Number(4,1) | 0 | Days consumed this year |
| `Annual_Leave_Granted_Year__c` | Number(4,0) | | Idempotency guard for the Jan 1 grant |
| `Refresh_Leave_Granted_Year__c` | Number(4,0) | | Idempotency guard for anniversary grants |
| `Leave_Plan_Submitted__c` | Checkbox | false | Month-5 planning requirement |
| `Probation_End_Date__c` | Formula (Date) | | `Start_Date__c + 119` |
| `Accrued_Leave_Days__c` | Formula (Number, 1dp) | | Accrual to date — see below |
| `Total_Leave_Available__c` | Formula (Number, 1dp) | | `Annual_Leave_Day__c + Carry_Over_Days__c + First_Year_Carry_Over__c` |

```
Accrued_Leave_Days__c =
MIN(Annual_Leave_Allocated__c,
    IF(YEAR(Start_Date__c) = YEAR(TODAY()),
       MONTH(TODAY()) - MONTH(Start_Date__c) + 1,
       MONTH(TODAY())))
```

Enable **Field History Tracking** on `Carry_Over_Days__c`, `Refresh_Leave_Days__c`, `Annual_Leave_Used__c`.

Reused unchanged: `Annual_Leave_Allocated__c`, `Annual_Leave_Day__c`, `Start_Date__c`.

### 2.3 New fields — `ApplicationItem__c`

| Field | Type | Purpose |
|---|---|---|
| `Days_From_Carry_Over__c` | Number(3,1) | Bucket attribution — makes carry-over-first auditable |
| `Days_From_Current_Year__c` | Number(3,1) | |
| `Days_From_Refresh__c` | Number(3,1) | |
| `Balance_Applied__c` | Checkbox | Prevents double-deduction across the async split |
| `Lead_Time_Override__c` | Checkbox | Emergency / flexible approval |
| `Override_Reason__c` | Text Area(255) | |
| `Is_Company_Designated__c` | Checkbox | Company designated holiday or individually-assigned date |
| `Converted_From_Unpaid__c` | Checkbox | Retrospective unpaid → annual conversion |
| `Leave_Allowance_Month__c` | Date | Payroll hand-off month |

New `Request_Type__c` picklist values: `Unpaid Leave`, `Refresh Leave`.

### 2.4 Validation rules

| Rule | Error when |
|---|---|
| Half-day units | `MOD(No_of_Days__c, 0.5) <> 0` |
| Probation block | `Term_From__c <= Owner.Probation_End_Date__c && NOT(Is_Company_Designated__c)` |
| Accrual overrun | `No_of_Days__c > Owner.Accrued_Leave_Days__c - Owner.Annual_Leave_Used__c` |
| Balance sufficiency | `No_of_Days__c > Owner.Total_Leave_Available__c` |
| Lead time | `(Term_From__c - TODAY()) < 3 / 14 / 21` by `No_of_Days__c`, bypassed when `Lead_Time_Override__c` is true |

> **Verify first:** the `Owner.` cross-object references must be confirmed in a sandbox. Formula references to User fields have known platform limitations. If any rule cannot be built, move that check into the before-insert trigger instead.

---

## 3. Business logic specification

### 3.1 Annual leave grant — January 1

```
For each active User where Start_Date__c != null
                       and Annual_Leave_Granted_Year__c != currentYear:

  carryOver = MIN(6, Annual_Leave_Day__c)

  IF probation ends in the grant year (Probation_End_Date__c.year() == currentYear):
      First_Year_Carry_Over__c = Annual_Leave_Day__c   // uncapped
      carryOver = 0

  Annual_Leave_Allocated__c   = 12
  Annual_Leave_Day__c         = 12
  Carry_Over_Days__c          = carryOver
  Carry_Over_Expiry__c        = June 30, currentYear
  Annual_Leave_Used__c        = 0
  Annual_Leave_Granted_Year__c = currentYear
```

### 3.2 New hire grant — on the joining date

```
days = 13 - Start_Date__c.month()
```

Verified against the policy examples: joined Jan 10 → 12 days; joined Oct 20 → 3 days.

Sets `Annual_Leave_Allocated__c`, `Annual_Leave_Day__c`, and `Annual_Leave_Granted_Year__c`.

### 3.3 Refresh leave grant — on the anniversary

```
years = Start_Date__c.monthsBetween(today) / 12
rule  = the Refresh_Leave_Rule__mdt row where Years_of_Service__c == years and Active__c
        (fall back to the Is_Max_Tier__c row when years exceeds every configured tier)

Refresh_Leave_Days__c        = rule.Days_Granted__c
Refresh_Leave_Expiry__c      = today + rule.Grant_Window_Months__c months
Refresh_Leave_Granted_Year__c = currentYear
```

> **Edge case:** February 29 joiners have no anniversary in non-leap years. Fall back to February 28.

### 3.4 Expiry sweep — daily

```
IF Carry_Over_Expiry__c < today:
    Carry_Over_Days__c = 0, First_Year_Carry_Over__c = 0, Carry_Over_Expiry__c = null
IF Refresh_Leave_Expiry__c < today:
    Refresh_Leave_Days__c = 0, Refresh_Leave_Expiry__c = null
```

Expired days are not encashable.

### 3.5 Deduction on approval

**Amount:** `AM leave` / `PM leave` → 0.5; anything else → 1.0.

**Bucket order:**
1. `Request_Type__c == 'Refresh Leave'` → `Refresh_Leave_Days__c` only.
2. Otherwise: `First_Year_Carry_Over__c` → `Carry_Over_Days__c` → `Annual_Leave_Day__c`.

Record what each bucket contributed in `Days_From_*` on the request, and increment `Annual_Leave_Used__c`.

**The async split — read this before writing the code.** `ApplicationItem__c` is a custom object and `User` is a *setup* object. DML on both within one transaction throws `MIXED_DML_OPERATION`, and **this restriction applies to asynchronous contexts too**. The existing codebase already hit this — see the `@future createLogFile` in `LeaveManagementController.cls:171`. Therefore:

- **Transaction 1** (trigger): update `ApplicationItem__c` — set `Days_From_*` and `Balance_Applied__c = true`. Enqueue an `@future` carrying a serialised `Map<Id userId, Decimal days>`.
- **Transaction 2** (`@future`): update `User` only.

Failure mode: if transaction 2 fails, the request is flagged applied but the balance is not decremented. Catch that and write an `Error_Log__c` record.

---

## 4. Task breakdown

Difficulty: 🟢 junior · 🟡 junior with review · 🔴 needs a senior.

### Blocking prerequisite

**LEAVE-0 · Confirm open policy questions with HR** — 🔴
Answers change the specification, so resolve before LEAVE-6 and LEAVE-13 start.

1. Half-day definition. The current code is asymmetric: AM = 3.5h, PM = 4.0h (`CreateLeaveRecordOnManInputTriggerLogic.cls:9`). Should both halves be 3.75h?
2. Does `First_Year_Carry_Over__c` also expire on June 30, or does it have its own window?
3. Is annual leave encashable on resignation? The policy states only that refresh leave is not.
4. What system consumes `Leave_Allowance_Month__c` for payroll?
5. Cutover date, and how balances granted under the old anniversary scheme convert.

---

### Phase 1 — Metadata foundation (no dependencies, fully parallel)

**LEAVE-1 · Create the 12 `User` fields** — 🟢
Per §2.2, including the three formula fields. Enable Field History Tracking on the three listed fields.
*Done when:* all fields deploy to sandbox; `Probation_End_Date__c` returns joining date + 119 days and `Accrued_Leave_Days__c` returns the expected value for a test user, both verified in Developer Console.

**LEAVE-2 · Create the 9 `ApplicationItem__c` fields + 2 picklist values** — 🟢
Per §2.3.
*Done when:* fields deploy; `Unpaid Leave` and `Refresh Leave` are selectable on `Request_Type__c`.

**LEAVE-3 · Create `Refresh_Leave_Rule__mdt` and its 5 rows** — 🟢
Per §2.1.
*Done when:* `Refresh_Leave_Rule__mdt.getAll().size() == 5` in anonymous Apex, and `Year_5` has `Is_Max_Tier__c = true`.

---

### Phase 2 — Declarative rules

**LEAVE-4 · Build the 5 validation rules** — 🟡
*Depends on:* LEAVE-1, LEAVE-2. Per §2.4.
**Start by proving `Owner.Probation_End_Date__c` resolves in a formula in the sandbox.** If it does not, stop and escalate — those checks move to LEAVE-13 instead.
*Done when:* each rule blocks its bad case and permits the good case; `Lead_Time_Override__c` bypasses the lead-time rule.

---

### Phase 3 — Grant engine

> All of Phase 3 edits the same file. **Assign LEAVE-5 through LEAVE-9 to one developer**, or sequence them strictly — parallel work here will conflict.

**LEAVE-5 · Strip the old logic and scaffold `runDaily()`** — 🟡
*Depends on:* LEAVE-1, LEAVE-3. File: `LeaveManagementController.cls`.
Delete the 3/6/8/10 tier ladder (lines 95–122), the Anniversary/CalendarYear mode fork, the `monthsWorked < 6` skip (line 86), the balance sync (line 140), and the `Leave_Calculation_Mode` try/catch (lines 26–35). Keep `createLogFile`.
Add `@TestVisible private static Date todayOverride;` and `@TestVisible private static List<Refresh_Leave_Rule__mdt> ruleOverride;`.

```apex
public void execute(SchedulableContext sc) { runDaily(); }

public static void runDaily() {
    Date today = todayOverride != null ? todayOverride : System.today();
    Map<Id, User> toUpdate = new Map<Id, User>();
    if (today.month() == 1 && today.day() == 1) grantAnnualLeave(today, toUpdate);
    grantNewHireLeave(today, toUpdate);
    grantRefreshLeave(today, toUpdate);
    expireLeave(today, toUpdate);
    if (!toUpdate.isEmpty()) { update toUpdate.values(); createLogFile(logDetails); }
}
```

*Done when:* the class compiles with four empty private methods and the existing test class is temporarily disabled with a linked follow-up ticket (LEAVE-17).

**LEAVE-6 · Implement `grantAnnualLeave`** — 🟡
*Depends on:* LEAVE-5, LEAVE-0 (Q2). Per §3.1.
*Done when:* a user with 8 remaining days carries over exactly 6 and ends with `Annual_Leave_Day__c = 12`, `Carry_Over_Days__c = 6`; a user whose probation ends in the grant year gets the full prior balance in `First_Year_Carry_Over__c` with `Carry_Over_Days__c = 0`; a second run in the same year changes nothing.

**LEAVE-7 · Implement `grantNewHireLeave`** — 🟢
*Depends on:* LEAVE-5. Per §3.2.
*Done when:* a user starting January 10 receives 12 days and one starting October 20 receives 3, both on their joining date, and neither is granted twice.

**LEAVE-8 · Implement `grantRefreshLeave`** — 🟡
*Depends on:* LEAVE-5, LEAVE-3. Per §3.3.
*Done when:* each tenure from 1 to 5 years grants the configured days on the anniversary; 7 years falls back to the `Is_Max_Tier__c` row; `Refresh_Leave_Expiry__c` is one month out; February 29 joiners are granted on February 28 in non-leap years.

**LEAVE-9 · Implement `expireLeave`** — 🟢
*Depends on:* LEAVE-5. Per §3.4.
*Done when:* balances past their expiry date zero out and the expiry date clears; balances before expiry are untouched.

**LEAVE-10 · Change the scheduler to daily** — 🟢
*Depends on:* LEAVE-5. File: `ScheduleAdjustLeaveManagement.cls:4`. `0 0 0 1 * ?` → `0 0 1 * * ?`.
*Done when:* the job appears in Scheduled Jobs with a daily next-run. Remember to delete the existing monthly job.

> **Scale check for the reviewer:** `grantAnnualLeave` queries all active users. Above roughly 10,000 employees this needs `Database.Batchable` added as a second interface on the same class. Confirm current headcount before sign-off.

---

### Phase 4 — Deduction on approval

**LEAVE-11 · Bulkify the existing trigger path** — 🟢
*No policy logic — a good first ticket, and it can start immediately.*
Files: `ApplicationItemTriggerHandler.cls:9-12` (one Queueable for the batch, not one per record), `ApplicationItemTriggerLogic.cls:25` (collect Events into a list, single `insert` after the loop).
*Done when:* approving 200 records in one transaction succeeds and creates 200 Events.

**LEAVE-12 · Add `after insert` to the trigger** — 🟢
File: `ApplicationItemTrigger.trigger:3`. Route it to the same handler method as `after update`.
*Done when:* a record inserted with `Status__c = 'Approved'` produces its Event and Man_hour records.

**LEAVE-13 · Implement the balance deduction** — 🔴
*Depends on:* LEAVE-1, LEAVE-2, LEAVE-11, LEAVE-0 (Q1). File: `ApplicationItemTriggerLogic.cls`.
Add `deductLeaveBalance(List<ApplicationItem__c>)` plus an `@future` method for the User update. **Read §3.5 in full before starting** — the Mixed DML split is the whole difficulty of this ticket.
*Done when:* approving a full-day request decrements carry-over before current-year; `Days_From_*` reflects the split; re-saving an approved record does not deduct twice; a `Refresh Leave` request only touches `Refresh_Leave_Days__c`; a failed async update produces an `Error_Log__c`.

---

### Phase 5 — UI

**LEAVE-14 · Add the new fields to `getUserInfo`** — 🟢
*Depends on:* LEAVE-1. File: `TimesheetController.cls:6-7`.
*Done when:* the LWC receives the new fields in its response.

**LEAVE-15 · Show the leave buckets on the timesheet screen** — 🟡
*Depends on:* LEAVE-14. Files: `timesheetManagementScreen.js:171`, `timesheetManagementScreen.html:120`.
Replace the single "Annual Leave" figure with remaining / carry-over + expiry date / refresh + expiry date.
*Done when:* all buckets render, and a user with no refresh leave sees a sensible empty state rather than `-undefined-`.

**LEAVE-16 · Fix the duplicate `workedHours` field** — 🟢
*Independent of everything else — can start immediately.*
File: `timesheetManagementScreen.js`. `workedHours` is declared twice, at line 92 (summary header, `'0:00'`) and line 667 (modal, `''`). They are the same class field, so opening the edit modal writes a raw millisecond value into the summary header via line 743. Rename the modal-scoped one.
*Done when:* opening the edit modal on an existing timestamp leaves the "Worked Hours" header unchanged.

---

### Phase 6 — Tests

**LEAVE-17 · Rewrite `LeaveManagementControllerTest`** — 🟡
*Depends on:* LEAVE-6 to LEAVE-9. Every current assertion encodes the retired 3/6/8/10 ladder (lines 93–96), so this is a rewrite rather than an edit. Drive dates with `todayOverride` and rules with `ruleOverride`.
*Coverage required:* January 10 → 12 days · October 20 → 3 days · probation crossing year-end · 6-day carry-over cap · June 30 expiry · each refresh tier plus the max-tier fallback · re-run idempotency.

**LEAVE-18 · Deduction tests** — 🟡
*Depends on:* LEAVE-13. Bucket ordering, `Days_From_*` attribution, double-approval idempotency, refresh-leave isolation, `Test.stopTest()` around the async assertions.

**LEAVE-19 · Bulk test** — 🟢
*Depends on:* LEAVE-11. 200 records through approval in a single transaction, asserting no limit exceptions.

---

### Phase 7 — Cutover

**LEAVE-20 · Backfill `Annual_Leave_Granted_Year__c`** — 🟡
*Depends on:* LEAVE-6. Set it on all existing users so the first January 1 run does not re-grant to people already handled under the old scheme.
*Done when:* a dry run of `grantAnnualLeave` against production data selects zero users.

**LEAVE-21 · Migrate existing balances** — 🔴
*Depends on:* LEAVE-0 (Q5), LEAVE-20. Convert anniversary-scheme balances per the agreed cutover rule. Also backfill `Start_Date__c` where null — the grant query filters on `Start_Date__c != NULL` and will silently skip those users.

**LEAVE-22 · Company Designated Holidays** — 🟡
*Depends on:* LEAVE-2, LEAVE-13. Record the dates as standard `Holiday` records — `TimesheetController.getHolidays` already reads that object, so the timesheet picks them up at no cost. Generate `ApplicationItem__c` records with `Is_Company_Designated__c = true` for regular employees; mark employees still in probation as WFH regular working days without consuming leave. Cap at 3 per year.

> `TimesheetController.cls:73-81` filters holidays on `ActivityDate`, which misses **recurring** holidays (those rows carry a null `ActivityDate`). Confirm whether designated holidays are affected before closing this ticket.

---

## 5. Suggested sequencing

```
LEAVE-0 (HR answers) ──────────────────────────┐
                                               │
LEAVE-1 ─┬─ LEAVE-4 ─────────────────┐         │
LEAVE-2 ─┤                           │         │
LEAVE-3 ─┴─ LEAVE-5 ─ 6 ─ 7 ─ 8 ─ 9 ─ 10 ─ 17 ─┤
         │                                     │
         ├─ LEAVE-14 ─ LEAVE-15                │
         │                                     │
LEAVE-11 ─ LEAVE-12 ─ LEAVE-13 ─ 18 ───────────┤
LEAVE-19                                       │
                                               ├─ LEAVE-20 ─ LEAVE-21 ─ LEAVE-22
LEAVE-16 (independent)
```

**Start immediately, no dependencies:** LEAVE-0, LEAVE-1, LEAVE-2, LEAVE-3, LEAVE-11, LEAVE-16.

**Deploy order:** fields → custom metadata type and rows → validation rules → Apex and trigger → LWC → tests → backfill.

**Highest-risk tickets:** LEAVE-13 (Mixed DML), LEAVE-21 (production data), LEAVE-4 (may prove infeasible and push scope into LEAVE-13).
