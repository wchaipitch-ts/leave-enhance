@isTest
public class ConnectGatewayTest {

	static testMethod void test_RetrieveToken(){
		PageReference pr = Page.Callbackpoint;
		pr.getParameters().put('state','/hoge?uid=' + UserInfo.getUserId());
		Test.setCurrentPage(pr);
		Test.setMock(HttpCalloutMock.class, new TokenCalloutMock());
		Test.startTest();
		ConnectGateway controller = new ConnectGateway();
		PageReference result = controller.retrieveToken();
		Assert.areNotEqual(result, null);
		Test.stopTest();
	}

	static testMethod void test_for_Exception(){
		try{
			Decimal d1 = 100;
			Decimal d2 = 0;
			Decimal d = d1/d2;
			Assert.fail();
		}catch(Exception e){
			String s = CalendarConnectException.getConcatErrorMessage(e);
			Assert.isTrue(s.contains('@@@'));
		}

		TokenCalloutMock mock = new TokenCalloutMock();
		HttpResponse res = mock.respond(new HttpRequest());
		String msg = CalendarConnectException.getConcatErrorMessage('https://endpoint.url', res);
		Assert.isTrue(msg.contains('StatusCode:200'));

		try{
			Decimal d1 = 100;
			Decimal d2 = 0;
			Decimal d = d1/d2;
			Assert.fail();
		}catch(Exception e){
			msg = CalendarConnectException.getConcatErrorMessage(e, null);
			Assert.isTrue(msg.contains('@@@'));

			msg = CalendarConnectException.getConcatErrorMessage(e, res);
			Assert.isTrue(msg.contains('Body:'));
		}
	}

	//token結果Mock
	public class TokenCalloutMock implements HttpCalloutMock {
		public HTTPResponse respond(HTTPRequest request) {
			HttpResponse response = new HttpResponse();
			response.setHeader('Content-Type', 'application/json');
			response.setBody(TOKEN_RESPONSE);
			response.setStatusCode(200);
			return response; 
		}
	}

	private static final String TOKEN_RESPONSE = '{'
		+ 	'"access_token":"00Dd0000000d2Iy!AQgAQLwpOxN4DhZO2qB8PCbD8VU1T35znzeDeCm....",'
		+ '"instance_url":"https://instance_name.my.salesforce.com",'
		+ '"id":"https://login.salesforce.com/id/00Dd000000XXXXXXX/005d000000XXXXX",'
		+ '"token_type":"Bearer",'
		+ '"issued_at":"1486507938095",'
		+ '"signature":"uEY/R99P/uqgq0GYNQKcvKc9LqICOMf91NvwI2my4eI="'
		+ '}';



}