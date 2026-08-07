public class CreateLeaveRecordOnManInputTriggerLogic {

    public void createLeaveRecord(ApplicationItem__c appl) {
        List<Man_hour__c> manhrList = [SELECT Id, Name, Project_Name__c, Work__c, Remark__c, Performed_Hours__c, Performed_Date__c, ProjectAssign_No__c  FROM Man_hour__c WHERE Project_Name__c = 'Leave FY'];
        
        if (appl.Status__c == 'Approved') {

            // Set leave time
            Decimal periodLeave = appl.Period_Leave__c == 'AM leave' ? 3.5 : appl.Period_Leave__c == 'PM leave' ? 4.0 : 7.5;

            String targetYear = String.valueOf(appl.Term_From__c.year());
            targetYear = targetYear.substring(2,4);
            String targetDate = String.valueOf(appl.Term_From__c);

            String projectName = 'Leave FY' + targetYear;
            Integer numberOfDays = Date.daysInMonth(appl.Term_From__c.year(), appl.Term_From__c.month());
    
            //create first Day Of Target Date and last Day Of Target Date
            Date startDateTemp = Date.newInstance(appl.Term_From__c.year(), appl.Term_From__c.month(), 1);
            Date endDateTemp = Date.newInstance(appl.Term_From__c.year(), appl.Term_From__c.month(), numberOfDays);

            //create first day and last day of year
            Date startYearDate = Date.newInstance(appl.Term_From__c.year(), 1, 1);
            Date endYearDate = Date.newInstance(appl.Term_From__c.year(), 12, 31);
            
            List<ProjectAssign__c> projectAssign = [SELECT 
                                                    Name, 
                                                    Project_Owner__c, 
                                                    Project_No__c, 
                                                    Project_Name__c, 
                                                    Assignee__c  
                                                FROM ProjectAssign__c 
                                                WHERE Project_Name__c = :projectName 
                                                    AND Assignee__c = :appl.OwnerId
                                                    AND (
                                                            (Start_Date__c >= :startDateTemp AND Start_Date__c <= :endDateTemp)
                                                            OR (Due_Date__c >= :startDateTemp AND Due_Date__c <= :endDateTemp)
                                                        )
                                                ORDER BY Id
                                                LIMIT 1];
            system.debug('projectAssign:'+ projectAssign);
            if (projectAssign.size() != 0) {
                Man_hour__c manHour = new Man_hour__c(                      
                    Performed_Date__c = appl.Term_From__c,
                    Performed_Hours__c = periodLeave,
                    ProjectAssign_No__c = projectAssign[0].Id,
                    Work__c = appl.Request_Type__c,
                    Remark__c = appl.Remark__c
                );
                insert manHour;
            }else {
                List<Project__c> project = [SELECT 
                                        Id,
                                        OwnerId,
                                        Project_Name__c,
                                        RecordType.DeveloperName
                                        FROM Project__c
                                        WHERE Project_Name__c = :projectName
                                        ORDER BY Id
                                        LIMIT 1];
                if (project.size() != 0) {
                    ProjectAssign__c projectAssignCreate = new ProjectAssign__c(
                        Assignee__c = appl.OwnerId,
                        Project_No__c = project[0].Id,
                        Start_Date__c = startDateTemp,
                        Due_Date__c = endDateTemp
                        );
                    insert projectAssignCreate;

                    Man_hour__c manHour = new Man_hour__c(                      
                        Performed_Date__c = appl.Term_From__c,
                        Performed_Hours__c = periodLeave,
                        ProjectAssign_No__c = projectAssignCreate.Id,
                        Work__c = appl.Request_Type__c,
                        Remark__c = appl.Remark__c
                    );
                    insert manHour;

                }else {
                   // User projectOwner = [SELECT Id, Name FROM User WHERE Username LIKE 'shin.kobayashi@terrasky.co.th%' LIMIT 1];
                   // User projectOwner = [SELECT Id, Name FROM User WHERE Username LIKE 'shin.kobayashi@terrasky.co.th%' LIMIT 1];
                   // User projectOwner = [SELECT Id, Name FROM User WHERE UserRole.Name LIKE 'Managing Director%' AND Isactive = true AND Profile.Name = 'System Administrator' LIMIT 1];
                    Id recordTypeId = Schema.SObjectType.Project__c.getRecordTypeInfosByDeveloperName().get('non_Charged').getRecordTypeId();
                    Project__c projectCreate = new Project__c(
                        OwnerId = UserInfo.getUserId(),
                        RecordTypeId = recordTypeId,
                        Project_Name__c = 'Leave FY' + targetYear,
                        Remark__c = 'for Leave in FY' + targetYear,
                        Project_Detail__c = 'for user input a Leave record',
                        Start_Date__c = startYearDate,
                        Close_Date__c = endYearDate
                    );
                    insert projectCreate;
                    
                    ProjectAssign__c projectAssignCreate = new ProjectAssign__c(
                        Assignee__c = appl.OwnerId,
                        Project_No__c = projectCreate.Id,
                        Start_Date__c = startDateTemp,
                        Due_Date__c = endDateTemp
                        );
                    insert projectAssignCreate;

                    Man_hour__c manHour = new Man_hour__c(                      
                        Performed_Date__c = appl.Term_From__c,
                        Performed_Hours__c = periodLeave,
                        ProjectAssign_No__c = projectAssignCreate.Id,
                        Work__c = appl.Request_Type__c,
                        Remark__c = appl.Remark__c
                    );
                    insert manHour;
                }
            }
        }

    }
}