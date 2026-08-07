public with sharing class SkillAndCertificationBoardController {
    private class CertificationInformation {
        String certIcon {get; set;}
        String certName {get; set;}
        String certCat {get; set;}
        String dateOfPassing {get; set;}
        String ownerTitle {get; set;}
    }
    private class CertificationChartDetail{
        String maxCountCert {get; set;}
        String maxCertType {get; set;}
        String allCertPass {get; set;}
        String maxCertUser {get; set;}
        List<String> topFiveName {get; set;}
        List<Integer> topFiveAmount {get; set;}
        List<String> allCertName {get; set;}
        List<Integer> allCertAmount {get; set;}
    }
    
    @AuraEnabled(cacheable=true)
    public static User userAvatar(String id){
        try { 
            User user = [SELECT MediumPhotoUrl FROM User WHERE Id = :id];
            return user;   
        } catch (Exception e) {
            System.debug(e);
            return null;
        }  
    }
    
    @AuraEnabled(cacheable=true)
    public static List<AggregateResult> certificationList(String ownerId){
        try {
            Id userId = Id.valueOf(ownerId);
            String query ='SELECT Certification_Name__c, CALENDAR_YEAR(Examination_Date__c) FROM Skill_Certification__c';
            String groupQuery =' GROUP BY CALENDAR_YEAR(Examination_Date__c), Certification_Name__c';
            
            if (String.isNotEmpty(ownerId)) query = query + ' WHERE Status__c = \'Pass\' AND OwnerId = :userId';
            
            query = query + groupQuery;
            List<AggregateResult> certificationList = (List<AggregateResult>) Database.query(query);                                          
            
            return certificationList;
        } catch (Exception e) {
            System.debug(e);
            return null;
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static Skill_Certification__c upcomingExam(String ownerId){
        try {
            Id userId = Id.valueOf(ownerId);
            Skill_Certification__c certification = [SELECT Id, Certification_Icon__c, Certification_Name__c, Examination_Date__c 
                                                    FROM Skill_Certification__c 
                                                    WHERE OwnerId =: userId
                                                     AND Status__c =: 'Applied'
                                                     AND Examination_Date__c >= TODAY
                                                    ORDER BY Examination_Date__c
                                                    LIMIT 1];
            
            return certification;
        } catch (Exception e) {
            System.debug(e);
            return null;
        }
    }

    @AuraEnabled(cacheable=true)
    public static string getAllCertification(){
        List<Skill_Certification__c> certificationList = [SELECT Certification_Name__c, Owner.Name, Owner.Title, Examination_Date__c, Certification_Categories__c, Certification_Icon__c FROM Skill_Certification__c WHERE Status__c = 'Pass' AND IsActiveUser__c = true];
        
        Map<String, List<CertificationInformation>> certificationMap = new Map<String, List<CertificationInformation>>();
        for (Skill_Certification__c cert : certificationList) {
            if (!certificationMap.containsKey(cert.Owner.Name)) certificationMap.put(cert.Owner.Name, new List<CertificationInformation>());
            CertificationInformation information = new CertificationInformation();
            information.certIcon = cert.Certification_Icon__c;
            information.certName = cert.Certification_Name__c;
            information.certCat = cert.Certification_Categories__c;
            information.dateOfPassing = String.valueOf(cert.Examination_Date__c);
            information.ownerTitle = cert.Owner.Title;
            certificationMap.get(cert.Owner.Name).add(information);
        }
        
        return JSON.serialize(certificationMap);
    }
    
    @AuraEnabled
    public static string certificationChart(){
        AggregateResult[] certMax = [SELECT COUNT(Id) maxCount, Certification_Name__c FROM Skill_Certification__c WHERE Status__c = 'Pass' AND IsActiveUser__c = true GROUP BY Certification_Name__c ORDER BY COUNT(Id) DESC LIMIT 1];
        AggregateResult[] certPass = [SELECT COUNT(Id) countPass FROM Skill_Certification__c WHERE Status__c = 'Pass' AND IsActiveUser__c = true];
        AggregateResult[] certTop = [SELECT COUNT(Id) topFive, Certification_Name__c FROM Skill_Certification__c WHERE Status__c = 'Pass' AND IsActiveUser__c = true GROUP BY Certification_Name__c ORDER BY COUNT(Id) DESC LIMIT 5];
        AggregateResult[] certUser = [SELECT COUNT(Id), Owner.Name OwnerName FROM Skill_Certification__c WHERE Status__c = 'Pass' AND IsActiveUser__c = true GROUP BY Owner.Name ORDER BY COUNT(Id) DESC LIMIT 1];
        AggregateResult[] certAllSummary = [SELECT COUNT(Id) certCount, Certification_Name__c FROM Skill_Certification__c WHERE Status__c = 'Pass' AND IsActiveUser__c = true GROUP BY Certification_Name__c ORDER BY COUNT(Id) DESC];

        if (certMax.size() == 0) return 'Not Found';
        AggregateResult certMaxChart = certMax.get(0);
        AggregateResult certPassChart = certPass.get(0);
        AggregateResult certUserChart = certUser.get(0);
        CertificationChartDetail chartDetail = new CertificationChartDetail();
        chartDetail.maxCountCert = String.valueOf(certMaxChart.get('maxCount'));
        chartDetail.maxCertType = String.valueOf(certMaxChart.get('Certification_Name__c'));
        chartDetail.allCertPass = String.valueOf(certPassChart.get('countPass'));
        chartDetail.maxCertUser = String.valueOf(certUserChart.get('OwnerName'));
        chartDetail.topFiveName = new List<String>();
        chartDetail.topFiveAmount = new List<Integer>();
        chartDetail.allCertName = new List<String>();
        chartDetail.allCertAmount = new List<Integer>();
    
        for (AggregateResult agr : certTop) {
            chartDetail.topFiveName.add(String.valueOf(agr.get('Certification_Name__c')));
            chartDetail.topFiveAmount.add(Integer.valueOf(agr.get('topFive')));
        }

        for (AggregateResult agr : certAllSummary) {
            chartDetail.allCertName.add(String.valueOf(agr.get('Certification_Name__c')));
            chartDetail.allCertAmount.add(Integer.valueOf(agr.get('certCount')));
        }
    
        return JSON.serialize(chartDetail);
    
    }
}