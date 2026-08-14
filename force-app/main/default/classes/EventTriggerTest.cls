@isTest
private class EventTriggerTest {
    @TestSetup
    static void createTestData(){
        User user = new User(
                    ProfileId = [SELECT Id FROM Profile WHERE Name = 'EngineerGroupMember'].Id,
                    LastName = 'last',
                    Email = 'testuser@terrasky.co.th',
                    Username = 'testuser@terrasky.co.th' + System.currentTimeMillis(),
                    CompanyName = 'TEST',
                    Title = 'title',
                    Alias = 'alias',
                    TimeZoneSidKey = 'Asia/Bangkok',
                    EmailEncodingKey = 'UTF-8',
                    LanguageLocaleKey = 'th',
                    LocaleSidKey = 'th',
                    // LEAVE-30: Accrued_Days__c is zero without a joining date, which
                    // would turn the approved request below into unpaid days and fail
                    // the setup before any event assertion runs.
                    Start_Date__c = Date.newInstance(2020, 1, 1)
                );
        insert user;

        /*
         * LEAVE-25: the approved request below deducts from Leave_Balance__c, and a
         * missing balance row is now a hard error rather than a silent approval.
         *
         * LEAVE-30: Upfront rather than Monthly. Accrued_Days__c is a formula over
         * TODAY(), so a Monthly row holds nothing at all in January — and a request
         * with no balance behind it is now held back for the Managing Director,
         * which would fail this test for one month of every twelve.
         */
        insert new Leave_Balance__c(
            Employee__c         = user.Id,
            Leave_Type__c       = 'Annual leave',
            Leave_Year__c       = System.today().year(),
            External_Key__c     = user.Id + '-Annual leave-' + System.today().year(),
            Entitlement_Days__c = 12,
            Accrual_Method__c   = 'Upfront',
            Carry_Over_Days__c  = 0,
            Used_Days__c        = 0,
            Pending_Days__c     = 0,
            Status__c           = 'Active'
        );

        ApplicationItem__c appItem = new ApplicationItem__c(
            Request_Type__c = 'Annual leave',
            Period_Leave__c = 'All day',
            Term_From__c = system.today(),
            Remark__c = 'Test All day',
            Status__c = 'Approved',
            OwnerId = user.Id
        );
        insert appItem; 
        System.debug('appItem : ' + appItem);
        ApplicationItem__c appItemToUpdate = [SELECT Id, Status__c FROM ApplicationItem__c WHERE Id =: appItem.Id LIMIT 1];
        appItemToUpdate.Status__c = 'Approved';
        System.debug('appItemToUpdate : ' + appItemToUpdate);        
        // start date and time 
        Datetime strDateTime =  ( 'PM leave'==appItem.Period_Leave__c 
                                ? DateTime.newInstance(appItem.Term_From__c.year(), appItem.Term_From__c.month(),appItem.Term_From__c.day() , 13, 0, 0)
                                : DateTime.newInstance(appItem.Term_From__c.year(), appItem.Term_From__c.month(),appItem.Term_From__c.day() , 8, 30, 0)
                            );
        // end date and time 
        Datetime endDateTime =  ( 'AM leave'==appItem.Period_Leave__c 
                                ? DateTime.newInstance(appItem.Term_From__c.year(), appItem.Term_From__c.month(),appItem.Term_From__c.day() , 12, 0, 0)
                                : DateTime.newInstance(appItem.Term_From__c.year(), appItem.Term_From__c.month(),appItem.Term_From__c.day() , 17, 0, 0)
                            );                
        // set even for block calendar
        Event event = new Event();
        event.WhatId = appItem.ID;
        event.Subject = appItem.Request_Type__c;
        event.OwnerId = appItem.OwnerId;
        event.StartDateTime = strDateTime;
        event.EndDateTime = endDateTime;
        event.Description = appItem.Period_Leave__c;
        
        insert event;
    }

    @IsTest
    static void eventEditByManagerTest(){        
        ApplicationItem__c appItem = [SELECT Id, CreatedById FROM ApplicationItem__c LIMIT 1];
        User user = [SELECT Id FROM User WHERE Id =: appItem.CreatedById LIMIT 1];
        Event event = [SELECT Id FROM Event WHERE WhatId =: appItem.Id LIMIT 1];        
        event.Description = 'Test edit event';
        Test.startTest();                      
            System.runAs(user) {
                update event;
            }
        Test.stopTest();
        Event eventAfterUpdate = [SELECT Id, Description FROM Event WHERE Id =: event.Id];
        System.assertEquals(event.Description, eventAfterUpdate.Description);
    }

    @IsTest
    static void eventEditByUserTest(){        
        ApplicationItem__c appItem = [SELECT Id, OwnerId FROM ApplicationItem__c LIMIT 1];
        User user = [SELECT Id FROM User WHERE Id =: appItem.OwnerId LIMIT 1];
        Event event = [SELECT Id FROM Event WHERE WhatId =: appItem.Id LIMIT 1];
        event.Description = 'Test edit event';
        
        Boolean isError = false;
        Test.startTest();
            try {                
                System.runAs(user) {
                    delete event;
                }
            } catch(Exception e) {
                isError = true;
            }
        Test.stopTest();
        System.assertEquals(true, isError);   
    }

    @IsTest
    static void eventDeleteByManagerTest(){        
        ApplicationItem__c appItem = [SELECT Id, CreatedById FROM ApplicationItem__c LIMIT 1];
        User user = [SELECT Id FROM User WHERE Id =: appItem.CreatedById LIMIT 1];
        Event event = [SELECT Id FROM Event WHERE WhatId =: appItem.Id LIMIT 1];
        Test.startTest();
        System.runAs(user) {
            delete event;
        }
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM Event WHERE Id = :event.id], 'event should be deleted');
    }

    @IsTest
    static void eventDeleteByUserTest(){        
        ApplicationItem__c appItem = [SELECT Id, OwnerId FROM ApplicationItem__c LIMIT 1];
        User user = [SELECT Id FROM User WHERE Id =: appItem.OwnerId LIMIT 1];
        Event event = [SELECT Id FROM Event WHERE WhatId =: appItem.Id LIMIT 1];
        
        Boolean isError = false;
        Test.startTest();
            try {                
                System.runAs(user) {
                    delete event;
                }
            } catch(Exception e) {
                isError = true;
            }
        Test.stopTest();
        System.assertEquals(true, isError);                             
    }
    
}