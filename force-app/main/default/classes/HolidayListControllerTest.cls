@isTest
public class HolidayListControllerTest {
    @isTest(SeeAllData=false)
    static void testGetAllHoliday() {
        // Create test data
        List<Holiday> testHolidays = new List<Holiday>();
        for(Integer i = 1; i <= 5; i++) {
            Holiday h = new Holiday(
                Name = 'Test Holiday ' + i,
                Description = 'Test Description ' + i,
                ActivityDate = Date.today()+i
            );
            testHolidays.add(h);
        }
        insert testHolidays;

        // Call the method being tested
		String yearStr = DateTime.newInstance(date.today().year(),1,1).format('YYYY');
        List<Holiday> result = HolidayListController.getAllHoliday(yearStr);
        // Verify the results
        Map<Id, Holiday> holidayMap = new Map<Id, Holiday>(result);
        for(Holiday h : testHolidays){
            if(holidayMap.containsKey(h.Id)){
                assert.areEqual(h.Name, holidayMap.get(h.Id).Name, 'Holiday name have to match');
                assert.areEqual(h.Description, holidayMap.get(h.Id).Description, 'Holiday Description have to match');
            }
        }
    }

    @isTest
    static void testGetFiscalYearOptions() {
        // Call the method to be tested
        List<FiscalYearSettings> result = HolidayListController.getFiscalYearOptions();
    
        // Perform assertions
        System.assertEquals(5, result.size(), 'Number of fiscal years should match');
    }
}