@isTest
private class DealIntelligenceServiceTest {

    private static final String MOM_TYPE    = 'Web Meeting';
    private static final String MOM_SUBJECT = 'Web Meeting - 1. Initial Meeting / Hearing';
    private static final String FILLER =
        ' The customer walked us through their current sales process and asked how the rollout would work for their team.';

    /**
     * Answers like Gemini does, chosen by a marker in the meeting text:
     * a JSON answer, an HTTP error, or text that isn't JSON.
     */
    private class GeminiMock implements HttpCalloutMock {
        Map<String, Map<String, Object>> answers = new Map<String, Map<String, Object>>();
        Set<String> httpErrors = new Set<String>();
        Set<String> notJson = new Set<String>();
        List<HttpRequest> requests = new List<HttpRequest>();

        public HttpResponse respond(HttpRequest req) {
            requests.add(req);
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            for (String marker : httpErrors) {
                if (req.getBody().contains(marker)) {
                    res.setStatusCode(500);
                    res.setStatus('Internal Server Error');
                    res.setBody('{"error":{"code":500,"message":"backend error"}}');
                    return res;
                }
            }
            String text = JSON.serialize(answer(new Map<String, Object>()));
            for (String marker : answers.keySet()) {
                if (req.getBody().contains(marker)) {
                    text = JSON.serialize(answers.get(marker));
                }
            }
            for (String marker : notJson) {
                if (req.getBody().contains(marker)) {
                    text = 'Sure! Here is the analysis you asked for.';
                }
            }
            res.setStatusCode(200);
            res.setStatus('OK');
            res.setBody(JSON.serialize(new Map<String, Object>{
                'candidates' => new List<Object>{
                    new Map<String, Object>{
                        'content' => new Map<String, Object>{
                            'role' => 'model',
                            'parts' => new List<Object>{ new Map<String, Object>{ 'text' => text } }
                        },
                        'finishReason' => 'STOP'
                    }
                },
                'usageMetadata' => new Map<String, Object>{
                    'promptTokenCount' => 2500,
                    'candidatesTokenCount' => 400
                }
            }));
            return res;
        }
    }

    /** A full answer in the prompt's numbered-key format: nothing found, score 50. */
    private static Map<String, Object> answer(Map<String, Object> overrides) {
        Map<String, Object> result = new Map<String, Object>();
        List<String> fields = DealIntelligenceRules.fields();
        for (Integer i = 0; i < fields.size(); i++) {
            String field = fields[i];
            Object value = 'No Data';
            if (DealIntelligenceRules.FLAG_FIELDS.contains(field)) {
                value = false;
            } else if (field.endsWith('Competitors__c') || field == 'Proposed_Products__c') {
                value = new List<Object>{ 'No Data' };
            } else if (field == 'Opportunity_Stage__c') {
                value = 'Cannot Determine';
            } else if (field == DealIntelligenceRules.SCORE_FIELD) {
                value = 50;
            } else if (field == DealIntelligenceRules.REASON_FIELD) {
                value = 'Nothing concrete yet.';
            }
            result.put((i + 1) + '_' + field, overrides.containsKey(field) ? overrides.get(field) : value);
        }
        return result;
    }

    @TestSetup
    static void makeData() {
        Opportunity template = new Opportunity(
            StageName = firstValue(Opportunity.StageName.getDescribe()),
            Your_Win_Confidence__c = firstValue(Opportunity.Your_Win_Confidence__c.getDescribe()),
            CloseDate = Date.today().addMonths(3)
        );
        List<Opportunity> opps = new List<Opportunity>();
        for (String name : new List<String>{ 'AIDI Single', 'AIDI Two Meetings', 'AIDI Http Error', 'AIDI Not Json', 'AIDI Short Note' }) {
            Opportunity opp = template.clone();
            opp.Name = name;
            opps.add(opp);
        }
        insert opps;

        // The later meeting is inserted first, so the test proves order comes from the
        // meeting date and not from the order the Ids are passed in.
        insert new List<Event>{
            mom(opps[0].Id, 'MOM-ALPHA' + FILLER, -3),
            mom(opps[1].Id, 'MOM-NEWER' + FILLER, -1),
            mom(opps[1].Id, 'MOM-OLDER' + FILLER, -10),
            mom(opps[2].Id, 'MOM-HTTP-ERROR' + FILLER, -2),
            mom(opps[3].Id, 'MOM-NOT-JSON' + FILLER, -2),
            mom(opps[4].Id, 'called, no answer', -2)
        };
    }

    private static String firstValue(Schema.DescribeFieldResult describe) {
        for (Schema.PicklistEntry entry : describe.getPicklistValues()) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return null;
    }

    private static Event mom(Id oppId, String description, Integer daysAgo) {
        Datetime starts = Datetime.now().addDays(daysAgo);
        return new Event(
            WhatId = oppId,
            Type = MOM_TYPE,
            Subject = MOM_SUBJECT,
            Description = description,
            StartDateTime = starts,
            EndDateTime = starts.addHours(1)
        );
    }

    private static List<Id> eventsOf(String oppName) {
        return new List<Id>(new Map<Id, Event>([SELECT Id FROM Event WHERE What.Name = :oppName WITH SYSTEM_MODE]).keySet());
    }

    private static Opportunity opp(String name) {
        return (Opportunity) Database.query(
            'SELECT Id, ' + String.join(new List<String>{
                'Budget_Topic_Mentioned__c', 'Mentioned_Product_Competitors__c', 'Explicit_Initial_Budget__c',
                'Customer_Seriousness_Score__c', 'Reason_for_Seriousness_Score__c'
            }, ', ') + ' FROM Opportunity WHERE Name = :name',
            AccessLevel.SYSTEM_MODE
        );
    }

    private static List<AI_Analysis_Log__c> logsOf(String oppName) {
        return [
            SELECT Status__c, Model__c, Input_Tokens__c, Output_Tokens__c, Response__c, Changes__c, Details__c, Event_Id__c
            FROM AI_Analysis_Log__c
            WHERE Opportunity__r.Name = :oppName
            WITH SYSTEM_MODE
        ];
    }

    @isTest
    static void analysesAMeetingSavesItAndTicksIt() {
        GeminiMock mock = new GeminiMock();
        mock.answers.put('MOM-ALPHA', answer(new Map<String, Object>{
            'Budget_Topic_Mentioned__c' => true,
            'Mentioned_Product_Competitors__c' => new List<Object>{ 'SAP' },
            'Explicit_Initial_Budget__c' => 'Implementation cost 3M THB',
            'Customer_Seriousness_Score__c' => 70,
            'Reason_for_Seriousness_Score__c' => 'Budget and schedule are explicit.'
        }));
        Test.setMock(HttpCalloutMock.class, mock);
        List<Id> ids = eventsOf('AIDI Single');

        Test.startTest();
        DealIntelligenceService.Summary summary = DealIntelligenceService.analyse(ids);
        Test.stopTest();

        Opportunity o = opp('AIDI Single');
        System.assertEquals(true, o.Budget_Topic_Mentioned__c);
        System.assertEquals('SAP', o.Mentioned_Product_Competitors__c);
        System.assertEquals('Implementation cost 3M THB', o.Explicit_Initial_Budget__c);
        System.assertEquals(70, o.Customer_Seriousness_Score__c);
        System.assertEquals('Budget and schedule are explicit.', o.Reason_for_Seriousness_Score__c);

        System.assertEquals(true, [SELECT AI_Processed__c FROM Event WHERE Id = :ids[0] WITH SYSTEM_MODE].AI_Processed__c);

        AI_Analysis_Log__c log = logsOf('AIDI Single')[0];
        System.assert(log.Status__c == 'Success' || log.Status__c == 'Partial', log.Status__c);
        System.assertEquals(ids[0], log.Event_Id__c);
        System.assertEquals(2500, log.Input_Tokens__c);
        System.assertEquals(400, log.Output_Tokens__c);
        System.assert(String.isNotBlank(log.Model__c));
        System.assert(log.Changes__c.contains('Explicit_Initial_Budget__c = Implementation cost 3M THB'), log.Changes__c);
        System.assert(log.Response__c.contains('Implementation cost 3M THB'));

        System.assertEquals(1, summary.analysed);
        System.assertEquals(0, summary.failed);
        System.assertEquals(2500, summary.inputTokens);
    }

    @isTest
    static void sendsThePromptWithTheMeetingInJsonMode() {
        GeminiMock mock = new GeminiMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        DealIntelligenceService.analyse(eventsOf('AIDI Single'));
        Test.stopTest();

        System.assertEquals(1, mock.requests.size(), 'one call per meeting');
        HttpRequest req = mock.requests[0];
        System.assert(req.getEndpoint().startsWith(DealIntelligenceService.ENDPOINT), req.getEndpoint());
        System.assert(req.getEndpoint().endsWith(':generateContent'), req.getEndpoint());

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
        Map<String, Object> config = (Map<String, Object>) body.get('generationConfig');
        System.assertEquals('application/json', config.get('responseMimeType'));

        String prompt = req.getBody();
        System.assert(prompt.contains('MOM-ALPHA'), 'the meeting text is in the prompt');
        System.assert(prompt.contains('0% Hallucination Policy'), 'the BA prompt is used');
        System.assert(!prompt.contains(DealIntelligenceService.MOM_PLACEHOLDER), 'placeholder replaced');
        System.assert(!prompt.contains('Summary Table Output Format'), 'Section 5 is not sent');
    }

    @isTest
    static void laterMeetingsMergeOntoEarlierOnes() {
        GeminiMock mock = new GeminiMock();
        mock.answers.put('MOM-OLDER', answer(new Map<String, Object>{
            'Budget_Topic_Mentioned__c' => true,
            'Mentioned_Product_Competitors__c' => new List<Object>{ 'SAP' },
            'Explicit_Initial_Budget__c' => 'Implementation cost 3M THB',
            'Customer_Seriousness_Score__c' => 80
        }));
        mock.answers.put('MOM-NEWER', answer(new Map<String, Object>{
            'Mentioned_Product_Competitors__c' => new List<Object>{ 'Odoo' },
            'Customer_Seriousness_Score__c' => 40,
            'Reason_for_Seriousness_Score__c' => 'No next meeting.'
        }));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        DealIntelligenceService.Summary summary = DealIntelligenceService.analyse(eventsOf('AIDI Two Meetings'));
        Test.stopTest();

        System.assert(mock.requests[0].getBody().contains('MOM-OLDER'), 'older meeting is sent first');

        Opportunity o = opp('AIDI Two Meetings');
        System.assertEquals(true, o.Budget_Topic_Mentioned__c, 'Rule A survives the later meeting');
        System.assertEquals('Implementation cost 3M THB', o.Explicit_Initial_Budget__c, 'Rule B keeps the budget');
        System.assertEquals('SAP;Odoo', o.Mentioned_Product_Competitors__c, 'competitors accumulate');
        System.assertEquals(40, o.Customer_Seriousness_Score__c, 'Rule C ends on the latest meeting');
        System.assertEquals('No next meeting.', o.Reason_for_Seriousness_Score__c);

        System.assertEquals(2, summary.analysed);
        System.assertEquals(2, [SELECT COUNT() FROM Event WHERE What.Name = 'AIDI Two Meetings' AND AI_Processed__c = true WITH SYSTEM_MODE]);
        System.assertEquals(2, logsOf('AIDI Two Meetings').size());
    }

    @isTest
    static void httpErrorChangesNothingAndRetriesLater() {
        GeminiMock mock = new GeminiMock();
        mock.httpErrors.add('MOM-HTTP-ERROR');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        DealIntelligenceService.Summary summary = DealIntelligenceService.analyse(eventsOf('AIDI Http Error'));
        Test.stopTest();

        Opportunity o = opp('AIDI Http Error');
        System.assertEquals(null, o.Customer_Seriousness_Score__c);
        System.assertEquals(null, o.Explicit_Initial_Budget__c);
        System.assertEquals(0, [SELECT COUNT() FROM Event WHERE What.Name = 'AIDI Http Error' AND AI_Processed__c = true WITH SYSTEM_MODE],
            'left unticked so the next run tries again');

        AI_Analysis_Log__c log = logsOf('AIDI Http Error')[0];
        System.assertEquals('Failed', log.Status__c);
        System.assert(log.Details__c.contains('HTTP 500'), log.Details__c);
        System.assert(log.Response__c.contains('backend error'), log.Response__c);
        System.assertEquals(1, summary.failed);
    }

    @isTest
    static void answerThatIsNotJsonIsAParseError() {
        GeminiMock mock = new GeminiMock();
        mock.notJson.add('MOM-NOT-JSON');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        DealIntelligenceService.analyse(eventsOf('AIDI Not Json'));
        Test.stopTest();

        AI_Analysis_Log__c log = logsOf('AIDI Not Json')[0];
        System.assertEquals('Parse Error', log.Status__c);
        System.assert(log.Response__c.contains('Here is the analysis'), log.Response__c);
        System.assertEquals(null, opp('AIDI Not Json').Customer_Seriousness_Score__c);
        System.assertEquals(0, [SELECT COUNT() FROM Event WHERE What.Name = 'AIDI Not Json' AND AI_Processed__c = true WITH SYSTEM_MODE]);
    }

    @isTest
    static void shortNoteIsSkippedWithoutACall() {
        GeminiMock mock = new GeminiMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        DealIntelligenceService.Summary summary = DealIntelligenceService.analyse(eventsOf('AIDI Short Note'));
        Test.stopTest();

        System.assertEquals(0, mock.requests.size());
        System.assertEquals(1, summary.skipped);
        System.assertEquals(0, logsOf('AIDI Short Note').size());
    }

    @isTest
    static void alreadyProcessedMeetingIsSkipped() {
        GeminiMock mock = new GeminiMock();
        Test.setMock(HttpCalloutMock.class, mock);
        List<Id> ids = eventsOf('AIDI Single');

        Test.startTest();
        DealIntelligenceService.analyse(ids);
        Test.stopTest();
        // The tick is committed now; a second run in the same test would need another
        // callout after DML, so check the filter on the saved row instead.
        Event saved = [SELECT Id, WhatId, Type, Subject, Description, AI_Processed__c FROM Event WHERE Id = :ids[0] WITH SYSTEM_MODE];
        System.assert(!DealIntelligenceRules.isMom(saved));
    }
}
