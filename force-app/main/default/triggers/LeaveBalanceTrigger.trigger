/*
 * LEAVE-51 — keeps Accrued_To_Date__c and Available_Balance__c right on every save.
 *
 * Both used to be formulas, so nothing had to maintain them. Now that they are stored,
 * something must, and it has to be something no caller can forget: the approval
 * deduction, the reversal, the split, the conversion, the migration and the nightly
 * grant job all move Used_Days__c, Entitlement_Days__c or Carry_Over_Days__c, and so
 * does anybody editing the record page by hand.
 *
 * Before rather than after, so the recalculated figures ride along on the save already
 * in flight instead of costing a second DML on the same object.
 */
trigger LeaveBalanceTrigger on Leave_Balance__c (before insert, before update) {
    if (Trigger.isBefore && (Trigger.isInsert || Trigger.isUpdate)) {
        LeaveBalanceTriggerHandler.recalculateAccruals(Trigger.new);
    }
}
