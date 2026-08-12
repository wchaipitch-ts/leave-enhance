public with sharing class ScheduleAdjustLeaveManagement {

    private static final String JOB_NAME = 'Daily Leave Management Job';

    /*
     * LEAVE-10: 01:00 every day, was '0 0 0 1 * ?' (midnight on the 1st).
     *
     * LeaveManagementController.runDaily() decides for itself what is due on the
     * date it is handed — the January 1 annual grant, a new hire's joining date,
     * an anniversary, an expiry. A monthly job only ever handed it the 1st, so
     * every grant that falls on any other day of the month never fired.
     */
    private static final String CRON_EXP = '0 0 1 * * ?';

    public static void scheduleJob() {
        // Re-scheduling replaces the existing job rather than throwing on the
        // duplicate name, so this is safe to run again after a code change.
        //
        // CronTrigger is not isolated in test context — an unguarded abort here
        // would take down the org's real scheduled job during a test run.
        if (!Test.isRunningTest()) {
            for (CronTrigger ct : [
                SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :JOB_NAME
            ]) {
                System.abortJob(ct.Id);
            }
        }

        System.schedule(JOB_NAME, CRON_EXP, new LeaveManagementController());
    }
}
// ScheduleAdjustLeaveManagement.scheduleJob();
