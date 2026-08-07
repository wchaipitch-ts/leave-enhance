public class CalendarConnectException extends Exception{


	public static String getConcatErrorMessage(Exception e){
		String TEMPLATE = '{0}@@@{1}';
		return String.format(TEMPLATE, new List<String>{
											e.getMessage()
											, e.getStackTraceString()
								});
	}

	public static String getConcatErrorMessage(String endpoint, HttpResponse res){
		String TEMPLATE = '[{0}]呼び出しエラー StatusCode:{1} Body:{2}';
		return String.format(TEMPLATE, new List<String>{
													endpoint
													, String.valueOf(res.getStatusCode())
													, res.getBody()
												});
	}

	public static String getConcatErrorMessage(Exception e, HttpResponse res){
		if(res==null){
			return getConcatErrorMessage(e);
		}

		String TEMPLATE = 'StatusCode:{0} Body:{1} \r\n【ERROR】{2}';
		return String.format(TEMPLATE, new List<String>{
										 String.valueOf(res.getStatusCode())
										, res.getBody()
										, getConcatErrorMessage(e)
		});
	}
}