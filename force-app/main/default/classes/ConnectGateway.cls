public with sharing class ConnectGateway {
	public String pageMsg{get;set;}		//ページメッセージ
	//カスタムメタデータ
	public CalenderConnectConfig__mdt connectedApp{
		get{
			if(connectedApp==null){
				connectedApp = CalenderConnectConfig__mdt.getInstance('Org1');
			}
			return connectedApp;
		}
		set;
	}

	private String domainUrl = connectedApp.OAuthDomain__c;//'https://login.salesforce.com';
	//private static final String domainUrl = 'https://terraskyth.my.salesforce.com';
	private String oauthEndpoint = domainUrl + '/services/oauth2/authorize'; //接続先組織のURLに変更する必要あり
	private String tokenEndpoint = domainUrl + '/services/oauth2/token'; //接続先組織のURLに変更する必要あり
	private String clientId = connectedApp.clientId__c; //Connected Appで設定したClient ID
	private String clientSecret = connectedApp.clientSecret__c; //Connected Appで設定したClient Secret
	private String redirectUri = connectedApp.redirectUri__c; //Connected Appで設定したコールバックURL
	private String responseType = 'code';
	//private static final String state = UserInfo.getUserId();	//'some_state_parameter'; //任意の文字列を指定>　UserIdを渡す
	

	//AccessToken情報を格納しているカスタム設定
	public CalendarConnection__c connection{
		get{
			if(connection==null){
				connection = CalendarConnection__c.getValues(currentUserId);
				if(connection==null){
					connection = new CalendarConnection__c();
				}
			}
			return connection;
		}
		private set;
	}

	public Boolean hasAccessToken(){
		return this.connection?.access_token__c!=null;
	}

	//現在のUserId　Sitesで呼び出されたときはCallbackで受け取ったStateからUserIdを取得する
	private String currentUserId{
		get{
			if(currentUserId == null){
				currentUserId = UserInfo.getUserId();
			}
			return currentUserId;
		}
		set;
	}
//==================================================================================================================================	
	public ConnectGateway() {
		
    }

	//認証用ページに飛ばす(通常ログイン後のVFで呼び出されるメソッド)
	public pageReference authorize(){
		PageReference startPg = new Pagereference(URL.getOrgDomainUrl().toExternalForm()+'/apex/Calendar?uid=' + UserInfo.getUserId());

		Map<String,String> parameters = new Map<String,String>();
		parameters.put('response_type', responseType);
		parameters.put('client_id',clientId);
		parameters.put('redirect_uri',redirectUri);
		parameters.put('state',EncodingUtil.urlEncode(startPg.getUrl(),'UTF-8'));

		String authUrl = getRequestUrl(oauthEndpoint, parameters);

		PageReference authPage = new PageReference(authUrl);
		authPage.setRedirect(true);
		
		//SalesforceのOauthエンドポイントに遷移する
		return authPage;
	}

	private String getRequestUrl(String endpoint, Map<String,String> paramMap){
		List<String> params = new List<String>();
		for(String key:paramMap.keySet()){
			params.add(key + '=' + paramMap.get(key));
		}
		return endpoint + '?' + String.join(params, '&');
	}

	private Map<String,String> getTokenRequestParameters(Boolean isRefresh){
		Map<String,String> parameters = new Map<String,String>();
		parameters.put('client_id', clientId);
		parameters.put('client_secret', clientSecret);

		if(isRefresh){
			parameters.put('grant_type', 'refresh_token');
			parameters.put('refresh_token', this.connection.refresh_token__c);
		}else{
			parameters.put('redirect_uri', redirectUri);
			parameters.put('grant_type', 'authorization_code');
			String authCode = ApexPages.currentPage().getParameters().get('code'); //コールバックURLから認証コードを取得する
			parameters.put('code', authCode);
		}
		return parameters;
	}

	//認証後戻ってくるところ(Siteページで呼び出しされる)
	//  Code取り出し➡AccessToken取得(/oauth2/token)
	public Pagereference retrieveToken(){
		try{
			return retrieveToken(false);
		}catch(Exception e){
			this.pageMsg = CalendarConnectException.getConcatErrorMessage(e);
			return null;
		}
	}
	public Pagereference retrieveToken(Boolean isRefresh){
		String tokenUrl = getRequestUrl(tokenEndpoint, getTokenRequestParameters(isRefresh));
		Http http = new Http();
		HttpRequest request = new HttpRequest();
		request.setEndpoint(tokenUrl);
		request.setMethod('POST');
		
		HttpResponse response = http.send(request);
		String responseBody = response.getBody();
		if(response.getStatusCode()==200){
			//アクセストークンを取り出す
			AuthResult result = (AuthResult)JSON.deserialize(responseBody, AuthResult.class);

			this.connection.setUpOwnerId = this.currentUserId;
			this.connection.access_token__c = result.access_token;
			this.connection.instance_url__c = result.instance_url;
			this.connection.refresh_token__c = result.refresh_token;
			this.connection.token_type__c = result.token_type;
			this.connection.user_id__c = result.getUserId();
			if(isRefresh){
				//DMLはqueryの後に実施する
			}else{
				//URLからリクエストしたユーザIdを取り出す
				String stateStrings = ApexPages.currentPage().getParameters().get('state');
				PageReference startPage = new Pagereference(EncodingUtil.urlDecode(stateStrings,'UTF-8'));
				this.currentUserId = startPage.getParameters().get('uid');

				this.connection.setUpOwnerId = this.currentUserId;
				upsert this.connection;
				// Calendarページに遷移する
				return startPage;
			}
			return null;
		}else{
			throw new CalendarConnectException(
				CalendarConnectException.getConcatErrorMessage(tokenEndpoint, response)
			);
		}
	}


	private static final String QUERY_ENDPOINT = '/services/data/v56.0/query/?q=';
	private Boolean retried = false;
	public List<Object> query(String soql){
		String soql_for_rest = soql.replace(' ','+');
		String url = this.connection.instance_url__c;
		url += QUERY_ENDPOINT;
		url += soql_for_rest;

		Http http = new Http();
		HttpRequest request = new HttpRequest();
		HttpResponse response;
		try{
			request.setEndpoint(url);
			request.setMethod('GET');
			request.setHeader('Authorization', connection.token_type__c +' '+ connection.access_token__c);
			response = http.send(request);
			if(response.getStatusCode()==200){
				Map<String, Object> jsonResponse = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
				List<Object> records = (List<Object>) jsonResponse.get('records');
				return records;

			}else if(response.getStatusCode()==401&&!retried){
				//RefreshToken処理
				retried = true;
				retrieveToken(true);
				List<Object> records = query(soql);
				upsert this.connection;		//再帰的にquery処理の後にDMLを発行する。
				return records;
			}else{
				throw new CalendarConnectException(
					CalendarConnectException.getConcatErrorMessage(tokenEndpoint, response)
				);
			}
		}catch(CalendarConnectException cce){
			throw cce;
		}catch(Exception e){
			throw new CalendarConnectException(CalendarConnectException.getConcatErrorMessage(e, response));
		}
	}


	public class AuthResult{
		public String access_token{get;set;}
		public String refresh_token{get;set;}		
		public String instance_url{get;set;}	
		public String token_type{get;set;}	
		public String id{get;set;}
		public String getUserId(){
			List<String> separated = id.split('/');
			return separated[separated.size()-1];		//idに格納されている最後の値がUserId
		}
	}

}