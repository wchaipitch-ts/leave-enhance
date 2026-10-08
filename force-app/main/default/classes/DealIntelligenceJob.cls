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
 *
 * When Gemini is busy (503) or rate-limited (429), the meeting is queued again a few
 * minutes later, up to MAX_ATTEMPTS calls in all, and nothing more is sent until then.
 * Apex can't wait inside a transaction, so a delayed job is the only way to give
 * Gemini time to recover. When Gemini says the quota is used up for longer than a
 * short wait (the free tier's daily limit, say), nothing is retried: the meetings stay
 * unticked for the next backfill run.
 */
public without sharing class DealIntelligenceJob
        implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    /** Meetings per transaction. A call usually takes 5–20 s; three keeps clear of 120 s. */
    @TestVisible private static final Integer PER_TRANSACTION = 3;

    /** Calls per meeting in all, the first one included. */
    @TestVisible private static final Integer MAX_ATTEMPTS = 3;
    @TestVisible private static final Integer RETRY_DELAY_MINUTES = 2;

    /** Off in test setup, so inserting test meetings doesn't start real-time jobs. */
    @TestVisible private static Boolean realTimeOn = true;

    /** In tests, the follow-up job that would have been queued, instead of queuing it. */
    @TestVisible private static RealTime queuedInTest;
    @TestVisible private static Integer queuedDelayInTest;

    private DealIntelligenceService.Summary total = new DealIntelligenceService.Summary();
    private Integer retriesQueued = 0;
    private Boolean quotaExhausted = false;

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
        @TestVisible private List<Id> pending;
        /** Calls already made per meeting, for meetings that are being retried. */
        @TestVisible private Map<Id, Integer> attempts;

        public RealTime(List<Id> eventIds) {
            this(eventIds, new Map<Id, Integer>());
        }

        @TestVisible private RealTime(List<Id> eventIds, Map<Id, Integer> attempts) {
            this.pending = eventIds;
            this.attempts = attempts;
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

            DealIntelligenceService.Summary summary = DealIntelligenceService.analyse(now);
            if (summary.quotaExhausted) {
                // Everything left would be refused too; the backfill picks them up later.
                return;
            }

            // A job may queue only one follow-up, so the rest and the retries share it.
            // After a busy answer the whole follow-up waits, so Gemini can recover.
            List<Id> next = new List<Id>(later);
            next.addAll(summary.deferred);
            next.addAll(retryable(summary.busy, attempts));
            if (!next.isEmpty()) {
                queue(new RealTime(next, attempts), summary.busy.isEmpty() ? 0 : RETRY_DELAY_MINUTES);
            }
        }
    }

    /** The busy meetings that still have attempts left, each counted one more attempt. */
    private static List<Id> retryable(List<Id> busy, Map<Id, Integer> attempts) {
        List<Id> result = new List<Id>();
        for (Id eventId : busy) {
            Integer made = attempts.containsKey(eventId) ? attempts.get(eventId) : 1;
            if (made < MAX_ATTEMPTS) {
                attempts.put(eventId, made + 1);
                result.add(eventId);
            }
        }
        return result;
    }

    private static void queue(RealTime job, Integer delayMinutes) {
        // Apex tests can't chain queueables, so a test reads the job here instead.
        if (Test.isRunningTest()) {
            queuedInTest = job;
            queuedDelayInTest = delayMinutes;
            return;
        }
        System.enqueueJob(job, delayMinutes);
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
        if (quotaExhausted) {
            // Gemini's quota ran out earlier in this run; calling now only fails again.
            total.skipped += ids.size();
            return;
        }
        DealIntelligenceService.Summary part = DealIntelligenceService.analyse(ids);
        if (part.quotaExhausted) {
            quotaExhausted = true;
            total.skipped += part.deferred.size();
        }
        total.analysed += part.analysed;
        total.failed += part.failed;
        total.skipped += part.skipped;
        total.inputTokens += part.inputTokens;
        total.outputTokens += part.outputTokens;

        if (quotaExhausted) {
            return;
        }
        Map<Id, Integer> attempts = new Map<Id, Integer>();
        List<Id> retries = new List<Id>(part.deferred);
        retries.addAll(retryable(part.busy, attempts));
        if (!retries.isEmpty()) {
            queue(new RealTime(retries, attempts), RETRY_DELAY_MINUTES);
            retriesQueued += retries.size();
        }
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
            quotaExhausted
                ? 'STOPPED EARLY: Gemini quota used up (free tier: 20 calls per day per model). Run again after it resets.'
                : '',
            '',
            'Analysed: ' + total.analysed,
            'Failed: ' + total.failed + '  (left unticked — run the backfill again to retry)',
            'Gemini busy, retrying automatically: ' + retriesQueued,
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
