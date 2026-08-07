public class EventTriggerLogic {

    // check applicationItem record when status is apporved
    public void checkApplicationItemPreventEditCalendar(List<Event> eventList, String acction){
        Event event = eventList[0];
        if(event.WhatId!=null 
				&& Schema.ApplicationItem__c.SObjectType==event.WhatId.getSobjectType()){            
            List<ApplicationItem__c> applicationItems = [SELECT Id, Status__c FROM ApplicationItem__c WHERE Id =: event.WhatId LIMIT 1];
            if(!applicationItems.isEmpty()){
                if( applicationItems[0]!=null && applicationItems[0].Status__c == 'Approved' && event.CreatedById != UserInfo.getUserId() ){
                    // add error massage 
                    event.addError('Cannot '+acction+', Please contact your manager.');
                }
            }
        }
    }
}