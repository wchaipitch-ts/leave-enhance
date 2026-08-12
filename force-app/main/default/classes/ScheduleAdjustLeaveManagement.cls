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
        /*
         * Re-scheduling replaces the existing job rather than throwing on the
         * duplicate name, so this is safe to run again after a code change.
         *
         * CronTrigger is not isolated in test context, which cuts both ways: an
         * unguarded abort would take down the org's real scheduled job, and reusing
         * the real job's name would collide with it. Tests therefore run against a
         * separate job name, which keeps the live job untouched while still exercising
         * both the abort and the schedule.
         */
        String jobName = Test.isRunningTest()
            ? JOB_NAME + ' (test)'
            : JOB_NAME;

        // Scoped to jobName rather than JOB_NAME, which is what makes this safe under
        // test: the test name never matches the live job, so the live job is never
        // found and never aborted. The name is fixed rather than timestamped so a
        // test can call this twice and genuinely exercise the abort path.
        for (CronTrigger ct : [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :jobName
        ]) {
            System.abortJob(ct.Id);
        }

        System.schedule(jobName, CRON_EXP, new LeaveManagementController());
    }
}
// ScheduleAdjustLeaveManagement.scheduleJob();
