@isTest
public with sharing class TimesheetControllerTest {    
    // private static User mdUser = TST_TestDataFactory.createManagingDirectorUser();
    private static User enrUser = TST_TestDataFactory.createEngineerUser();   

    /**
	* Prepare test data
	*/
	@testSetup static void prepareTestData(){
        System.runAs ( enrUser ) {
            Timestamp__c timestamp = new Timestamp__c(Stamped_Date__c = Date.newInstance(2023, 8, 30));
            insert timestamp;
        }
    }

    private static testMethod void testGetUserAvatar01(){
		TimesheetController controller = new TimesheetController();
        System.runAs ( enrUser ) {
			Test.startTest();
            User userInfo = TimesheetController.getUserAvatar(enrUser.Id);
			Test.stopTest();
            Assert.areEqual('User1 Test1', userInfo.Name);
		}
        
    }
    
    private static testMethod void testGetUserAvatar02(){
		TimesheetController controller = new TimesheetController();
        System.runAs ( enrUser ) {
			Test.startTest();
            User userInfo = TimesheetController.getUserAvatar(null);
			Test.stopTest();
            Assert.isNull(userInfo);
		}
        
    }

    // private static testMethod void testCheckPermissionUser01(){
    //     System.runAs(enrUser){
    //         Test.startTest();
    //         boolean isHavePermission = TimesheetController.checkPermissionUser();
    //         Test.stopTest();
    //         Assert.areEqual(false, isHavePermission, 'User must have permission');
    //     }
    // }

    @isTest(seeAllData=false)
    static void testCheckPermissionUserWithPermissionSet() {
        // Assign the "Time_Sheet_Management_Screen_Permission" permission set to the user
        TST_TestDataFactory.assignPermissionSetToUser(enrUser, 'Time_Sheet_Management_Screen_Permission');
        
        // Run the checkPermissionUser method as the engineer user
        System.runAs(enrUser) {
            Test.startTest();
            boolean hasPermission = TimesheetController.checkPermissionUser();
            Test.stopTest();
            
            // Verify that the user has the permission
            System.assertEquals(true, hasPermission, 'Engineer user should have the permission set.');
        }
    }

    @isTest(seeAllData=false)
    static void testCheckPermissionUserWithoutPermissionSet() {
        // Run the checkPermissionUser method as the engineer user without assigning any permission set
        System.runAs(enrUser) {
            Test.startTest();
            boolean hasPermission = TimesheetController.checkPermissionUser();
            Test.stopTest();
            
            // Verify that the user does not have the permission
            System.assertEquals(false, hasPermission, 'Engineer user should not have the permission set.');
        }
    }

    private static testMethod void testGetActiveUser01(){
        Test.startTest();
        List<User> userList = TimesheetController.getActiveUser();
        Test.stopTest();
    }

    private static testMethod void testGetHolidays01(){
        System.runAs(enrUser){
            Test.startTest();
            List<Holiday> holidayList = TimesheetController.getHolidays( String.valueOf(System.Today().year()),'01');
            Test.stopTest();
        }
    }

    private static testMethod void testGetHolidays02(){
        System.runAs(enrUser){
            Test.startTest();
            List<Holiday> holidayList = TimesheetController.getHolidays( String.valueOf(System.Today().year()),'99');
            Test.stopTest();
            Assert.areEqual(new List<Holiday>(), holidayList);
        }
    }

    private static testMethod void testGetLeaveRequestes01(){
        System.runAs(enrUser){
            Test.startTest();
            List<ApplicationItem__c> applicationItems = TimesheetController.getLeaveRequestes( enrUser.Id, String.valueOf(System.Today().year()), '01' );
            Test.stopTest();
        }
    }

    private static testMethod void testGetLeaveRequestes02(){
        System.runAs(enrUser){
            Test.startTest();
            List<ApplicationItem__c> applicationItems = TimesheetController.getLeaveRequestes( enrUser.Id, String.valueOf(System.Today().year()), '99' );
            Test.stopTest();
            Assert.areEqual(new List<ApplicationItem__c>(), applicationItems);
        }
    }

    private static testMethod void testGetTimeStamps01(){
        System.runAs(enrUser){
            Test.startTest();
            List<Timestamp__c> stampedList = TimesheetController.getTimeStamps( enrUser.Id, String.valueOf(System.Today().year()), '01' );
            Test.stopTest();
        }
    }

    private static testMethod void testGetTimeStamps02(){
        System.runAs(enrUser){
            Test.startTest();
            List<Timestamp__c> stampedList = TimesheetController.getTimeStamps( enrUser.Id, String.valueOf(System.Today().year()), '99' );
            Test.stopTest();
            Assert.areEqual(new List<Timestamp__c>(), stampedList);
        }
    }

    private static testMethod void testCreateTimeStamps01(){
        System.runAs(enrUser){
            Test.startTest();
            String msg = TimesheetController.createTimeStamps(String.valueOf(System.Today()), '08:25', '17:40', 'remark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testCreateTimeStamps02(){
        System.runAs(enrUser){
            Test.startTest();
            String msg = TimesheetController.createTimeStamps(String.valueOf(System.Today()), null, '17:40', 'remark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testCreateTimeStamps03(){
        System.runAs(enrUser){
            Test.startTest();
            String msg = TimesheetController.createTimeStamps(String.valueOf(System.Today()), '08:25', null, 'remark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testCreateTimeStamps04(){
        System.runAs(enrUser){
            Test.startTest();
            String msg = TimesheetController.createTimeStamps(String.valueOf(System.Today()), null, null, 'remark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testCreateTimeStamps05(){
        System.runAs(enrUser){
            Test.startTest();
            String msg = TimesheetController.createTimeStamps(String.valueOf(System.Today()), '08', null, 'remark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testUpdateTimeStamps01(){
        System.runAs(enrUser){
            Date dateStamp = Date.newInstance(2023, 8, 30);
            Timestamp__c timestamp = [SELECT Id, Name FROM Timestamp__c WHERE OwnerId =:enrUser.Id AND Stamped_Date__c =:dateStamp];
            Test.startTest();
            String msg = TimesheetController.updateTimeStamps(timestamp.Name, TRUE, FALSE, '8:25', null, 'testRemark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testUpdateTimeStamps02(){
        System.runAs(enrUser){
            Date dateStamp = Date.newInstance(2023, 8, 30);
            Timestamp__c timestamp = [SELECT Id, Name FROM Timestamp__c WHERE OwnerId =:enrUser.Id AND Stamped_Date__c =:dateStamp];
            Test.startTest();
            String msg = TimesheetController.updateTimeStamps(timestamp.Name, FALSE, TRUE, null, '17:45', 'testRemark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testUpdateTimeStamps03(){
        System.runAs(enrUser){
            Date dateStamp = Date.newInstance(2023, 8, 30);
            Timestamp__c timestamp = [SELECT Id, Name FROM Timestamp__c WHERE OwnerId =:enrUser.Id AND Stamped_Date__c =:dateStamp];
            Test.startTest();
            String msg = TimesheetController.updateTimeStamps(timestamp.Name, FALSE, FALSE, null, null, 'Test Remark', '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testUpdateTimeStamps04(){
        System.runAs(enrUser){
            Date dateStamp = Date.newInstance(2023, 8, 30);
            Timestamp__c timestamp = [SELECT Id, Name FROM Timestamp__c WHERE OwnerId =:enrUser.Id AND Stamped_Date__c =:dateStamp];
            Test.startTest();
            String msg = TimesheetController.updateTimeStamps(timestamp.Name, FALSE, FALSE, null, null, null, '', '', '');
            Test.stopTest();
        }
    }

    private static testMethod void testUpdateTimeStamps05(){
        System.runAs(enrUser){
            Test.startTest();
            String msg = TimesheetController.updateTimeStamps(null, TRUE, TRUE, '08:25', '17:45', 'testRemark', '', '', '');
            Test.stopTest();
        }
    }

}