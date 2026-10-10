# AI Deal Intelligence — Test Data (sandbox `dev5-ts`)

Created 8 Oct 2026. Use with [testing-steps.md](testing-steps.md).

**State (8 Oct 2026, after the stress run):** the meetings on Test 3 / Test 4 and the BA's records have been analysed. To run them again, use the reset script (§5) first — it clears the AI fields, deletes their log rows, deletes meetings you logged by hand on Test 1 / 2, and unticks the rest so they wait for the backfill.

| Opportunity | Id | Use for |
|---|---|---|
| AIDI Test 1 - Filter | `006fc0000069zf8AAA` | §1: you log meetings by hand |
| AIDI Test 2 - Merge Rules | `006fc0000069zf9AAA` | §2: you log meetings A–C by hand |
| AIDI Test 3 - Backfill (Bangkok Retail) | `006fc0000069zfAAAQ` | Backfill — 5 meetings (3 should be analysed) |
| AIDI Test 4 - Thai MOM (Chiang Mai Hospital) | `006fc0000069zfBAAQ` | Backfill — 1 Thai meeting |
| AIDI Stress 001–025, AIDI Stress Edge - … (29 deals) | — | Stress test (§4) |
| Gemini MOM, Gemini MOM 01–14 (BA's records) | — | 15 On-site / Visit meetings; covered by the reset script |
| Gemini Automate 01, Gemini automate 002 / 003 (BA's records) | — | Logged by hand by the BA (instant process); covered by the reset script |

---

## 1. Filter test — on *AIDI Test 1 - Filter*

Create each Event by hand (**New Event**, Related To = the Opportunity). Use this long note where a row says "long note":

```
Customer reviewed our CRM demo and asked how lead assignment would work for their 20 sales reps. They want a follow-up session next week.
```

| # | Type | Subject | Description | Expected |
|---|------|---------|-------------|----------|
| 1.1 | Web Meeting | Web Meeting - 1. Initial Meeting / Hearing | long note | ✅ analysed within ~1 min |
| 1.2 | On-site / Visit | On-site / Visit - 3. Proposal / Quote Submission | long note | ✅ analysed |
| 1.3 | Dinner / Event | Dinner / Event - 1. Initial Meeting / Hearing | long note | ❌ nothing |
| 1.4 | Web Meeting | Catch-up | long note | ❌ nothing |
| 1.5 | Web Meeting | Web Meeting - 1. Initial Meeting / Hearing | `called, no answer` | ❌ nothing |
| 1.6 | Web Meeting | Web Meeting - 1. Initial Meeting / Hearing | long note, **Related To any Account** | ❌ nothing |
| 1.7 | Edit 1.5 → paste the long note | | | ❌ nothing (only new meetings) |

## 2. Merge rules — on *AIDI Test 2 - Merge Rules*

Log one at a time (Type **Web Meeting**, Subject **Web Meeting - 2. Detailed Hearing / Requirement Check**). Wait ~1 min and check the Opportunity before the next one.

**Meeting A**
```
Attendees: Khun Anan (CFO) and Khun Pim (Sales Manager) from Thai Packaging Co.
Implementation cost budget is 3M THB. They are also talking to SAP.
The CEO must approve the purchase at the board meeting.
They want to go live around October next year.
Next meeting: 5 November for a product demo.
```
Expect: Budget / Decision Maker / Schedule ✅, Initial Budget = "Implementation cost 3M THB" (word for word), Product Competitors = SAP, empty facts show **No Data** (AI stage **Cannot Determine** if not stated), Score / Reason / Risks filled.

**Meeting B**
```
Technical demo only. We showed the mobile app and dashboards to two sales staff.
They liked the reports. Nothing was said about budget, competitors or timing.
No next meeting was agreed.
```
Expect: all ✅ from A still ✅; budget and competitors **unchanged**; Score / Reason / Risks **replaced**, score lower (no next meeting).

**Meeting C**
```
Khun Pim said running cost should be around 50k THB per month.
They have also received a quote from Odoo.
Khun Pim: "Looks good, I will check with my boss" — no date given.
```
Expect: Running Budget changes from No Data to the quote, Initial Budget still 3M; Competitors = **SAP;Odoo**; Reason mentions the polite non-commitment (Kreng-jai).

## 3. Backfill — *AIDI Test 3* and *AIDI Test 4*

Six meetings, created as processed and then unticked (an update), so saving them didn't start the instant process. After a reset they wait for the backfill again:

| Opportunity | Meeting date | Subject | Expected |
|---|---|---|---|
| Test 3 | 2025-09-03 (400 days ago) | Web Meeting - 1 | ❌ skipped — older than a year |
| Test 3 | 2026-03-22 | On-site / Visit - 1 | ✅ budget ~2M THB, SAP, CEO decides, Q2 go-live, next meeting set |
| Test 3 | 2026-08-09 | Web Meeting - 2 | ✅ POS integration + migration questions, adds Odoo, "check with my boss", no next meeting |
| Test 3 | 2026-09-08 | Web Meeting - 2 | ❌ skipped — "Sent follow-up email." is too short |
| Test 3 | 2026-09-28 | Web Meeting - 3 | ✅ Sales + Service Cloud, ~120 users, running ~80k/month, 10% discount asked, January start, next meeting 28 Oct |
| Test 4 | 2026-09-18 | Web Meeting - 1 (Thai) | ✅ Excel & paper, Service Cloud ~25 users, polite "ขอปรึกษาผู้บริหารก่อน", no budget, no next meeting |

Run in Anonymous Apex:

```apex
DealIntelligenceJob.runBackfill();
```

Then check:
- **Test 3**: 3 log rows (not 5). Competitors = **SAP;Odoo**. Initial Budget from March, Running Budget from September. Discount ✅. Score / Reason / Risks describe the **September** proposal meeting.
- **Test 4**: Reason recognises the polite deferral (Kreng-jai) and the score is low (no budget, no next meeting, no questions). Review the Thai wording for the manager.
- Run the backfill **again** → no new log rows.

## 4. Stress test records

Created by `scripts/apex/ai-deal-intelligence-stress-data.apex`. Each deal's **Description** states what the backfill should leave on it (e.g. `EXPECT competitors=SAP;Odoo;kintone;Zoho | budgetFrom=meeting 1 | scoreFrom=meeting 4`); `…-stress-check.apex` compares. Every regular deal has 4 meetings (≈300, 200, 100, 10 days ago) plus 1 the filter must skip (short note, dinner, older than a year, or a custom subject). Edge cases: a ~8,000-character note, three meetings on one day, products not in the picklists, a Thai polite deferral.

## 5. Reset and clean up

```bash
sf apex run --file scripts/apex/ai-deal-intelligence-reset.apex --target-org dev5-ts
```

No checkout at hand? Paste the browser version from [snippets.md](snippets.md) into the Developer Console. Edit the switches at the top first: `DRY_RUN` (true = only print, roll back), `DELETE_LOGS`, `DELETE_HAND_LOGGED_MEETINGS`, `DELETE_STRESS_DEALS` (true = remove the stress deals completely). Scope: `AIDI Test%`, `AIDI Stress%`, `Gemini MOM%`, `Gemini Automate%` (the BA's hand-logged deals).

To remove the AIDI Test deals for good, delete the four Opportunities; their meetings go with them, log rows stay with the Opportunity link blank.
