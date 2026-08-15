trigger ApplicationItemTrigger on ApplicationItem__c (before insert, before update, before delete, after insert, after update, after delete) {
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

    // LEAVE-34: after delete was declared from the start but never routed, so deleting
    // an approved request left its balance spent and its bookings orphaned. Before
    // delete is needed too, to note the Man_hour__c rows while their lookup still holds.
    if (Trigger.isBefore && Trigger.isDelete) {
        handler.onBeforeDelete(Trigger.old);
    }
    if (Trigger.isAfter && Trigger.isDelete) {
        handler.onAfterDelete(Trigger.old);
    }
}