trigger ApplicationItemTrigger on ApplicationItem__c (before insert, before update, after insert, after update, after delete) {
    ApplicationItemTriggerHandler handler = new ApplicationItemTriggerHandler();

    // LEAVE-13: balance deduction runs before save, so the bucket split is written to
    // the in-flight record rather than requiring a second DML on the same object.
    if (Trigger.isBefore && Trigger.isInsert) {
        handler.onBeforeInsert(Trigger.new);
    }
    if (Trigger.isBefore && Trigger.isUpdate) {
        handler.onBeforeUpdate(Trigger.new, Trigger.oldMap);
    }

    // LEAVE-12: after insert was declared but never routed, so a record created
    // already Approved produced no calendar Event and no Man_hour__c record.
    if (Trigger.isAfter && Trigger.isInsert) {
        handler.onAfterInsert(Trigger.new);
    }
    if (Trigger.isAfter && Trigger.isUpdate) {
        handler.onAfterUpdate(Trigger.new, Trigger.oldMap);
    }
}