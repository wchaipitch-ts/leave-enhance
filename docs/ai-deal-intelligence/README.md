# AI Deal Intelligence (Gemini × Opportunity)

Gemini reads each meeting minute (MOM) logged on an Opportunity, pulls out 33 data points, and writes them onto the Opportunity — so sales managers can see how serious a customer is and what could kill the deal, without reading every MOM.

This is a **demo MVP**, built to show customers. Not a package yet. Current target: the sandbox `dev5-ts`. Production comes later.

Branch: `feature/ai-deal-intelligence`

## Documents

| File | What's in it |
|------|-------------|
| [requirements.md](requirements.md) | Scope, the merge rules, open questions |
| [implementation-plan.md](implementation-plan.md) | Design, classes, metadata, hour breakdown, deploy order |
| [testing-steps.md](testing-steps.md) | Checklists for unit tests, manual tests, backfill |

## How it works

1. A rep logs a meeting as an **Event** on an Opportunity.
2. If it's a **real MOM** (a meeting Type/Subject, at least 100 characters, not yet processed), it is sent to Gemini with the BA's prompt. Dinners, short notes and Events on other objects are skipped.
3. Gemini returns **one JSON** with all 33 items.
4. Salesforce **merges** the result into the Opportunity:
   - **Checkboxes (17):** once true, stay true.
   - **Facts (13 picklists/text):** "No Data" never wipes out real data. It only fills a blank field.
   - **Score / Reason / Risks (3):** always replaced. They show the deal's current temperature.
5. The Event is marked `AI_Processed__c = true`, so it is never analysed twice.
6. A one-time **backfill batch** does the same for the past year's MOMs, so the demo has history from day one.

Field list, filter values and rules come from the BA sheet [Gemini Opp](https://docs.google.com/spreadsheets/d/17Pd_wTmj5Zwxr9l2YMQUynawdlLy66LKJwErmsUvz2E/edit).

## Scope

This branch is **only the Gemini integration** (backfill, real-time, filter, one JSON per MOM, merge rules). The 33 Opportunity fields, `Event.AI_Processed__c` and the page layout are already in the org (built separately). The dashboard comes later.

## Configuration

| Setting | Where |
|---------|-------|
| Gemini model | `Program_Constant__mdt` → `GeminiMODEL` (Flash now; switch to Pro/Thinking without code changes) |
| API endpoint + key | Named Credential `Gemini` → Google **AI Studio** (key set in Setup per org, never in git) |
| Prompt | Static resource `DealIntelligencePrompt` (copy of the BA prompt) |
| MOM Types, Subjects, min length | `Program_Constant__mdt` |

## Run the backfill

```apex
DealIntelligenceJob.runBackfill();
```

Safe to re-run — already analysed MOMs are skipped. Results and token usage are in `AI_Analysis_Log__c`.

## What comes next

- Sales Management Dashboard on these 33 fields.
- Feed Google Meet transcripts instead of typed MOMs — the pipeline already takes plain text, so this is a new input source, not a rewrite.
