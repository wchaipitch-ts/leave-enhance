trigger ApplicationItemTrigger on ApplicationItem__c (before insert, before update, after insert, after update, after delete) {
    ApplicationItemTriggerHandler handler = new ApplicationItemTriggerHandler();
    if (Trigger.isAfter && Trigger.isUpdate) {
        handler.onAfterUpdate(Trigger.new);
    }
}