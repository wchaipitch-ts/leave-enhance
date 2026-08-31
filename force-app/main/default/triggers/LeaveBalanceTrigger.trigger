trigger LeaveBalanceTrigger on Leave_Balance__c (before insert, before update) {
    if (Trigger.isBefore && (Trigger.isInsert || Trigger.isUpdate)) {
        LeaveBalanceTriggerHandler.recalculateAccruals(Trigger.new);
    }
}