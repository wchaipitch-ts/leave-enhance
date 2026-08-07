public class GeminiCalloutService {

    private static final String API_KEY = 'AQ.Ab8RN6Imwk7zxfvH-h166gJLLJ4fQJ1ho2JHHQgNQkoYWknKfg'; 
    private static final String MODEL = 'gemini-3.1-flash-lite'; 
    private static final String ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models/' + MODEL + ':generateContent?key=' + API_KEY;    

    @future(callout=true)
    public static void askGemini(String prompt , String accId) {
        Http http = new Http();
        HttpRequest request = new HttpRequest();
        
        request.setEndpoint(ENDPOINT);
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setTimeout(60000);
        
        // Construct the JSON Payload
        Map<String, Object> rootPayload = new Map<String, Object>();
        List<Object> contentsList = new List<Object>();
        Map<String, Object> contentMap = new Map<String, Object>();
        List<Object> partsList = new List<Object>();
        Map<String, Object> textMap = new Map<String, Object>();
        
        textMap.put('text', prompt);
        partsList.add(textMap);
        contentMap.put('parts', partsList);
        contentsList.add(contentMap);
        rootPayload.put('contents', contentsList);

        Map<String, Object> generationConfig = new Map<String, Object>();
        generationConfig.put('responseMimeType', 'application/json');
        rootPayload.put('generationConfig', generationConfig);
        
        String jsonBody = JSON.serialize(rootPayload);
        request.setBody(jsonBody);
        
        try {
            HttpResponse response = http.send(request);
            
            if (response.getStatusCode() == 200) {
                GeminiResult geminiResult = parseGeminiResponse(response.getBody());
                System.debug('response>>>>>' + geminiResult.textResponse);
                String cleanJson = sanitizeJson(geminiResult.textResponse);
                System.debug('cleanJson>>>>>' + cleanJson);
                
                // Pre-process and safely normalize casing/type inconsistencies 
                String normalizedJson = normalizePayloadSchema(cleanJson);
                System.debug('normalizedJson>>>>>' + normalizedJson);
                
                CompanyInfo info = null;
                try {
                    GeminiResponseWrapper wrapper = (GeminiResponseWrapper) JSON.deserialize(normalizedJson, GeminiResponseWrapper.class);
                    if (wrapper != null && wrapper.company_info != null) {
                        info = wrapper.company_info;
                    } else {
                        info = (CompanyInfo) JSON.deserialize(normalizedJson, CompanyInfo.class);
                    }
                } catch (Exception e) {
                    System.debug('Typed Deserialization failed: ' + e.getMessage());
                }

                if (info != null) {
                    Account acc = [SELECT Id, Country__c, Date_Of_Latest_Ai_Update__c, Industry, Website, Phone, Company_nationality__c,
                                    BillingAddress, Description, Business_Model__c, Branches_Factories__c, NumberOfEmployees, Official_Sns__c, SAP_Case_Studies__c,
                                    SFDC_Case_Studies__c, kintone_Case_Studies__c, Ai_Summary__c, Top_3_Business_Challenges__c, Top_3_Hypotheses_On_Sales_Challenges__c,
                                    estimated_revenue_range__c, Salesforce_case_studies_of_competitors__c, Input_Token__c, Output_Token__c 
                                   FROM Account WHERE Id = :accId LIMIT 1];

                    acc.Input_Token__c = geminiResult.promptTokens;
                    acc.Output_Token__c = geminiResult.completionTokens;

                    acc.Date_Of_Latest_Ai_Update__c = parseDate(info.date_of_latest_ai_update);
                    //acc.Country__c = info.country;
                    acc.Industry = info.industry;
                    acc.Website = info.website_url;
                    acc.Phone = info.hq_main_phone;
                    
                    String nationality = info.nationality_of_parent;
                    acc.Company_nationality__c = nationality;
                    
                    acc.Description = info.business_desc;
                    acc.Business_Model__c = info.business_model;
                    acc.Branches_Factories__c = info.branches_factories;
                    acc.Ai_Summary__c = info.ai_summary;
                    acc.estimated_revenue_range__c = info.estimated_revenue_thb;
                    
                    acc.Top_3_Business_Challenges__c = formatList(info.top_3_business_challenges);
                    acc.Top_3_Hypotheses_On_Sales_Challenges__c = formatList(info.top_3_hypotheses_on_sales_challenges);
                    acc.Salesforce_case_studies_of_competitors__c = formatList(info.competitor_salesforce_case_studies);
                    
                    acc.Official_Sns__c = info.official_sns;
                    acc.SAP_Case_Studies__c = info.sap_case_studies_ref;
                    acc.SFDC_Case_Studies__c = info.sdfc_case_studies_ref; 
                    acc.kintone_Case_Studies__c = info.kintone_case_studies_ref;

                    update acc;
                }

            } else {
                System.debug('Error Status: ' + response.getStatus());
                System.debug('Error Body: ' + response.getBody());
            }
        } catch (Exception e) {
            System.debug('Exception encountered at line ' + e.getLineNumber() + ': ' + e.getMessage());
        }
    }

    // ==========================================
    // NORMAL DESERIALIZATION TARGET WRAPPERS
    // ==========================================

    public class GeminiResponseWrapper {
        public CompanyInfo company_info;
    }

    public class CompanyInfo {
        public String company_name;
        public String date_of_latest_ai_update;
        public String industry;
        public String website_url;
        public String hq_main_phone;
        public String nationality_of_parent;
        public String head_office_address_th;
        public String business_desc;
        public String business_model;
        public String branches_factories;
        public String number_of_employee; 
        public String official_sns;
        public String sap_case_studies_ref;
        public String sdfc_case_studies_ref; 
        public String kintone_case_studies_ref;
        public String ai_summary;
        public List<String> top_3_business_challenges;            
        public List<String> top_3_hypotheses_on_sales_challenges; 
        public String estimated_revenue_thb;
        public List<String> competitor_salesforce_case_studies;
    }

    // ==========================================
    // LIGHTWEIGHT DATA TYPE UTILITIES & NORMALIZER
    // ==========================================

    /**
     * Reconciles casing structural duplicates dynamically by performing 
     * case-sensitive extraction removals prior to typed parsing.
     */
    private static String normalizePayloadSchema(String cleanJson) {
        if (String.isBlank(cleanJson)) return cleanJson;
        
        try {
            Map<String, Object> untypedJson = (Map<String, Object>) JSON.deserializeUntyped(cleanJson);
            
            Map<String, Object> info = untypedJson;
            String companyInfoKey = findKeyCaseInsensitive(untypedJson, 'company_info');
            if (companyInfoKey != null) {
                Object compInfoVal = untypedJson.remove(companyInfoKey); // Atomic remove stops duplicate keys
                if (compInfoVal instanceof Map<String, Object>) {
                    info = (Map<String, Object>) compInfoVal;
                }
                untypedJson.put('company_info', info);
            }
            
            // Normalize Array fields cleanly
            List<String> listKeys = new List<String>{
                'top_3_business_challenges', 
                'top_3_hypotheses_on_sales_challenges', 
                'competitor_salesforce_case_studies'
            };
            
            for (String key : listKeys) {
                String actualKey = findKeyCaseInsensitive(info, key);
                if (actualKey != null) {
                    // FIXED: info.remove(actualKey) purges any old rogue casing variations entirely
                    Object val = info.remove(actualKey); 
                    List<String> stringList = new List<String>();
                    
                    if (val instanceof String) {
                        stringList.add((String)val);
                    } else if (val instanceof List<Object>) {
                        for (Object o : (List<Object>)val) {
                            stringList.add(String.valueOf(o));
                        }
                    }
                    info.put(key, stringList);
                }
            }
            
            // Normalize String/URL reference fields cleanly
            List<String> stringKeys = new List<String>{
                'company_name', 'date_of_latest_ai_update', 'industry', 'website_url', 
                'hq_main_phone', 'nationality_of_parent', 'head_office_address_th', 
                'business_desc', 'business_model', 'branches_factories', 'number_of_employee', 
                'official_sns', 'sap_case_studies_ref', 'sdfc_case_studies_ref', 
                'kintone_case_studies_ref', 'ai_summary', 'estimated_revenue_thb'
            };
            
            for (String key : stringKeys) {
                String actualKey = findKeyCaseInsensitive(info, key);
                if (actualKey != null) {
                    Object val = info.remove(actualKey); // Purges alternative casings safely
                    info.put(key, val != null ? String.valueOf(val) : '');
                }
            }
            
            return JSON.serialize(untypedJson);
        } catch (Exception e) {
            System.debug('Payload schema normalization bypassed: ' + e.getMessage());
            return cleanJson; 
        }
    }

    private static String findKeyCaseInsensitive(Map<String, Object> m, String targetKey) {
        if (m == null || String.isBlank(targetKey)) return null;
        String idealizedTarget = targetKey.toLowerCase().replaceAll('_', '');
        for (String k : m.keySet()) {
            if (k.toLowerCase().replaceAll('_', '') == idealizedTarget) {
                return k;
            }
        }
        return null;
    }

    private static Date parseDate(String dateStr) {
        if (String.isBlank(dateStr)) return null;
        try {
            return Date.valueOf(dateStr);
        } catch (Exception e) {
            System.debug('Invalid date format layout parsed: ' + dateStr);
            return null;
        }
    }

    private static Integer parseInteger(String intStr) {
        if (String.isBlank(intStr)) return null;
        try {
            return Integer.valueOf(intStr.replaceAll('[^0-9]', ''));
        } catch (Exception e) {
            System.debug('Failed to transform standard numerical integer: ' + intStr);
            return null;
        }
    }

    private static String formatList(List<String> entries) {
        if (entries == null || entries.isEmpty()) return '';
        return String.join(entries, '\n');
    }

    private static String sanitizeJson(String rawResponse) {
        if (String.isBlank(rawResponse)) {
            return rawResponse;
        }
        String cleanJson = rawResponse.trim();
        if (cleanJson.startsWith('```json')) {
            cleanJson = cleanJson.substringAfter('```json');
        } else if (cleanJson.startsWith('```')) {
            cleanJson = cleanJson.substringAfter('```');
        }
        if (cleanJson.endsWith('```')) {
            cleanJson = cleanJson.substringBeforeLast('```');
        }
        return cleanJson.trim();
    }

    private static GeminiResult parseGeminiResponse(String jsonResponse) {
        GeminiResult result = new GeminiResult();
        Map<String, Object> deserialized = (Map<String, Object>) JSON.deserializeUntyped(jsonResponse);
        
        List<Object> candidates = (List<Object>) deserialized.get('candidates');
        if (candidates != null && !candidates.isEmpty()) {
            Map<String, Object> firstCandidate = (Map<String, Object>) candidates[0];
            Map<String, Object> content = (Map<String, Object>) firstCandidate.get('content');
            if (content != null) {
                List<Object> parts = (List<Object>) content.get('parts');
                if (parts != null && !parts.isEmpty()) {
                    Map<String, Object> firstPart = (Map<String, Object>) parts[0];
                    result.textResponse = (String) firstPart.get('text');
                }
            }
        }
        
        Map<String, Object> usage = (Map<String, Object>) deserialized.get('usageMetadata');
        if (usage != null) {
            result.promptTokens = usage.get('promptTokenCount') != null ? Integer.valueOf(usage.get('promptTokenCount')) : 0;
            result.completionTokens = usage.get('candidatesTokenCount') != null ? Integer.valueOf(usage.get('candidatesTokenCount')) : 0;
            result.totalTokens = usage.get('totalTokenCount') != null ? Integer.valueOf(usage.get('totalTokenCount')) : 0;
        }
        
        return result;
    }

    public class GeminiResult {
        public String textResponse {get; set;}
        public Integer promptTokens {get; set;}
        public Integer completionTokens {get; set;}
        public Integer totalTokens {get; set;}
    }
}