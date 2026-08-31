@isTest
private class ScheduleAdjustLeaveManagementTest {

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