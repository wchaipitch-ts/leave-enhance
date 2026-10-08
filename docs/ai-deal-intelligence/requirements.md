# AI Deal Intelligence — Requirements

Sources:
- *[Gemini] Next Step_06102026* — manager's instruction memo (6 Oct 2026)
- BA sheet **"Gemini Opp"** — tabs *Obj&Fields*, *Requirements*, *Gemini Prompt* ([Google Sheet](https://docs.google.com/spreadsheets/d/17Pd_wTmj5Zwxr9l2YMQUynawdlLy66LKJwErmsUvz2E/edit))

Branch: `feature/ai-deal-intelligence`
Status: Ready to build. BA and manager decisions recorded 8 Oct 2026 (§7). No open questions.

**Target org for now: sandbox `dev5-ts`.** MOMs are Events under the Opportunity. Production is out of scope for now (D7).

---

## 1. Scope

**In scope (this branch):** the Gemini integration only.

1. **Task 1 — Backfill:** one-time batch over the past 1 year of MOMs (top priority — the demo needs it).
2. **Task 2 — Real-time:** analyse each new MOM when it is created.
3. Filter: only real MOMs (§3.4).
4. One call per MOM returning all 33 items as one JSON.
5. Flash model now; model switch by configuration only.
6. Merge rules A / B / C — never a plain overwrite.
7. Mark each analysed MOM `AI_Processed__c = true`.

**Out of scope:**

- Creating the fields and the page-layout sections (Meng — done in the org, see §2).
- The Sales Management Dashboard.
- A generic / managed package.
- Google Meet transcript input (design must allow it later — §6).

## 2. Data model (from BA sheet *Obj&Fields*, checked against sandbox `dev5-ts` on 8 Oct 2026)

### 2.1 MOM source

| Object | Field | Use |
|--------|-------|-----|
| **Event** under the Opportunity (Task is not used) | `Description` | The MOM text sent to Gemini |
| Event | `Type`, `Subject` | Filter (§3.4) |
| Event | `WhatId` | The Opportunity to update |
| Activity (Event) | `AI_Processed__c` (Checkbox, default false) | Set to `true` once analysed — stops double processing. ✅ exists in org |

### 2.2 Opportunity fields (33)

| # | API name | Type | Values / length | Rule |
|---|----------|------|-----------------|------|
| 1 | `Competitor_Topic_Mentioned__c` | Checkbox | | A |
| 2 | `Budget_Topic_Mentioned__c` | Checkbox | | A |
| 3 | `Decision_Maker_Mentioned__c` | Checkbox | | A |
| 4 | `Schedule_Topic_Mentioned__c` | Checkbox | | A |
| 5 | `Comparison_Topic_Mentioned__c` | Checkbox | | A |
| 6 | `Discount_Request_Mentioned__c` | Checkbox | | A |
| 7 | `Current_System_Dissatisfaction_Mentioned__c` | Checkbox | | A |
| 8 | `Demo_Trial_Requested__c` | Checkbox | | A |
| 9 | `System_Integration_Topic_Mentioned__c` | Checkbox | | A |
| 10 | `Data_Migration_Topic_Mentioned__c` | Checkbox | | A |
| 11 | `Target_Scale_Mentioned__c` | Checkbox | | A |
| 12 | `Approval_Process_Mentioned__c` | Checkbox | | A |
| 13 | `Compelling_Event_Mentioned__c` | Checkbox | | A |
| 14 | `Customer_Next_Action_Assigned__c` | Checkbox | | A |
| 15 | `Our_Sales_Next_Action_Assigned__c` | Checkbox | | A |
| 16 | `Customer_Asked_Specific_Questions__c` | Checkbox | | A |
| 17 | `CustomerSpecifiedConditionsOrConstraints__c` | Checkbox | | A |
| 18 | `Mentioned_Product_Competitors__c` | Multi-picklist | Microsoft, Oracle, SAP, Odoo, kintone, Zoho, HubSpot, Zendesk, Bitrix, Cloudee, Others, No Data | B |
| 19 | `Mentioned_SI_Competitors__c` | Multi-picklist | Beryl 8, IIG(i&I), M Intelligence, NTTD, NEC, Ignite Idea, SmartOSC, Softsquare, Others, No Data | B |
| 20 | `Proposed_Products__c` ⚠️ | Multi-picklist | Sales Cloud, Service Cloud, Marketing Cloud, Salesforce Platform, Experience Cloud, mitoco, UPWARD, mitoco buddy, Lingo, Sky Visual Editor, mitoco AI, Others, No Data | B |
| 21 | `Current_Management_Method__c` | Picklist | Excel & Paper, Legacy System, Other SaaS, No Data | B |
| 22 | `Next_Action_Owner__c` | Picklist | Our Sales, Customer, Both, No Next Action, No Data | B |
| 23 | `Opportunity_Stage__c` | Picklist | 02. Early Stage, 03. Final Proposal, 05. Negotiation, 06. Closed Won, 06. Closed Lost, Cannot Determine | B |
| 24 | `Explicit_Initial_Budget__c` | Text | 255 | B |
| 25 | `Explicit_Running_Budget__c` | Text | 255 | B |
| 26 | `Explicit_Budget_Unclear_Type__c` | Text | 255 | B |
| 27 | `Target_Scale_Quantity__c` | Text | 255 | B |
| 28 | `Expected_Release_Date__c` | Text | 255 | B |
| 29 | `Expected_Contract_Project_Start_Date__c` | Text | 255 | B |
| 30 | `Next_Meeting_Date__c` | Text | 255 | B |
| 31 | `Customer_Seriousness_Score__c` | Number(3,0) | 1–100 | C |
| 32 | `Reason_for_Seriousness_Score__c` | Long Text | 3000 | C |
| 33 | `Hidden_Risks_and_Blockers__c` | Long Text | 3000 | C |

Numbering follows the Gemini prompt (1–33). The sheet's *Obj&Fields* tab numbers the same fields 2–34 because `AI_Processed__c` is its #1.

> ⚠️ **#20 was created in the sandbox as `Proposed_Products_c__c`** (extra `_c`). **Decision (BA): rename it to `Proposed_Products__c`** before any build. All other 32 fields match the sheet exactly (name, type, length, picklist values).

`Opportunity_Stage__c` is a separate AI field. The standard `StageName` is **not** touched.

## 3. Requirements

### 3.1 Processing patterns

- **FR-1 Backfill (Task 1).** One-time batch over qualifying MOMs from the **past 1 year**: send each one to Gemini, parse the JSON, merge into the Opportunity, set `AI_Processed__c = true`. Must be Batch Apex (async) because of callout limits. The sheet also flags the Gemini **per-day request limit** as a concern (§4).
- **FR-2 Real-time (Task 2).** When a MOM is **created**, do the same steps asynchronously. (Edits to an existing MOM do not trigger analysis.)

### 3.2 Model

- **FR-3** Build with **Gemini 3.8 Flash** (or the latest Flash model).
- **FR-4** The model name is configuration (`Program_Constant__mdt.GeminiMODEL`). Moving to Pro / Thinking later must be a config change only.
- **FR-5** Record which model produced each result, for the quality review.

### 3.3 Prompt and output

- **FR-6** Use the BA's prompt from the *Gemini Prompt* tab. The MOM text replaces `{{INSERT_MINUTES_OF_MEETING_HERE}}`.
- **FR-7** One API call per MOM returns **all 33 items in one JSON object**, with `responseMimeType: "application/json"`.
- **FR-8** The prompt's JSON keys have a number prefix (`"1_Competitor_Topic_Mentioned__c"`). The parser strips the `N_` prefix to get the field API name.
- **FR-9** Section 5 of the prompt (Markdown table after the JSON) is **dropped** from the prompt we send, because it can't be combined with JSON-only output. *(Decision: BA.)*

### 3.4 Filter — analyse only real MOMs (sheet *Requirements* #1)

An Event is analysed only if **all** of these are true:

- **FR-10 Type** is `Meeting`, `On-site / Visit`, `Web Meeting`, `Meeting Customer for Prospecting` or `Meeting Customer for Current Opportunity`.
- **FR-11 AND Subject** is one of: `Meeting`, `On-site / Visit - 1. Initial Meeting / Hearing`, `On-site / Visit - 2. Detailed Hearing / Requirement Check`, `On-site / Visit - 3. Proposal / Quote Submission`, `On-site / Visit - 6. Other`, `Web Meeting - 1. Initial Meeting / Hearing`, `Web Meeting - 2. Detailed Hearing / Requirement Check`, `Web Meeting - 3. Proposal / Quote Submission`. *(Decision (BA): both Type **and** Subject must match.)*
- **FR-12 Description** has **at least 100 characters** (after trimming spaces).
- **FR-13** `AI_Processed__c = false`.
- **FR-14** `WhatId` is an Opportunity. (Not written in the sheet, but there is nothing to update otherwise. In the org, Events are also related to `ApplicationItem__c`.)

Types and subjects live in configuration, not code, so the BA can change them.

> Note: `Meeting`, `Meeting Customer for Prospecting` and `Meeting Customer for Current Opportunity` are not Type values in the sandbox. Events with those Types can't be created there, so in the sandbox only On-site / Visit and Web Meeting can be tested.

### 3.5 Merge rules (CRITICAL — sheet *Requirements* #10–12)

Only the current MOM is sent to Gemini. The merge happens in Salesforce. **A plain overwrite on 2nd and later updates is prohibited.**

| Rule | Fields | Logic (as written by BA) |
|------|--------|--------------------------|
| **A — Keep True** | #1–17 checkboxes | If the Opportunity field is already `true` → no update. Otherwise → set it to the AI value. |
| **B — Ignore No Data** | #18–30 picklists, multi-picklists, text | If the AI value is `No Data`, `Cannot Determine` or null: **write it only if the Opportunity field is blank**, otherwise keep the current value. If the AI value is real data → overwrite. |
| **C — Always Overwrite** | #31–33 | Always write the latest AI value. Exceptions (D8): an empty Reason or a non-numeric Score keeps the old value. |

What this means in practice:

- **FR-15** After the first MOM, a field with no information shows **"No Data"** / **"Cannot Determine"** rather than staying blank. Real data replaces "No Data" later. "No Data" never replaces real data.
- **FR-16** Multi-picklists **accumulate** *(decision: BA)*. Existing `SAP` + new `Odoo` → `SAP;Odoo`. `"No Data"` is dropped whenever there is at least one real value (existing `No Data` + new `SAP` → `SAP`). `["No Data"]` on a blank field → `No Data`.
- **FR-17** An AI value that is not a valid picklist value is treated as `No Data`, and this is logged. It never fails the whole update.
- **FR-18** Text longer than 255 characters (verbatim extraction can be long) is cut to fit and logged.
- **FR-19** Score: clamped to 1–100. If the new score is missing or not a number → **keep the old score** and log a warning (D8).
- **FR-19a** Reason: if Gemini returns an empty Reason (null / blank) → **keep the old Reason** (D8). Exception to Rule C.
- **FR-20** When one Opportunity has several MOMs (backfill), apply them **oldest → newest**, so Rule C ends on the latest meeting.

### 3.6 Reliability

- **FR-21** A failed call or bad JSON for one MOM must not stop the others or roll back other Opportunities. A failed MOM keeps `AI_Processed__c = false`, so it is retried on the next run.
- **FR-22** Log every call: Opportunity, Event, model, status, token counts, error, raw response.
- **FR-23** Updating the Opportunity or the Event must not re-trigger analysis.
- **FR-24** No API key or credentials in Apex or in git.

## 4. Non-functional

- **NFR-1** Salesforce limits: max 100 callouts and 120 s total callout time per transaction. Batch scope stays small (3–5).
- **NFR-2** Gemini limits: requests per minute and per day depend on the Google project tier. The backfill must be throttleable (scope size, pause between chunks) and resumable, because `AI_Processed__c` makes re-runs safe.
- **NFR-3** Apex test coverage ≥ 75 % for new classes, using `HttpCalloutMock`.
- **NFR-4** Handles Thai and English MOM text.

## 5. Data reality check (sandbox `dev5-ts`, 8 Oct 2026)

| | Count |
|---|---|
| Events in last 365 days related to an Opportunity | 111 |
| … with a Type in the filter list | 4 (On-site / Visit 2, Web Meeting 2) |
| … with Description ≥ 100 characters | **0** (the 4 above say "Test01" etc.) |

Event `Type` values in the org: Web Meeting, On-site / Visit, Dinner / Event, Discovery Meeting, Proposal Review, Demo Session, Management Meeting, Renewal Discussion.
**`Meeting`, `Meeting Customer for Prospecting` and `Meeting Customer for Current Opportunity` do not exist** as Type values. Subjects follow the pattern `<Type> - <purpose>` (for example `Web Meeting - 1. Initial Meeting / Hearing`).

→ In this sandbox the backfill would analyse **nothing**. For sandbox testing we create realistic test Events ourselves.

## 6. Future-proofing (design for it, don't build it)

- **FR-F1** The pipeline takes plain text plus metadata (Opportunity, source Id, date). Event is only today's source; a Google Meet transcript can be added later as another source.

## 7. Decisions (8 Oct 2026)

| # | Topic | Decision | By |
|---|-------|----------|----|
| D1 | `Proposed_Products_c__c` | Rename to `Proposed_Products__c` | BA |
| D2 | Prompt Section 5 (Markdown table) | Drop it from the API prompt | BA |
| D3 | Filter | Type **and** Subject must both match | BA |
| D4 | Multi-picklists | Accumulate (`SAP;Odoo`) | BA |
| D5 | Gemini endpoint | **Google AI Studio** for now (API key). Vertex AI maybe later. | Manager |
| D6 | MOM source | Events under the Opportunity | Manager |
| D7 | Org | Build and test in the sandbox `dev5-ts` only. **Ignore Production for now.** | Manager |
| D8 | Rule C exceptions | Empty Reason → don't overwrite. Score not a number → keep the old score. | BA |
