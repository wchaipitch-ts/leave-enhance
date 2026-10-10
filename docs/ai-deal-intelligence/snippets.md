# AI Deal Intelligence — Snippets (run from any machine)

For working on the sandbox `dev5-ts` without this checkout. Two ways: the browser only, or the Salesforce CLI.

## Option 1: browser only (Developer Console)

In the sandbox: **gear icon → Developer Console → Debug → Open Execute Anonymous Window**. Paste a snippet, tick **Open Log**, **Execute**. In the log, tick **Debug Only** to see the summary line.

### Reset the test records

Clears the 33 AI fields on the test deals (`AIDI Test%`, `AIDI Stress%`, `Gemini MOM%`, `Gemini Automate%`), unticks their meetings so they wait for the backfill (an update — it doesn't start the instant process), and deletes their log rows and the meetings logged by hand on AIDI Test 1 / 2. Same as `scripts/apex/ai-deal-intelligence-reset.apex`.

Run it first with `DRY_RUN = true` (only shows what would change), then with `false`.

```apex
Boolean DRY_RUN = true;                     // true = only show what would change
Boolean DELETE_LOGS = true;                 // delete the test deals' log rows
Boolean DELETE_HAND_LOGGED_MEETINGS = true; // delete meetings logged by hand on AIDI Test 1 / 2
Boolean DELETE_STRESS_DEALS = false;        // true = remove the AIDI Stress deals completely
Set<String> HAND_LOGGED = new Set<String>{ 'AIDI Test 1 - Filter', 'AIDI Test 2 - Merge Rules' };

Savepoint sp = Database.setSavepoint();
List<Opportunity> opps = [SELECT Id FROM Opportunity
    WHERE Name LIKE 'AIDI Test%' OR Name LIKE 'AIDI Stress%' OR Name LIKE 'Gemini MOM%' OR Name LIKE 'Gemini Automate%'];
Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();

Map<String, Schema.SObjectField> oppFields = Schema.SObjectType.Opportunity.fields.getMap();
for (Opportunity o : opps) {
    for (String f : DealIntelligenceRules.fields()) {
        if (oppFields.containsKey(f)) { o.put(f, DealIntelligenceRules.FLAG_FIELDS.contains(f) ? (Object) false : null); }
    }
}
update opps;

List<Event> handLogged = new List<Event>();
if (DELETE_HAND_LOGGED_MEETINGS) {
    handLogged = [SELECT Id FROM Event WHERE WhatId IN :oppIds AND What.Name IN :HAND_LOGGED];
    delete handLogged;
}
List<Event> ticked = [SELECT Id FROM Event WHERE WhatId IN :oppIds AND AI_Processed__c = true];
for (Event e : ticked) { e.AI_Processed__c = false; }
update ticked;

Integer logs = 0;
if (DELETE_LOGS) {
    List<AI_Analysis_Log__c> a = [SELECT Id FROM AI_Analysis_Log__c WHERE Opportunity__c IN :oppIds];
    List<Gemini_Opty_Log__c> g = [SELECT Id FROM Gemini_Opty_Log__c WHERE Opportunity__c IN :oppIds];
    logs = a.size() + g.size();
    delete a; delete g;
}
List<Opportunity> stress = new List<Opportunity>();
if (DELETE_STRESS_DEALS) { stress = [SELECT Id FROM Opportunity WHERE Name LIKE 'AIDI Stress%']; delete stress; }

System.debug('RESET ' + (DRY_RUN ? '(dry run, rolled back) ' : '') + opps.size() + ' deals cleared, '
    + handLogged.size() + ' hand-logged meetings deleted, ' + ticked.size() + ' meetings unticked, '
    + logs + ' log rows deleted, ' + stress.size() + ' stress deals deleted');
if (DRY_RUN) { Database.rollback(sp); }
```

### Run the backfill

About one Gemini call per waiting meeting — check the quota first ([ai.dev/rate-limit](https://ai.dev/rate-limit)).

```apex
System.debug('JOB ' + DealIntelligenceJob.runBackfill());
```

Progress: **Setup → Apex Jobs**. A pause for a Gemini rate limit shows in **Setup → Scheduled Jobs** as *AI Deal Intelligence - retry after Gemini rate limit*.

### See what landed on a test deal

```apex
String deal = 'AIDI Test 2 - Merge Rules';
for (Gemini_Opty_Log__c g : [SELECT CreatedDate, Status__c, Model__c, Token_Used__c, Error_Message__c
                             FROM Gemini_Opty_Log__c WHERE Opportunity__r.Name = :deal ORDER BY CreatedDate]) {
    System.debug('LOG ' + g.CreatedDate + ' | ' + g.Status__c + ' | ' + g.Model__c + ' | ' + g.Token_Used__c + ' | ' + g.Error_Message__c);
}
Opportunity o = [SELECT Customer_Seriousness_Score__c, Mentioned_Product_Competitors__c, Explicit_Initial_Budget__c,
                 Explicit_Running_Budget__c, Reason_for_Seriousness_Score__c FROM Opportunity WHERE Name = :deal];
System.debug('DEAL ' + JSON.serializePretty(o));
```

### Which model is in use

```apex
System.debug('MODEL ' + Program_Constant__mdt.getInstance('GeminiMODEL').Value__c);
```

## Option 2: command line (Salesforce CLI)

1. Get the code:
   ```bash
   git clone https://github.com/wchaipitch-ts/leave-enhance.git
   ```
2. Switch to the feature branch:
   ```bash
   cd leave-enhance && git checkout feature/ai-deal-intelligence
   ```
3. Log in to the sandbox:
   ```bash
   sf org login web --alias dev5-ts --instance-url https://terraskyth--dev5.sandbox.my.salesforce.com
   ```
4. Reset the test records (dry run by default — edit `DRY_RUN` in the file):
   ```bash
   sf apex run --file scripts/apex/ai-deal-intelligence-reset.apex --target-org dev5-ts
   ```

The other scripts run the same way:

| Script | What it does |
|---|---|
| `scripts/apex/ai-deal-intelligence-stress-data.apex` | Creates the stress-test deals and meetings (`DEAL_COUNT` at the top) |
| `scripts/apex/ai-deal-intelligence-stress-check.apex` | Read-only report on a stress run — add `2>&1 \| grep CHECK` |

Meeting notes and expected results for the hand tests: [test-data.md](test-data.md). Checklists: [testing-steps.md](testing-steps.md).
