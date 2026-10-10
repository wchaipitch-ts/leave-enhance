# AI Deal Intelligence — Testing Steps

Run in the sandbox `dev5-ts`. Tick each box. For a failure, note the Opportunity, the Event Id and the log rows (AI Analysis Log and Gemini Opty Log).

**Test data:** the records and ready-to-paste meeting notes are in [test-data.md](test-data.md). To start a round again, run the reset script — first as it is (`DRY_RUN = true`, it only prints), then with `DRY_RUN = false`:

```bash
sf apex run --file scripts/apex/ai-deal-intelligence-reset.apex --target-org dev5-ts
```

**Gemini quota:** every analysed meeting is one call. On the free tier the limits are low (see requirements NFR-2); check [ai.dev/rate-limit](https://ai.dev/rate-limit) before a big run.

---

## 1. Before testing

- [ ] 1.1 All 33 Opportunity fields exist with the API names in requirements.md §2.2 (including `Proposed_Products__c`).
- [ ] 1.2 `Event.AI_Processed__c` exists, default false.
- [ ] 1.3 External Credential **Gemini AI Studio** → principal `Gemini_AI_Studio_Principal` has the `ApiKey` parameter.
- [ ] 1.4 Named Credential **Gemini AI Studio** has *Allow Formulas in HTTP Header* ticked (without it every call fails with `API_KEY_INVALID`).
- [ ] 1.5 Permission set **AI Deal Intelligence** is assigned to the testers (and to every rep who logs MOMs).
- [ ] 1.6 `GeminiMODEL` holds the model you mean to test (`SELECT Value__c FROM Program_Constant__mdt WHERE DeveloperName = 'GeminiMODEL'`).
- [ ] 1.7 In the sandbox only On-site / Visit and Web Meeting exist among the BA's Types (requirements §3.4 note).

## 2. Apex unit tests

- [ ] 2.1 Run the feature's tests:
  ```bash
  sf apex run test --class-names DealIntelligenceRulesTest --class-names DealIntelligenceServiceTest --class-names DealIntelligenceJobTest --class-names EventTriggerTest --code-coverage --result-format human --wait 20
  ```
- [ ] 2.2 All pass (53 as of 8 Oct 2026) and each `DealIntelligence*` class has ≥ 75 % coverage. (The full org run has pre-existing failures — don't use it as the gate.)

What they cover:

| Area | Cases |
|------|-------|
| Filter | 100 chars → yes, 99 → no, padded 99 → no; Type and Subject must both match; case and spaces ignored; not on an Opportunity → no; already ticked → no; missing config → nothing; **all 8 BA Subjects are read from the deployed config** (catches a value cut at 255) |
| Keys | `"1_Competitor_Topic_Mentioned__c"` → `Competitor_Topic_Mentioned__c`; unnumbered keys work too |
| Rule A | true stays true; false → true when mentioned; `"true"` string counts |
| Rule B | No Data fills a blank (Stage gets `Cannot Determine`); never replaces real data; real data replaces No Data and older data; picklist matched ignoring case, unknown values dropped with a warning; text cut to 255; multi-picklists accumulate, no duplicates, No Data dropped once a real value exists |
| Rule C | latest score / reason / risks win; score bounded 1–100 and rounded; non-numeric or missing score keeps the old one; empty reason keeps the old one |
| Service | one call per meeting in JSON mode with the BA prompt (no Section 5); success saves, ticks, writes both logs (Event Id, model, tokens); later meetings merge onto earlier ones; HTTP 500 → nothing changed, unticked; not JSON → Parse Error; short note → no call; **after a 503 the rest of the run is held back**; 429 reported as rate-limited |
| Job | saving a MOM starts the background job; a short note doesn't; 3 per job; backfill takes the past year only; **503 → queued again in 2 min, gives up after 3 calls; 429 → no quick retry, one hourly retry scheduled (only once); held-back deals go first; backfill stops at the first 429; the hourly retry runs the backfill**; other errors not retried |

## 3. Filter (instant process, manual)

On **AIDI Test 1 - Filter**, create each Event from test-data.md §1, wait about 1 minute, then check **Setup → Apex Jobs**, the logs, and **AI Processed** on the Event.

| # | Type | Subject | Description | Expected |
|---|------|---------|-------------|----------|
| 3.1 | Web Meeting | Web Meeting - 1. Initial Meeting / Hearing | long note | ✅ analysed, deal updated, Event ticked |
| 3.2 | On-site / Visit | On-site / Visit - 3. Proposal / Quote Submission | long note | ✅ analysed |
| 3.3 | Web Meeting | Web Meeting - 3. Proposal / Quote Submission | long note | ✅ analysed (this Subject was once cut from the config) |
| 3.4 | Dinner / Event | Dinner / Event - 1. Initial Meeting / Hearing | long note | ❌ no job, no log |
| 3.5 | Web Meeting | Catch-up | long note | ❌ nothing |
| 3.6 | Web Meeting | Web Meeting - 1. Initial Meeting / Hearing | `called, no answer` | ❌ nothing |
| 3.7 | Web Meeting | Web Meeting - 1. Initial Meeting / Hearing | long note, Related To an **Account** | ❌ nothing |
| 3.8 | Edit 3.6 → paste the long note | | | ❌ nothing (only new meetings) |

## 4. Merge rules (instant process, manual)

On **AIDI Test 2 - Merge Rules**, log meetings A, B, C from test-data.md §2 one at a time, checking the deal after each.

1. **Meeting A**
   - [ ] Budget, Decision Maker and Schedule flags ✅; Initial Budget = the words in the note; Product Competitors = SAP; Release Date filled.
   - [ ] Fields with nothing to say show **No Data** (AI stage **Cannot Determine**), not blank.
   - [ ] Score, Reason, Risks filled; Score 1–100.
2. **Meeting B** (demo only)
   - [ ] **Rule A:** flags from A still ✅.
   - [ ] **Rule B:** budget, competitors, release date unchanged.
   - [ ] **Rule C:** Score, Reason, Risks replaced; score lower (no next meeting).
3. **Meeting C** (running cost, Odoo, "check with my boss")
   - [ ] Running Budget changes from No Data to the note's words; Initial Budget unchanged.
   - [ ] Competitors = **SAP;Odoo**.
   - [ ] Reason mentions the polite non-commitment (Kreng-jai).
4. - [ ] Edit Score by hand, log another meeting → Score overwritten.
5. - [ ] Standard **Stage** untouched; only **Opportunity Stage** (AI) changes.
6. - [ ] Saving the deal or the Event did not start another job.

## 5. Logs

For any analysed meeting:

- [ ] 5.1 **AI Analysis Log**: Status Success (or Partial, with Details saying why), model, input / output tokens, Changes listing each field, Response = one JSON with 33 keys and no Markdown table.
- [ ] 5.2 **Gemini Opty Log**: one row per call, with Event Id, Model, Status Success / Fail, Input / Output / Total tokens, JSON Log; Error Message filled on failures.
- [ ] 5.3 A retried meeting has one row per attempt; the last one is the outcome.

## 6. Batch (backfill)

1. Run the reset script (`DRY_RUN = false`) so the AIDI Test 3 / 4 and Gemini MOM meetings wait again.
2. Run in Anonymous Apex:
   ```apex
   DealIntelligenceJob.runBackfill();
   ```
3. Check:
   - [ ] 6.1 Setup → Apex Jobs: batch **Completed**, 0 failed chunks.
   - [ ] 6.2 Summary email arrives (if sandbox email is on): analysed + failed + skipped add up.
   - [ ] 6.3 AIDI Test 3: only the 3 meetings in the past year with real notes are analysed (not the 400-day-old one, not "Sent follow-up email."); Competitors **SAP;Odoo**; Initial Budget from March, Running Budget from September; Score / Reason / Risks describe the September meeting.
   - [ ] 6.4 Run the backfill **again** → no new log rows.

## 7. Errors, retries and safety

- [ ] 7.1 Set `GeminiMODEL` to a made-up name, log a meeting → both logs `Failed` / `Fail`, deal unchanged, Event unticked. Set it back.
- [ ] 7.2 **503 (busy):** when it happens, the log says `HTTP 503`; about 2 minutes later a new `DealIntelligenceJob` appears in Apex Jobs and the meeting is analysed; after 3 calls in all it stops (next backfill picks it up).
- [ ] 7.3 **429 (rate limit):** the log says `HTTP 429`; no more calls in that run; **Setup → Scheduled Jobs** shows one *AI Deal Intelligence - retry after Gemini rate limit*, about an hour ahead (never two). When it runs, the held-back deals are analysed first, then the rest; if Gemini still refuses, a new one appears an hour later.
- [ ] 7.4 A deal failing a validation rule doesn't stop other deals in the same chunk.
- [ ] 7.4a Nightly: run `DealIntelligenceJob.scheduleNightly();` twice → Setup → Scheduled Jobs shows one *AI Deal Intelligence - nightly backfill*, next run 02:00. Leave a meeting waiting (e.g. reset one) → next morning it is analysed.
- [ ] 7.5 `grep -rn "AQ\.\|AIza" force-app` finds **no** API key in tracked source (`GeminiCalloutService.cls` is untracked and still has one — see implementation-plan §0).

## 8. Demo readiness

- [ ] 8.1 Three demo deals: real data where the meetings had it, "No Data" elsewhere.
- [ ] 8.2 Thai meeting (AIDI Test 4, or the Thai stress deal): Reason and Risks make sense in a Thai business context. **Judge this on a Flash model**, not Lite — it decides the manager's model choice.
- [ ] 8.3 Tokens for the backfill noted for the manager (sum of Gemini Opty Log `Token_Used__c`).

## 9. Stress test (optional, ~150 Gemini calls)

1. Create the data (25 regular + 4 edge-case deals; `DEAL_COUNT` at the top):
   ```bash
   sf apex run --file scripts/apex/ai-deal-intelligence-stress-data.apex --target-org dev5-ts
   ```
2. `DealIntelligenceJob.runBackfill();` and wait for the batch, any retry jobs and any hourly retry to finish.
3. Report:
   ```bash
   sf apex run --file scripts/apex/ai-deal-intelligence-stress-check.apex --target-org dev5-ts 2>&1 | grep CHECK
   ```
   - [ ] Regular deals complete (competitors = the expected four, score set); the incomplete ones are explained by the log.
   - [ ] Edge cases: long note analysed; same-day score from the 16:00 meeting; unknown products as "Others"; Thai score low.
4. Remove: reset script with `DELETE_STRESS_DEALS = true`.
