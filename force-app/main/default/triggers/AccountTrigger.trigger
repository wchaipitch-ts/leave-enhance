trigger AccountTrigger on Account (before insert, before update, after insert) {
    
    
    if (Trigger.isBefore) {
        for (Account acc : Trigger.new) {
            if (Trigger.isInsert || (Trigger.isUpdate && acc.Name != Trigger.oldMap.get(acc.Id).Name)) {
                acc.Normalized_Company_Name__c = StringUtils.normalizeCompanyName(acc.Name);
            }
        }
    }

    if (Trigger.IsAfter && Trigger.isInsert ){

        for(Account acc : Trigger.new) {

            Map<String,Object> request = new Map<String,Object>();

            String companyName = acc.Name;
            String country = acc.Country__c == null ? 'N/A' : acc.Country__c;

            String prompt ='You are the agentic AI which will help Sales team to work smarter. Please provide the business information for ' + companyName +  'Country: '+ country  + 
            'with includes Date of Latest AI Update,Industry,Website URL,HQ Main Phone,Nationality of Parent,Head Office Address (TH), Business Desc. (<50 chars),Business Model,Branches' +
            '/ Factories,Number of Employee,Official SNS (FB/LinkedIn), SAP Case Studies and reference url, SDFC Case Studies and reference url, Kintone Case Studies and reference url , '+
            'AI Summary (Limited 1000 character), Top 3 Business Challenges, Top 3 Hypotheses on Sales Challenges, estimate the revenue of the company  in a range (0 - 10 million THB, 10 - 50 million THB'+
            ', 50 million+ THB), and URLs of publicly available Salesforce case studies of competitors in the same industry. in JSON format' ;

            //request.put('prompt',prompt);
            //request.put('accId',acc.Id);
            GeminiCalloutService.askGemini(prompt,acc.Id);
        }
    }

    
    /*for (Account acc : Trigger.new) {
        if (String.isNotBlank(acc.Name) && 
           (Trigger.isInsert || (Trigger.isUpdate && acc.Name != Trigger.oldMap.get(acc.Id).Name))) {
            
            // เรียกใช้ method กลางจาก StringUtils เพื่อให้แน่ใจว่า Logic เหมือนกัน 100%
            acc.Normalized_Company_Name__c = StringUtils.normalizeCompanyName(acc.Name);
        }
    }*/
}