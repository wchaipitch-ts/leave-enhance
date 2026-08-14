/*
 * LEAVE-31 — approved overtime hours for a person in a month.
 *
 * Deliberately its own class rather than another method on TimesheetController: that
 * file is being reworked for the multi-day timesheet rendering, and a new class means
 * the two pieces of work never touch the same lines.
 *
 * Only Approved requests count. A Draft or Pending claim is a proposal, and a Rejected
 * one is a refusal; neither is hours anybody owes.
 *
 * Computed from the requests themselves rather than from the Man_hour__c records they
 * produce. Man_hour__c is shared with leave and with ordinary project work, so summing
 * it would mean trusting a project-name convention to tell overtime apart. The requests
 * are the record of what was approved, so they are what gets counted.
 */
public with sharing class OvertimeSummaryService {

    /*
     * A request cannot be expanded further back than a year, so this bounds the query
     * without risking a range that started before the window and reaches into it.
     */
    private static final Integer MAX_LOOKBACK_DAYS = 366;

    /**
     * Total approved overtime hours falling inside the given month.
     *
     * @param employeeId whose overtime; null means the running user
     * @param year       four digit year
     * @param month      1-12
     */
    @AuraEnabled(cacheable=true)
    public static Decimal getApprovedOvertimeHours(Id employeeId, Integer year, Integer month) {
        if (year == null || month == null || month < 1 || month > 12) {
            throw new AuraHandledException('A four digit year and a month from 1 to 12 are required.');
        }
        Id target = employeeId == null ? UserInfo.getUserId() : employeeId;

        Date monthStart = Date.newInstance(year, month, 1);
        Date monthEnd = Date.newInstance(year, month, Date.daysInMonth(year, month));
        Date earliestStart = monthStart.addDays(-MAX_LOOKBACK_DAYS);

        Decimal total = 0;
        for (ApplicationItem__c appl : [
            SELECT Term_From__c, Term_To__c, OT_Start__c, OT_End__c
            FROM ApplicationItem__c
            WHERE RecordType.DeveloperName = 'Overtime_Request'
              AND Status__c = 'Approved'
              AND OwnerId = :target
              AND Term_From__c >= :earliestStart
              AND Term_From__c <= :monthEnd
        ]) {
            Decimal hoursPerDay = ApplicationItemTriggerLogic.overtimeHoursPerDay(appl);
            if (hoursPerDay <= 0) {
                continue;
            }
            /*
             * A request spanning a month boundary contributes only the dates that
             * actually fall in this month, so the same request counted in two
             * consecutive months adds up to itself rather than to double.
             */
            for (Date d : ApplicationItemTriggerLogic.overtimeDatesFor(appl)) {
                if (d >= monthStart && d <= monthEnd) {
                    total += hoursPerDay;
                }
            }
        }
        return total;
    }
}
