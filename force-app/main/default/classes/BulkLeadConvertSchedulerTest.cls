@IsTest
private class BulkLeadConvertSchedulerTest {

    @IsTest
    static void testSchedulerRunsBatchAtSchedule() {
        // Schedule the job; in tests, it will run once at Test.stopTest().
        Test.startTest();
        String jobId = System.schedule('BulkLeadConvert_Daily_Midnight_Test', '0 0 0 * * ?', new BulkLeadConvertScheduler());
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Scheduled job id should be returned');
        // Optional sanity: confirm the class is schedulable and no unhandled exceptions occurred.
    }
}