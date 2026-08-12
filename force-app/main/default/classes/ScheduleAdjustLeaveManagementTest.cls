@isTest
private class ScheduleAdjustLeaveManagementTest {

    /*
     * Called twice on purpose. The second call finds the job the first one scheduled
     * and aborts it before re-scheduling, which is the idempotency the production
     * path relies on after a code change — and the only way to reach System.abortJob
     * from a test without touching the org's live job.
     */
    @isTest
    static void schedulingIsIdempotent() {
        Test.startTest();
        ScheduleAdjustLeaveManagement.scheduleJob();
        ScheduleAdjustLeaveManagement.scheduleJob();
        Test.stopTest();

        List<CronTrigger> scheduled = [
            SELECT Id, CronExpression FROM CronTrigger
            WHERE CronJobDetail.Name = 'Daily Leave Management Job (test)'
        ];
        System.assertEquals(1, scheduled.size(),
            'scheduling twice must leave exactly one job, not two');
        System.assertEquals('0 0 1 * * ?', scheduled[0].CronExpression,
            'the job runs daily at 01:00');
    }
}
