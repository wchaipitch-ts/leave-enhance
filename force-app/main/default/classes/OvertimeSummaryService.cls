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
        Id target = LeaveBalanceService.assertCanView(employeeId);

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