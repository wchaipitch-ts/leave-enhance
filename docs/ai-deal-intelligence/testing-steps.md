# AI Deal Intelligence — Testing Steps

Run in the sandbox `dev5-ts`. Tick each box. For a failure, note the Opportunity Id, the Event Id and the `AI_Analysis_Log__c` record.

Test data: one test Account + Opportunity `AIDI Test Opp` (any stage). Use it for §3–§5 unless a step says otherwise. MOM texts must be **real-looking** (≥ 100 characters, budget/competitor/schedule details). The sandbox has none today (requirements.md §5).

---

## 1. Before testing

- [ ] 1.1 All 33 Opportunity fields exist with the API names in requirements.md §2.2, including the renamed `Proposed_Products__c` (D1).
- [ ] 1.2 `Event.AI_Processed__c` exists, default false.
- [ ] 1.3 The user running the batch has edit access to the 33 fields and `AI_Processed__c`.
- [ ] 1.4 The Event Type values used by the filter exist (sandbox has only On-site / Visit and Web Meeting of the list — see requirements §3.4 note).
- [ ] 1.5 External Credential `Gemini AI Studio` → principal `Gemini_AI_Studio_Principal` has the `ApiKey` parameter set in this org.
- [ ] 1.6 Permission set `AI_Deal_Intelligence` is assigned to the test users (and to every rep who logs MOMs).

## 2. Apex unit tests

- [ ] 2.1 Run only the new test classes:
  ```bash
  sf apex run test --class-names DealIntelligenceRulesTest --class-names DealIntelligenceServiceTest --class-names DealIntelligenceJobTest --code-coverage --result-format human --wait 20
  ```
- [ ] 2.2 All pass, and each new class has ≥ 75 % coverage. (Team baseline: the full org run has pre-existing failures, so don't use it as the gate.)

Unit tests must cover at least:

| Area | Case |
|------|------|
| Filter | Web Meeting + 100 chars → yes; 99 chars → no; 99 chars padded with spaces → no; Type `Dinner / Event` → no; right Type but Subject not in list → no; right Subject but wrong Type → no (D3); WhatId = Account / ApplicationItem → no; `AI_Processed__c = true` → no |
| Keys | `"1_Competitor_Topic_Mentioned__c"` → `Competitor_Topic_Mentioned__c`; `"20_Proposed_Products__c"` → `Proposed_Products__c` |
| Rule A | old true + AI false → true; old false + AI true → true; old false + AI false → false |
| Rule B — text | old blank + AI "No Data" → "No Data"; old "300k" + AI "No Data" → "300k"; old "No Data" + AI "300k" → "300k"; old "300k" + AI "500k" → "500k"; AI null → same as "No Data" |
| Rule B — picklist | old blank + AI "Cannot Determine" → "Cannot Determine"; old "02. Early Stage" + AI "Cannot Determine" → unchanged; AI "Bogus" → treated as No Data, warning logged |
| Rule B — multi-picklist | AI `["No Data"]` on blank → "No Data"; AI `["SAP","No Data"]` → "SAP"; old "SAP" + AI `["Odoo"]` → "SAP;Odoo"; old "SAP" + AI `["SAP"]` → "SAP" (no duplicate); old "No Data" + AI `["SAP"]` → "SAP"; AI `["No Data"]` on "SAP" → "SAP" |
| Rule C | old score 80 + AI 40 → 40; AI 150 → 100; AI 0 → 1; AI `"high"` / null → stays 80 (D8); new Reason replaces old; AI Reason `""` / null → old Reason kept (D8); Risk always replaced |
| Text | 300-char verbatim budget → cut to 255, warning logged |
| Service | HTTP 500 → no Opp change, log Failed, `AI_Processed__c` still false; invalid JSON → Parse Error; 2 MOMs on the same Opp → merged oldest → newest; success → `AI_Processed__c = true` |
| Prompt | `{{INSERT_MINUTES_OF_MEETING_HERE}}` replaced; Section 5 (Markdown table) not in the request |

## 3. Filter (real-time, manual)

For each row, create an Event on `AIDI Test Opp`, wait about 1 minute, then check **Setup → Apex Jobs**, the AI log, and `AI_Processed__c` on the Event.

| # | Type | Subject | Description | Expected |
|---|------|---------|-------------|----------|
| 3.1 | Web Meeting | Web Meeting - 1. Initial Meeting / Hearing | 150 chars | ✅ analysed, Opp updated, `AI_Processed__c` = true |
| 3.2 | On-site / Visit | On-site / Visit - 3. Proposal / Quote Submission | 150 chars | ✅ analysed |
| 3.3 | Dinner / Event | Dinner / Event - 1. Initial Meeting / Hearing | 500 chars | ❌ no job, no log |
| 3.4 | Web Meeting | Web Meeting - 1. Initial Meeting / Hearing | 99 chars | ❌ no job |
| 3.5 | Web Meeting | Web Meeting - 1. Initial Meeting / Hearing | exactly 100 chars | ✅ analysed (boundary) |
| 3.6 | Web Meeting | Web Meeting - 1. Initial Meeting / Hearing | 150 chars, related to an **Account** | ❌ no job |
| 3.7 | Edit 3.4 to 150 chars | | | ❌ no job (only create triggers, FR-2) |
| 3.8 | Insert 10 qualifying Events at once (anonymous Apex) | | | ✅ all 10 analysed, no limit errors |

## 4. Merge rules (real-time, manual)

Use a fresh Opportunity. Create MOMs one after another and check the fields after each one.

1. **MOM 1**: budget "Implementation cost 3M THB", competitor SAP, CEO must approve, go-live "around October", next meeting date set.
   - [ ] Budget flag, decision-maker flag and schedule flag are true. `Explicit_Initial_Budget__c` = the verbatim text. `Mentioned_Product_Competitors__c` = SAP. `Expected_Release_Date__c` filled.
   - [ ] Fields with no information show **"No Data"** / **"Cannot Determine"**, not blank (Rule B: blank gets filled).
   - [ ] Score, Reason and Risk are filled. Score is 1–100.
2. **MOM 2**: only a technical demo. No budget, no competitor, no decision maker, no next meeting.
   - [ ] **Rule B:** budget, competitor and release date are **unchanged** from MOM 1.
   - [ ] **Rule A:** budget, decision-maker and schedule flags are **still true**.
   - [ ] **Rule C:** Score, Reason and Risk **changed**. The score should drop (no next meeting = −20 in the BA logic).
3. **MOM 3**: "running cost 50k per month", competitor Odoo, customer says "I'll check with my boss" with no deadline.
   - [ ] `Explicit_Running_Budget__c` changes from "No Data" to the verbatim text. `Explicit_Initial_Budget__c` stays at 3M.
   - [ ] Competitors = **"SAP;Odoo"** (accumulated, D4).
   - [ ] Reason mentions the polite non-commitment (Kreng-jai).
4. [ ] Edit Score by hand, then create MOM 4 → Score is overwritten (Rule C).
5. [ ] Standard `StageName` is untouched. Only `Opportunity_Stage__c` changes.
6. [ ] Updating the Opportunity / Event did **not** start another AI job.
7. [ ] Each log has the model name, input/output tokens and the list of changed fields.

## 5. JSON output

- [ ] 5.1 A Success log's `Response__c` is one JSON object with 33 keys, and no Markdown table.
- [ ] 5.2 Exactly **one** callout per MOM (one log per MOM).
- [ ] 5.3 The request body (debug log) contains `"responseMimeType":"application/json"`.

## 6. Backfill batch

Do a small dry run first.

- [ ] 6.1 Count the expected MOMs: Events in the last 365 days, linked to an Opportunity, matching Type (and Subject), `AI_Processed__c = false`, Description ≥ 100 characters. That count is the expected number of calls.
- [ ] 6.2 Run `DealIntelligenceJob.runBackfill();`
- [ ] 6.3 Setup → Apex Jobs: the job completes with 0 failed batches.
- [ ] 6.4 Finish email: processed + skipped + failed = expected. Any failures are few and explained.
- [ ] 6.5 Pick 3 Opportunities with several MOMs: Score, Reason and Risk match the **latest** MOM.
- [ ] 6.6 Events older than 365 days were **not** analysed.
- [ ] 6.7 Run the batch **again** → 0 new calls (all processed Events have `AI_Processed__c = true`).
- [ ] 6.8 A failed Event still has `AI_Processed__c = false`. Re-run → it succeeds.

## 7. Errors and safety

- [ ] 7.1 Temporarily set a wrong model name → log Failed, Opportunity unchanged, `AI_Processed__c` false, no unhandled exception email.
- [ ] 7.2 An Opportunity that fails a validation rule doesn't stop the other Opportunities in the same chunk from updating.
- [ ] 7.3 `grep -rn "AQ\.\|AIza" force-app` finds **no** API key in source.
- [ ] 7.4 Gemini busy (503) or rate-limited (429): the log shows `Failed` / `HTTP 503`, and about 2 minutes later a new `DealIntelligenceJob` appears in Apex Jobs and the meeting is analysed. After 3 calls in all it stops retrying; the next backfill picks it up.

## 8. Demo readiness

- [ ] 8.1 Open 3 demo Opportunities: real data is shown where the MOMs had it, and "No Data" elsewhere.
- [ ] 8.2 Thai-language MOM: Reason and Risk make sense in a Thai business context. The manager reviews the quality and decides on a model upgrade.
- [ ] 8.3 Total tokens / cost for the backfill recorded for the manager.
