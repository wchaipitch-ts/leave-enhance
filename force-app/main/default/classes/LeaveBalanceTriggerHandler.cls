public with sharing class LeaveBalanceTriggerHandler {

    public static void recalculateAccruals(List<Leave_Balance__c> balances) {
        LeaveAccrualService.recalculate(balances, LeaveAccrualService.asOfDate());
    }
}