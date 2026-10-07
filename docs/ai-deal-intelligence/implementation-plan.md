# AI Deal Intelligence — Implementation Plan

Read with [requirements.md](requirements.md). FR-x numbers refer to that file.

---

## 0. Starting point (what already exists)

| Item | State | Reuse? |
|------|-------|--------|
| `GeminiCalloutService` | `@future` callout to AI Studio, sets `responseMimeType` | Pattern only. `@future` can't be called from Batch Apex, so the new code uses a plain synchronous service called from Batch / Queueable. |
| `GeminiCallOutPOC.parseGeminiResponse` | Parses `candidates[0].content.parts[0].text` + token counts | Yes — move into the new client. |
| `Program_Constant__mdt` `GeminiMODEL` / `GeminiAPI_KEY` | Model + key as config | Model: yes. Key: move to Named Credential (FR-2.17). |
| `OpportunityTrigger` / `OpportunityTriggerHandler` | Email-draft PoC on Opportunity insert/update | Leave alone. Must not fire AI analysis (FR-2.16). |
| `EventTrigger` | Exists | Add one handler call. |
| Task trigger | None | Create `TaskTrigger`. |
| Opportunity fields | **Not in this repo** — created in the org by Meng | Retrieve first (see §1). |

> ⚠️ `GeminiCalloutService.cls` line 3 has a real-looking API key in a comment. The file is untracked today — remove the line (and rotate the key) before anything is committed.

## 1. Dependency — Opportunity fields

The 33 fields and layout sections are built outside this branch (Meng). Before coding the mapping:

1. Get the agreed 33-item table (requirements.md §2, Q1).
2. Retrieve the fields into the project so the classes compile against them. (Per the team's note, `--output-dir` retrieves 0 files in this org — use `sf project retrieve start --metadata "CustomField:Opportunity.*"` into the project, or the mdapi retrieve to a scratch dir and copy across.)
3. Give the user running the batch / queueable edit access to all 33 fields (permission set `AI_Deal_Intelligence`).

## 2. Architecture

```
 Task/Event trigger ──► MomFilter ──► MomAnalysisQueueable ─┐
                                                           ├─► DealIntelligenceService
 DealIntelligenceBackfillBatch ──► MomFilter ──────────────┘        │
                                                                   ├─ GeminiClient            (1 callout, JSON in/out)
 (future) MeetTranscriptSource ───────────────────────────────────►├─ DealIntelligencePrompt  (prompt + responseSchema)
                                                                   ├─ DealIntelligenceMerger  (Rules A/B/C)
                                                                   └─ AI_Analysis_Log__c      (audit + tokens)
```

Key idea: everything after the filter takes a **`MomInput`** (`opportunityId`, `sourceId`, `sourceType`, `meetingDate`, `text`). Task/Event is just one source; a Meet transcript becomes another (FR-F1).

### 2.1 New metadata

| Metadata | Purpose |
|----------|---------|
| `AI_Extraction_Field__mdt` | One row per item: `JSON_Key__c`, `Field_API_Name__c`, `Merge_Rule__c` (`KEEP_TRUE` / `IGNORE_NO_DATA` / `ALWAYS_OVERWRITE`), `Data_Type__c`, `Prompt_Description__c`, `Sort_Order__c`. Drives prompt, schema and merge (FR-F2). 33 records. |
| `Program_Constant__mdt` records | `GeminiMODEL` → Flash model; `AI_MOM_Types` → `Meeting;On-site / Visit;Web Meeting`; `AI_MOM_Min_Length` → `100`; `AI_No_Data_Tokens` → `No Data;Cannot Determine;N/A;Unknown;null;ไม่มีข้อมูล;ไม่ทราบ`. |
| Named Credential + External Credential `Gemini` | Endpoint + auth. AI Studio: API key as header `x-goog-api-key`. Vertex: OAuth JWT bearer with a GCP service account. Decided by Q2. |
| `Task`/`Event` fields `AI_Analyzed_At__c` (DateTime), `AI_Analysis_Status__c` (picklist) | Idempotency (FR-2.11) + visibility. |
| `AI_Analysis_Log__c` object | `Opportunity__c`, `Source_Id__c`, `Model__c`, `Status__c`, `Input_Tokens__c`, `Output_Tokens__c`, `Raw_Response__c` (LTA 131k), `Error__c`, `Fields_Changed__c`. (FR-2.5, FR-2.15; also gives score history for Q7.) |
| Activity Type picklist values | Add `On-site / Visit`, `Web Meeting` if missing (Q4). |

### 2.2 Apex classes

| Class | Responsibility |
|-------|----------------|
| `MomFilter` | `isQualifying(type, description, whatId)`: type in list, trimmed length ≥ 100, WhatId prefix `006`, not already analysed. Pure logic → easy to unit test. |
| `MomInput` | Plain data class (see above). `fromTask(Task)`, `fromEvent(Event)`. |
| `GeminiClient` | `GeminiResponse generate(String prompt, Map<String,Object> schema)`. Builds body with `generationConfig.responseMimeType = 'application/json'` and `responseSchema`; reads model from config; `callout:Gemini/...`; timeout 60 s; returns text + tokens + status. No DML (callouts first, DML later). |
| `DealIntelligencePrompt` | Builds the prompt from `AI_Extraction_Field__mdt`: role (Thai B2B sales analyst), the MOM text + date, the opportunity's name/stage for context, instruction "return `null` when not stated — never guess", item definitions. Builds the matching `responseSchema`. |
| `DealIntelligenceMerger` | `Opportunity merge(Opportunity current, Map<String,Object> aiJson)` applying Rules A/B/C per mdt row. Handles type coercion (string → number/date/boolean), invalid picklist → no data, text truncation to field length. Returns changed-field list for the log. **Pure — no SOQL/DML, fully unit-testable.** |
| `DealIntelligenceService` | `List<Result> analyse(List<MomInput>)`: for each input call Gemini (stop early if callout time budget near limit); then query Opportunities once; merge in order oldest → newest per Opportunity; one `Database.update(opps, false)`; insert logs; stamp `AI_Analyzed_At__c` on activities. |
| `DealIntelligenceBackfillBatch` | `Database.Batchable<MomInput>, Database.AllowsCallouts, Database.Stateful`. `start` returns an **`Iterable<MomInput>`**: query Tasks and Events (last 365 days, `WhatId` Opportunity, MOM types, `AI_Analyzed_At__c = null`), apply the length filter in Apex (SOQL can't filter Description length), then sort the combined list by Opportunity → meeting date → created date. One combined list is needed so a Task MOM and an Event MOM on the same deal are still merged oldest → newest. (Iterable start is fine for demo volumes; it is capped at 50k rows.) **Scope size 3–5** so ≤ 5 × ~20 s stays under the 120 s callout limit. `finish`: email summary (processed / skipped / failed / tokens). |
| `MomAnalysisQueueable` | `Queueable, Database.AllowsCallouts`. Takes a list of activity Ids; processes up to N per job, chains the rest. |
| `TaskTriggerHandler` / extend `EventTriggerHandler` | After insert (and after update if Q8 = yes): filter → enqueue `MomAnalysisQueueable`. Skip when `System.isBatch()` / `isQueueable()` already processing, and use a static guard against recursion. |

Order-of-processing note: Batch Apex runs chunks serially in iterable order, so the sorted list keeps each Opportunity's MOMs oldest → newest (FR-2.12). If one Opportunity's MOMs span two chunks, the second chunk re-queries the Opportunity, so it sees the merged values from the first chunk.

### 2.3 Request shape (AI Studio form; Vertex is the same body)

```json
{
  "contents": [{ "role": "user", "parts": [{ "text": "<prompt + MOM>" }] }],
  "generationConfig": {
    "responseMimeType": "application/json",
    "responseSchema": { "type": "OBJECT", "properties": { "...33 keys...": {} } },
    "temperature": 0.2
  }
}
```

Endpoints:
- AI Studio: `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`
- Vertex AI: `https://{region}-aiplatform.googleapis.com/v1/projects/{project}/locations/{region}/publishers/google/models/{model}:generateContent`

### 2.4 Failure handling

| Case | Behaviour |
|------|-----------|
| HTTP ≠ 200 / timeout | Log `Failed`, leave Opportunity and `AI_Analyzed_At__c` untouched → picked up on re-run. |
| 429 rate limit | Same; backfill can be re-run. Optional: `finish` re-launches for leftovers once. |
| Invalid JSON / missing keys | Log `Parse Error` + raw response; no update. |
| One field bad (picklist / number format) | Skip that field only, note in log. |
| Opportunity update fails (validation rule, lock) | `Database.update(…, false)`, log the error per row. |

## 3. Work breakdown (~30 h)

| # | Task | h |
|---|------|---|
| 1 | Answer Q1–Q4; get the 33-item table; retrieve fields | 2 |
| 2 | Credentials: Named/External Credential (+ GCP service account if Vertex) | 3 |
| 3 | Metadata: `AI_Extraction_Field__mdt` + 33 records, constants, log object, activity fields | 3 |
| 4 | `GeminiClient` + `MomInput` + `MomFilter` | 3 |
| 5 | `DealIntelligencePrompt` + schema; tune against 5–10 real MOMs (Thai + English) | 5 |
| 6 | `DealIntelligenceMerger` (Rules A/B/C, type coercion) | 4 |
| 7 | `DealIntelligenceService` + log | 3 |
| 8 | `DealIntelligenceBackfillBatch` + dry run on a small date range | 3 |
| 9 | Task/Event triggers + `MomAnalysisQueueable` | 2 |
| 10 | Unit tests (mocks), deploy, run backfill, run testing-steps.md | 2 |
| | **Total** | **30** |

Suggested order: 1 → 3 → 4 → 6 (merger is the risky part; test it first) → 2 → 5 → 7 → 8 (demo priority) → 9 → 10.

## 4. Deploy order

1. *(Prerequisite, outside this branch)* 33 Opportunity fields in the org; permission set `AI_Deal_Intelligence`
2. Custom metadata types + records, log object, activity fields, picklist values
3. Named/External Credential (then fill secrets in Setup — never in git)
4. Apex classes + tests
5. Triggers (Task, Event)
6. Run backfill from Anonymous Apex:
   ```apex
   Database.executeBatch(new DealIntelligenceBackfillBatch(), 5);
   ```

> Note (team baseline): the full org test run has ~63 pre-existing failures, so deploy with `--test-level RunSpecifiedTests` naming the new test classes.

## 5. Switching model later

Change `Program_Constant__mdt.GeminiMODEL` value (e.g. `gemini-3.1-pro`). No code change. Logs record the model, so before/after quality can be compared on the same MOMs (clear `AI_Analyzed_At__c` on a sample and re-run).
