public with sharing class ScheduleAdjustLeaveManagement {

    private static final String JOB_NAME = 'Daily Leave Management Job';

    private static final String CRON_EXP = '0 0 1 * * ?';

    public static void scheduleJob() {

        String jobName = Test.isRunningTest()
            ? JOB_NAME + ' (test)'
            : JOB_NAME;

        for (CronTrigger ct : [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :jobName
        ]) {
            System.abortJob(ct.Id);
        }

        System.schedule(jobName, CRON_EXP, new LeaveManagementController());
    }
}
// ScheduleAdjustLeaveManagement.scheduleJob();