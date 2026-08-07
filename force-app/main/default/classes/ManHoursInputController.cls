public with sharing class ManHoursInputController {

    @AuraEnabled(cacheable=false)
    public static List<ProjectAssign__c> getProjectList(String userId, String year, String month){
        try {
            Id user = (Id)userId;
            Date tempDate = Date.valueOf(year+'-'+month+'-15');
            Integer numberOfDays = Date.daysInMonth(tempDate.year(), tempDate.month());

            Date startDateTemp = Date.newInstance(tempDate.year(), tempDate.month(), 1);
            Date endDateTemp = Date.newInstance(tempDate.year(), tempDate.month(), numberOfDays);

            List<ProjectAssign__c> projectAssignList = [SELECT
                                                            Id,
                                                            Name,
                                                            Project_No__r.Project_Name__c,
                                                            Start_Date__c,
                                                            Due_Date__c,
                                                            Actual_Hours__c,
                                                            Planning_Hours__c,
                                                            (SELECT Id,
                                                                    Name,
                                                                    Work__c,
                                                                    Performed_Date__c,
                                                                    Performed_Hours__c,
                                                                    Remark__c
                                                                FROM Man_hours__r
                                                                WHERE Performed_Date__c >= :startDateTemp AND Performed_Date__c <= :endDateTemp
                                                                ORDER BY Performed_Date__c ASC)
                                                        FROM ProjectAssign__c
                                                        WHERE Assignee__c =:user
                                                            AND (
                                                                (Start_Date__c >= :startDateTemp AND Start_Date__c <= :endDateTemp)
                                                                OR (Due_Date__c >= :startDateTemp AND Due_Date__c <= :endDateTemp)
                                                            )
                                                        ];
            return projectAssignList;
        } catch (Exception e) {
            System.debug(e.getMessage());
            return new List<ProjectAssign__c>();
        }
    }

    @AuraEnabled(cacheable=false)
    public static ProjectAssign__c getManhourList(String projectAssignId, String dateSelected){
        try {
            Id projectAssignIdTemp = (Id)projectAssignId;
            Date tempDate = Date.valueOf(dateSelected);
            ProjectAssign__c projectAssign = [SELECT
                                                Id,
                                                Name,
                                                Project_No__r.Project_Name__c,
                                                Start_Date__c,
                                                Due_Date__c,
                                                (SELECT
                                                    Id,
                                                    Name,
                                                    Performed_Date__c,
                                                    Performed_Hours__c,
                                                    Project_Name__c,
                                                    Project_No__c,
                                                    ProjectAssign_Name__c,
                                                    ProjectAssign_No__c,
                                                    Remark__c,
                                                    Work__c
                                                FROM Man_hours__r
                                                WHERE Performed_Date__c =:tempDate
                                                ORDER BY CreatedDate ASC)
                                            FROM ProjectAssign__c
                                            WHERE Id =:projectAssignIdTemp
                                            LIMIT 1];
            return projectAssign;
        } catch (Exception e) {
            System.debug(e.getMessage());
            return new ProjectAssign__c();
        }
    }

    @AuraEnabled(cacheable=false)
    public static List<Man_hour__c> addManhour(String projectAssignId, String performedDate){
        Date performedDateTemp = Date.valueOf(performedDate);
        try {
            Man_hour__c manHour = new Man_hour__c(
                                        Work__c='',
                                        ProjectAssign_No__c=projectAssignId,
                                        Performed_Date__c=performedDateTemp,
                                        Performed_Hours__c=0,
                                        Remark__c=''
                                    );
            insert manHour;
            List<Man_hour__c> manHours = [SELECT Id,
                                            Name,
                                            Work__c,
                                            Performed_Date__c,
                                            Performed_Hours__c,
                                            ProjectAssign_No__c,
                                            Remark__c
                                        FROM Man_hour__c
                                        WHERE  ProjectAssign_No__c=:projectAssignId AND Performed_Date__c=:performedDateTemp
                                        ORDER BY CreatedDate ASC];
            return manHours;
        } catch (Exception e) {
            System.debug(e.getMessage());
            throw new AuraHandledException('Failed to insert man-hour: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=false)
    public static List<Man_hour__c> editManhour(List<Man_hour__c> editRecords){
        try {
            List<Man_hour__c> manHours = new List<Man_hour__c>();
            if(editRecords.size()>0) {
                update editRecords;
                Man_hour__c manHour = [SELECT Id, Performed_Date__c, ProjectAssign_No__c FROM Man_hour__c WHERE Id=:editRecords.get(0).Id LIMIT 1];
                manHours = [SELECT Id,
                                Name,
                                Work__c,
                                Performed_Date__c,
                                Performed_Hours__c,
                                ProjectAssign_No__c,
                                Remark__c
                            FROM Man_hour__c
                            WHERE ProjectAssign_No__c=:manHour.ProjectAssign_No__c AND Performed_Date__c=:manHour.Performed_Date__c
                            ORDER BY CreatedDate ASC];
            }
            return manHours;
        } catch (Exception e) {
            System.debug(e.getMessage());
            throw new AuraHandledException('Failed to edit man-hour: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=false)
    public static List<Man_hour__c> deleteManhour(List<Man_hour__c> deleteRecords){
        try {
            Id projectAssignId = null;
            Date performedDate = null;
            List<Man_hour__c> manHours = new List<Man_hour__c>();

            if(deleteRecords.size()>0) {
                Man_hour__c manHour = [SELECT Id, Performed_Date__c, ProjectAssign_No__c FROM Man_hour__c WHERE Id=:deleteRecords.get(0).Id LIMIT 1];
                delete deleteRecords;
                manHours = [SELECT Id,
                                Name,
                                Work__c,
                                Performed_Date__c,
                                Performed_Hours__c,
                                ProjectAssign_No__c,
                                Remark__c
                            FROM Man_hour__c
                            WHERE ProjectAssign_No__c=:manHour.ProjectAssign_No__c AND Performed_Date__c=:manHour.Performed_Date__c
                            ORDER BY CreatedDate ASC];
            }
            return manHours;
        } catch (Exception e) {
            System.debug(e.getMessage());
            throw new AuraHandledException('Failed to delete man-hour: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=false)
    public static User getUserAvatar(String Id) {
        try {
            User user = [SELECT Id, Name, Title, Department, Manager.Name, Manager.Id, MediumPhotoUrl FROM User WHERE Id = :Id LIMIT 1];
            return user;
        } catch (Exception e) {
            System.debug(e);
            return null;
        }
    }
}