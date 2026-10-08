// AI Deal Intelligence — check the stress-test backfill (read only).
//
//   sf apex run --file scripts/apex/ai-deal-intelligence-stress-check.apex --target-org dev5-ts 2>&1 | grep CHECK
//
// Prints meeting and log counts for the 'AIDI Stress%' deals, and lists every regular
// deal whose competitors don't match what its Description expects.

List<Opportunity> opps = [
    SELECT Id, Name, Description, Mentioned_Product_Competitors__c, Customer_Seriousness_Score__c,
           Explicit_Initial_Budget__c, Explicit_Running_Budget__c
    FROM Opportunity WHERE Name LIKE 'AIDI Stress%' ORDER BY Name
];
Set<Id> oppIds = new Map<Id, Opportunity>(opps).keySet();

Integer ticked = [SELECT COUNT() FROM Event WHERE WhatId IN :oppIds AND AI_Processed__c = true];
Integer waiting = [SELECT COUNT() FROM Event WHERE WhatId IN :oppIds AND AI_Processed__c = false];
System.debug('CHECK deals: ' + opps.size() + ' | meetings ticked: ' + ticked + ' | not ticked: ' + waiting
    + ' (one skipped meeting per regular deal is expected to stay unticked)');

for (AggregateResult r : [
    SELECT Status__c status, COUNT(Id) n, SUM(Input_Tokens__c) tin, SUM(Output_Tokens__c) tout
    FROM AI_Analysis_Log__c WHERE Opportunity__c IN :oppIds GROUP BY Status__c
]) {
    System.debug('CHECK log ' + r.get('status') + ': ' + r.get('n') + ' rows, tokens in ' + r.get('tin') + ' / out ' + r.get('tout'));
}
// Long text can't be grouped in SOQL, so the failure reasons are counted here.
Map<String, Integer> reasons = new Map<String, Integer>();
for (AI_Analysis_Log__c log : [
    SELECT Details__c FROM AI_Analysis_Log__c WHERE Opportunity__c IN :oppIds AND Status__c = 'Failed'
]) {
    String reason = String.valueOf(log.Details__c).substringBefore(' (').left(120);
    reasons.put(reason, reasons.containsKey(reason) ? reasons.get(reason) + 1 : 1);
}
for (String reason : reasons.keySet()) {
    System.debug('CHECK failure "' + reason + '": ' + reasons.get(reason));
}

Integer ok = 0;
List<String> wrong = new List<String>();
for (Opportunity o : opps) {
    if (o.Description == null || !o.Description.startsWith('EXPECT competitors=') || o.Name.contains('Edge')) {
        continue;
    }
    Set<String> expected = new Set<String>(o.Description.substringBetween('competitors=', ' |').split(';'));
    Set<String> actual = o.Mentioned_Product_Competitors__c == null
        ? new Set<String>() : new Set<String>(o.Mentioned_Product_Competitors__c.split(';'));
    if (actual.containsAll(expected) && o.Customer_Seriousness_Score__c != null) {
        ok++;
    } else {
        wrong.add(o.Name + ' expected ' + expected + ' got ' + actual + ' score ' + o.Customer_Seriousness_Score__c);
    }
}
System.debug('CHECK regular deals complete: ' + ok + ' | incomplete: ' + wrong.size());
for (String w : wrong) {
    System.debug('CHECK incomplete ' + w);
}
for (Opportunity o : opps) {
    if (o.Name.contains('Edge')) {
        System.debug('CHECK edge ' + o.Name + ' | competitors ' + o.Mentioned_Product_Competitors__c
            + ' | score ' + o.Customer_Seriousness_Score__c + ' | ' + o.Description);
    }
}
