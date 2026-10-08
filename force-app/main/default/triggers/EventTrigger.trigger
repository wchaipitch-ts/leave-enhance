trigger EventTrigger on Event (before insert, before update, before delete, after insert, after update, after delete) {
    EventTriggerHandler handler = new EventTriggerHandler();
    if (Trigger.isBefore) {
        if(Trigger.isUpdate){
            handler.onBeforeUpdate(Trigger.new);
        }else if(Trigger.isDelete){
            handler.onBeforeDelete(Trigger.Old);
        }
    }
    if (Trigger.isAfter && Trigger.isInsert) {
        handler.onAfterInsert(Trigger.new);
    }
}