public with sharing class TimestampController {

    private static final string CHECK_IN = 'in';
    private static final string CHECK_OUT = 'out';
    private static final string REMARKS_WORKEDHOURS = 'WorkHour under 7.5 Hours Reason';  //Added by TSJP Raman
    private static final string REMARKS_OVERTIME = 'Over Time Reason';  //Added by TSJP Raman
    private static final string REMARKS_LATECHECKIN = 'Late Check-In Reason';  //Added by TSJP Raman

    public class CurrentTimeDisplay {
        @AuraEnabled
        public integer hours { get; set; }

        @AuraEnabled
        public integer minutes { get; set; }
    }

    @AuraEnabled
    public static List<Timestamp__c> checkTimeRecord(Id userId) {
        //Added remark fields in query by TSJP Raman
        List<Timestamp__c> stampedObjectList = [SELECT Id, Name, Stamped_TimeIn__c, Stamped_TimeOut__c, Remark__c, Maunal_Input_Reason__c, Overtime_Reason__c, WorkHour_Reason__c FROM Timestamp__c WHERE OwnerId = :userId AND Stamped_Date__c = TODAY];
        return stampedObjectList;
    }

    @AuraEnabled
    public static string setTimeStamp(Id userId, String type, Double latitude, Double longitude, string remarks) {
        try {
            // Set Today Date and Current Time for Save and Update 
            Date dateValue = Date.today();
            Datetime dateTimeNow = Datetime.now();
            Time timeNow = Time.newInstance(dateTimeNow.hour(), dateTimeNow.minute(), dateTimeNow.second(), dateTimeNow.millisecond());

            List<Timestamp__c> stampedTimeList = checkTimeRecord(userId);

            Location stampedLocation = null;
            if(latitude != null && longitude != null) {
                stampedLocation = Location.newInstance(latitude, longitude);
            }

            if(stampedTimeList.size() == 0) {
                registerTimeStamp(userId, type, timeNow, dateValue, stampedLocation, remarks); //Added remark fields in param by TSJP Raman
            } else {
                //20251006 TSJP Raman Start Process To Avoid Double Checkin/out 
                if((type == REMARKS_LATECHECKIN || type == CHECK_IN) && stampedTimeList[0].Stamped_TimeIn__c != null) {
                    return 'DOUBLE_CHECKIN';
                } else if((type == REMARKS_OVERTIME || type == REMARKS_WORKEDHOURS || type == CHECK_OUT) && stampedTimeList[0].Stamped_TimeOut__c != null) {
                    return 'DOUBLE_CHECKOUT';
                } else {
                    updateTimeStamp(stampedTimeList, type, timeNow, stampedLocation, remarks); //Added remark fields in param by TSJP Raman
                }
                //20251006 TSJP Raman End Process To Avoid Double Checkin/out 
            }
            return 'SUCCESS';
        } catch (Exception e) {
            System.debug(e.getMessage());
            return 'ERROR';
        }
    }

    private static void registerTimeStamp(Id userId, String type, Time timeNow, Date dateValue, Location stampedLocation, string remarks) {
        Timestamp__c timeStamp = new Timestamp__c(
            Stamped_Date__c = dateValue,
            OwnerId = userId
        );

        if (type == CHECK_IN) {
            timeStamp.Stamped_TimeIn__c = timeNow;
        } else if (type == CHECK_OUT) {
            timeStamp.Stamped_TimeOut__c = timeNow;
        } 
        
        //Added by TSJP Raman - Start
        else if (type == REMARKS_WORKEDHOURS) {
            timeStamp.Stamped_TimeOut__c = timeNow;
            timeStamp.WorkHour_Reason__c = remarks;
        } else if(type == REMARKS_OVERTIME) {
            timeStamp.Stamped_TimeOut__c = timeNow;
            timeStamp.Overtime_Reason__c = remarks;

        //202051002 Modified by Raman Start
        } else if(type == REMARKS_LATECHECKIN) {
            timeStamp.Stamped_TimeIn__c = timeNow;
            timeStamp.Maunal_Input_Reason__c = remarks;
        } else {
            timeStamp.Stamped_TimeIn__c = timeNow;
        }
        //202051002 Modified by Raman End
        
        timeStamp.Remark__c = remarks;
        //Added by TSJP Raman - End

        if(stampedLocation != null) {
            timeStamp.Stamped_Location__latitude__s = stampedLocation.getLatitude();
            timeStamp.Stamped_Location__longitude__s = stampedLocation.getLongitude();
        }
        
        insert timeStamp;  
    }


    private static void updateTimeStamp(List<Timestamp__c> stampedTimeList, String type, Time timeNow, Location stampedLocation, string remarks) {
        for (Timestamp__c stampedTime : stampedTimeList) {
            stampedTime.Stamped_TimeOut__c = timeNow;

            if (type == CHECK_IN) {
                stampedTime.Stamped_TimeIn__c = timeNow;
            } else if (type == CHECK_OUT) {
                stampedTime.Stamped_TimeOut__c = timeNow;
            } 
            
            //Added by TSJP Raman - Start
            else if (type == REMARKS_WORKEDHOURS) {
                stampedTime.Stamped_TimeOut__c = timeNow;
                stampedTime.WorkHour_Reason__c = remarks;
            } else if(type == REMARKS_OVERTIME) {
                stampedTime.Stamped_TimeOut__c = timeNow;
                stampedTime.Overtime_Reason__c = remarks;
            
            //202051002 Modified by Raman Start
            } else if(type == REMARKS_LATECHECKIN) {
                stampedTime.Stamped_TimeIN__c = timeNow;
                stampedTime.Maunal_Input_Reason__c = remarks;
            } else {
                stampedTime.Stamped_TimeOut__c = timeNow;
            }
            //202051002 Modified by Raman End

            if(stampedTime.Remark__c != null) {
                stampedTime.Remark__c += '\r\n' + remarks;
            }
            //Added by TSJP Raman - End

            if(stampedLocation != null) {
                stampedTime.Stamped_Location__latitude__s = stampedLocation.getLatitude();
                stampedTime.Stamped_Location__longitude__s = stampedLocation.getLongitude();
            }
        }
        update stampedTimeList;
    }

    @AuraEnabled
    public static CurrentTimeDisplay getCurrentDateTimeForDisplay(){
        Datetime dateTimeNow = Datetime.now();
        CurrentTimeDisplay currentTimeDisplay = new CurrentTimeDisplay();
        currentTimeDisplay.hours = dateTimeNow.hour();
        currentTimeDisplay.minutes = dateTimeNow.minute();
        return currentTimeDisplay;
    }
}