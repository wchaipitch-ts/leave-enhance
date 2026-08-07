public with sharing class HolidayListController {

    @AuraEnabled
    public static List<Holiday> getAllHoliday(String year){
        Date startYear = Date.valueOf(year + '-01-01');
        Date endYear = Date.valueOf(year+ '-12-31');

        List<Holiday> holidayList = [SELECT Id, Name, Description, ActivityDate 
                                    FROM Holiday 
                                    WHERE ActivityDate >= :startYear
                                      AND ActivityDate <= :endYear
                                    ORDER BY ActivityDate 
                                    ASC];
        return holidayList;
    }

    @AuraEnabled(cacheable=true)
    public static List<FiscalYearSettings> getFiscalYearOptions() {
        return [SELECT Name FROM FiscalYearSettings WHERE StartDate <= THIS_YEAR ORDER BY Name DESC LIMIT 5];
    }

}