public with sharing class ScheduleAdjustLeaveManagement {
    public static void scheduleJob() {
        // CRON expression for 12:00 AM on the 1st day of every month
        String cronExp = '0 0 0 1 * ?';
        
        // Schedule the job
        System.schedule('Monthly Leave Management Job', cronExp, new LeaveManagementController());
    }
}
// ScheduleAdjustLeaveManagement.scheduleJob();