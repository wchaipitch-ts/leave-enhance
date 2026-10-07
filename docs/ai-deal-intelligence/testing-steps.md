# AI Deal Intelligence — Testing Steps

Run in our Salesforce org after deploy. Tick each box. Record failures with the Opportunity/Activity Id and the `AI_Analysis_Log__c` record.

Test data: create one test Account + Opportunity `AIDI Test Opp` (any stage). Use it for §3–§5 unless a step says otherwise.

---

## 1. Before testing

- [ ] 1.1 All 33 Opportunity fields exist in the org and match the agreed table (prerequisite — built outside this branch).
- [ ] 1.2 The user running the batch has edit access to all 33 fields.

## 2. Apex unit tests

- [ ] 2.1 Run only the new test classes:
  ```bash
  sf apex run test --class-names MomFilterTest --class-names DealIntelligenceMergerTest --class-names DealIntelligenceServiceTest --class-names DealIntelligenceBackfillBatchTest --class-names MomAnalysisQueueableTest --code-coverage --result-format human --wait 20
  ```
- [ ] 2.2 All pass, each new class ≥ 75 % coverage (team baseline: the full org run has pre-existing failures — don't use it as the gate).

Unit tests must cover at least:

| Area | Case |
|------|------|
| Filter | Meeting + 100 chars → yes; Meeting + 99 chars → no; Email + 500 chars → no; Call → no; whitespace-padded 99 chars → no; WhatId = Account → no; already analysed → no |
| Rule A | old true + AI false → true; old false + AI true → true; old false + AI null → false |
| Rule B | old "X" + AI "No Data" / "Cannot Determine" / "" / null / "ไม่มีข้อมูล" → "X"; old "X" + AI "Y" → "Y"; old null + AI "Y" → "Y"; invalid picklist → unchanged |
| Rule C | old score 80 + AI 40 → 40; reason and risk replaced every time |
| Types | number as string `"1,500,000"`, date `"2026-12-31"`, boolean `"true"` coerced correctly; over-length text truncated |
| Service | HTTP 500 → no Opportunity change, log = Failed, activity not stamped; invalid JSON → Parse Error; 2 MOMs same Opp → merged oldest → newest |

## 3. Trigger filter (real-time, manual)

For each row, log an activity on `AIDI Test Opp`, wait ~1 min, then check **Setup → Apex Jobs** and the AI log related list.

| # | Activity | Type | Description length | Expected |
|---|----------|------|-------------------|----------|
| 3.1 | Event | Meeting | 150 | ✅ analysed, Opp updated, log Success |
| 3.2 | Event | Web Meeting | 150 | ✅ analysed |
| 3.3 | Task | On-site / Visit | 150 | ✅ analysed |
| 3.4 | Task | Email | 500 | ❌ no job, no log |
| 3.5 | Task | Call | 500 | ❌ no job, no log |
| 3.6 | Event | Meeting | 99 | ❌ no job |
| 3.7 | Event | Meeting | 100 | ✅ analysed (boundary) |
| 3.8 | Event | Meeting | 150, related to an **Account** not an Opp | ❌ no job |
| 3.9 | Insert 10 qualifying MOMs at once (Data Loader / anon Apex) | | | ✅ all 10 analysed, no limit errors |

## 4. Merge rules (real-time, manual)

Use a fresh Opportunity. Log MOMs one after another; check field values after each.

1. **MOM 1** — mentions budget "3 million baht", competitor "Company X", decision maker identified, timeline Q1 next year.
   - [ ] Budget, competitor, decision-maker flag, timeline filled. Score/Reason/Risk filled.
2. **MOM 2** — talks only about a technical demo; no budget, no competitor, no decision maker.
   - [ ] **Rule B:** budget, competitor, timeline **unchanged** from MOM 1.
   - [ ] **Rule A:** decision-maker checkbox **still true**.
   - [ ] **Rule C:** Score, Reason, Risk **changed** to reflect MOM 2.
3. **MOM 3** — budget revised to "5 million baht", customer sounds hesitant.
   - [ ] Budget now 5 million (specific new data overwrites).
   - [ ] Score lower than after MOM 2; Risk mentions hesitation.
4. [ ] Edit Score by hand, then log MOM 4 → Score overwritten (Rule C).
5. [ ] Opportunity update did **not** create another AI job (no recursion).
6. [ ] Each log has model name, input/output tokens, list of changed fields.

## 5. JSON output

- [ ] 5.1 Open a Success log → `Raw_Response__c` is one JSON object with all 33 keys.
- [ ] 5.2 Exactly **one** callout per MOM (one log per MOM).
- [ ] 5.3 Request body (debug log) contains `"responseMimeType":"application/json"`.

## 6. Backfill batch

Do a small dry run first.

- [ ] 6.1 Count expected MOMs (Event + Task, last 365 days, MOM type, linked to Opp). Note the count of those ≥ 100 chars — this is the expected number of calls.
- [ ] 6.2 Run `Database.executeBatch(new DealIntelligenceBackfillBatch(), 5);`
- [ ] 6.3 Setup → Apex Jobs: job completes, 0 failed batches.
- [ ] 6.4 Finish email: processed + skipped + failed = expected; failed is small and explained.
- [ ] 6.5 Pick 3 Opportunities with several MOMs: Score/Reason/Risk match the **latest** MOM, not an older one.
- [ ] 6.6 Activities older than 365 days were **not** analysed.
- [ ] 6.7 Run the batch **again** → 0 new calls (idempotent; nothing double-processed).
- [ ] 6.8 Clear `AI_Analyzed_At__c` on one failed activity, re-run → it now succeeds.

## 7. Errors and safety

- [ ] 7.1 Temporarily set a wrong model name → log Failed, Opportunity unchanged, no unhandled exception email.
- [ ] 7.2 An Opportunity with a validation rule failure → other Opportunities in the same chunk still update.
- [ ] 7.3 `grep -rn "AQ\.\|AIza" force-app` finds **no** API key in source.

## 8. Demo readiness

- [ ] 8.1 Open 3 demo Opportunities: the 33 fields are filled where the MOMs had data, and no "No Data" text is stored in any field.
- [ ] 8.2 Thai-language MOM: Reason and Risk make sense in Thai business context (manager reviews quality → decides on model upgrade).
- [ ] 8.3 Total tokens / cost for the backfill recorded for the manager.
