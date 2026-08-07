public class ApplicationItemTriggerLogic {

    public void setLeaveDateTime(List<ApplicationItem__c> newList){
        for(ApplicationItem__c appl : newList){
            if(appl.Status__c == 'Approved'){
                // start date and time 
                Datetime strDateTime =  ( 'PM leave'==appl.Period_Leave__c 
                                        ? DateTime.newInstance(appl.Term_From__c.year(), appl.Term_From__c.month(),appl.Term_From__c.day() , 13, 0, 0)
                                        : DateTime.newInstance(appl.Term_From__c.year(), appl.Term_From__c.month(),appl.Term_From__c.day() , 8, 30, 0)
                                    );
                // end date and time 
                Datetime endDateTime =  ( 'AM leave'==appl.Period_Leave__c 
                                        ? DateTime.newInstance(appl.Term_From__c.year(), appl.Term_From__c.month(),appl.Term_From__c.day() , 12, 0, 0)
                                        : DateTime.newInstance(appl.Term_From__c.year(), appl.Term_From__c.month(),appl.Term_From__c.day() , 17, 0, 0)
                                    );                
                // set even for block calendar
                Event event = new Event();
                event.WhatId = appl.ID;
                event.Subject = appl.Request_Type__c;
                event.OwnerId = appl.OwnerId;
                event.StartDateTime = strDateTime;
                event.EndDateTime = endDateTime;
                event.Description = appl.Period_Leave__c;
                
                insert event;
            }
        }
    }
    
}