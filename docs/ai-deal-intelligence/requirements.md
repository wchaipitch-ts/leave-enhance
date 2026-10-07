# AI Deal Intelligence — Requirements

Source: *[Gemini] Next Step_06102026* (instruction memo, 6 Oct 2026)
Branch: `feature/ai-deal-intelligence`
Status: Draft — open questions in §6 must be answered before build starts.

---

## 1. Scope

**In scope (this branch):** the Gemini integration only.

1. One-time backfill of the past 1 year of MOMs (top priority — the demo needs it).
2. Real-time analysis of newly logged MOMs.
3. Trigger filter (MOM types + 100-character minimum).
4. One call per MOM returning all 33 items as one JSON.
5. Flash model now; model switch by configuration only.
6. Merge rules A / B / C — never a plain overwrite.

**Out of scope:**

- Creating the 33 Opportunity fields and the page-layout sections (Meng's task — a **dependency**, see §2).
- The Sales Management Dashboard.
- A generic / managed package.
- Google Meet transcript input (design must allow it later — §5).

## 2. Dependency — Opportunity fields

The integration writes to 33 Opportunity fields created outside this branch. Before mapping, we need for each item: API name, type, length / picklist values, and merge rule.

| No. | API name | Merge rule |
|-----|----------|-----------|
| 31 | `Customer_Seriousness_Score__c` | C — always overwrite |
| 32 | `Reason_for_Seriousness_Score__c` | C — always overwrite |
| 33 | `Hidden_Risks_and_Blockers__c` | C — always overwrite |
| 1–30 | *from requirement document* (BANT, competitors, budget, schedule, …) | A (checkbox) or B (everything else) |

> ⚠️ Items 1–30 are **not in the memo** — see Q1. The integration user also needs edit access to all 33 fields.

## 3. Gemini integration

### 3.1 Processing patterns

- **FR-2.1 Backfill (top priority for demo).** One-time job that analyses all qualifying MOMs from the **past 1 year** and updates the linked Opportunities. Must be **Batch Apex** (or equivalent async) to stay within callout governor limits. Purpose: realistic trend data for the demo dashboard.
- **FR-2.2 Real-time.** When a new qualifying MOM is logged against an Opportunity, analyse it straight away (async) and merge the result into the Opportunity.

### 3.2 Model

- **FR-2.3** Build and finalise with **Gemini 3.8 Flash** (or the latest Flash model).
- **FR-2.4** The model name must be configuration, not code. Switching to Gemini 3.1 Pro / 3.6 Thinking later must only need a config change. (Existing `Program_Constant__mdt.GeminiMODEL` already does this.)
- **FR-2.5** Record which model produced each result, so the quality review can compare models.

### 3.3 One call, one JSON

- **FR-2.6** One API call per MOM returns **all 33 items in one JSON object**.
- **FR-2.7** Request must set `responseMimeType: "application/json"` (`response_mime_type`). A `responseSchema` should also be sent so key names and types are fixed.

### 3.4 Trigger filter — analyse only real MOMs

A Task/Event is analysed **only if BOTH** are true:

- **FR-2.8 Type:** a MOM type — `Meeting`, `On-site / Visit`, `Web Meeting`. `Email`, `Call` and all other types are excluded.
- **FR-2.9 Length:** `Description` has **at least 100 characters** (after trimming whitespace).
- **FR-2.10** The activity is linked to an Opportunity (`WhatId` is an Opportunity).
- **FR-2.11** The same MOM must not be analysed twice (backfill and real-time must not double-process).

### 3.5 Merge rules (CRITICAL)

Send **only the current MOM** to Gemini. Merge in Salesforce. **Plain overwrite on 2nd+ updates is prohibited.**

| Rule | Applies to | Behaviour |
|------|-----------|-----------|
| **A — Keep True** | Checkbox (flag) fields | Once `true`, stays `true` even if the new AI result is `false`. New `true` sets it. |
| **B — Ignore No Data** | Text, picklist, number, date fields | If AI returns `null`, empty, `No Data`, `Cannot Determine`, `N/A`, `Unknown` (and Thai equivalents) → keep the current value. Only specific new data overwrites. |
| **C — Always Overwrite** | Fields 31, 32, 33 (AI Deal Intelligence) | Always replace with the latest AI output — we want the deal's current temperature. |

- **FR-2.12** When several MOMs are processed for one Opportunity (backfill), apply them **oldest → newest**, so Rule C ends on the latest MOM.
- **FR-2.13** Picklist values from AI that are not valid picklist values are treated as No Data (Rule B) and logged — never cause the whole update to fail.

### 3.6 Reliability and cost

- **FR-2.14** A failed callout or bad JSON for one MOM must not stop other MOMs or roll back other Opportunities.
- **FR-2.15** Log every call: Opportunity, Activity, model, status, token counts, error, raw response.
- **FR-2.16** Updating the Opportunity must not re-trigger AI analysis (no recursion).
- **FR-2.17** The API key / credentials must not be hard-coded in Apex or committed to git.

## 4. Non-functional

- **NFR-1** Stay within governor limits: max 100 callouts and 120 s total callout time per transaction.
- **NFR-2** Apex test coverage ≥ 75 % for new classes, using `HttpCalloutMock` (no real callouts in tests).
- **NFR-3** Prompt must handle Thai and English MOM text and reason with Thai business culture in mind (Score/Reason/Risk).

## 5. Future-proofing (design must allow, not build now)

- **FR-F1** The MOM "source" must be swappable: today Task/Event Description; later a Google Meet transcript. The extraction + merge pipeline must accept plain text + metadata and not depend on Task/Event.
- **FR-F2** Field mapping (JSON key → field → merge rule) should be data-driven so adding items doesn't need code changes.

## 6. Open questions

| # | Question | Ask |
|---|----------|-----|
| Q1 | Full list of the 33 items: name, type, picklist values, Rule A/B/C. | Tak / requirement doc |
| Q2 | **Vertex AI or Google AI Studio?** The PoC calls `generativelanguage.googleapis.com` with an API key (AI Studio). The memo says Vertex AI (needs GCP project, service account, OAuth). | Manager |
| Q3 | Which Gemini model did the PoC use? (Memo asks Tak directly. Code shows `gemini-3.1-flash-lite` / `gemini-3.5-flash-lite`.) | Tak |
| Q4 | Are MOMs logged as **Task**, **Event**, or both? Do the picklist values `On-site / Visit` and `Web Meeting` already exist on Activity Type? | Tak / org check |
| Q5 | Seriousness Score range (0–100? 1–5? 1–10?). | Manager |
| Q6 | Rule C when the AI returns no data for an insight field — overwrite with blank, or keep? (Memo says "always overwrite".) | Manager |
| Q7 | Should real-time also fire when an existing MOM is **edited** (e.g. Description grows past 100 chars)? | Manager |
