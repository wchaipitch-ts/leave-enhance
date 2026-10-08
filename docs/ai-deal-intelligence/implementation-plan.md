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

```
 EventTrigger (after insert) ──► MomFilter ──► MomAnalysisQueueable ─┐
                                                                     ├─► DealIntelligenceService
 DealIntelligenceBackfillBatch ──► MomFilter ────────────────────────┘        │
                                                                             ├─ DealIntelligencePrompt  (BA prompt + MOM text)
 (future) Meet transcript source ───────────────────────────────────────────►├─ GeminiClient            (1 callout → 1 JSON)
                                                                             ├─ DealIntelligenceMerger  (Rules A / B / C)
                                                                             └─ AI_Analysis_Log__c      (audit + tokens)
```

Everything after the filter takes a **`MomInput`** (`opportunityId`, `sourceId`, `meetingDate`, `text`). Event is just today's source (FR-F1).

### 2.1 New metadata

| Metadata | Purpose |
|----------|---------|
| Static resource `DealIntelligencePrompt` (text) | The BA prompt, Sections 1–4, without Section 5 (FR-9, D2). It is versioned in git, and the BA can update it without code changes. |
| `Program_Constant__mdt` records | `GeminiMODEL` (Flash), `AI_MOM_Types`, `AI_MOM_Subjects` (semicolon lists, FR-10/11), `AI_MOM_Min_Length` = `100`. |
| Named Credential + External Credential `Gemini` | **AI Studio** (D5). URL `https://generativelanguage.googleapis.com`, custom header `x-goog-api-key` = `{!$Credential.Gemini.ApiKey}`. The key is entered in Setup in each org, never in git. Moving to Vertex later only changes this credential and the URL path. |
| `AI_Analysis_Log__c` object | `Opportunity__c`, `Event_Id__c`, `Model__c`, `Status__c` (Success / Failed / Parse Error / Partial), `Input_Tokens__c`, `Output_Tokens__c`, `Raw_Response__c` (Long Text 131k), `Error__c`, `Fields_Changed__c`. Also gives a score history for the future dashboard. |
| Permission set `AI_Deal_Intelligence` | See §1. |

Merge rules don't need their own config. They follow the field: #1–17 → A, #18–30 → B, #31–33 → C. That is a fixed list in `DealIntelligenceMerger`.

### 2.2 Apex classes

| Class | Responsibility |
|-------|----------------|
| `MomFilter` | `isQualifying(Event e)`: Type in list **and** Subject in list (D3), trimmed Description ≥ 100, `AI_Processed__c = false`, WhatId prefix `006`. Pure logic, easy to unit test. |
| `MomInput` | Data class, `fromEvent(Event)`. |
| `DealIntelligencePrompt` | Loads the static resource and replaces `{{INSERT_MINUTES_OF_MEETING_HERE}}` with the Description. |
| `GeminiClient` | `GeminiResponse generate(String prompt)`. Body: `contents` + `generationConfig { responseMimeType: "application/json", temperature: 0.2 }`. Model from config, endpoint `callout:Gemini/v1beta/models/{model}:generateContent`, timeout 60 s. Returns the JSON text, token counts and HTTP status. **No DML** (all callouts run before any DML). |
| `DealIntelligenceMerger` | `MergeResult merge(Opportunity current, Map<String,Object> aiJson)`: strips the `N_` key prefix (FR-8), then applies Rule A / B / C per field. **Rule B:** a "no data" value is written only if the field is blank; real data overwrites. Multi-picklist: **union** of the existing and new values (D4), with `No Data` dropped when any real value is present. Invalid picklist value → treated as no data. Text truncated to 255. Score parsed and clamped to 1–100; a missing/non-numeric Score or an empty Reason keeps the old value (D8). Returns the updated record plus the list of changes and warnings. **Pure — no SOQL/DML.** |
| `DealIntelligenceService` | `analyse(List<MomInput>)`: (1) call Gemini for each input; (2) query the Opportunities once; (3) merge in order oldest → newest; (4) `Database.update(opps, false)`; (5) set `AI_Processed__c = true` **only** on Events whose result was saved; (6) insert logs. |
| `DealIntelligenceBackfillBatch` | `Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful`. Query: `Event WHERE ActivityDate = LAST_N_DAYS:365 AND What.Type = 'Opportunity' AND Type IN :types AND Subject IN :subjects AND AI_Processed__c = false ORDER BY WhatId, ActivityDateTime, CreatedDate`. The Description length check is done in Apex, because SOQL can't filter long text. **Scope 3–5** to stay under 120 s of callout time. `finish`: email a summary (processed / skipped / failed / tokens). |
| `MomAnalysisQueueable` | `Queueable, Database.AllowsCallouts`. Takes Event Ids, processes a few per job, chains the rest. |
| `EventTriggerHandler` (extend) | After insert only (FR-2): filter, then enqueue `MomAnalysisQueueable`. Our own update that sets `AI_Processed__c` is an *update*, so it can't re-trigger. |

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
| HTTP ≠ 200 / timeout / 429 | Log `Failed`. Opportunity untouched, `AI_Processed__c` stays false, so the next run retries it. |
| Invalid JSON | Log `Parse Error` with the raw response. No update. |
| One field bad (picklist / number) | Skip that field only, log `Partial` with a warning. |
| Opportunity update fails (validation rule, lock) | `Database.update(…, false)`. The Event stays unprocessed and the error is logged. |

## 3. Work breakdown (~30 h)

| # | Task | h |
|---|------|---|
| 1 | Rename field; retrieve fields; permission set | 2 |
| 2 | Credentials: Named/External Credential for AI Studio | 2 |
| 3 | Static resource prompt, constants, `AI_Analysis_Log__c` | 2 |
| 4 | `GeminiClient` + `MomInput` + `MomFilter` | 3 |
| 5 | `DealIntelligenceMerger` (Rules A/B/C, multi-picklist, coercion) | 5 |
| 6 | `DealIntelligenceService` + log | 3 |
| 7 | Prompt check: run 5–10 real MOMs (Thai + English), confirm the JSON keys and values parse | 3 |
| 8 | `DealIntelligenceBackfillBatch` + dry run | 3 |
| 9 | Event trigger + `MomAnalysisQueueable` | 2 |
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
   Database.executeBatch(new DealIntelligenceBackfillBatch(), 5);
   ```

> Team baseline: the full sandbox test run has ~63 pre-existing failures. Deploy with `--test-level RunSpecifiedTests` and name the new test classes.
>
> If the AI Studio daily quota is hit, the batch just leaves the rest with `AI_Processed__c = false`. Run it again the next day.

## 5. Switching model later

Change `Program_Constant__mdt.GeminiMODEL` (e.g. to `gemini-3.1-pro`). No code change. The log records the model. To compare models on the same MOMs, set `AI_Processed__c = false` on a sample and re-run.
