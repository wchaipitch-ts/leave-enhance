# AI Deal Intelligence (Gemini × Opportunity)

Gemini reads each meeting minute (MOM) logged on an Opportunity, pulls out 33 data points, and writes them onto the Opportunity — so sales managers can see how serious a customer is and what could kill the deal, without reading every MOM.

This is a **demo MVP in our own org**, built to show customers. Not a package yet.

Branch: `feature/ai-deal-intelligence`

## Documents

| File | What's in it |
|------|-------------|
| [requirements.md](requirements.md) | Scope, the merge rules, open questions |
| [implementation-plan.md](implementation-plan.md) | Design, classes, metadata, hour breakdown, deploy order |
| [testing-steps.md](testing-steps.md) | Checklists for unit tests, manual tests, backfill |

## How it works

1. A rep logs a meeting (Task or Event) on an Opportunity.
2. If it's a **real MOM** — type Meeting / On-site / Visit / Web Meeting, and at least 100 characters — it is sent to Gemini. Emails, calls and short notes are skipped.
3. Gemini returns **one JSON** with all 33 items.
4. Salesforce **merges** the result into the Opportunity:
   - **Checkboxes:** once true, stay true.
   - **Facts (text, picklist, numbers):** "No Data" never wipes out what we already know.
   - **Score / Reason / Risks:** always replaced — they show the deal's current temperature.
5. A one-time **backfill batch** does the same for the past year's MOMs, so the demo has history from day one.

## Scope

This branch is **only the Gemini integration** (backfill, real-time, filter, one JSON per MOM, merge rules). The 33 Opportunity fields and the page layout are built separately and are a prerequisite. The dashboard comes later.

## Configuration

| Setting | Where |
|---------|-------|
| Gemini model | `Program_Constant__mdt` → `GeminiMODEL` (Flash now; switch to Pro/Thinking without code changes) |
| API endpoint + key / service account | Named Credential `Gemini` (secrets set in Setup, never in git) |
| MOM types, min length, "no data" words | `Program_Constant__mdt` |
| Field ↔ JSON key ↔ merge rule | `AI_Extraction_Field__mdt` |

## Run the backfill

```apex
Database.executeBatch(new DealIntelligenceBackfillBatch(), 5);
```

Safe to re-run — already analysed MOMs are skipped. Results and token usage are in `AI_Analysis_Log__c`.

## What comes next

- Sales Management Dashboard on these 33 fields.
- Feed Google Meet transcripts instead of typed MOMs — the pipeline already takes plain text, so this is a new input source, not a rewrite.
