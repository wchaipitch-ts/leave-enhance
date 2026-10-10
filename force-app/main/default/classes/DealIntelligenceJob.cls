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
 * When Gemini refuses a call, nothing more is sent in that run, and:
 *   503 (busy for a moment)  the meetings are queued again RETRY_DELAY_MINUTES later,
 *                            up to MAX_ATTEMPTS calls each;
 *   429 (rate limit, quota)  everything waits for one scheduled retry (this class,
 *                            Schedulable): a couple of minutes later when Gemini asks
 *                            for a short wait (a per-minute limit), an hour later when
 *                            it asks for a long one or doesn't say (a used-up daily
 *                            quota). It runs the backfill with the deals that hit the
 *                            limit first, then everything else still unticked, and
 *                            pauses again if Gemini is still refusing.
 *
 * Nightly safety net (inner class Nightly, Schedulable): the backfill every night at
 * 02:00, switched on once with DealIntelligenceJob.scheduleNightly(). It only sends
 * meetings still waiting — ones that failed for a reason that isn't retried, or ran
 * out of busy retries — so most nights it makes no Gemini calls at all.
 */
public without sharing class DealIntelligenceJob
        implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful, Schedulable {

    /** Meetings per transaction. A call usually takes 5–20 s; three keeps clear of 120 s. */
    @TestVisible private static final Integer PER_TRANSACTION = 3;

    /** Calls per meeting in all for a busy Gemini (503), the first one included. */
    @TestVisible private static final Integer MAX_ATTEMPTS = 3;
    @TestVisible private static final Integer RETRY_DELAY_MINUTES = 2;

    /** How long to leave Gemini alone after a 429: long by default (a used-up quota)... */
    @TestVisible private static final Integer RATE_LIMIT_WAIT_MINUTES = 60;
    /** ...short when Gemini asks for at most SHORT_WAIT_MAX_SECONDS (a per-minute limit). */
    @TestVisible private static final Integer SHORT_WAIT_MINUTES = 2;
    @TestVisible private static final Integer SHORT_WAIT_MAX_SECONDS = 600;
    @TestVisible private static final String RATE_LIMIT_RETRY_NAME = 'AI Deal Intelligence - retry after Gemini rate limit';

    @TestVisible private static final String NIGHTLY_NAME = 'AI Deal Intelligence - nightly backfill';
    /** 02:00 every day, in the time zone of the user who switches it on. */
    @TestVisible private static final String NIGHTLY_CRON = '0 0 2 * * ?';

    /** Off in test setup, so inserting test meetings doesn't start real-time jobs. */
    @TestVisible private static Boolean realTimeOn = true;

    /** In tests, the follow-up job and the hourly retry that would have been started. */
    @TestVisible private static RealTime queuedInTest;
    @TestVisible private static Integer queuedDelayInTest;
    @TestVisible private static Boolean rateLimitRetryInTest = false;
    @TestVisible private static Integer rateLimitRetryMinutesInTest;
    /** Lets a test schedule the hourly retry for real, to check it. */
    @TestVisible private static Boolean scheduleForRealInTest = false;

    private Boolean startedBySchedule = false;
    private DealIntelligenceService.Summary total = new DealIntelligenceService.Summary();
    private Integer retriesQueued = 0;
    private Boolean rateLimited = false;
    private Integer rateLimitWaitSeconds;
    private Integer leftForLater = 0;

    public DealIntelligenceJob() {}

    private DealIntelligenceJob(Boolean startedBySchedule) {
        this.startedBySchedule = startedBySchedule;
    }

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
            if (summary.rateLimited) {
                // The rest stays unticked; the rate-limit retry's backfill picks it all up.
                scheduleRateLimitRetry(waitMinutes(summary.rateLimitWaitSeconds));
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

    // ---- Retry after a rate limit ---------------------------------------------

    /**
     * How long to wait after a 429, from the wait Gemini asked for: a short one (a
     * per-minute limit) gets SHORT_WAIT_MINUTES, or a minute more than Gemini asked
     * if that is longer; a long one or none at all (a used-up quota) gets the hour.
     */
    @TestVisible private static Integer waitMinutes(Integer geminiAskedSeconds) {
        if (geminiAskedSeconds == null || geminiAskedSeconds > SHORT_WAIT_MAX_SECONDS) {
            return RATE_LIMIT_WAIT_MINUTES;
        }
        return Math.max(SHORT_WAIT_MINUTES, (geminiAskedSeconds + 59) / 60 + 1);
    }

    /**
     * Schedules one backfill run the given minutes from now. However many jobs hit the
     * limit, only one retry ever waits: a retry already due sooner is kept, and one due
     * later is replaced by the sooner one.
     */
    public static void scheduleRateLimitRetry(Integer minutes) {
        if (Test.isRunningTest() && !scheduleForRealInTest) {
            rateLimitRetryInTest = true;
            rateLimitRetryMinutesInTest = minutes;
            return;
        }
        Datetime at = Datetime.now().addMinutes(minutes);
        for (CronTrigger t : [
            SELECT Id, NextFireTime FROM CronTrigger
            WHERE CronJobDetail.Name = :RATE_LIMIT_RETRY_NAME
            WITH SYSTEM_MODE
        ]) {
            if (t.NextFireTime != null && t.NextFireTime <= at) {
                return;
            }
            System.abortJob(t.Id); // later than needed, or finished but still holding the name
        }
        String cron = at.second() + ' ' + at.minute() + ' ' + at.hour() + ' '
            + at.day() + ' ' + at.month() + ' ? ' + at.year();
        System.schedule(RATE_LIMIT_RETRY_NAME, cron, new DealIntelligenceJob());
    }

    /** The rate-limit retry: a backfill that puts the deals that hit the limit first. */
    public void execute(SchedulableContext context) {
        if (context != null) {
            System.abortJob(context.getTriggerId()); // one-off: free the name for the next pause
        }
        Database.executeBatch(new DealIntelligenceJob(true), PER_TRANSACTION);
    }

    // ---- Nightly safety net ---------------------------------------------------

    /** Switches the nightly backfill on (once is enough; a second call changes nothing). */
    public static Id scheduleNightly() {
        for (CronTrigger t : [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :NIGHTLY_NAME WITH SYSTEM_MODE
        ]) {
            return t.Id;
        }
        return System.schedule(NIGHTLY_NAME, NIGHTLY_CRON, new Nightly());
    }

    public class Nightly implements Schedulable {
        public void execute(SchedulableContext context) {
            // Quiet like the hourly retry: no email, the logs hold the outcome.
            Database.executeBatch(new DealIntelligenceJob(true), PER_TRANSACTION);
        }
    }

    // ---- Backfill -----------------------------------------------------------

    public Iterable<SObject> start(Database.BatchableContext context) {
        List<String> types = DealIntelligenceRules.momTypes();
        List<String> subjects = DealIntelligenceRules.momSubjects();
        // Sorted by deal, then meeting date, so each Opportunity sees its meetings
        // oldest first — also across chunks, which run one after another. The
        // Description length can't be filtered in SOQL; the service checks it.
        List<Event> pending = [
            SELECT Id, WhatId
            FROM Event
            WHERE ActivityDate = LAST_N_DAYS:365
              AND What.Type = 'Opportunity'
              AND Type IN :types
              AND Subject IN :subjects
              AND AI_Processed__c = false
            WITH SYSTEM_MODE
            ORDER BY WhatId, StartDateTime, CreatedDate
            LIMIT 50000
        ];

        // Deals that were held back by a rate limit go first, as whole deals, so their
        // meetings still merge oldest first.
        Set<Id> heldBack = dealsHeldBackByRateLimit(pending);
        List<Event> first = new List<Event>();
        List<Event> rest = new List<Event>();
        for (Event e : pending) {
            if (heldBack.contains(e.WhatId)) {
                first.add(e);
            } else {
                rest.add(e);
            }
        }
        first.addAll(rest);
        return first;
    }

    /** Deals with a pending meeting whose last week of logs shows a 429. */
    @TestVisible private static Set<Id> dealsHeldBackByRateLimit(List<Event> pending) {
        Set<String> limitedMeetings = new Set<String>();
        for (AI_Analysis_Log__c log : [
            SELECT Event_Id__c, Details__c FROM AI_Analysis_Log__c
            WHERE Status__c = 'Failed' AND CreatedDate = LAST_N_DAYS:7
            WITH SYSTEM_MODE
        ]) {
            if (log.Details__c != null && log.Details__c.startsWith(DealIntelligenceService.RATE_LIMITED_DETAIL)) {
                limitedMeetings.add(log.Event_Id__c);
            }
        }
        Set<Id> deals = new Set<Id>();
        for (Event e : pending) {
            if (limitedMeetings.contains(e.Id)) {
                deals.add(e.WhatId);
            }
        }
        return deals;
    }

    public void execute(Database.BatchableContext context, List<SObject> scope) {
        List<Id> ids = new List<Id>(new Map<Id, SObject>(scope).keySet());
        if (rateLimited) {
            // Gemini is refusing; the rest waits for the rate-limit retry.
            leftForLater += ids.size();
            return;
        }
        DealIntelligenceService.Summary part = DealIntelligenceService.analyse(ids);
        total.analysed += part.analysed;
        total.failed += part.failed;
        total.skipped += part.skipped;
        total.inputTokens += part.inputTokens;
        total.outputTokens += part.outputTokens;

        if (part.rateLimited) {
            rateLimited = true;
            rateLimitWaitSeconds = part.rateLimitWaitSeconds;
            leftForLater += part.deferred.size();
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
        if (rateLimited) {
            scheduleRateLimitRetry(waitMinutes(rateLimitWaitSeconds));
        }
        // Scheduled runs are quiet; only a backfill someone started sends an email.
        if (startedBySchedule) {
            return;
        }
        AsyncApexJob job = [
            SELECT Status, NumberOfErrors, TotalJobItems
            FROM AsyncApexJob
            WHERE Id = :context.getJobId()
            WITH SYSTEM_MODE
        ];
        String body = String.join(new List<String>{
            'AI Deal Intelligence backfill finished: ' + job.Status + '.',
            rateLimited
                ? 'PAUSED by Gemini rate limit (429): ' + leftForLater + ' meeting(s) wait. '
                    + 'It continues automatically in ' + waitMinutes(rateLimitWaitSeconds) + ' minutes (Setup > Scheduled Jobs).'
                : '',
            '',
            'Analysed: ' + total.analysed,
            'Failed: ' + total.failed + '  (left unticked for the next run)',
            'Gemini busy, retrying in ' + RETRY_DELAY_MINUTES + ' minutes: ' + retriesQueued,
            'Skipped: ' + total.skipped + '  (e.g. Description under the minimum length)',
            'Chunks with an unhandled error: ' + job.NumberOfErrors + ' of ' + job.TotalJobItems,
            'Tokens: ' + total.inputTokens + ' in, ' + total.outputTokens + ' out',
            '',
            'Details per meeting: AI Analysis Log records.'
        }, '\n');

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setTargetObjectId(UserInfo.getUserId());
        mail.setSaveAsActivity(false);
        mail.setSubject('AI Deal Intelligence backfill: ' + total.analysed + ' analysed, ' + total.failed + ' failed'
            + (rateLimited ? ', paused for rate limit' : ''));
        mail.setPlainTextBody(body);
        try {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        } catch (Exception e) {
            // Sandboxes often have email turned off; the logs still hold everything.
            System.debug(LoggingLevel.WARN, body);
        }
    }
}
