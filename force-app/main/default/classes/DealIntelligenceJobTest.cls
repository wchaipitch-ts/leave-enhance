@isTest
private class DealIntelligenceJobTest {

    private static final String MOM_SUBJECT = 'Web Meeting - 1. Initial Meeting / Hearing';
    private static final String LONG_TEXT =
        'Customer confirmed a budget for next year and asked how data migration from their legacy system would work.';

    /** Every call gets the same small answer (score 60), or the given error status. */
    private class GeminiMock implements HttpCalloutMock {
        Integer calls = 0;
        Integer status = 200;
        String retryDelay;

        GeminiMock() {}

        GeminiMock(Integer status) {
            this.status = status;
        }

        public HttpResponse respond(HttpRequest req) {
            calls++;
            if (status != 200) {
                HttpResponse busy = new HttpResponse();
                busy.setStatusCode(status);
                busy.setStatus(status == 503 ? 'Service Unavailable' : 'Error');
                busy.setBody('{"error":{"code":' + status + ',"message":"This model is currently experiencing high demand."'
                    + (retryDelay == null ? '' : ',"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"' + retryDelay + '"}]')
                    + '}}');
                return busy;
            }
            String text = JSON.serialize(new Map<String, Object>{
                '31_Customer_Seriousness_Score__c' => 60,
                '32_Reason_for_Seriousness_Score__c' => 'Budget confirmed.'
            });
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new Map<String, Object>{
                'candidates' => new List<Object>{
                    new Map<String, Object>{
                        'content' => new Map<String, Object>{
                            'parts' => new List<Object>{ new Map<String, Object>{ 'text' => text } }
                        }
                    }
                },
                'usageMetadata' => new Map<String, Object>{ 'promptTokenCount' => 100, 'candidatesTokenCount' => 10 }
            }));
            return res;
        }
    }

    @TestSetup
    static void makeData() {
        DealIntelligenceJob.realTimeOn = false;
        List<Opportunity> opps = new List<Opportunity>();
        for (String name : new List<String>{ 'AIDI Job', 'AIDI Retry' }) {
            opps.add(new Opportunity(
                Name = name,
                StageName = firstValue(Opportunity.StageName.getDescribe()),
                Your_Win_Confidence__c = firstValue(Opportunity.Your_Win_Confidence__c.getDescribe()),
                CloseDate = Date.today().addMonths(3)
            ));
        }
        insert opps;
        // Retry tests run the job directly, and a callout can't follow DML in the same
        // test, so their meeting is made here.
        Event retry = mom(LONG_TEXT, 1);
        retry.WhatId = opps[1].Id;
        insert retry;
    }

    private static List<Id> retryMeeting() {
        return new List<Id>(new Map<Id, Event>([
            SELECT Id FROM Event WHERE What.Name = 'AIDI Retry' WITH SYSTEM_MODE
        ]).keySet());
    }

    private static String firstValue(Schema.DescribeFieldResult describe) {
        for (Schema.PicklistEntry entry : describe.getPicklistValues()) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return null;
    }

    private static Opportunity theOpp() {
        return (Opportunity) Database.query(
            'SELECT Id, Customer_Seriousness_Score__c FROM Opportunity WHERE Name = \'AIDI Job\' LIMIT 1',
            AccessLevel.SYSTEM_MODE
        );
    }

    private static Event mom(String description, Integer daysAgo) {
        Datetime starts = Datetime.now().addDays(-daysAgo);
        return new Event(
            WhatId = theOpp().Id,
            Type = 'Web Meeting',
            Subject = MOM_SUBJECT,
            Description = description,
            StartDateTime = starts,
            EndDateTime = starts.addHours(1)
        );
    }

    private static Integer ticked() {
        return [SELECT COUNT() FROM Event WHERE What.Name = 'AIDI Job' AND AI_Processed__c = true WITH SYSTEM_MODE];
    }

    // ---- Real-time

    @isTest
    static void loggingAMeetingAnalysesItInTheBackground() {
        Test.setMock(HttpCalloutMock.class, new GeminiMock());

        Test.startTest();
        insert mom(LONG_TEXT, 0);
        Test.stopTest();

        System.assertEquals(1, ticked());
        System.assertEquals(60, theOpp().Customer_Seriousness_Score__c);
    }

    @isTest
    static void shortNoteDoesNotStartAJob() {
        Test.startTest();
        insert mom('called, no answer', 0);
        Test.stopTest();

        System.assertEquals(0, [
            SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'DealIntelligenceJob' WITH SYSTEM_MODE
        ]);
    }

    @isTest
    static void eachJobTakesOnlyAFewMeetings() {
        GeminiMock mock = new GeminiMock();
        Test.setMock(HttpCalloutMock.class, mock);
        List<Event> moms = new List<Event>();
        for (Integer i = 0; i < DealIntelligenceJob.PER_TRANSACTION + 1; i++) {
            moms.add(mom(LONG_TEXT, i));
        }

        Test.startTest();
        insert moms;
        Test.stopTest();

        // Tests can't chain jobs, so only the first job's share is done here; outside
        // tests the next job takes the rest.
        System.assertEquals(DealIntelligenceJob.PER_TRANSACTION, mock.calls);
        System.assertEquals(DealIntelligenceJob.PER_TRANSACTION, ticked());
    }

    // ---- Backfill

    @isTest
    static void backfillTakesThePastYearOnly() {
        GeminiMock mock = new GeminiMock();
        Test.setMock(HttpCalloutMock.class, mock);
        DealIntelligenceJob.realTimeOn = false;
        // Out of the way: a test batch runs one chunk only.
        update new Event(Id = retryMeeting()[0], AI_Processed__c = true);
        insert new List<Event>{
            mom(LONG_TEXT, 30),
            mom(LONG_TEXT, 200),
            mom(LONG_TEXT, 400),               // older than a year
            mom('called, no answer', 10)       // too short
        };

        Test.startTest();
        DealIntelligenceJob.runBackfill();
        Test.stopTest();

        System.assertEquals(2, ticked());
        System.assertEquals(60, theOpp().Customer_Seriousness_Score__c);
        System.assertEquals(2, [SELECT COUNT() FROM AI_Analysis_Log__c WHERE Opportunity__r.Name = 'AIDI Job' WITH SYSTEM_MODE]);
    }

    // ---- Retry when Gemini is busy

    @isTest
    static void busyMeetingIsQueuedAgainAfterADelay() {
        Test.setMock(HttpCalloutMock.class, new GeminiMock(503));
        List<Id> ids = retryMeeting();

        Test.startTest();
        new DealIntelligenceJob.RealTime(ids).execute(null);
        Test.stopTest();

        DealIntelligenceJob.RealTime next = DealIntelligenceJob.queuedInTest;
        System.assertNotEquals(null, next, 'a retry is queued');
        System.assertEquals(ids, next.pending);
        System.assertEquals(2, next.attempts.get(ids[0]), 'the retry is the second attempt');
        System.assertEquals(DealIntelligenceJob.RETRY_DELAY_MINUTES, DealIntelligenceJob.queuedDelayInTest);

        System.assertEquals(false, [SELECT AI_Processed__c FROM Event WHERE Id = :ids[0] WITH SYSTEM_MODE].AI_Processed__c);
        AI_Analysis_Log__c log = [SELECT Status__c, Details__c FROM AI_Analysis_Log__c WHERE Opportunity__r.Name = 'AIDI Retry' WITH SYSTEM_MODE];
        System.assertEquals('Failed', log.Status__c);
        System.assert(log.Details__c.contains('HTTP 503'), log.Details__c);
    }

    @isTest
    static void rateLimitWaitsForTheHourlyRetry() {
        Test.setMock(HttpCalloutMock.class, new GeminiMock(429));

        Test.startTest();
        new DealIntelligenceJob.RealTime(retryMeeting()).execute(null);
        Test.stopTest();

        System.assertEquals(null, DealIntelligenceJob.queuedInTest, 'no quick retry for a 429');
        System.assert(DealIntelligenceJob.rateLimitRetryInTest, 'the hourly retry is scheduled');
        System.assertEquals(false, [SELECT AI_Processed__c FROM Event WHERE Id = :retryMeeting()[0] WITH SYSTEM_MODE].AI_Processed__c);
    }

    @isTest
    static void hourlyRetryIsScheduledOnlyOnce() {
        DealIntelligenceJob.scheduleForRealInTest = true;
        // No startTest/stopTest: the scheduled job must not actually run here.
        DealIntelligenceJob.scheduleRateLimitRetry();
        DealIntelligenceJob.scheduleRateLimitRetry();

        List<CronTrigger> retries = [
            SELECT NextFireTime FROM CronTrigger
            WHERE CronJobDetail.Name = :DealIntelligenceJob.RATE_LIMIT_RETRY_NAME
        ];
        System.assertEquals(1, retries.size(), 'one retry an hour, however many jobs hit the limit');
        Long minutes = (retries[0].NextFireTime.getTime() - Datetime.now().getTime()) / 60000;
        System.assert(minutes >= DealIntelligenceJob.RATE_LIMIT_WAIT_MINUTES - 2 && minutes <= DealIntelligenceJob.RATE_LIMIT_WAIT_MINUTES,
            'fires in about an hour: ' + minutes + ' minutes');
    }

    @isTest
    static void dealsHeldBackByRateLimitGoFirst() {
        DealIntelligenceJob.realTimeOn = false;
        insert new List<Event>{ mom(LONG_TEXT, 20), mom(LONG_TEXT, 10) };
        Id retryId = retryMeeting()[0];
        insert new AI_Analysis_Log__c(
            Event_Id__c = retryId,
            Status__c = 'Failed',
            Details__c = 'HTTP 429 Too Many Requests (Gemini asks to wait 14 s)'
        );

        List<SObject> order = (List<SObject>) new DealIntelligenceJob().start(null);

        System.assertEquals(retryId, order[0].Id, 'the deal that hit the limit comes first');
        System.assertEquals(3, order.size(), 'then everything else still pending');
    }

    @isTest
    static void backfillStopsCallingAtTheFirstRateLimit() {
        GeminiMock mock = new GeminiMock(429);
        Test.setMock(HttpCalloutMock.class, mock);
        DealIntelligenceJob.realTimeOn = false;
        insert new List<Event>{ mom(LONG_TEXT, 20), mom(LONG_TEXT, 10) };

        Test.startTest();
        DealIntelligenceJob.runBackfill();
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM AI_Analysis_Log__c WITH SYSTEM_MODE], 'one refused call, the rest held back');
        System.assertEquals(0, [SELECT COUNT() FROM Event WHERE AI_Processed__c = true WITH SYSTEM_MODE]);
    }

    @isTest
    static void hourlyRetryRunsTheBackfill() {
        Test.setMock(HttpCalloutMock.class, new GeminiMock());

        Test.startTest();
        new DealIntelligenceJob().execute((SchedulableContext) null);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'BatchApex' AND ApexClass.Name = 'DealIntelligenceJob' WITH SYSTEM_MODE]);
        System.assertEquals(true, [SELECT AI_Processed__c FROM Event WHERE Id = :retryMeeting()[0] WITH SYSTEM_MODE].AI_Processed__c);
    }

    @isTest
    static void givesUpAfterTheLastAttempt() {
        Test.setMock(HttpCalloutMock.class, new GeminiMock(503));
        List<Id> ids = retryMeeting();
        Map<Id, Integer> attempts = new Map<Id, Integer>{ ids[0] => DealIntelligenceJob.MAX_ATTEMPTS };

        Test.startTest();
        new DealIntelligenceJob.RealTime(ids, attempts).execute(null);
        Test.stopTest();

        System.assertEquals(null, DealIntelligenceJob.queuedInTest, 'no more retries; the backfill can still pick it up');
    }

    @isTest
    static void otherErrorsAreNotRetried() {
        Test.setMock(HttpCalloutMock.class, new GeminiMock(500));

        Test.startTest();
        new DealIntelligenceJob.RealTime(retryMeeting()).execute(null);
        Test.stopTest();

        System.assertEquals(null, DealIntelligenceJob.queuedInTest);
    }
}
