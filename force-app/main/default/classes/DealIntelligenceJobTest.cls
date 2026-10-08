@isTest
private class DealIntelligenceJobTest {

    private static final String MOM_SUBJECT = 'Web Meeting - 1. Initial Meeting / Hearing';
    private static final String LONG_TEXT =
        'Customer confirmed a budget for next year and asked how data migration from their legacy system would work.';

    /** Every call gets the same small answer: score 60. */
    private class GeminiMock implements HttpCalloutMock {
        Integer calls = 0;

        public HttpResponse respond(HttpRequest req) {
            calls++;
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
        insert new Opportunity(
            Name = 'AIDI Job',
            StageName = firstValue(Opportunity.StageName.getDescribe()),
            Your_Win_Confidence__c = firstValue(Opportunity.Your_Win_Confidence__c.getDescribe()),
            CloseDate = Date.today().addMonths(3)
        );
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
            'SELECT Id, Customer_Seriousness_Score__c FROM Opportunity WHERE Name = \'AIDI Job\'',
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
        insert new List<Event>{
            mom(LONG_TEXT, 30),
            mom(LONG_TEXT, 200),
            mom(LONG_TEXT, 400),               // older than a year
            mom('called, no answer', 10)       // too short
        };

        Test.startTest();
        DealIntelligenceJob.runBackfill();
        Test.stopTest();

        System.assertEquals(2, mock.calls);
        System.assertEquals(2, ticked());
        System.assertEquals(60, theOpp().Customer_Seriousness_Score__c);
        System.assertEquals(2, [SELECT COUNT() FROM AI_Analysis_Log__c WITH SYSTEM_MODE]);
    }
}
