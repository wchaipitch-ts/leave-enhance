# AI Deal Intelligence (Gemini × Opportunity)

Gemini reads each meeting minute (MOM) logged on an Opportunity, pulls out 33 data points, and writes them onto the Opportunity — so sales managers can see how serious a customer is and what could kill the deal, without reading every MOM.

A **demo MVP**, built to show customers; not a package. Built and tested in the sandbox `dev5-ts` (8 Oct 2026). Production comes later.

Branch: `feature/ai-deal-intelligence`

## Status

| | |
|---|---|
| Build | ✅ Done: filter, Gemini call, merge rules A/B/C, backfill, real-time, retries, two logs. 53 Apex tests pass. |
| Tested | ✅ End to end with real Gemini calls; stress test of 29 deals / 131 meetings (see [implementation-plan.md](implementation-plan.md) §6). |
| Model | `gemini-3.5-flash-lite` for now — the free tier allows only 20 calls a day on `gemini-3.8-flash`. Switch back to Flash once Google billing is on. |
| Before the demo | Turn on billing for the Google project; switch the model; decide the ordering limitation (§ Known limitations). |
| Before Production | Retrieve the 33 Opportunity fields and `Event.AI_Processed__c` into this repo (they exist only in the sandbox); enter the API key; assign the permission set to every rep. |

## Documents and scripts

| File | What's in it |
|------|-------------|
| [requirements.md](requirements.md) | Scope, the 33 fields, filter, merge rules, decisions |
| [implementation-plan.md](implementation-plan.md) | Design, classes, metadata, failure handling, stress-test results |
| [testing-steps.md](testing-steps.md) | Checklists: unit tests, manual tests, backfill, retries, stress test |
| [test-data.md](test-data.md) | The sandbox test records and ready-to-paste meeting notes |
| `scripts/apex/ai-deal-intelligence-reset.apex` | Clears the AI fields on the test deals and makes their meetings wait again (`DRY_RUN` first) |
| `scripts/apex/ai-deal-intelligence-stress-data.apex` | Creates the stress-test deals and meetings |
| `scripts/apex/ai-deal-intelligence-stress-check.apex` | Read-only report on a stress run |

## How it works

1. A rep logs a meeting as an **Event** on an Opportunity.
2. If it's a **real MOM** — Type **and** Subject in the BA's lists, at least 100 characters, not yet processed — it goes to Gemini with the BA's prompt. Dinners, short notes and Events on other objects are skipped.
3. Gemini returns **one JSON** with all 33 items.
4. Salesforce **merges** it into the Opportunity, never a plain overwrite:
   - **Checkboxes (17):** once true, stay true.
   - **Facts (13):** "No Data" only fills a blank, never replaces real data; competitor and product lists add up (`SAP;Odoo`).
   - **Score / Reason / Risks (3):** replaced by the latest meeting — except an empty Reason or a non-numeric Score keeps the old one.
5. The Event is ticked `AI_Processed__c`, so it is never analysed twice.

Two ways it runs — same filter, same Gemini call, same rules:

| | Batch (backfill) | Instant (real-time) |
|---|---|---|
| Starts | `DealIntelligenceJob.runBackfill();` or the hourly retry | A rep saves a new meeting |
| Takes | Every unticked MOM of the past year, deal by deal, oldest first | The meetings just saved |
| Runs as | Whoever started it | The rep (needs the permission set) |

When Gemini refuses a call: **503 (busy)** → tried again 2 minutes later, up to 3 times; **429 (rate limit / quota)** → everything pauses and one scheduled retry runs an hour later, doing the held-back deals first, then the rest.

Field list, filter values, rules and prompt come from the BA sheet [Gemini Opp](https://docs.google.com/spreadsheets/d/17Pd_wTmj5Zwxr9l2YMQUynawdlLy66LKJwErmsUvz2E/edit).

## Configuration

| Setting | Where |
|---------|-------|
| Gemini model | `Program_Constant__mdt` → `GeminiMODEL` (no code change to switch) |
| API key | Setup → Named Credentials → External Credentials → **Gemini AI Studio** → principal `Gemini_AI_Studio_Principal` → parameter `ApiKey`. Per org, never in git. The Named Credential `Gemini_AI_Studio` must keep *Allow Formulas in HTTP Header* on. |
| Who may call Gemini | Permission set **AI Deal Intelligence** — every rep who logs meetings, plus whoever runs the backfill |
| Prompt | Static resource `DealIntelligencePrompt` (the BA prompt, Sections 1–4) |
| MOM Types, Subjects, minimum length | `Program_Constant__mdt` → `AI_MOM_Types`, `AI_MOM_Subjects` + `AI_MOM_Subjects_2`, `AI_MOM_Min_Length`. Each value holds **255 characters at most** — add `AI_MOM_Subjects_3` rather than lengthening one. |

## Logs

Every call to Gemini writes one row to each (so a meeting that was retried has several rows — the last one is the outcome):

- **AI Analysis Log** (`AI_Analysis_Log__c`) — full detail: status (Success / Partial / Failed / Parse Error / Save Failed), the fields it changed, warnings, the raw answer.
- **Gemini Opty Log** (`Gemini_Opty_Log__c`, the team's log) — Success / Fail, Event Id, model, tokens (in, out, total), error message, the JSON.

## Run the backfill

```apex
DealIntelligenceJob.runBackfill();
```

Safe to re-run — ticked meetings are skipped. The person who starts it gets a summary email (if email is on). A pause for a rate limit shows in Setup → Scheduled Jobs as *AI Deal Intelligence - retry after Gemini rate limit*.

## Known limitations

- A meeting that is analysed *after* newer meetings of the same deal (it failed earlier and a later run picks it up) is merged last, so the score / reason / risks — and newer text values — can take its older view. Fix: one more Opportunity field holding the date of the latest meeting merged, so an older meeting only adds facts. To be decided.
- On the free tier, Gemini allows few calls per minute and per day; a year of real meetings needs billing on.

## What comes next

- Sales Management Dashboard on these 33 fields.
- Feed Google Meet transcripts instead of typed MOMs — the pipeline already takes plain text, so this is a new input source, not a rewrite.
