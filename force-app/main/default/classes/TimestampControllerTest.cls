@IsTest
public class TimestampControllerTest {

    // 共通で使うユーザを作成
    private static User createTestUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name='Standard User' LIMIT 1];
        User u = new User(
            Alias = 'testu',
            Email = 'testuser@test.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Test',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Tokyo',
            UserName = 'testuser' + System.currentTimeMillis() + '@test.com'
        );
        insert u;
        return u;
    }

    @IsTest
    static void testCheckTimeRecord_NoRecords() {
        User u = createTestUser();
        Test.startTest();
        List<Timestamp__c> result = TimestampController.checkTimeRecord(u.Id);
        Test.stopTest();

        System.assertEquals(0, result.size(), '新規ユーザは当日レコードなし');
    }

    @IsTest
    static void testSetTimeStamp_CheckIn_NewRecord() {
        User u = createTestUser();

        Test.startTest();
        String result = TimestampController.setTimeStamp(u.Id, 'in', 35, 139, 'First Check-In');
        Test.stopTest();

        System.assertEquals('SUCCESS', result);
        List<Timestamp__c> stampedList = TimestampController.checkTimeRecord(u.Id);
        System.assertEquals(1, stampedList.size(), '新しいレコードが作成されるはず');
        System.assertNotEquals(null, stampedList[0].Stamped_TimeIn__c, 'Check-In 時間が設定されるはず');
        System.assertEquals('First Check-In', stampedList[0].Remark__c);
    }

    @IsTest
    static void testSetTimeStamp_CheckOut_UpdateRecord() {
        User u = createTestUser();

        // 先にCheck-In
        TimestampController.setTimeStamp(u.Id, 'in', 35, 139, 'Initial Check-In');

        Test.startTest();
        String result = TimestampController.setTimeStamp(u.Id, 'out', 35, 139, 'Checked Out');
        Test.stopTest();

        System.assertEquals('SUCCESS', result);
        List<Timestamp__c> stampedList = TimestampController.checkTimeRecord(u.Id);
        System.assertNotEquals(null, stampedList[0].Stamped_TimeOut__c, 'Check-Out 時間が設定されるはず');
        System.assert(stampedList[0].Remark__c.contains('Checked Out'), 'Remarkに追記されるはず');
    }

    @IsTest
    static void testSetTimeStamp_RemarksWorkedHours() {
        User u = createTestUser();
        TimestampController.setTimeStamp(u.Id, 'in', 35, 139, 'First In');

        Test.startTest();
        String result = TimestampController.setTimeStamp(u.Id, 'WorkHour under 7.5 Hours Reason', null, null, 'Left Early');
        Test.stopTest();

        System.assertEquals('SUCCESS', result);
        List<Timestamp__c> stampedList = TimestampController.checkTimeRecord(u.Id);
        System.assertEquals('Left Early', stampedList[0].WorkHour_Reason__c);
    }

    @IsTest
    static void testSetTimeStamp_RemarksOvertime() {
        User u = createTestUser();
        TimestampController.setTimeStamp(u.Id, 'in', 35, 139, 'First In');

        Test.startTest();
        String result = TimestampController.setTimeStamp(u.Id, 'Over Time Reason', null, null, 'Overtime Work');
        Test.stopTest();

        System.assertEquals('SUCCESS', result);
        List<Timestamp__c> stampedList = TimestampController.checkTimeRecord(u.Id);
        System.assertEquals('Overtime Work', stampedList[0].Overtime_Reason__c);
    }

    @IsTest
    static void testSetTimeStamp_FallbackManualInput() {
        User u = createTestUser();

        Test.startTest();
        String result = TimestampController.setTimeStamp(u.Id, 'SomeOtherType', null, null, 'Manual Reason');
        Test.stopTest();

        System.assertEquals('SUCCESS', result);
        List<Timestamp__c> stampedList = TimestampController.checkTimeRecord(u.Id);
        System.assertEquals(null, stampedList[0].Maunal_Input_Reason__c);
    }

    @IsTest
    static void testGetCurrentDateTimeForDisplay() {
        Test.startTest();
        TimestampController.CurrentTimeDisplay display = TimestampController.getCurrentDateTimeForDisplay();
        Test.stopTest();

        System.assertNotEquals(null, display.hours);
        System.assertNotEquals(null, display.minutes);
        System.assert(display.hours >= 0 && display.hours <= 23);
        System.assert(display.minutes >= 0 && display.minutes <= 59);
    }
}