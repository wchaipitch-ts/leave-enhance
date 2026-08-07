@isTest
public class CalendarControllerTest {


	static testmethod void test_init() {
		PageReference pr = Page.Calendar;
		Test.setCurrentPage(pr);
		Test.startTest();
		CalendarController controller = new CalendarController();
		PageReference result = controller.init();
		Assert.areEqual(result, null);
		Assert.areEqual(controller.getHasAccessToken(), false);
		Assert.areNotEqual(controller.getUserTimezone(), null);

		controller.startAuthorize();
		Assert.isTrue(controller.authUrl.contains('/services/oauth2/authorize'));

		Test.stopTest();
	}

	static testmethod void test_collectEvents(){
		CalendarConnection__c setting = new CalendarConnection__c();
		setting.user_id__c = UserInfo.getUserId();
		setting.setUpOwnerId = UserInfo.getUserId();
		insert setting;


		PageReference pr = Page.Calendar;
		Test.setCurrentPage(pr);
		Test.setMock(HttpCalloutMock.class, new EventRetrieveCalloutMock());
		Test.startTest();

		CalendarController controller = new CalendarController();
		controller.init();
		controller.collectEvents();
		System.assertEquals(20, controller.records.size());

		controller.doSync();
		Test.stopTest();

		List<Event> events = [SELECT Id FROM Event];
		System.assertEquals(20, events.size());
	}

	static testmethod void test_Event2(){
		List<Event> events = [SELECT Id,Subject,StartDatetime,EndDatetime
									,Location,IsAllDayEvent,Description,UpsertKey__c
								FROM Event];
		CalendarController.Event2 ev2 = new CalendarController.Event2(events[0]);
		Assert.areEqual(ev2.getIsNew(), false);
		Assert.areEqual(ev2.getMyOriginal(), true);
		Assert.areEqual(ev2.getIsUpdated(), false);
		ev2.getBorderStyle();
	}

	@TestSetup
	static void makeData(){
		List<Event> events = new List<Event>();
		for(Integer i=1;i<=10;i++){
			events.add(new Event(
								subject = 'TEST EVENT' + String.valueOf(i)
								, startDatetime = System.now().addHours(24)
								, endDatetime = System.now().addHours(25)
								, location = 'LOCATION'
								, IsAllDayEvent = false
					));
		}	
		insert events;
	}

	//Eventを接続先組織から取得するAPI結果Mock
	public class EventRetrieveCalloutMock implements HttpCalloutMock {
		public HTTPResponse respond(HTTPRequest request) {
			StaticResource sr = [SELECT Id, Body FROM StaticResource 
									WHERE Name = 'QUERY_RESULT_EVENT' LIMIT 1];
			String body = sr.Body.toString();

			HttpResponse response = new HttpResponse();
			response.setHeader('Content-Type', 'application/json');
			response.setBody(body);
			response.setStatusCode(200);
			return response; 
		}
	}

}