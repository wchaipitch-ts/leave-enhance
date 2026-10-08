/**
 * Sends meeting notes (Events) to Gemini and merges the answers into their Opportunities.
 *
 * One call per meeting, with the BA's prompt (static resource DealIntelligencePrompt)
 * and JSON-only output. Every callout runs before any DML, as Salesforce requires.
 * The answers are then merged oldest meeting first, so the insight fields end on the
 * latest one. A meeting is ticked AI_Processed__c only once its Opportunity has
 * saved; anything that failed stays unticked and is picked up again on the next run.
 * Every meeting sent to Gemini leaves one AI_Analysis_Log__c row (full detail) and one
 * Gemini_Opty_Log__c row (the team's summary log: JSON, Success/Fail, tokens).
 *
 * Without sharing and in system mode: the rep who logs the meeting may not own the
 * deal or see the AI fields and the log, and they must still be written. (From API
 * 67.0, SOQL and DML respect field access unless told otherwise.)
 */
public without sharing class DealIntelligenceService {

    @TestVisible private static final String PROMPT_RESOURCE = 'DealIntelligencePrompt';
    @TestVisible private static final String MOM_PLACEHOLDER = '{{INSERT_MINUTES_OF_MEETING_HERE}}';
    @TestVisible private static final String ENDPOINT = 'callout:Gemini_AI_Studio/v1beta/models/';
    private static final String MODEL_KEY = 'GeminiMODEL';
    private static final Integer TIMEOUT_MS = 60000;

    @TestVisible private static final String SUCCESS     = 'Success';
    @TestVisible private static final String PARTIAL     = 'Partial';
    @TestVisible private static final String FAILED      = 'Failed';
    @TestVisible private static final String PARSE_ERROR = 'Parse Error';
    @TestVisible private static final String SAVE_FAILED = 'Save Failed';

    /** Counts for the caller, e.g. the backfill's summary email. */
    public class Summary {
        public Integer analysed = 0;
        public Integer failed = 0;
        public Integer skipped = 0;
        public Integer inputTokens = 0;
        public Integer outputTokens = 0;
    }

    /** One meeting's trip to Gemini and back. */
    private class Call {
        Event mom;
        String status;
        String response;
        Map<String, Object> answer;
        Integer inputTokens;
        Integer outputTokens;
        DealIntelligenceRules.MergeResult merged;
        List<String> details = new List<String>();

        Call(Event mom) {
            this.mom = mom;
        }

        void fail(String status, String reason) {
            this.status = status;
            this.answer = null;
            this.details.add(reason);
        }
    }

    public static Summary analyse(List<Id> eventIds) {
        Summary summary = new Summary();
        List<Event> events = [
            SELECT Id, WhatId, Type, Subject, Description, AI_Processed__c
            FROM Event
            WHERE Id IN :eventIds
            WITH SYSTEM_MODE
            ORDER BY WhatId, StartDateTime, CreatedDate
        ];
        summary.skipped = eventIds.size() - events.size();

        List<Call> calls = new List<Call>();
        for (Event e : events) {
            if (DealIntelligenceRules.isMom(e)) {
                calls.add(new Call(e));
            } else {
                summary.skipped++;
            }
        }
        if (calls.isEmpty()) {
            return summary;
        }

        String model = model();
        String prompt = prompt();
        for (Call c : calls) {
            if (String.isBlank(model) || prompt == null) {
                c.fail(FAILED, String.isBlank(model)
                    ? 'No model set in Program_Constant__mdt.' + MODEL_KEY
                    : 'Static resource ' + PROMPT_RESOURCE + ' not found');
            } else {
                ask(c, prompt, model);
            }
        }

        Map<Id, String> saveErrors = mergeAndSave(calls);
        tickAndLog(calls, saveErrors, model, summary);
        return summary;
    }

    // ---- Gemini -------------------------------------------------------------

    private static void ask(Call c, String prompt, String model) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(ENDPOINT + model + ':generateContent');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(TIMEOUT_MS);
        // No temperature: Google advises leaving Gemini 3 models at their default.
        req.setBody(JSON.serialize(new Map<String, Object>{
            'contents' => new List<Object>{
                new Map<String, Object>{
                    'role' => 'user',
                    'parts' => new List<Object>{
                        new Map<String, Object>{ 'text' => prompt.replace(MOM_PLACEHOLDER, c.mom.Description.trim()) }
                    }
                }
            },
            'generationConfig' => new Map<String, Object>{ 'responseMimeType' => 'application/json' }
        }));

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (Exception e) {
            c.fail(FAILED, e.getTypeName() + ': ' + e.getMessage());
            return;
        }
        if (res.getStatusCode() != 200) {
            c.response = res.getBody();
            c.fail(FAILED, 'HTTP ' + res.getStatusCode() + ' ' + res.getStatus());
            return;
        }

        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Map<String, Object> usage = (Map<String, Object>) body.get('usageMetadata');
            if (usage != null) {
                c.inputTokens = (Integer) usage.get('promptTokenCount');
                c.outputTokens = (Integer) usage.get('candidatesTokenCount');
            }
            c.response = answerText(body);
            c.answer = (Map<String, Object>) JSON.deserializeUntyped(c.response);
        } catch (Exception e) {
            if (c.response == null) {
                c.response = res.getBody();
            }
            c.fail(PARSE_ERROR, e.getTypeName() + ': ' + e.getMessage());
        }
    }

    /** The text of the first candidate, leaving out any thinking parts. */
    private static String answerText(Map<String, Object> body) {
        Map<String, Object> candidate = (Map<String, Object>) ((List<Object>) body.get('candidates'))[0];
        Map<String, Object> content = (Map<String, Object>) candidate.get('content');
        String text = '';
        for (Object o : (List<Object>) content.get('parts')) {
            Map<String, Object> part = (Map<String, Object>) o;
            if (part.get('thought') != true && part.get('text') != null) {
                text += (String) part.get('text');
            }
        }
        return text;
    }

    // ---- Salesforce ---------------------------------------------------------

    /** Merges every answer, oldest meeting first, and saves. Returns save errors by Opportunity. */
    private static Map<Id, String> mergeAndSave(List<Call> calls) {
        Set<Id> oppIds = new Set<Id>();
        for (Call c : calls) {
            if (c.answer != null) {
                oppIds.add(c.mom.WhatId);
            }
        }
        Map<Id, String> saveErrors = new Map<Id, String>();
        if (oppIds.isEmpty()) {
            return saveErrors;
        }

        Map<Id, Opportunity> opps = new Map<Id, Opportunity>((List<Opportunity>) Database.query(
            'SELECT Id, ' + String.join(existingFields(), ', ') + ' FROM Opportunity WHERE Id IN :oppIds',
            AccessLevel.SYSTEM_MODE
        ));

        // Calls are already in WhatId, StartDateTime order, so each Opportunity sees its
        // meetings oldest first, and each merge builds on the one before.
        Map<Id, Opportunity> changed = new Map<Id, Opportunity>();
        for (Call c : calls) {
            if (c.answer == null) {
                continue;
            }
            Opportunity opp = opps.get(c.mom.WhatId);
            if (opp == null) {
                c.fail(SAVE_FAILED, 'Opportunity ' + c.mom.WhatId + ' not found');
                continue;
            }
            c.merged = DealIntelligenceRules.mergeAnswer(opp, c.answer);
            if (!c.merged.changes.isEmpty()) {
                Opportunity upd = changed.containsKey(opp.Id) ? changed.get(opp.Id) : new Opportunity(Id = opp.Id);
                for (String field : c.merged.changes.keySet()) {
                    upd.put(field, c.merged.changes.get(field));
                }
                changed.put(opp.Id, upd);
            }
        }

        List<Opportunity> toSave = changed.values();
        List<Database.SaveResult> results = Database.update(toSave, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                saveErrors.put(toSave[i].Id, errorText(results[i].getErrors()));
            }
        }
        return saveErrors;
    }

    /** The 33 fields that exist on Opportunity; a missing one is reported by the merge. */
    private static List<String> existingFields() {
        Map<String, Schema.SObjectField> oppFields = Schema.SObjectType.Opportunity.fields.getMap();
        List<String> result = new List<String>();
        for (String field : DealIntelligenceRules.fields()) {
            if (oppFields.containsKey(field)) {
                result.add(field);
            }
        }
        return result;
    }

    private static void tickAndLog(List<Call> calls, Map<Id, String> saveErrors, String model, Summary summary) {
        List<Event> ticks = new List<Event>();
        List<Call> ticked = new List<Call>();
        for (Call c : calls) {
            if (c.answer == null) {
                continue;
            }
            String saveError = saveErrors.get(c.mom.WhatId);
            if (saveError != null) {
                c.fail(SAVE_FAILED, saveError);
                continue;
            }
            c.details.addAll(c.merged.warnings);
            c.status = c.merged.warnings.isEmpty() ? SUCCESS : PARTIAL;
            ticks.add(new Event(Id = c.mom.Id, AI_Processed__c = true));
            ticked.add(c);
        }

        List<Database.SaveResult> tickResults = Database.update(ticks, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < tickResults.size(); i++) {
            if (!tickResults[i].isSuccess()) {
                // The Opportunity is saved, but the meeting will be analysed again next run.
                ticked[i].details.add('Could not tick AI_Processed__c: ' + errorText(tickResults[i].getErrors()));
            }
        }

        List<AI_Analysis_Log__c> logs = new List<AI_Analysis_Log__c>();
        List<Gemini_Opty_Log__c> optyLogs = new List<Gemini_Opty_Log__c>();
        for (Call c : calls) {
            logs.add(toLog(c, model));
            optyLogs.add(toOptyLog(c));
            if (c.status == SUCCESS || c.status == PARTIAL) {
                summary.analysed++;
            } else {
                summary.failed++;
            }
            summary.inputTokens += c.inputTokens == null ? 0 : c.inputTokens;
            summary.outputTokens += c.outputTokens == null ? 0 : c.outputTokens;
        }
        Database.insert(logs, false, AccessLevel.SYSTEM_MODE);
        Database.insert(optyLogs, false, AccessLevel.SYSTEM_MODE);
    }

    private static AI_Analysis_Log__c toLog(Call c, String model) {
        List<String> changes = new List<String>();
        if (c.merged != null && (c.status == SUCCESS || c.status == PARTIAL)) {
            for (String field : c.merged.changes.keySet()) {
                changes.add(field + ' = ' + c.merged.changes.get(field));
            }
        }
        return new AI_Analysis_Log__c(
            Opportunity__c = c.mom.WhatId,
            Event_Id__c = c.mom.Id,
            Model__c = model == null ? null : model.left(80),
            Status__c = c.status,
            Input_Tokens__c = c.inputTokens,
            Output_Tokens__c = c.outputTokens,
            Response__c = c.response == null ? null : c.response.left(131072),
            Changes__c = String.join(changes, '\n').left(32768),
            Details__c = String.join(c.details, '\n').left(32768)
        );
    }

    /** Gemini_Opty_Log__c only knows Success and Fail; Partial still saved, so it's a Success. */
    private static Gemini_Opty_Log__c toOptyLog(Call c) {
        Boolean saved = c.status == SUCCESS || c.status == PARTIAL;
        Integer tokens = (c.inputTokens == null ? 0 : c.inputTokens) + (c.outputTokens == null ? 0 : c.outputTokens);
        return new Gemini_Opty_Log__c(
            Opportunity__c = c.mom.WhatId,
            Status__c = saved ? 'Success' : 'Fail',
            Token_Used__c = tokens,
            JSON_Log__c = c.response == null ? String.join(c.details, '\n').left(131072) : c.response.left(131072)
        );
    }

    // ---- Config -------------------------------------------------------------

    private static String model() {
        Program_Constant__mdt row = Program_Constant__mdt.getInstance(MODEL_KEY);
        return row == null || row.Value__c == null ? null : row.Value__c.trim();
    }

    private static String prompt() {
        List<StaticResource> rows = [SELECT Body FROM StaticResource WHERE Name = :PROMPT_RESOURCE WITH SYSTEM_MODE LIMIT 1];
        return rows.isEmpty() ? null : rows[0].Body.toString();
    }

    private static String errorText(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error e : errors) {
            messages.add(e.getStatusCode() + ': ' + e.getMessage());
        }
        return String.join(messages, '; ');
    }
}
