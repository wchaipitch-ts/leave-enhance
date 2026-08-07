public with sharing class CertificationBoardingTrailhead {
    private static final String TRAIL_MIX_ICON = 'https://trailblazer.me/profilephoto/7291I0000019lbG/F';
    private static final String TRAILMIX_ASSIGNMENT_DEFAULT_STATUS = 'Processed';
    private static final String TRAILMIX_USER_DEFAULT_STATUS = 'In Progress';
    private static final String BADGE_ASSIGNMENT_DEFAULT_STATUUS = 'Assigned';
    private static final String FORMAT_EXTERNAL_ID = '{0}-{1}';
    private static final String TRAILMIX_TYPE = 'trailmix';

    public class BadgeAndTrailInformation {
        @AuraEnabled
        public List<BadgeAndTrailData> badges { get; set; }
        
        @AuraEnabled
        public List<BadgeAndTrailData> trailmixes { get; set; }
    }

    public class BadgeAndTrailData {
        @AuraEnabled
        public String id { get; set; }
        
        @AuraEnabled
        public String name { get; set; }
        
        @AuraEnabled
        public String icon { get; set; }
        
        @AuraEnabled
        public String url { get; set; }

        @AuraEnabled
        public string externalId { get; set; }
    }

    public class BadgeAndTrailSaveData {
        @AuraEnabled
        public String id { get; set; }

        @AuraEnabled
        public Date dueDate { get; set; }

        @AuraEnabled
        public string externalId { get; set; }

        @AuraEnabled
        public string type { get; set; }
    }

    @AuraEnabled
    public static BadgeAndTrailInformation searchBadgesAndTrail(String searchText) {
        List<List<SObject>> searchList = [FIND :searchText 
                                          IN Name Fields 
                                          RETURNING 
                                           trailheadapp__Badge__c(Name, trailheadapp__Icon__c, trailheadapp__URL__c, trailheadapp__External_Id__c),
                                           trailheadapp__Trailmix__c(Name, trailheadapp__URL__c, trailheadapp__External_Id__c)];
        
        BadgeAndTrailInformation informations = new BadgeAndTrailInformation();
        informations.badges = setBadges((List<trailheadapp__Badge__c>) searchList.get(0));
        informations.trailmixes = setTrailmixes((List<trailheadapp__Trailmix__c>) searchList.get(1));

        return informations;
    }

    @AuraEnabled
    public static Boolean saveBadgeAndTrail(List<BadgeAndTrailSaveData> saveData, String skillAndCertId) {
        List<trailheadapp__Trailmix_Assignment__c> assignmentList = new List<trailheadapp__Trailmix_Assignment__c>();
        List<trailheadapp__User_Trailmix__c> userTrailmixList = new List<trailheadapp__User_Trailmix__c>();
        List<trailheadapp__User_Badge__c> userBadgeList = new List<trailheadapp__User_Badge__c>();

        Skill_Certification__c skillAndCertData = [SELECT Id, Owner.Id FROM Skill_Certification__c WHERE Id = :skillAndCertId];
        System.debug(saveData);
        for (BadgeAndTrailSaveData data : saveData) {
            String externalId = String.format(FORMAT_EXTERNAL_ID, new Object[]{ data.externalId, skillAndCertData.Owner.Id });

            if (data.type == TRAILMIX_TYPE) {
                trailheadapp__Trailmix_Assignment__c trailmixAssingment = new trailheadapp__Trailmix_Assignment__c();
                trailmixAssingment.trailheadapp__User__c = skillAndCertData.Owner.Id;
                trailmixAssingment.trailheadapp__Trailmix__c = data.id;
                trailmixAssingment.trailheadapp__Due_Datetime__c = data.dueDate;
                trailmixAssingment.trailheadapp__Status__c = TRAILMIX_ASSIGNMENT_DEFAULT_STATUS;

                trailheadapp__User_Trailmix__c trailmixUser = new trailheadapp__User_Trailmix__c();
                trailmixUser.trailheadapp__User__c = skillAndCertData.Owner.Id;
                trailmixUser.Skill_Certification__c = skillAndCertData.Id;
                trailmixUser.trailheadapp__Trailmix__c = data.id;
                trailmixUser.trailheadapp__Due_At__c = data.dueDate;
                trailmixUser.trailheadapp__External_Id__c = externalId;
                trailmixUser.trailheadapp__Assigned_At__c = Date.today();
                trailmixUser.trailheadapp__Status__c = TRAILMIX_USER_DEFAULT_STATUS;

                assignmentList.add(trailmixAssingment);
                userTrailmixList.add(trailmixUser);
            } else {
                trailheadapp__User_Badge__c badgeAssignment = new trailheadapp__User_Badge__c();
                badgeAssignment.trailheadapp__User__c = skillAndCertData.Owner.Id;
                badgeAssignment.Skill_Certification__c = skillAndCertData.Id;
                badgeAssignment.trailheadapp__Badge__c = data.id;
                badgeAssignment.trailheadapp__Due_Date__c = data.dueDate;
                badgeAssignment.trailheadapp__External_Id__c = externalId;
                badgeAssignment.trailheadapp__Status__c = BADGE_ASSIGNMENT_DEFAULT_STATUUS;

                userBadgeList.add(badgeAssignment);
            }
        }

        try {
            if (assignmentList.size() > 0) insert assignmentList;
            if (userTrailmixList.size() > 0) insert userTrailmixList;
            if (userBadgeList.size() > 0) insert userBadgeList;
            
            return true;
        } catch (DmlException ex) {
            System.debug('----ERROR----');
            System.debug(ex);

            return false;
        }
    }

    private static List<BadgeAndTrailData> setBadges(List<trailheadapp__Badge__c> badgeList) {
        List<BadgeAndTrailData> badges = new List<BadgeAndTrailData>();
        for (trailheadapp__Badge__c badge : badgeList) {
            BadgeAndTrailData badgeData = new BadgeAndTrailData();
            badgeData.id = badge.Id;
            badgeData.name = badge.Name;
            badgeData.icon = badge.trailheadapp__Icon__c;
            badgeData.url = badge.trailheadapp__URL__c;
            badgeData.externalId = badge.trailheadapp__External_Id__c;
            badges.add(badgeData);
        }
        return badges;
    }

    private static List<BadgeAndTrailData> setTrailmixes(List<trailheadapp__Trailmix__c> trailmixList) {
        List<BadgeAndTrailData> trailmixes = new List<BadgeAndTrailData>();
        for (trailheadapp__Trailmix__c trailmix : trailmixList) {
            BadgeAndTrailData trailmixData = new BadgeAndTrailData();
            trailmixData.id = trailmix.Id;
            trailmixData.name = trailmix.Name;
            trailmixData.url = trailmix.trailheadapp__URL__c;
            trailmixData.icon = TRAIL_MIX_ICON;
            trailmixData.externalId = trailmix.trailheadapp__External_Id__c;
            trailmixes.add(trailmixData);
        }
        return trailmixes;
    }
}