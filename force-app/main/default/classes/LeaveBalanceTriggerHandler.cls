/*
 * LEAVE-51 — the one place a Leave_Balance__c save recalculates its derived figures.
 *
 * Thin on purpose. The rule lives in LeaveAccrualService so it can be unit tested
 * without saving a record, which was the whole reason for moving it out of the
 * Accrued_Days__c formula; this class only decides when it runs.
 */
public with sharing class LeaveBalanceTriggerHandler {

    /*
     * Recursion is not guarded and does not need to be. This runs in the BEFORE context
     * and performs no DML, so it cannot re-enter itself. Running it a second time on a
     * row that another trigger re-saved is harmless anyway: the calculation is a pure
     * function of the row and the date, so it lands on the same answer.
     *
     * Every row is recalculated rather than only those whose inputs changed. Checking
     * would cost more than the arithmetic, and the accrual moves with the CALENDAR as
     * well as with the record — a row saved on 31 March earns a day that no field
     * comparison against Trigger.oldMap would have noticed.
     */
    public static void recalculateAccruals(List<Leave_Balance__c> balances) {
        LeaveAccrualService.recalculate(balances, LeaveAccrualService.asOfDate());
    }
}
