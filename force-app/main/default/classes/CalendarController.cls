public with sharing class CalendarController {
    public CalendarController() {

    }

	private ConnectGateWay gateWay;

	/**
	 * 	初期処理
	 * 		CalendarConnection__cの取得
	 */
	public pageReference init(){
		this.gateWay = new ConnectGateWay();
		this.selectedUserId = UserInfo.getUserId();
		if(getHasAccessToken()){
			collectEvents();
		}
		return null;
	}

	public Boolean getHasAccessToken(){
		return this.gateWay.hasAccessToken();
	}

	public String getUserTimezone(){
		return UserInfo.getTimeZone().getDisplayName();
	}

	/**
	 * 	Tokenがない場合にToke取得フローを発動する
	 */
	public String authUrl{get;set;}
	public pageReference startAuthorize(){
		//return this.gateWay.authorize();
		PageReference pg = this.gateWay.authorize();
		authUrl = pg.getUrl();
		return null;
	}

	/** GBD User 
Takafumi Funayama	0055i000006TRSqAAO	0055F000007MjLvQAK
Kohei Yokoyama		0055i000006TRTFAA4	00510000000FGkYAAW
Kobayashi Shin		0055i000003XPfBAAW	0055i000000lDjdAAE
Chiharu				0055i000006UZZkAAO	00510000000FH9EAAW

{"0055i000003XPfBAAW":"0055i000000lDjdAAE", "0055i000006TRSqAAO":"0055F000007MjLvQAK", 
 "0055i000006TRTFAA4":"00510000000FGkYAAW", "0055i000006UZZkAAO":"00510000000FH9EAAW",
 "0055i000004eGjOAAU":"00510000000FGkYAAW", "0055i000005s9WOAAY":"00510000000FH9EAAW"}
	*/


	private Map<String,String> userIdMap{		//MyOrg => YourOrg
		get{
			if(userIdMap == null){
				userIdMap = (Map<String,String>)JSON.deserialize(gateway.connectedApp.UserIdMap__c, Map<String,String>.class);
			}
			return userIdMap;
		}
		set;
	}
	public String selectedUserId{get;set;}
	public List<SelectOption> GBDUsers{
		get{
			if(GBDUsers==null){
				GBDUsers = new List<SelectOption>();
				for(User u: [SELECT Id, Name 
								FROM User 
								WHERE Id in:userIdMap.keyset()]){
					GBDUsers.add(new SelectOption(u.Id, u.Name));
				}
			}
			return GBDUsers;
		}
		private set;
	}


	/**
	 * 	イベント取得
	 */
	@TestVisible
	private void collectEvents(){
		this.records = new List<Event2>();
		
		//接続先Event情報の取得
		Map<Id, Event> urEvs = getYourEvents();

		//自組織のEvent収集処理
		for(Event myEv:getMyEvents()){
			Event2 ev2;
			//すでに同期済の場合
			if(urEvs.containsKey(myEv.upsertKey__c)){
				ev2 = new Event2(urEvs.get(myEv.upsertKey__c), myEv);		//接続先の情報で作成される
				urEvs.remove(myEv.upsertKey__c);
			}else{
				ev2 = new Event2(myEv);
			}
			this.records.add(ev2);
		}

		//接続先の残りのEventを追加
		for(Event ev:urEvs.values()){
			Event2 ev2 = new Event2(ev, null);
			this.records.add(ev2);
		}

		this.records.sort();

		Event2 beforeEv2 = null;
		for(Event2 ev2:this.records){
			if(beforeEv2!=null){
				beforeEv2.setNext(ev2);
			}
			beforeEv2 = ev2;
		}
	}

	//接続先組織のEventの取得
	private Map<Id, Event> getYourEvents(){
		Map<Id, Event> yourEvents = new Map<Id, Event>();
		List<String> soqlFields = new List<String>();
		soqlFields.addAll(SYNC_FIELDS);
		soqlFields.addAll(SYNC_FIELDS_DATETIME);
 
		//認証したときの相方のUserIdをOwnerIdに設定する　　TODO：取得先のUserIdを可変にする
		String yourUserId = userIdMap.get(selectedUserId);
		String soql = String.format(SOQL_EVENT, new List<String>{String.join(soqlFields,',')
																	,''			//接続先はUpsertKey含めない
																	,'\''+yourUserId+'\''});

		//接続先組織のEvent情報の収集
		List<Object> records = gateWay.query(soql);
		for (Object record : records) {
			Map<String, Object> recordMap = (Map<String, Object>) record;
			Event ev = new Event();
			for(String s:SYNC_FIELDS){
				ev.put(s, recordMap.get(s));
			}
			for(String s:SYNC_FIELDS_DATETIME){
				// 2023-03-17T08:30:00.000+0000
				String dtVal = String.valueOf(recordMap.get(s));
				ev.put(s, GMTStringToDatetime(dtVal));
			}
			//ev.Id = (String) recordMap.get('Id');
			ev.upsertKey__c = (String) recordMap.get('Id');			//接続先EventのIdをセット 
			ev.Subject = gateWay.connectedApp.subjectPrefix__c + ev.Subject;	//Prefixを追加する
			yourEvents.put(ev.upsertKey__c, ev);
		}

		return yourEvents;
	}

	//同期項目　API名が一致してること
	private static final List<String> SYNC_FIELDS = new List<String>{
		'Subject','Location','IsAllDayEvent','Description'
	};
	private static final List<String> SYNC_FIELDS_DATETIME = new List<String>{
		'StartDateTime','EndDateTime'
	};
	private Datetime GMTStringToDatetime(String sGmt){
		// String s = '2023-03-17T08:30:00.000+0000';
		// System.debug(s);
		
		// Datetime dt = Datetime.valueOFGMT(s.replace('T', ' '));
		// System.debug(dt.format());
		// System.debug(dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSSZ'));          sと同じ文字列
		if(sGmt==null) return null;

		Datetime dt = Datetime.valueOFGMT(sGmt.replace('T', ' '));
		System.assert(dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSSZ').equals(sGmt));
		return dt;
	}

	// 自組織のEventの取得
	private List<Event> getMyEvents(){
		List<String> soqlFields = new List<String>();
		soqlFields.addAll(SYNC_FIELDS);
		soqlFields.addAll(SYNC_FIELDS_DATETIME);
		String soql = String.format(SOQL_EVENT, new List<String>{String.join(soqlFields,',')
															, ',UpsertKey__c'
															,'\''+ selectedUserId +'\''});		//, String.join(evIds,',')
		return Database.query(soql);
	}

	private static final String SOQL_EVENTRELATION = 'SELECT Id,EventId '
													//+ 'Relation.Name,RespondedDate,Response,Status '
													+ 'FROM EventRelation '
													+ 'WHERE Event.StartDateTime>=TODAY AND RelationId={0} '
													+ 'ORDER BY Event.StartDateTime '
													+ 'LIMIT 100';
	private static final String SOQL_EVENT = 'SELECT Id,Owner.Name,{0}{1} '
											+ 'FROM EVENT '
											+ 'WHERE StartDateTime>=TODAY AND StartDateTime <= NEXT_90_DAYS AND OwnerId={2} '//OR Id IN {1} '
											+ 'ORDER BY StartDateTime,EndDateTime,CreatedDate ';
											//+ 'LIMIT 200';

	public PageReference doSync(){
		List<Event> delTargets = new List<Event>();
		List<Event> upsertTargets = new List<Event>();
		//for(Event2 ev2:this.records){
		for(Integer i=this.records.size()-1; i>=0; i--){
			Event2 ev2 = this.records[i];
			if(ev2.deleteTarget){
				delTargets.add(ev2.record);
				this.records.remove(i);
			}
			if(!ev2.getMyOriginal() && (ev2.getIsNew()||ev2.getIsUpdated())){
				upsertTargets.add(ev2.record);
			}
		}

		delete delTargets;
		upsert upsertTargets UpsertKey__c;
		
		return null;
	}


	/**
	 * 	表示イベント　情報
	 */
	public List<Event2> records{get;set;}

	public class Event2 implements Comparable{
		public Event record{get;set;}
		private Event copiedRecord{get;set;}	//すでにコピーされてるレコードが自組織にある場合に設定される
		private Event nextEvent{get;set;}		//次のEventレコード
		public Boolean deleteTarget{get;private set;}
		//public Boolean isNew{get;private set;}
		public Boolean isFirst{get;set;}		//その日の最初のイベント

		//自組織のEvent
		public Event2(Event ev){
			record = ev;
			copiedRecord = null;
			deleteTarget = (String.isNotBlank(ev.upsertKey__c));
			//isNew = false;
			isFirst = false;
		}

		//接続先組織のEvent　から生成
		public Event2(Event urEv, Event ev){
			record = urEv;
			copiedRecord = ev;
			deleteTarget = false;
			//isNew = (ev==null);
			isFirst = false;
		}

		public Boolean getIsNew(){
			return record.Id==null && copiedRecord==null;
		}

		public Boolean getMyOriginal(){
			//自組織固有のスケジュールの場合True
			return (getisNew()==false) && (copiedRecord==null);
		}

		public Boolean getIsUpdated(){
			if(copiedRecord==null) return false;

			for(String s:SYNC_FIELDS){
				if(String.valueOf(record.get(s)) != String.valueOf(copiedRecord.get(s))){
					return true;
				}
			}
			for(String s:SYNC_FIELDS_DATETIME){
				if(String.valueOf(record.get(s)) != String.valueOf(copiedRecord.get(s))){
					return true;
				}
			}
			return false;
		}

		public Integer compareTo(Object compareTo) {
			Event2 compareToEv2 = (Event2)compareTo;
			if(record.StartDateTime < compareToEv2.record.StartDateTime) return -1;
			if(record.StartDateTime > compareToEv2.record.StartDateTime) return 1;
			if(record.EndDateTime < compareToEv2.record.EndDateTime) return -1;
			if(record.EndDateTime > compareToEv2.record.EndDateTime) return 1;
			return 0;        
		}

		public void setNext(Event2 nextEv2){
			//同日の場合にNextEventとして保持
			if(record.EndDateTime.date()==nextEv2.record.StartDateTime.date()){
				nextEvent = nextEv2.record;
			}else{
				nextEv2.isFirst = true;
			}
		}
		
		public String getBorderStyle(){
			if(this.isFirst){
				return 'first-event';
			}
			Time t = Time.newInstance(10,0,0,0);		//GMT10時➡JST19時
			Datetime nextStartTime = Datetime.newInstanceGmt(record.EndDatetime.Date(), t);
			if(nextEvent!=null){
				nextStartTime = nextEvent.startDateTime;
			}

			//前のイベントと同日の場合その間の時間を求める
			long diff = nextStartTime.getTime() - record.EndDateTime.getTime();
			Decimal diffHour = diff/(1000*60*60);

			if(diffHour.intValue()>0){
				return 'gap-hours-' + String.valueOf(diffHour.intValue());
			}
			return '';
		}
	}

}