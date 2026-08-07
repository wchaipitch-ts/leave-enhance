public without sharing class TimesheetController {

    @AuraEnabled(cacheable=false)
    public static User getUserInfo(String Id) {
        try {
            User user = [SELECT Id, Name, EmployeeNumber, Title, Department, Manager.Name, Manager.Id, MediumPhotoUrl, Start_Date__c,
            Annual_Leave_Day__c FROM User WHERE Id = :Id LIMIT 1];
            return user;
        } catch (Exception e) {
            System.debug(e);
            return null;
        }
    }

    @AuraEnabled(cacheable=false)
    public static User getUserAvatar(String Id) {
        try {
            User user = [SELECT Id, Name, EmployeeNumber, Title, Department, Manager.Name, Manager.Id, MediumPhotoUrl FROM User WHERE Id = :Id LIMIT 1];
            return user;
        } catch (Exception e) {
            System.debug(e);
            return null;
        }
    }

    @AuraEnabled(cacheable=false)
    public static boolean checkPermissionUser() {
        try {
            String userId = UserInfo.getUserId();
            PermissionSetAssignment permissionSetAssignment = [SELECT Id, AssigneeId, PermissionSetId, PermissionSet.Name 
            FROM PermissionSetAssignment 
            WHERE AssigneeId = :userId 
              AND PermissionSet.Name = 'Time_Sheet_Management_Screen_Permission' 
              LIMIT 1];
            if(permissionSetAssignment != null)    {
                return true;
            } else {
                return false;
            }
   
        } catch (Exception e) {
            System.debug(e);
            return false;
        }
    }

    @AuraEnabled(cacheable=false)
    public static List<User> getActiveUser() {
        try {
            List<String> exceptUserList = new List<String>{'System',
                                            'ReleaseManager',
                                            'Site Guest User TerraSky_Thailand_ExperienceSite',
                                            'Process Automated',
                                            'Platform Integration User'};
            List<User> userList = [SELECT Id, Name, IsActive FROM User WHERE IsActive = TRUE AND Name NOT IN :exceptUserList ORDER BY Name ASC];

            return userList;
        } catch (Exception e) {
            System.debug(e);
            return new List<User>();
        }
    }

    @AuraEnabled
    public static List<Holiday> getHolidays(String year, String month) {
        try {
            Date tempDate = Date.valueOf(year + '-' + month + '-15');
            Integer numberOfDays = Date.daysInMonth(tempDate.year(), tempDate.month());

            Date startDateTemp = Date.newInstance(tempDate.year(), tempDate.month(), 1);
            Date endDateTemp = Date.newInstance(tempDate.year(), tempDate.month(), numberOfDays);

            List<Holiday> holidayList = [SELECT Id,
                                                Name,
                                                Description,
                                                ActivityDate
                                            FROM Holiday
                                            WHERE ActivityDate >= :startDateTemp
                                                AND ActivityDate <= :endDateTemp
                                            ORDER BY ActivityDate ASC
                                        ];
            return holidayList;
        } catch (Exception e) {
            System.debug(e.getMessage());
            return new List<Holiday>();
        }
    }

    @AuraEnabled
    public static List<ApplicationItem__c> getLeaveRequestes(String userId, String year, String month) {
        try {
            Id user = (Id)userId;
            Date tempDate = Date.valueOf(year + '-' + month + '-15');
            Integer numberOfDays = Date.daysInMonth(tempDate.year(), tempDate.month());

            Date startDateTemp = Date.newInstance(tempDate.year(), tempDate.month(), 1);
            Date endDateTemp = Date.newInstance(tempDate.year(), tempDate.month(), numberOfDays);

            List<ApplicationItem__c> applicationItem = [SELECT Id,
                                                                Name,
                                                                Term_From__c,
                                                                Request_Type__c,
                                                                Period_Leave__c,
                                                                Remark__c,
                                                                No_of_Days__c,
                                                                OwnerId,
                                                                Status__c
                                                            FROM ApplicationItem__c
                                                            WHERE OwnerId =:user
                                                                AND Status__c != 'Rejected'
                                                                AND Term_From__c >= :startDateTemp
                                                                AND Term_From__c <= :endDateTemp
                                                            ORDER BY Term_From__c ASC
                                                        ];
            return applicationItem;
        } catch (Exception e) {
            System.debug(e.getMessage());
            return new List<ApplicationItem__c>();
        }
    }

    @AuraEnabled
    public static List<Timestamp__c> getTimeStamps(String userId, String year, String month) {
        try {
            Id user = (Id)userId;
            Date tempDate = Date.valueOf(year + '-' + month + '-15');
            Integer numberOfDays = Date.daysInMonth(tempDate.year(), tempDate.month());

            Date startDateTemp = Date.newInstance(tempDate.year(), tempDate.month(), 1);
            Date endDateTemp = Date.newInstance(tempDate.year(), tempDate.month(), numberOfDays);

            List<Timestamp__c> stampedList = [SELECT Id,
                                                        Name,
                                                        Stamped_Date__c,
                                                        Stamped_TimeIn__c,
                                                        Stamped_TimeOut__c,
                                                        is_Manual_Edit_TimeIn__c,
                                                        is_Manual_Edit_TimeOut__c,
                                                        Stamped_Location__c,
                                                        Remark__c,
                                                        Maunal_Input_Reason__c,
                                                        WorkHour_Reason__c,
                                                        Overtime_Reason__c
                                                    FROM Timestamp__c
                                                    WHERE OwnerId =:user
                                                        AND Stamped_Date__c >= :startDateTemp
                                                        AND Stamped_Date__c <= :endDateTemp
                                                    ORDER BY Stamped_Date__c ASC
                                                ];

                                                System.debug(stampedList);
            return stampedList;
        } catch (Exception e) {
            System.debug(e.getMessage());
            return new List<Timestamp__c>();
        }
    }

    @AuraEnabled
    public static String createTimeStamps(String stampedDate, String timeIn, String timeOut, String remark, String manualInputReason, String workHourReason, String overTimeReason) {
        try {
            Date tempDate = Date.valueOf(stampedDate);

            Timestamp__c timestamp = new Timestamp__c(Stamped_Date__c = tempDate, Remark__c = remark, Maunal_Input_Reason__c = manualInputReason, WorkHour_Reason__c = workHourReason, Overtime_Reason__c = overTimeReason);
    
            if(!(timeIn == null && timeOut == null)) {
                if(timeIn != null) {
                    List<String> splitedTimeIn = timeIn.split(':');
                    timestamp.Stamped_TimeIn__c = Time.newInstance( Integer.valueOf(splitedTimeIn[0])  //hour
                                                                    ,Integer.valueOf(splitedTimeIn[1]) //min
                                                                    ,0                                 //sec
                                                                    ,0);                               //ms
                    timestamp.is_Manual_Edit_TimeIn__c = true;
                } else {
                    timestamp.Stamped_TimeIn__c = null;
                    timestamp.is_Manual_Edit_TimeIn__c = false;
                }
                
                if(timeOut != null) {
                    List<String> splitedTimeOut = timeOut.split(':');
                    timestamp.Stamped_TimeOut__c = Time.newInstance( Integer.valueOf(splitedTimeOut[0]) //hour
                                                                    ,Integer.valueOf(splitedTimeOut[1]) //min
                                                                    ,0                                  //sec
                                                                    ,0);                                //ms
                    timestamp.is_Manual_Edit_TimeOut__c = true;
                } else {
                    timestamp.Stamped_TimeOut__c = null;
                    timestamp.is_Manual_Edit_TimeOut__c = false;
                }

                insert timestamp;

                return 'success';
            } else {
                return 'Please enter Time In or Time Out';
            }
        } catch (Exception e) {
            System.debug(e.getMessage());
            return e.getMessage();
        }
    }

    @AuraEnabled
    public static String updateTimeStamps(String timestampNumber, Boolean isEditedTimeIn, Boolean isEditedTimeOut, String timeIn, String timeOut, String remark, String manualInputReason, String workHourReason, String overTimeReason) {
        try {
            Timestamp__c timestamp = [SELECT Id,
                                            Name,
                                            Stamped_Date__c,
                                            Stamped_TimeIn__c,
                                            Stamped_TimeOut__c,
                                            is_Manual_Edit_TimeIn__c,
                                            is_Manual_Edit_TimeOut__c,
                                            Stamped_Location__c,
                                            Remark__c,
                                            Maunal_Input_Reason__c,
                                            WorkHour_Reason__c,
                                            Overtime_Reason__c
                                        FROM Timestamp__c
                                        WHERE Name =:timestampNumber
                                        LIMIT 1
                                    ];
            timestamp.Remark__c = remark;
            timestamp.Maunal_Input_Reason__c = manualInputReason;
            timestamp.WorkHour_Reason__c = workHourReason;
            timestamp.Overtime_Reason__c = overTimeReason;
    
            if(!(timeIn == null && timeOut == null)) {
                if(timeIn != null) {
                    List<String> splitedTimeIn = timeIn.split(':');
                    timestamp.Stamped_TimeIn__c = Time.newInstance( Integer.valueOf(splitedTimeIn[0])  //hour
                                                                    ,Integer.valueOf(splitedTimeIn[1]) //min
                                                                    ,0                                 //sec
                                                                    ,0);                               //ms
                    timestamp.is_Manual_Edit_TimeIn__c = isEditedTimeIn;
                } else {
                    timestamp.Stamped_TimeIn__c = null;
                    timestamp.is_Manual_Edit_TimeIn__c = isEditedTimeIn;
                }
                
                if(timeOut != null) {
                    List<String> splitedTimeOut = timeOut.split(':');
                    timestamp.Stamped_TimeOut__c = Time.newInstance( Integer.valueOf(splitedTimeOut[0]) //hour
                                                                    ,Integer.valueOf(splitedTimeOut[1]) //min
                                                                    ,0                                  //sec
                                                                    ,0);                                //ms
                    timestamp.is_Manual_Edit_TimeOut__c = isEditedTimeOut;
                } else {
                    timestamp.Stamped_TimeOut__c = null;
                    timestamp.is_Manual_Edit_TimeOut__c = isEditedTimeOut;
                }
                update timestamp;
                return 'success';
            }
            
            if(remark != null) {
                update timestamp;
                return 'success';
            }
            return 'Please enter Time In or Time Out';
        } catch (Exception e) {
            System.debug(e.getMessage());
            return e.getMessage();
        }
    }
}