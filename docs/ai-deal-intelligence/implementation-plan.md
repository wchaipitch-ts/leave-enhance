# AI Deal Intelligence — Implementation Plan

Read with [requirements.md](requirements.md). FR-x, D-x and O-x refer to that file.
Status: **built and tested in the sandbox `dev5-ts`** (8 Oct 2026).

---

## 0. What was there before, and what happened to it

| Item | Before | Now |
|------|--------|-----|
| 33 Opportunity fields | In the sandbox (Meng); `Proposed_Products_c__c` misnamed | ✅ Renamed to `Proposed_Products__c` (D1). ⚠️ **Still only in the sandbox, not in this repo** — retrieve before deploying elsewhere (O3). |
| `Event.AI_Processed__c` | In the sandbox | Used as the "done" tick. ⚠️ Not in this repo either (O3). |
| BA prompt | Google Sheet | Static resource `DealIntelligencePrompt`, Sections 1–4 (D2). |
| `Gemini_Opty_Log__c` | Team object, sandbox only | Retrieved into the repo; 5 fields added (D10); written on every call (D9). |
| `GeminiCalloutService`, `GeminiCallOutPOC` (untracked PoC) | `@future` call with the key in a URL parameter | Pattern only — not used. ⚠️ `GeminiCalloutService.cls` line 3 still holds an API key in a comment; delete the line before that file is ever committed, and treat the key as exposed. |
| `Program_Constant__mdt.GeminiMODEL` | `gemini-3.1-flash-lite` (PoC) | Now drives our model; `gemini-3.5-flash-lite` while on the free tier (D11). The old PoC classes read it too. |
| `EventTrigger` / `EventTriggerHandler` | Before update / delete only | After insert → `DealIntelligenceJob.enqueueFor`. |
| `OpportunityTrigger` | Email-draft PoC | Untouched. Our updates don't start anything AI-related. |
| `Gemini_OAuth_NC` / `Gemini_OAuth_EC` | Someone's Vertex OAuth attempt | Untouched; not used. |

## 1. Prerequisites — status

1. ✅ Rename `Proposed_Products_c__c` → `Proposed_Products__c` (D1).
2. ⏳ Retrieve the 33 fields and `Event.AI_Processed__c` into the project (O3). The code compiles against the org today; any other org needs them deployed first. (Per the team's note, `--output-dir` retrieves 0 files in this org — retrieve into the project, or mdapi-retrieve to a scratch dir and copy across.)
3. ✅ Permission set `AI_Deal_Intelligence` — access to the Gemini credential, read on both logs. No edit access on the 33 fields is needed: the service writes in system mode.

## 2. Architecture

Three Apex classes plus their tests:

```
 Event saved (trigger, after insert) ──► DealIntelligenceJob.RealTime (Queueable) ─┐
 DealIntelligenceJob.runBackfill() ────► DealIntelligenceJob (Batchable) ──────────┤
 Hourly retry after a 429 ─────────────► DealIntelligenceJob (Schedulable) ─────────┘
                                                        │
                                                        ▼
                                     DealIntelligenceService ── prompt, Gemini call, lock + save, logs
                                                        │
                                                        ▼
                                     DealIntelligenceRules ──── filter + merge rules (no SOQL / DML)
```

The service works from the meeting text plus the Opportunity Id. Event is just today's source; a Meet transcript can be added later without changing the rules (FR-F1).

### 2.1 Metadata

| Metadata | Purpose |
|----------|---------|
| Static resource `DealIntelligencePrompt` | The BA prompt, Sections 1–4 (Section 5's Markdown table dropped, D2). The MOM replaces `{{INSERT_MINUTES_OF_MEETING_HERE}}`. |
| `Program_Constant__mdt` records | `GeminiMODEL`; `AI_MOM_Types`; `AI_MOM_Subjects` + `AI_MOM_Subjects_2`; `AI_MOM_Min_Length` = `100`. **`Value__c` holds only 255 characters and a longer value is cut silently on deploy**, so the Subject list is read from every record whose name starts with `AI_MOM_Subjects` — add `AI_MOM_Subjects_3` rather than lengthening one. |
| Named Credential + External Credential `Gemini_AI_Studio` | AI Studio (D5). URL `https://generativelanguage.googleapis.com`; header `x-goog-api-key` = `{!$Credential.Gemini_AI_Studio.ApiKey}`. **Per org, by hand:** Setup → External Credentials → Gemini AI Studio → principal `Gemini_AI_Studio_Principal` → parameter `ApiKey`. The Named Credential **must** have *Allow Formulas in HTTP Header* on (`allowMergeFieldsInHeader`), or the key is never filled in and Google answers `API_KEY_INVALID`. `AQ.`-style keys work this way. |
| `AI_Analysis_Log__c` (new) | `Opportunity__c`, `Event_Id__c`, `Model__c`, `Status__c` (Success / Partial / Failed / Parse Error / Save Failed), `Input_Tokens__c`, `Output_Tokens__c`, `Response__c`, `Changes__c`, `Details__c`. |
| `Gemini_Opty_Log__c` (team object) | `Opportunity__c`, `Event_Id__c`, `Model__c`, `Status__c` (`Success` for our Success/Partial, `Fail` otherwise), `Error_Message__c`, `Token_Used__c`, `Input_Token__c`, `Output_Token__c`, `JSON_Log__c` (Gemini's JSON, or the error). |
| Permission set `AI_Deal_Intelligence` | Gemini principal access + read on both logs and their fields. **Every rep who logs MOMs needs it** — real-time runs as the rep. |

Merge rules follow the field, no config: #1–17 → A, #18–30 → B, #31–33 → C (a fixed list in `DealIntelligenceRules`).

### 2.2 Apex classes

| Class | Responsibility |
|-------|----------------|
| `DealIntelligenceRules` | **Filter** `isMom(Event)` / `qualifying(List<Event>)`: Type **and** Subject in the config lists (D3, case and spaces ignored), trimmed Description ≥ 100, not ticked, on an Opportunity. Missing config → nothing qualifies (never blocks a save). `momTypes()` / `momSubjects()` for the backfill query. **Merge** `mergeAnswer(Opportunity, Map)` (`merge` is reserved in Apex): strips the `N_` key prefix; Rule A; Rule B ("No Data" only fills a blank, real data overwrites, multi-picklists accumulate, invalid picklist values dropped with a warning, text cut to field length); Rule C (Score clamped 1–100; non-numeric Score or empty Reason keeps the old value). Applies changes to the record it is given, returns `changes` + `warnings`. No SOQL / DML. |
| `DealIntelligenceService` | `analyse(List<Id> eventIds)`: re-reads the Events (oldest first per deal) and re-checks the filter; calls Gemini per meeting — `responseMimeType: application/json`, no temperature (Google advises the default for Gemini 3), 60 s timeout, all callouts before any DML; **after the first refusal (503/429) the rest of the run is held back**; reads the deals **`FOR UPDATE`** (so two jobs on one deal can't lose each other's changes; still locked → handed back as busy); merges; saves with `Database.update(…, false)`; ticks only Events whose deal saved; writes both logs. Without sharing, system mode. Returns a `Summary` (counts, tokens, `busy`, `deferred`, `rateLimited`). |
| `DealIntelligenceJob` | **Batchable** (`runBackfill()`, 3 per chunk): `start` returns the pending past-year MOMs ordered by deal and meeting date, with **deals held back by a 429 put first** (found through `Failed` logs of the last 7 days whose Details start `HTTP 429`). **Queueable** inner class `RealTime` (one class can't be both Queueable and Batchable): 3 per job, chains the rest; started by `enqueueFor` from the trigger, which never throws. **Schedulable**: the hourly retry. **Inner class `Nightly`** (Schedulable): the backfill at 02:00 (`0 0 2 * * ?`, in the switching-on user's time zone), switched on by `scheduleNightly()` (a second call changes nothing). Retry policy in §2.4. A backfill started by hand emails a summary; scheduled ones run quietly. |
| `EventTriggerHandler` (extended) | After insert: `DealIntelligenceJob.enqueueFor(Trigger.new)`. Our own tick is an update, so it can't re-trigger. |

Processing order: chunks run one after another in `start`'s order — deal by deal, oldest meeting first — so each deal ends on its latest meeting (FR-20), also when one deal's meetings span two chunks.

### 2.3 Request

```json
{
  "contents": [{ "role": "user", "parts": [{ "text": "<BA prompt with MOM inserted>" }] }],
  "generationConfig": { "responseMimeType": "application/json" }
}
```

`POST callout:Gemini_AI_Studio/v1beta/models/{GeminiMODEL}:generateContent`. A `responseSchema` is optional; the BA prompt carries a JSON template and the stress test parsed every answer.

### 2.4 Failure handling

| Case | Behaviour |
|------|-----------|
| 503 (Gemini busy for a moment) | Log `Failed`; the rest of the run is held back; queued again 2 minutes later, up to 3 calls per meeting; after that it waits for the next backfill. |
| 429 (rate limit or quota) | Log `Failed`; nothing more is sent; **one scheduled retry an hour later** (*AI Deal Intelligence - retry after Gemini rate limit*, Setup → Scheduled Jobs — a queued job can wait at most 10 minutes). It runs the backfill with the held-back deals first, then everything else still unticked, and pauses again if Gemini still refuses. Only one such retry is ever waiting. |
| Other HTTP errors / timeout | Log `Failed`; deal untouched; meeting unticked → next backfill (the nightly one, once switched on). |
| Invalid JSON | Log `Parse Error` with the raw answer; no update. |
| One field bad (picklist / number) | That field skipped, log `Partial` with a warning. |
| Opportunity save fails (validation rule) | `Database.update(…, false)`; meeting unticked; error logged as `Save Failed`. |
| Two jobs on one deal | Deal read `FOR UPDATE`; the second job waits and merges onto the first's result. Still locked after Salesforce's wait → `Save Failed`, retried like a 503. |

## 3. Work breakdown (~30 h)

| # | Task | Status |
|---|------|--------|
| 1 | Rename field; permission set; retrieve fields | ✅ / ✅ / ⏳ retrieve (O3) |
| 2 | Credentials for AI Studio | ✅ (key entered in the sandbox) |
| 3 | Static resource prompt, constants, logs | ✅ |
| 4 | `DealIntelligenceRules`: filter | ✅ |
| 5 | `DealIntelligenceRules`: merge | ✅ |
| 6 | `DealIntelligenceService` | ✅ |
| 7 | Prompt check on real-looking MOMs (Thai + English) | ✅ end-to-end test + stress test |
| 8 | `DealIntelligenceJob` backfill + dry run | ✅ |
| 9 | Event trigger + real-time | ✅ |
| 10 | Unit tests, test data, testing-steps, backfill | ✅ 53 tests; manual checklist for the team |
| — | Added along the way: retries (503 / hourly 429), deal lock, Gemini Opty Log fields, test scripts | ✅ |

## 4. Deploy order (any new org)

1. The 33 Opportunity fields + `Event.AI_Processed__c` (retrieve first — O3) + layout
2. `Gemini_Opty_Log__c` and its fields, `AI_Analysis_Log__c`, custom metadata records, static resource
3. Named + External Credential `Gemini_AI_Studio`; then enter `ApiKey` in Setup
4. Permission set `AI_Deal_Intelligence`; assign to reps and to whoever runs the backfill
5. Apex classes + tests, then the Event trigger / handler change
6. `DealIntelligenceJob.runBackfill();`

> **Scheduled jobs block deploys:** `dev5-ts` has *Allow deployments of components when corresponding Apex jobs are pending or in progress* **off**, so while the nightly job (or a waiting hourly retry) is scheduled, deploying `DealIntelligenceJob` fails. Turn that setting on, or delete the scheduled jobs first (Setup → Scheduled Jobs) and run `scheduleNightly()` again after.
>
> Team baseline: the full sandbox test run has ~63 pre-existing failures. Deploy with `--test-level RunSpecifiedTests --tests DealIntelligenceRulesTest --tests DealIntelligenceServiceTest --tests DealIntelligenceJobTest --tests EventTriggerTest`.

## 5. Switching model

Change `Program_Constant__mdt.GeminiMODEL` — no code change; both logs record the model. To compare models on the same MOMs, run the reset script on a sample and re-run the backfill. Free-tier quotas are **per model**.

> Google notice (Oct 2026): **`gemini-3.7-flash` is deprecated** and redirected to `gemini-3.8-flash` (same pricing). Don't set `GeminiMODEL` to 3.7; for Flash use `gemini-3.8-flash`. The end-to-end test in §6 ran on 3.7 before the change.

## 6. Test results (8 Oct 2026, sandbox)

**End to end** (`gemini-3.7-flash`, one realistic English MOM): all 33 fields filled correctly; score 75 with the BA's arithmetic spelled out (50 + 15 budget/timeline + 10 customer homework); risks named the SAP integration, data migration and two competitors.

**Stress test** (`gemini-3.5-flash-lite`, 29 deals / 131 meetings from `scripts/apex/ai-deal-intelligence-stress-data.apex`, checked with `…-stress-check.apex`):

| | Run 1 | Run 2 (after fixes, from a reset) |
|---|---|---|
| Batch | 25 chunks, 0 errors | 47 chunks in ~4 min, 0 errors |
| Gemini calls | 64 | 144: 100 Success, 4 Partial, 40 × 429 (per-minute limit) |
| Regular deals exactly as expected | 0 of 25 | 19 of 25 |
| Found | Subject list cut at 255 characters → every "Web Meeting - 2/3" skipped (also in real time). **Fixed.** | Two jobs saving one deal lost a competitor. **Fixed** (`FOR UPDATE`). |

Run 2's other 4 deals: 2 had a meeting give up after 3 quick 429 retries (since replaced by the hourly retry, D12); 2 had Gemini put a product (Cloudee) in the SI list — dropped with a warning (model quality). Edge cases: an ~8,000-character note was fine; same-day meetings merged in time order; unknown products stored as "Others", never as invalid values; Thai polite deferral scored 5.

Not yet re-run after the last two changes (deal lock, hourly 429 retry) — their unit tests pass.

## 7. Open items

See requirements.md §8: O1 ordering after a late retry (needs one more Opportunity field), O2 billing + Flash model, O3 Production prerequisites.
