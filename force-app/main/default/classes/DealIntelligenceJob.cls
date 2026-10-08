/**
 * Runs AI Deal Intelligence in the background, in the two ways the BA asked for:
 *
 *   Backfill   (this class, Batchable) every unprocessed meeting of the past year:
 *              DealIntelligenceJob.runBackfill();
 *   Real-time  (inner class RealTime, Queueable) the meetings just logged, enqueued by
 *              the Event trigger. Inner, because Salesforce won't let one class be
 *              both Queueable and Batchable.
 *
 * Both hand Event Ids to DealIntelligenceService, a few at a time: each meeting is one
 * Gemini call, and Salesforce allows 120 seconds of callouts per transaction.
 */
public without sharing class DealIntelligenceJob
        implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    /** Meetings per transaction. A call usually takes 5–20 s; three keeps clear of 120 s. */
    @TestVisible private static final Integer PER_TRANSACTION = 3;

    /** Off in test setup, so inserting test meetings doesn't start real-time jobs. */
    @TestVisible private static Boolean realTimeOn = true;

    private DealIntelligenceService.Summary total = new DealIntelligenceService.Summary();

    public static Id runBackfill() {
        return Database.executeBatch(new DealIntelligenceJob(), PER_TRANSACTION);
    }

    // ---- Real-time ----------------------------------------------------------

    /**
     * Called from the Event trigger after insert. Never throws: a rep's save must not
     * fail because of the AI. A meeting that can't be queued now stays unticked, and
     * the next backfill run picks it up.
     */
    public static void enqueueFor(List<Event> inserted) {
        if (!realTimeOn) {
            return;
        }
        try {
            List<Id> ids = new List<Id>(new Map<Id, Event>(DealIntelligenceRules.qualifying(inserted)).keySet());
            if (!ids.isEmpty() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
                System.enqueueJob(new RealTime(ids));
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AI Deal Intelligence could not queue ' + inserted.size() + ' meeting(s): ' + e);
        }
    }

    public class RealTime implements Queueable, Database.AllowsCallouts {
        private List<Id> pending;

        public RealTime(List<Id> eventIds) {
            this.pending = eventIds;
        }

        public void execute(QueueableContext context) {
            List<Id> now = new List<Id>();
            List<Id> later = new List<Id>();
            for (Id eventId : pending) {
                if (now.size() < PER_TRANSACTION) {
                    now.add(eventId);
                } else {
                    later.add(eventId);
                }
            }

            DealIntelligenceService.analyse(now);

            // Apex tests can't chain queueables; outside tests the rest runs in the next job.
            if (!later.isEmpty() && !Test.isRunningTest()) {
                System.enqueueJob(new RealTime(later));
            }
        }
    }

    // ---- Backfill -----------------------------------------------------------

    public Database.QueryLocator start(Database.BatchableContext context) {
        List<String> types = DealIntelligenceRules.momTypes();
        List<String> subjects = DealIntelligenceRules.momSubjects();
        // Sorted by deal, then meeting date, so each Opportunity sees its meetings
        // oldest first — also across chunks, which run one after another. The
        // Description length can't be filtered in SOQL; the service checks it.
        return Database.getQueryLocator([
            SELECT Id
            FROM Event
            WHERE ActivityDate = LAST_N_DAYS:365
              AND What.Type = 'Opportunity'
              AND Type IN :types
              AND Subject IN :subjects
              AND AI_Processed__c = false
            WITH SYSTEM_MODE
            ORDER BY WhatId, StartDateTime, CreatedDate
        ]);
    }

    public void execute(Database.BatchableContext context, List<SObject> scope) {
        List<Id> ids = new List<Id>(new Map<Id, SObject>(scope).keySet());
        DealIntelligenceService.Summary part = DealIntelligenceService.analyse(ids);
        total.analysed += part.analysed;
        total.failed += part.failed;
        total.skipped += part.skipped;
        total.inputTokens += part.inputTokens;
        total.outputTokens += part.outputTokens;
    }

    public void finish(Database.BatchableContext context) {
        AsyncApexJob job = [
            SELECT Status, NumberOfErrors, TotalJobItems
            FROM AsyncApexJob
            WHERE Id = :context.getJobId()
            WITH SYSTEM_MODE
        ];
        String body = String.join(new List<String>{
            'AI Deal Intelligence backfill finished: ' + job.Status + '.',
            '',
            'Analysed: ' + total.analysed,
            'Failed: ' + total.failed + '  (left unticked — run the backfill again to retry)',
            'Skipped: ' + total.skipped + '  (e.g. Description under the minimum length)',
            'Chunks with an unhandled error: ' + job.NumberOfErrors + ' of ' + job.TotalJobItems,
            'Tokens: ' + total.inputTokens + ' in, ' + total.outputTokens + ' out',
            '',
            'Details per meeting: AI Analysis Log records.'
        }, '\n');

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setTargetObjectId(UserInfo.getUserId());
        mail.setSaveAsActivity(false);
        mail.setSubject('AI Deal Intelligence backfill: ' + total.analysed + ' analysed, ' + total.failed + ' failed');
        mail.setPlainTextBody(body);
        try {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        } catch (Exception e) {
            // Sandboxes often have email turned off; the logs still hold everything.
            System.debug(LoggingLevel.WARN, body);
        }
    }
}
