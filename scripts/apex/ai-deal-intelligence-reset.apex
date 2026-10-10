// AI Deal Intelligence — reset the sandbox test records so the tests can run again.
//
// Scope: Opportunities named 'AIDI Test%' (made for testing-steps / test-data.md),
// 'AIDI Stress%' (made by ai-deal-intelligence-stress-data.apex) and the BA's mock
// records 'Gemini MOM%' and 'Gemini Automate%' (LIKE ignores case).
//
//   sf apex run --file scripts/apex/ai-deal-intelligence-reset.apex --target-org dev5-ts
//
// It clears the 33 AI fields, unticks AI_Processed__c on their meetings (an update, so the
// real-time trigger stays quiet and the meetings wait for DealIntelligenceJob.runBackfill()),
// and optionally deletes their log rows, the meetings logged by hand on AIDI Test 1 and 2,
// and the stress-test deals altogether (their meetings go with them).
// DRY_RUN = true rolls everything back and only prints what would change.

Boolean DRY_RUN = true;
Boolean DELETE_LOGS = true;
Boolean DELETE_HAND_LOGGED_MEETINGS = true;
Boolean DELETE_STRESS_DEALS = false;
Set<String> HAND_LOGGED = new Set<String>{ 'AIDI Test 1 - Filter', 'AIDI Test 2 - Merge Rules' };

Savepoint sp = Database.setSavepoint();

List<Opportunity> opps = [
    SELECT Id, Name FROM Opportunity
    WHERE Name LIKE 'AIDI Test%' OR Name LIKE 'AIDI Stress%' OR Name LIKE 'Gemini MOM%' OR Name LIKE 'Gemini Automate%'
];
Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();

// 1. Clear the AI fields: checkboxes back to false, everything else blank.
Map<String, Schema.SObjectField> oppFields = Schema.SObjectType.Opportunity.fields.getMap();
for (Opportunity o : opps) {
    for (String field : DealIntelligenceRules.fields()) {
        if (oppFields.containsKey(field)) {
            o.put(field, DealIntelligenceRules.FLAG_FIELDS.contains(field) ? (Object) false : null);
        }
    }
}
update opps;

// 2. Meetings logged by hand on Test 1 and 2 go, so those tests start from nothing.
List<Event> handLogged = new List<Event>();
if (DELETE_HAND_LOGGED_MEETINGS) {
    handLogged = [SELECT Id FROM Event WHERE WhatId IN :oppIds AND What.Name IN :HAND_LOGGED];
    delete handLogged;
}

// 3. Every other meeting on these deals waits for the backfill again.
List<Event> ticked = [SELECT Id FROM Event WHERE WhatId IN :oppIds AND AI_Processed__c = true];
for (Event e : ticked) {
    e.AI_Processed__c = false;
}
update ticked;

// 4. Their log rows.
Integer logs = 0;
if (DELETE_LOGS) {
    List<AI_Analysis_Log__c> analysisLogs = [SELECT Id FROM AI_Analysis_Log__c WHERE Opportunity__c IN :oppIds];
    List<Gemini_Opty_Log__c> optyLogs = [SELECT Id FROM Gemini_Opty_Log__c WHERE Opportunity__c IN :oppIds];
    logs = analysisLogs.size() + optyLogs.size();
    delete analysisLogs;
    delete optyLogs;
}

// 5. The stress-test deals themselves, if asked.
List<Opportunity> stress = new List<Opportunity>();
if (DELETE_STRESS_DEALS) {
    stress = [SELECT Id FROM Opportunity WHERE Name LIKE 'AIDI Stress%'];
    delete stress;
}

System.debug('RESET ' + (DRY_RUN ? '(dry run, rolled back) ' : '')
    + opps.size() + ' opportunities cleared, '
    + stress.size() + ' stress deals deleted, '
    + handLogged.size() + ' hand-logged meetings deleted, '
    + ticked.size() + ' meetings unticked, '
    + logs + ' log rows deleted');

if (DRY_RUN) {
    Database.rollback(sp);
}
