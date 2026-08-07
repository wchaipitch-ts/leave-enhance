@isTest
public with sharing class LeaveManagementControllerTest {
    
    @testSetup
    static void setupTestData() {
        List<User> users = new List<User>();
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        
        // --- NORMAL CASES ---
        // 1. 6 Months Tenure -> Expect 3 Days
        users.add(createTestUser(p.Id, 'User6Month', System.today().addMonths(-6)));
        
        // 2. 1 Year Tenure -> Expect 6 Days
        users.add(createTestUser(p.Id, 'User1Year', System.today().addMonths(-12)));
        
        // 3. 3 Years Tenure -> Expect 8 Days
        users.add(createTestUser(p.Id, 'User3Year', System.today().addMonths(-36)));
        
        // 4. 6 Years Tenure -> Expect 10 Days
        users.add(createTestUser(p.Id, 'User6Year', System.today().addMonths(-72)));
        
        // --- NEGATIVE CASES ---
        // 5. 5 Months Tenure (Too early) -> Expect 0 Days (No change)
        users.add(createTestUser(p.Id, 'User5Month', System.today().addMonths(-5)));
        
        // 6. 8 Months Tenure (Between milestones) -> Expect 0 Days (No change)
        // Note: They got their 3 days at month 6. At month 8, nothing should happen.
        users.add(createTestUser(p.Id, 'User8Month', System.today().addMonths(-8)));
        
        // --- EDGE CASES ---
        // 7. Carry Over: Exact 6 days balance -> Expect 6 carried + New Entitlement
        User userExactCarry = createTestUser(p.Id, 'UserExactCarry', System.today().addMonths(-12));
        userExactCarry.Annual_Leave_Day__c = 6;
        users.add(userExactCarry);
        
        // 8. Carry Over: 5.5 days balance -> Expect 5.5 carried + New Entitlement
        User userUnderCarry = createTestUser(p.Id, 'UserUnderCarry', System.today().addMonths(-12));
        userUnderCarry.Annual_Leave_Day__c = 5.5;
        users.add(userUnderCarry);
        
        // 9. Carry Over: 10 days balance -> Expect 6 carried + New Entitlement
        User userOverCarry = createTestUser(p.Id, 'UserOverCarry', System.today().addMonths(-12));
        userOverCarry.Annual_Leave_Day__c = 10;
        users.add(userOverCarry);
        
        // 10. Mid-Month Start (Month Only Rule)
        // Started 15th of month, 12 months ago. Should trigger on 1st of month.
        users.add(createTestUser(p.Id, 'UserMidMonth', System.today().addMonths(-12).addDays(15))); 

        insert users;
    }
    
    private static User createTestUser(Id profileId, String lastName, Date startDate) {
        String uniqueName = lastName + DateTime.now().getTime();
        return new User(
            FirstName = 'Test',
            LastName = lastName,
            Email = uniqueName + '@example.com',
            Username = uniqueName + '@example.com',
            Alias = lastName.left(8),
            CommunityNickname = lastName.left(8),
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = profileId,
            LanguageLocaleKey = 'en_US',
            Start_Date__c = startDate,
            /*
             * 2025/12/15 fix:
             * Implementation Update:
             * Initialize 'Annual_Leave_Allocated__c' instead of 'Annual_Leave_Day__c'.
             */
            /*
             * 2025/12/15 fix:
             * Implementation Update:
             * Initialize 'Annual_Leave_Allocated__c' instead of 'Annual_Leave_Day__c'.
             * Also initialize 'Annual_Leave_Day__c' to 0 to ensure sync assertions pass for negative cases.
             */
            Annual_Leave_Allocated__c = 0,
            Annual_Leave_Day__c = 0
        );
    }

    @IsTest
    static void testAnniversaryMode_Comprehensive() {
        LeaveManagementController.testMode = 'Anniversary';
        
        Test.startTest();
        LeaveManagementController.adjustAnnualLeaveDay();
        Test.stopTest();
        
        // --- NORMAL CASES ---
        System.assertEquals(3, getUserLeave('User6Month'), '6 Month User should get 3 days');
        System.assertEquals(6, getUserLeave('User1Year'), '1 Year User should get 6 days');
        System.assertEquals(8, getUserLeave('User3Year'), '3 Year User should get 8 days');
        System.assertEquals(10, getUserLeave('User6Year'), '6 Year User should get 10 days');
        
        // --- NEGATIVE CASES ---
        System.assertEquals(0, getUserLeave('User5Month'), '5 Month User should get 0 days');
        System.assertEquals(0, getUserLeave('User8Month'), '8 Month User should get 0 days (no grant due)');
        
        // --- EDGE CASES (Carry Over) ---
        // UserExactCarry: 6 (Old) + 6 (New) = 12
        System.assertEquals(12, getUserLeave('UserExactCarry'), 'Exact 6 days should carry over fully');
        
        // UserUnderCarry: 5.5 (Old) + 6 (New) = 11.5
        System.assertEquals(11.5, getUserLeave('UserUnderCarry'), '5.5 days should carry over fully');
        
        // UserOverCarry: 10 (Old) -> Cap 6 + 6 (New) = 12
        System.assertEquals(12, getUserLeave('UserOverCarry'), '10 days should be capped at 6 before adding new');
        
        // --- EDGE CASES (Dates) ---
        // UserMidMonth: 12 months ago + 15 days. Normalized to 1st. Should be exactly 12 months diff.
        System.assertEquals(6, getUserLeave('UserMidMonth'), 'Mid Month User should get 6 days due to normalization');
        
        // --- LOGGING VERIFICATION ---
        List<Error_Log__c> logs = [SELECT Id, Process_Type__c FROM Error_Log__c];
        System.assertEquals(1, logs.size(), 'Should create exactly one Error Log header');
        System.assertEquals('Annual Leave Calculation', logs[0].Process_Type__c);
        
        List<ContentVersion> files = [SELECT Id, FirstPublishLocationId FROM ContentVersion WHERE FirstPublishLocationId = :logs[0].Id];
        System.assertEquals(1, files.size(), 'Should create one Log File attachment linked to the Error Log');
    }
    
    @IsTest
    static void testCalendarYearMode() {
        LeaveManagementController.testMode = 'CalendarYear';
        
        Test.startTest();
        LeaveManagementController.adjustAnnualLeaveDay();
        Test.stopTest();
        
        // In Calendar Year mode, everyone gets updated based on tenure as of Today
        System.assertEquals(3, getUserLeave('User6Month'));
        System.assertEquals(6, getUserLeave('User1Year'));
        System.assertEquals(0, getUserLeave('User5Month')); // Still < 6 months
        
        // --- LOGGING VERIFICATION ---
        List<Error_Log__c> logs = [SELECT Id, Process_Type__c FROM Error_Log__c];
        System.assertEquals(1, logs.size(), 'Should create exactly one Error Log header');
        System.assertEquals('Annual Leave Calculation', logs[0].Process_Type__c);
        
        List<ContentVersion> files = [SELECT Id, FirstPublishLocationId FROM ContentVersion WHERE FirstPublishLocationId = :logs[0].Id];
        System.assertEquals(1, files.size(), 'Should create one Log File attachment linked to the Error Log');
    }
    
    private static Decimal getUserLeave(String lastName) {
        User u = [SELECT Annual_Leave_Allocated__c, Annual_Leave_Day__c FROM User WHERE LastName = :lastName LIMIT 1];
        System.debug('User: ' + lastName + ' | Allocated: ' + u.Annual_Leave_Allocated__c + ' | Day: ' + u.Annual_Leave_Day__c);
        // Verify Sync (Implicit Assertion)
        System.assertEquals(u.Annual_Leave_Allocated__c, u.Annual_Leave_Day__c, 'Annual_Leave_Day__c should match Annual_Leave_Allocated__c');
        return u.Annual_Leave_Allocated__c;
    }
}