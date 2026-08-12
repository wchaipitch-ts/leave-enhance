@isTest
private class ApplicationItemTriggerTest {
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
                    LocaleSidKey = 'th'
                );
        insert user;
        // User user = [SELECT Id, ManagerId FROM User WHERE Profile.name = 'EngineerGroupMember' LIMIT 1];

        List<ApplicationItem__c> leaveRequestList = new List<ApplicationItem__c>();
        // All day request
        leaveRequestList.add(new ApplicationItem__c(
                            Request_Type__c = 'Annual leave',
                            Period_Leave__c = 'All day',
                            Term_From__c = system.today(),
                            Remark__c = 'Test All day',
                            Status__c = 'Pending',
                            OwnerId = user.Id
                        ));
        // AM leave request
        leaveRequestList.add(new ApplicationItem__c(
                            Request_Type__c = 'Annual leave',
                            Period_Leave__c = 'AM leave',
                            Term_From__c = system.today(),
                            Remark__c = 'Test AM leave',
                            Status__c = 'Pending',
                            OwnerId = user.Id
                        ));
        // PM leave request
        leaveRequestList.add(new ApplicationItem__c(
                            Request_Type__c = 'Annual leave',
                            Period_Leave__c = 'PM leave',
                            Term_From__c = system.today(),
                            Remark__c = 'Test',
                            Status__c = 'Pending',
                            OwnerId = user.Id
                        ));        
        insert leaveRequestList;
    }

    @IsTest
    private static void leaveRequestIsApprovedTest() {
        List<Id> leaveRequestIds = new List<Id>();
        List<ApplicationItem__c> leaveRequestList = [SELECT Id, Status__c FROM ApplicationItem__c];
        // approve request
        for(ApplicationItem__c leaveRequest : leaveRequestList){
            leaveRequestIds.add(leaveRequest.Id);
            leaveRequest.Status__c = 'Approved';
        }
        Test.startTest();
        update leaveRequestList;
        Test.stopTest();
        Map<Id, ApplicationItem__c> leaveRequestMap = new Map<Id, ApplicationItem__c>();
        for(ApplicationItem__c leaveRequest : [SELECT Id, Request_Type__c, Period_Leave__c, Status__c, OwnerId FROM ApplicationItem__c WHERE Id IN : leaveRequestIds]){
            leaveRequestMap.put(leaveRequest.Id, leaveRequest);
            System.assertEquals('Approved', leaveRequest.Status__c,'Status should match');
        }
        List<Event> eventList = [SELECT Id, Subject, OwnerId, StartDateTime, EndDateTime, Description, WhatId
                                FROM Event
                                WHERE WhatId IN :leaveRequestIds];
        System.assertEquals(leaveRequestIds.size(), eventList.size());
        DateTime todaysDate = System.today();
        String todaysDateStr = todaysDate.format('yyyy/M/dd');

        for(Event ev : eventList){
            ApplicationItem__c appItem = leaveRequestMap.get(ev.WhatId);
            System.assertEquals(ev.Subject, appItem.Request_Type__c);
            System.assertEquals(ev.OwnerId, appItem.OwnerId);
            System.assertEquals(ev.Description, appItem.Period_Leave__c);
            System.assertEquals(ev.WhatId, appItem.Id);
            if('PM leave' == appItem.Period_Leave__c){
                System.assertEquals(ev.StartDateTime.format('yyyy/M/dd HH:mm a'), todaysDateStr + ' 13:00 PM');
                System.assertEquals(ev.EndDateTime.format('yyyy/M/dd HH:mm a'), todaysDateStr + ' 17:00 PM');
            }else if('AM leave' == appItem.Period_Leave__c){
                System.assertEquals(ev.StartDateTime.format('yyyy/M/dd HH:mm a'), todaysDateStr + ' 08:30 AM');
                System.assertEquals(ev.EndDateTime.format('yyyy/M/dd HH:mm a'), todaysDateStr + ' 12:00 PM');
            }else{
                System.assertEquals(ev.StartDateTime.format('yyyy/M/dd HH:mm a'), todaysDateStr + ' 08:30 AM');
                System.assertEquals(ev.EndDateTime.format('yyyy/M/dd HH:mm a'), todaysDateStr + ' 17:00 PM');
            }
        }
    }

    // ------------------------------------------------------ LEAVE-11 / LEAVE-12

    /*
     * LEAVE-12. A record created already Approved used to produce nothing at all,
     * because the trigger declared after insert but never routed it.
     */
    @IsTest
    private static void recordInsertedAsApprovedIsProcessed() {
        User owner = [SELECT Id FROM User WHERE CompanyName = 'TEST' LIMIT 1];

        Test.startTest();
        ApplicationItem__c appl = new ApplicationItem__c(
            Request_Type__c = 'Annual leave',
            Period_Leave__c = 'All day',
            Term_From__c    = System.today(),
            Remark__c       = 'Created already approved',
            Status__c       = 'Approved',
            OwnerId         = owner.Id
        );
        insert appl;
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Event WHERE WhatId = :appl.Id],
            'inserting an approved record must create its calendar event');
        System.assertEquals(1, [SELECT COUNT() FROM Man_hour__c WHERE Performed_Date__c = :appl.Term_From__c],
            'inserting an approved record must create its man hour record');
    }

    /*
     * Editing an already-approved record used to re-run the whole path and create a
     * second Event and a second Man_hour__c. Only a transition INTO Approved counts.
     */
    @IsTest
    private static void editingAnApprovedRecordDoesNotDuplicate() {
        ApplicationItem__c appl = [SELECT Id, Status__c FROM ApplicationItem__c LIMIT 1];
        appl.Status__c = 'Approved';
        update appl;

        Integer eventsAfterApproval = [SELECT COUNT() FROM Event WHERE WhatId = :appl.Id];

        Test.startTest();
        appl.Remark__c = 'Edited after approval';
        update appl;
        Test.stopTest();

        System.assertEquals(1, eventsAfterApproval, 'approval creates exactly one event');
        System.assertEquals(eventsAfterApproval, [SELECT COUNT() FROM Event WHERE WhatId = :appl.Id],
            'editing an approved record must not create a second event');
    }

    /*
     * LEAVE-11. The old path inserted one Event per iteration and enqueued one
     * Queueable per record, so this volume broke both the DML statement limit and
     * the 50-job ceiling.
     */
    @IsTest
    private static void bulkApprovalStaysWithinGovernorLimits() {
        User owner = [SELECT Id FROM User WHERE CompanyName = 'TEST' LIMIT 1];
        List<ApplicationItem__c> batch = new List<ApplicationItem__c>();
        for (Integer i = 0; i < 200; i++) {
            batch.add(new ApplicationItem__c(
                Request_Type__c = 'Annual leave',
                Period_Leave__c = 'All day',
                Term_From__c    = System.today(),
                Remark__c       = 'Bulk ' + i,
                Status__c       = 'Pending',
                OwnerId         = owner.Id
            ));
        }
        insert batch;

        Set<Id> ids = new Map<Id, ApplicationItem__c>(batch).keySet();
        for (ApplicationItem__c appl : batch) {
            appl.Status__c = 'Approved';
        }

        Test.startTest();
        update batch;
        Test.stopTest();

        System.assertEquals(200, [SELECT COUNT() FROM Event WHERE WhatId IN :ids],
            'every approved record must get exactly one event');
    }
}