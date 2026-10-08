# AI Deal Intelligence — Implementation Plan

Read with [requirements.md](requirements.md). FR-x and Q-x numbers refer to that file.

---

## 0. Starting point (what already exists)

| Item | State | Reuse? |
|------|-------|--------|
| 33 Opportunity fields | ✅ In the sandbox (Meng). `Proposed_Products_c__c` is to be renamed to `Proposed_Products__c` (D1). **Not in this repo yet.** | Retrieve into the project (§1) so they are versioned with the feature. |
| `Event.AI_Processed__c` | ✅ In the org | Retrieve. |
| BA prompt | In the Google Sheet | Copy into a static resource (§2.1). |
| `GeminiCalloutService` | `@future` callout to AI Studio, sets `responseMimeType` | Pattern only. `@future` can't be called from Batch Apex, so the new client is plain synchronous code called from Batch / Queueable. |
| `GeminiCallOutPOC.parseGeminiResponse` | Reads `candidates[0].content.parts[0].text` + token counts | Move into the new client. |
| `Program_Constant__mdt` `GeminiMODEL` / `GeminiAPI_KEY` | Model + key as config | Model: yes. Key: move to a Named Credential (FR-24). |
| `EventTrigger` | Exists | Add one handler call. |
| `OpportunityTrigger` | Email-draft PoC | Leave alone. Our Opportunity update must not fire anything AI-related (FR-23). |

> ⚠️ `GeminiCalloutService.cls` line 3 has a real-looking API key in a comment. The file is untracked today. Remove the line (and rotate the key) before anything is committed.

## 1. Prerequisites

1. Rename `Proposed_Products_c__c` → `Proposed_Products__c` in the sandbox (D1). Delete-and-recreate is fine while the field holds no data.
2. Retrieve the fields into the project so the classes compile and deploy against them. (Per the team's note, `--output-dir` retrieves 0 files in this org. Retrieve into the project with `sf project retrieve start --metadata "CustomField:Opportunity.Competitor_Topic_Mentioned__c" …`, or do an mdapi retrieve to a scratch dir and copy across.)
3. Permission set `AI_Deal_Intelligence`: edit access on the 33 fields and `Event.AI_Processed__c` for whoever runs the batch, plus read access for demo users.

## 2. Architecture

Kept to **three Apex classes** (plus their tests):

```
 EventTrigger (after insert) ─┐
                              ├─► DealIntelligenceJob ──► DealIntelligenceService ──► DealIntelligenceRules
 Backfill (run once) ─────────┘   (Batchable + inner       (prompt, Gemini call,       (filter + merge rules,
                                   Queueable RealTime)
                                                            save, log)                  no SOQL / DML)
```

The service takes plain text plus the Opportunity Id. Event is just today's source, so a Meet transcript can be added later without changing the rules (FR-F1).

### 2.1 New metadata

| Metadata | Purpose |
|----------|---------|
| Static resource `DealIntelligencePrompt` (text) ✅ | The BA prompt, Sections 1–4, without Section 5 (FR-9, D2). It is versioned in git, and the BA can update it without code changes. |
| `Program_Constant__mdt` records ✅ | `GeminiMODEL`, `AI_MOM_Types`, `AI_MOM_Subjects` + `AI_MOM_Subjects_2` (semicolon lists, FR-10/11), `AI_MOM_Min_Length` = `100`. **`Value__c` holds only 255 characters and a longer value is cut silently on deploy**, so the Subject list is spread over every record whose name starts with `AI_MOM_Subjects`; add `AI_MOM_Subjects_3` etc. rather than lengthening one. |
| Named Credential + External Credential `Gemini_AI_Studio` ✅ | **AI Studio** (D5). URL `https://generativelanguage.googleapis.com`; the External Credential (Custom protocol) adds header `x-goog-api-key` = `{!$Credential.Gemini_AI_Studio.ApiKey}`. **Manual step per org:** Setup → External Credentials → Gemini AI Studio → principal `Gemini_AI_Studio_Principal` → add authentication parameter `ApiKey`. Never in git. The Named Credential **must** have *Allow Formulas in HTTP Header* on (`allowMergeFieldsInHeader`), otherwise the key formula is never filled in and Google answers `API_KEY_INVALID`. `AQ.`-style keys work with this header on the AI Studio endpoint (checked 8 Oct 2026). (The OAuth `Gemini_OAuth_NC` / `Gemini_OAuth_EC` someone created for Vertex is left untouched.) |
| `AI_Analysis_Log__c` object ✅ | `Opportunity__c`, `Event_Id__c`, `Model__c`, `Status__c` (Success / Partial / Failed / Parse Error / Save Failed), `Input_Tokens__c`, `Output_Tokens__c`, `Response__c` (Long Text 131k), `Changes__c`, `Details__c` (errors + warnings). Also gives a score history for the future dashboard. |
| `Gemini_Opty_Log__c` (existing team object, now in the repo) ✅ | One row per call (so one per meeting, plus one per retry) **as well as** `AI_Analysis_Log__c`: `Opportunity__c`, `Event_Id__c`, `Model__c`, `JSON_Log__c` (Gemini's JSON, or the error when there is none), `Status__c` (`Success` for our Success/Partial, `Fail` for Failed/Parse Error/Save Failed), `Error_Message__c`, `Token_Used__c` (input + output), `Input_Token__c`, `Output_Token__c`. |
| Permission set `AI_Deal_Intelligence` ✅ | Access to the `Gemini_AI_Studio` principal + read on the log. **Real-time runs as the rep who logs the meeting, so every such rep needs this permission set** — without it the callout fails. |

Merge rules don't need their own config. They follow the field: #1–17 → A, #18–30 → B, #31–33 → C. That is a fixed list in `DealIntelligenceRules`.

### 2.2 Apex classes

| Class | Responsibility |
|-------|----------------|
| `DealIntelligenceRules` ✅ | **Filter:** `isMom(Event)` / `qualifying(List<Event>)`: Type **and** Subject in the config lists (D3), trimmed Description ≥ 100, `AI_Processed__c = false`, related to an Opportunity. Missing config → nothing qualifies (it must never block a rep's save). `momTypes()` / `momSubjects()` for the backfill SOQL. **Merge:** `mergeAnswer(Opportunity, Map<String,Object>)` strips the `N_` key prefix (FR-8), then applies Rule A / B / C per field. Rule B: "no data" only fills a blank; real data overwrites; multi-picklists accumulate (D4); an invalid picklist value counts as no data; text is cut to the field length. Rule C: Score clamped to 1–100; a non-numeric Score or an empty Reason keeps the old value (D8). It applies changes to the record it's given and returns `changes` + `warnings`. **No SOQL / DML.** (`merge` is a reserved word in Apex, hence `mergeAnswer`.) |
| `DealIntelligenceService` ✅ | `Summary analyse(List<Id> eventIds)`: re-reads the Events and re-checks the filter, then (1) builds the prompt from the static resource and calls Gemini for each Event (`responseMimeType: "application/json"`, no temperature — Google advises the default for Gemini 3, model from `GeminiMODEL`, `callout:Gemini_AI_Studio`, timeout 60 s); (2) query the Opportunities once with `DealIntelligenceRules.fields()`; (3) `mergeAnswer` oldest → newest; (4) `Database.update(opps, false)`; (5) set `AI_Processed__c = true` **only** on Events whose result was saved; (6) insert logs. All callouts happen before any DML. Without sharing and in system mode (from API 67.0 SOQL/DML respect field access by default), because the rep may not own the deal or see the AI fields. Returns counts + tokens for the backfill email. |
| `DealIntelligenceJob` ✅ | One file for both modes. **Backfill** (the class itself): `Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful`; start with `DealIntelligenceJob.runBackfill()` (scope **3**). Query: `Event WHERE ActivityDate = LAST_N_DAYS:365 AND What.Type = 'Opportunity' AND Type IN :types AND Subject IN :subjects AND AI_Processed__c = false ORDER BY WhatId, StartDateTime, CreatedDate`; the service checks the length. `finish` emails the runner a summary (analysed / failed / skipped / tokens); if email is off in the sandbox it only goes to the debug log. **Real-time** (inner class `DealIntelligenceJob.RealTime`, `Queueable, Database.AllowsCallouts`): 3 meetings per job, chains the rest. It's an inner class because Salesforce refuses a class that is both Queueable and Batchable. `enqueueFor(List<Event>)` never throws, so a rep's save is never blocked; a meeting that can't be queued stays unticked for the next backfill. |
| `EventTriggerHandler` (existing, extended) ✅ | After insert only (FR-2): `DealIntelligenceJob.enqueueFor(Trigger.new)`. Our own update that sets `AI_Processed__c` is an *update*, so it can't re-trigger. |

Processing order: Batch Apex runs chunks one after another in query order. `ORDER BY WhatId, ActivityDateTime` therefore keeps each Opportunity's MOMs oldest → newest (FR-20). If one Opportunity's MOMs fall into two chunks, the second chunk re-reads the Opportunity and sees the first chunk's result.

### 2.3 Request shape

```json
{
  "contents": [{ "role": "user", "parts": [{ "text": "<BA prompt with MOM inserted>" }] }],
  "generationConfig": { "responseMimeType": "application/json", "temperature": 0.2 }
}
```

A `responseSchema` is optional. The BA prompt already contains a JSON template. We can add a schema later if Gemini drifts from the key names.

Endpoint (AI Studio, D5): `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`. Auth is the `x-goog-api-key` header added by the Named Credential.

### 2.4 Failure handling

| Case | Behaviour |
|------|-----------|
| 503 (Gemini busy for a moment) | Log `Failed`; the rest of that run is held back; queued again 2 minutes later, up to 3 calls per meeting. After that it waits for the next backfill. |
| 429 (rate limit or quota) | Log `Failed`; nothing more is sent. **One scheduled retry an hour later** (`AI Deal Intelligence - retry after Gemini rate limit`, Setup → Scheduled Jobs — a queued job can wait at most 10 minutes). It runs the backfill with the deals that hit the limit first (whole deals, oldest meeting first), then everything else still unticked, and pauses for another hour if Gemini still refuses. Only one such retry is ever waiting. |
| Other HTTP errors / timeout | Log `Failed`. Opportunity untouched, `AI_Processed__c` stays false, so the next backfill run retries it. |
| Invalid JSON | Log `Parse Error` with the raw response. No update. |
| One field bad (picklist / number) | Skip that field only, log `Partial` with a warning. |
| Opportunity update fails (validation rule, lock) | `Database.update(…, false)`. The Event stays unprocessed and the error is logged. |
| Two jobs on the same deal at once (a retry next to a backfill chunk) | The deal is read `FOR UPDATE`, so the second job waits for the first to save and merges onto its result. Without it the stress test lost competitors (last save won). Still locked after Salesforce's wait → `Save Failed`, retried like a busy answer. |

## 3. Work breakdown (~30 h)

| # | Task | h |
|---|------|---|
| 1 | Rename field; retrieve fields; permission set | 2 |
| 2 | ✅ Credentials: Named/External Credential for AI Studio (key still to be entered) | 2 |
| 3 | ✅ Static resource prompt, constants, `AI_Analysis_Log__c` | 2 |
| 4 | ✅ `DealIntelligenceRules`: filter | 3 |
| 5 | ✅ `DealIntelligenceRules`: merge (Rules A/B/C, multi-picklist, coercion) | 5 |
| 6 | ✅ `DealIntelligenceService`: prompt, Gemini call, save, log | 3 |
| 7 | Prompt check: run 5–10 real MOMs (Thai + English), confirm the JSON keys and values parse | 3 |
| 8 | ✅ `DealIntelligenceJob` (backfill); dry run still to do | 3 |
| 9 | ✅ Event trigger + `DealIntelligenceJob.RealTime` | 2 |
| 10 | Unit tests (mocks), realistic test Events, run testing-steps.md, run backfill | 5 |
| | **Total** | **30** |

Suggested order: 1 → 5 (merger is the risky part, so test it first) → 4 → 3 → 2 → 6 → 7 → 8 (demo priority) → 9 → 10.

## 4. Deploy order

Into the sandbox `dev5-ts` only (D7):

1. 33 Opportunity fields (with `Proposed_Products__c` renamed) + `Event.AI_Processed__c` + layout
2. Permission set, static resource, custom metadata records, log object
3. Named/External Credential (fill secrets in Setup, never in git)
4. Apex classes + tests
5. Event trigger change
6. Backfill from Anonymous Apex:
   ```apex
   DealIntelligenceJob.runBackfill();
   ```

> Team baseline: the full sandbox test run has ~63 pre-existing failures. Deploy with `--test-level RunSpecifiedTests` and name the new test classes.
>
> If the AI Studio daily quota is hit, the batch just leaves the rest with `AI_Processed__c = false`. Run it again the next day.

## 5. Switching model later

Change `Program_Constant__mdt.GeminiMODEL` (e.g. to `gemini-3.1-pro`). No code change. The log records the model. To compare models on the same MOMs, set `AI_Processed__c = false` on a sample and re-run.

## 6. Stress test (8 Oct 2026, sandbox, `gemini-3.5-flash-lite`)

29 deals / 131 meetings from `scripts/apex/ai-deal-intelligence-stress-data.apex`, checked with `…-stress-check.apex`.

- Batch: 47 chunks in ~4 min, 0 chunk errors. 144 Gemini calls: 100 Success, 4 Partial, 40 × 429 (per-minute limit); 45 retry jobs.
- 19 of 25 regular deals exactly as expected. Of the 6 others: 2 had one meeting give up after 3 × 429 (picked up by the next backfill), 2 had Gemini put a product (Cloudee) in the SI list (dropped with a warning — model quality), 2 lost a competitor to two jobs saving the same deal at once → **fixed with `FOR UPDATE`**.
- Edge cases: ~8,000-character note fine; same-day meetings merged in time order (score from the 16:00 "paused" meeting = 15); unknown products stored as "Others", never as invalid values; Thai polite deferral scored 5–10.
- Found and fixed: the Subject list was cut at 255 characters, so every "Web Meeting - 2/3" meeting was skipped (also in real time).

**Known limitation:** a meeting that fails for good and is picked up by a *later* backfill is merged after newer meetings, so Rule C (score/reason/risks) and Rule B (newer text values) can take the older meeting's view. Fix would need a "latest meeting applied" date on the Opportunity (one more field) so an older meeting only adds facts (flags, competitors, blanks) and never overwrites — to be decided.
