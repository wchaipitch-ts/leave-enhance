@isTest
private class DealIntelligenceRulesTest {

    private static final String MOM_TYPE    = 'Web Meeting';
    private static final String MOM_SUBJECT = 'Web Meeting - 1. Initial Meeting / Hearing';

    // ======== Filter ========================================================

    private static void useFilterConfig() {
        DealIntelligenceRules.types = new Set<String>{ 'web meeting', 'on-site / visit' };
        DealIntelligenceRules.subjects = new Set<String>{ MOM_SUBJECT.toLowerCase() };
        DealIntelligenceRules.minLength = 100;
    }

    private static Id fakeId(Schema.SObjectType type) {
        return Id.valueOf(type.getDescribe().getKeyPrefix() + '000000000001');
    }

    private static Event mom(String description) {
        return new Event(
            Type = MOM_TYPE,
            Subject = MOM_SUBJECT,
            Description = description,
            WhatId = fakeId(Opportunity.SObjectType),
            AI_Processed__c = false
        );
    }

    @isTest
    static void meetingOfAtLeastMinimumLengthIsMom() {
        useFilterConfig();
        System.assert(DealIntelligenceRules.isMom(mom('x'.repeat(100))), 'exactly 100 characters qualifies');
        System.assert(!DealIntelligenceRules.isMom(mom('x'.repeat(99))), '99 characters does not');
    }

    @isTest
    static void paddingDoesNotCountTowardsTheLength() {
        useFilterConfig();
        String padded = '   ' + 'x'.repeat(99) + '\n\n   ';
        System.assert(!DealIntelligenceRules.isMom(mom(padded)), 'spaces around the text are not content');
        System.assert(!DealIntelligenceRules.isMom(mom(null)), 'no Description');
    }

    @isTest
    static void typeAndSubjectMustBothMatch() {
        useFilterConfig();
        Event wrongType = mom('x'.repeat(150));
        wrongType.Type = 'Dinner / Event';
        Event wrongSubject = mom('x'.repeat(150));
        wrongSubject.Subject = 'Dinner / Event - 1. Initial Meeting / Hearing';

        System.assert(!DealIntelligenceRules.isMom(wrongType), 'right Subject, wrong Type');
        System.assert(!DealIntelligenceRules.isMom(wrongSubject), 'right Type, wrong Subject');
    }

    @isTest
    static void typeAndSubjectIgnoreCaseAndSpaces() {
        useFilterConfig();
        Event e = mom('x'.repeat(150));
        e.Type = ' web MEETING ';
        e.Subject = MOM_SUBJECT.toUpperCase() + ' ';
        System.assert(DealIntelligenceRules.isMom(e));
    }

    @isTest
    static void onlyUnprocessedMeetingsOnAnOpportunity() {
        useFilterConfig();
        Event processed = mom('x'.repeat(150));
        processed.AI_Processed__c = true;
        Event onAccount = mom('x'.repeat(150));
        onAccount.WhatId = fakeId(Account.SObjectType);
        Event onNothing = mom('x'.repeat(150));
        onNothing.WhatId = null;

        System.assert(!DealIntelligenceRules.isMom(processed), 'already analysed');
        System.assert(!DealIntelligenceRules.isMom(onAccount), 'related to an Account');
        System.assert(!DealIntelligenceRules.isMom(onNothing), 'related to nothing');
    }

    @isTest
    static void missingConfigLetsNothingThrough() {
        DealIntelligenceRules.types = new Set<String>();
        DealIntelligenceRules.subjects = new Set<String>();
        DealIntelligenceRules.minLength = 100;
        System.assert(!DealIntelligenceRules.isMom(mom('x'.repeat(150))));
    }

    @isTest
    static void qualifyingKeepsOnlyMoms() {
        useFilterConfig();
        Event good = mom('x'.repeat(150));
        Event shortNote = mom('called, no answer');
        List<Event> result = DealIntelligenceRules.qualifying(new List<Event>{ good, shortNote });
        System.assertEquals(1, result.size());
        System.assert(result[0] === good);
    }

    @isTest
    static void readsTheDeployedConfig() {
        System.assert(DealIntelligenceRules.momTypes().contains('Web Meeting'), DealIntelligenceRules.momTypes());
        // All eight of the BA's Subjects, so a record cut at 255 characters shows up here.
        List<String> subjects = DealIntelligenceRules.momSubjects();
        for (String expected : new List<String>{
                'Meeting',
                'On-site / Visit - 1. Initial Meeting / Hearing',
                'On-site / Visit - 2. Detailed Hearing / Requirement Check',
                'On-site / Visit - 3. Proposal / Quote Submission',
                'On-site / Visit - 6. Other',
                'Web Meeting - 1. Initial Meeting / Hearing',
                'Web Meeting - 2. Detailed Hearing / Requirement Check',
                'Web Meeting - 3. Proposal / Quote Submission' }) {
            System.assert(subjects.contains(expected), expected + ' missing from ' + subjects);
        }
        System.assert(DealIntelligenceRules.isMom(mom('x'.repeat(100))), 'qualifies with the deployed config');
    }

    // ======== Merge =========================================================

    /** The prompt's own JSON template: nothing found, score 50. */
    private static Map<String, Object> emptyAnswer() {
        return (Map<String, Object>) JSON.deserializeUntyped('{'
            + '"1_Competitor_Topic_Mentioned__c": false,'
            + '"2_Budget_Topic_Mentioned__c": false,'
            + '"3_Decision_Maker_Mentioned__c": false,'
            + '"4_Schedule_Topic_Mentioned__c": false,'
            + '"5_Comparison_Topic_Mentioned__c": false,'
            + '"6_Discount_Request_Mentioned__c": false,'
            + '"7_Current_System_Dissatisfaction_Mentioned__c": false,'
            + '"8_Demo_Trial_Requested__c": false,'
            + '"9_System_Integration_Topic_Mentioned__c": false,'
            + '"10_Data_Migration_Topic_Mentioned__c": false,'
            + '"11_Target_Scale_Mentioned__c": false,'
            + '"12_Approval_Process_Mentioned__c": false,'
            + '"13_Compelling_Event_Mentioned__c": false,'
            + '"14_Customer_Next_Action_Assigned__c": false,'
            + '"15_Our_Sales_Next_Action_Assigned__c": false,'
            + '"16_Customer_Asked_Specific_Questions__c": false,'
            + '"17_CustomerSpecifiedConditionsOrConstraints__c": false,'
            + '"18_Mentioned_Product_Competitors__c": ["No Data"],'
            + '"19_Mentioned_SI_Competitors__c": ["No Data"],'
            + '"20_Proposed_Products__c": ["No Data"],'
            + '"21_Current_Management_Method__c": "No Data",'
            + '"22_Next_Action_Owner__c": "No Data",'
            + '"23_Opportunity_Stage__c": "Cannot Determine",'
            + '"24_Explicit_Initial_Budget__c": "No Data",'
            + '"25_Explicit_Running_Budget__c": "No Data",'
            + '"26_Explicit_Budget_Unclear_Type__c": "No Data",'
            + '"27_Target_Scale_Quantity__c": "No Data",'
            + '"28_Expected_Release_Date__c": "No Data",'
            + '"29_Expected_Contract_Project_Start_Date__c": "No Data",'
            + '"30_Next_Meeting_Date__c": "No Data",'
            + '"31_Customer_Seriousness_Score__c": 50,'
            + '"32_Reason_for_Seriousness_Score__c": "Nothing concrete yet.",'
            + '"33_Hidden_Risks_and_Blockers__c": "No Data"'
            + '}');
    }

    private static Map<String, Object> answer(Map<String, Object> overrides) {
        Map<String, Object> result = emptyAnswer();
        for (String key : overrides.keySet()) {
            for (String existing : new List<String>(result.keySet())) {
                if (existing.endsWith('_' + key)) {
                    result.put(existing, overrides.get(key));
                }
            }
        }
        return result;
    }

    @isTest
    static void fieldsCoversAllThirtyThree() {
        System.assertEquals(33, DealIntelligenceRules.fields().size());
        System.assertEquals(33, new Set<String>(DealIntelligenceRules.fields()).size(), 'no duplicates');
    }

    @isTest
    static void numberedKeysMapToTheirFields() {
        Opportunity opp = new Opportunity();
        DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{ 'Budget_Topic_Mentioned__c' => true }));
        System.assertEquals(true, opp.Budget_Topic_Mentioned__c);
    }

    @isTest
    static void unnumberedKeysWorkToo() {
        Opportunity opp = new Opportunity();
        DealIntelligenceRules.mergeAnswer(opp, new Map<String, Object>{ 'Budget_Topic_Mentioned__c' => true });
        System.assertEquals(true, opp.Budget_Topic_Mentioned__c);
    }

    // ---- Rule A

    @isTest
    static void flagOnceTrueStaysTrue() {
        Opportunity opp = new Opportunity(Budget_Topic_Mentioned__c = true);
        DealIntelligenceRules.MergeResult r = DealIntelligenceRules.mergeAnswer(opp,
            answer(new Map<String, Object>{ 'Budget_Topic_Mentioned__c' => false }));
        System.assertEquals(true, opp.Budget_Topic_Mentioned__c);
        System.assert(!r.changes.containsKey('Budget_Topic_Mentioned__c'));
    }

    @isTest
    static void flagTurnsTrueWhenMentioned() {
        Opportunity opp = new Opportunity(Budget_Topic_Mentioned__c = false, Decision_Maker_Mentioned__c = false);
        DealIntelligenceRules.MergeResult r = DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{
            'Budget_Topic_Mentioned__c' => true,
            'Decision_Maker_Mentioned__c' => 'true'
        }));
        System.assertEquals(true, opp.Budget_Topic_Mentioned__c);
        System.assertEquals(true, opp.Decision_Maker_Mentioned__c, 'a "true" string counts');
        System.assertEquals(true, r.changes.get('Budget_Topic_Mentioned__c'));
        System.assert(!r.changes.containsKey('Schedule_Topic_Mentioned__c'), 'false on false is no change');
    }

    // ---- Rule B: text and picklist

    @isTest
    static void noDataFillsABlankField() {
        Opportunity opp = new Opportunity();
        DealIntelligenceRules.mergeAnswer(opp, emptyAnswer());
        System.assertEquals('No Data', opp.Explicit_Initial_Budget__c);
        System.assertEquals('No Data', opp.Current_Management_Method__c);
        System.assertEquals('Cannot Determine', opp.Opportunity_Stage__c);
        System.assertEquals('No Data', opp.Mentioned_Product_Competitors__c);
    }

    @isTest
    static void noDataNeverReplacesRealData() {
        Opportunity opp = new Opportunity(
            Explicit_Initial_Budget__c = 'Implementation cost 3M THB',
            Opportunity_Stage__c = '02. Early Stage'
        );
        DealIntelligenceRules.MergeResult r = DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{
            'Explicit_Running_Budget__c' => null,
            'Expected_Release_Date__c' => 'N/A'
        }));
        System.assertEquals('Implementation cost 3M THB', opp.Explicit_Initial_Budget__c);
        System.assertEquals('02. Early Stage', opp.Opportunity_Stage__c);
        System.assertEquals('No Data', opp.Explicit_Running_Budget__c, 'null counts as No Data');
        System.assertEquals('No Data', opp.Expected_Release_Date__c, 'N/A is written as No Data');
        System.assert(!r.changes.containsKey('Explicit_Initial_Budget__c'));
    }

    @isTest
    static void realDataReplacesNoDataAndOlderData() {
        Opportunity opp = new Opportunity(
            Explicit_Initial_Budget__c = 'Implementation cost 3M THB',
            Explicit_Running_Budget__c = 'No Data'
        );
        DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{
            'Explicit_Initial_Budget__c' => 'Implementation cost 5M THB',
            'Explicit_Running_Budget__c' => 'Monthly 50k'
        }));
        System.assertEquals('Implementation cost 5M THB', opp.Explicit_Initial_Budget__c);
        System.assertEquals('Monthly 50k', opp.Explicit_Running_Budget__c);
    }

    @isTest
    static void picklistUsesTheRealValueAndRejectsUnknownOnes() {
        Opportunity opp = new Opportunity(Current_Management_Method__c = 'Excel & Paper');
        DealIntelligenceRules.MergeResult r = DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{
            'Next_Action_Owner__c' => 'our sales',
            'Current_Management_Method__c' => 'Notebook',
            'Opportunity_Stage__c' => 'No Data'
        }));
        System.assertEquals('Our Sales', opp.Next_Action_Owner__c, 'matched ignoring case');
        System.assertEquals('Excel & Paper', opp.Current_Management_Method__c, 'unknown value is No Data');
        System.assertEquals('Cannot Determine', opp.Opportunity_Stage__c, 'the Stage field has no "No Data" value');
        System.assert(String.join(r.warnings, '\n').contains('"Notebook" is not a picklist value'), r.warnings);
    }

    @isTest
    static void longTextIsCutToFit() {
        Opportunity opp = new Opportunity();
        DealIntelligenceRules.MergeResult r = DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{
            'Explicit_Budget_Unclear_Type__c' => 'b'.repeat(300)
        }));
        System.assertEquals(255, opp.Explicit_Budget_Unclear_Type__c.length());
        System.assert(String.join(r.warnings, '\n').contains('300 characters cut to 255'), r.warnings);
    }

    // ---- Rule B: multi-picklist

    @isTest
    static void multiPicklistAccumulates() {
        Opportunity opp = new Opportunity(Mentioned_Product_Competitors__c = 'SAP');
        DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{
            'Mentioned_Product_Competitors__c' => new List<Object>{ 'Odoo' }
        }));
        System.assertEquals('SAP;Odoo', opp.Mentioned_Product_Competitors__c);
    }

    @isTest
    static void multiPicklistDropsNoDataOnceThereIsARealValue() {
        Opportunity mixed = new Opportunity();
        DealIntelligenceRules.mergeAnswer(mixed, answer(new Map<String, Object>{
            'Mentioned_Product_Competitors__c' => new List<Object>{ 'SAP', 'No Data' }
        }));
        System.assertEquals('SAP', mixed.Mentioned_Product_Competitors__c);

        Opportunity wasNoData = new Opportunity(Mentioned_Product_Competitors__c = 'No Data');
        DealIntelligenceRules.mergeAnswer(wasNoData, answer(new Map<String, Object>{
            'Mentioned_Product_Competitors__c' => new List<Object>{ 'SAP' }
        }));
        System.assertEquals('SAP', wasNoData.Mentioned_Product_Competitors__c);
    }

    @isTest
    static void multiPicklistKeepsWhatItHasWhenNothingNew() {
        Opportunity opp = new Opportunity(Mentioned_Product_Competitors__c = 'SAP;Odoo');
        DealIntelligenceRules.MergeResult r = DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{
            'Mentioned_Product_Competitors__c' => new List<Object>{ 'odoo', 'Notion' }
        }));
        System.assertEquals('SAP;Odoo', opp.Mentioned_Product_Competitors__c, 'no duplicate, no unknown value');
        System.assert(!r.changes.containsKey('Mentioned_Product_Competitors__c'));
        System.assert(String.join(r.warnings, '\n').contains('"Notion" is not a picklist value'), r.warnings);

        DealIntelligenceRules.mergeAnswer(opp, emptyAnswer());
        System.assertEquals('SAP;Odoo', opp.Mentioned_Product_Competitors__c, 'No Data keeps the list');
    }

    // ---- Rule C

    @isTest
    static void insightFieldsTakeTheLatestAnswer() {
        Opportunity opp = new Opportunity(
            Customer_Seriousness_Score__c = 80,
            Reason_for_Seriousness_Score__c = 'Old reason',
            Hidden_Risks_and_Blockers__c = 'Old risk'
        );
        DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{
            'Customer_Seriousness_Score__c' => 40,
            'Reason_for_Seriousness_Score__c' => 'Polite but no next meeting.',
            'Hidden_Risks_and_Blockers__c' => 'No Data'
        }));
        System.assertEquals(40, opp.Customer_Seriousness_Score__c);
        System.assertEquals('Polite but no next meeting.', opp.Reason_for_Seriousness_Score__c);
        System.assertEquals('No Data', opp.Hidden_Risks_and_Blockers__c, 'risks are always replaced');
    }

    @isTest
    static void scoreIsRoundedAndKeptInsideOneToHundred() {
        Opportunity opp = new Opportunity();
        DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{ 'Customer_Seriousness_Score__c' => 150 }));
        System.assertEquals(100, opp.Customer_Seriousness_Score__c);
        DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{ 'Customer_Seriousness_Score__c' => -5 }));
        System.assertEquals(1, opp.Customer_Seriousness_Score__c);
        DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{ 'Customer_Seriousness_Score__c' => '72.6' }));
        System.assertEquals(73, opp.Customer_Seriousness_Score__c, 'a numeric string counts');
    }

    @isTest
    static void scoreThatIsNotANumberKeepsTheOldOne() {
        Opportunity opp = new Opportunity(Customer_Seriousness_Score__c = 80);
        DealIntelligenceRules.MergeResult r = DealIntelligenceRules.mergeAnswer(opp,
            answer(new Map<String, Object>{ 'Customer_Seriousness_Score__c' => 'high' }));
        System.assertEquals(80, opp.Customer_Seriousness_Score__c);
        System.assert(String.join(r.warnings, '\n').contains('kept the old score'), r.warnings);

        DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{ 'Customer_Seriousness_Score__c' => null }));
        System.assertEquals(80, opp.Customer_Seriousness_Score__c);
    }

    @isTest
    static void emptyReasonKeepsTheOldOne() {
        Opportunity opp = new Opportunity(Reason_for_Seriousness_Score__c = 'Old reason');
        DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{ 'Reason_for_Seriousness_Score__c' => '' }));
        System.assertEquals('Old reason', opp.Reason_for_Seriousness_Score__c);
        DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{ 'Reason_for_Seriousness_Score__c' => null }));
        System.assertEquals('Old reason', opp.Reason_for_Seriousness_Score__c);
    }

    // ---- Whole answers

    @isTest
    static void missingKeyLeavesTheFieldAlone() {
        Opportunity opp = new Opportunity(Explicit_Initial_Budget__c = '3M');
        Map<String, Object> partial = emptyAnswer();
        partial.remove('24_Explicit_Initial_Budget__c');
        partial.remove('31_Customer_Seriousness_Score__c');
        DealIntelligenceRules.MergeResult r = DealIntelligenceRules.mergeAnswer(opp, partial);
        System.assertEquals('3M', opp.Explicit_Initial_Budget__c);
        System.assertEquals(null, opp.Customer_Seriousness_Score__c);
        System.assert(String.join(r.warnings, '\n').contains('Explicit_Initial_Budget__c: missing from the AI answer'), r.warnings);
    }

    @isTest
    static void secondMeetingMergesOntoTheFirst() {
        Opportunity opp = new Opportunity();

        DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{
            'Budget_Topic_Mentioned__c' => true,
            'Mentioned_Product_Competitors__c' => new List<Object>{ 'SAP' },
            'Explicit_Initial_Budget__c' => 'Implementation cost 3M THB',
            'Customer_Seriousness_Score__c' => 80
        }));
        DealIntelligenceRules.MergeResult second = DealIntelligenceRules.mergeAnswer(opp, answer(new Map<String, Object>{
            'Mentioned_Product_Competitors__c' => new List<Object>{ 'Odoo' },
            'Customer_Seriousness_Score__c' => 45
        }));

        System.assertEquals(true, opp.Budget_Topic_Mentioned__c, 'Rule A');
        System.assertEquals('Implementation cost 3M THB', opp.Explicit_Initial_Budget__c, 'Rule B');
        System.assertEquals('SAP;Odoo', opp.Mentioned_Product_Competitors__c, 'Rule B accumulates');
        System.assertEquals(45, opp.Customer_Seriousness_Score__c, 'Rule C');
        System.assertEquals('SAP;Odoo', second.changes.get('Mentioned_Product_Competitors__c'));
        System.assert(!second.changes.containsKey('Explicit_Initial_Budget__c'), 'only real changes are reported');
    }

    @isTest
    static void nullAnswerChangesNothing() {
        Opportunity opp = new Opportunity(Explicit_Initial_Budget__c = '3M');
        DealIntelligenceRules.MergeResult r = DealIntelligenceRules.mergeAnswer(opp, null);
        System.assert(r.changes.isEmpty());
        System.assertEquals('3M', opp.Explicit_Initial_Budget__c);
    }
}
