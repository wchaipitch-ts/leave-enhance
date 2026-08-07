@isTest
private class ScheduleAdjustLeaveManagementTest {

@isTest
    static void testScheduleJob() {
        // Schedule the job
        Test.startTest();
        ScheduleAdjustLeaveManagement.scheduleJob();
        Test.stopTest();
    }
}