/**
 * @description Invocable Apex to calculate and set the First Response Due Date
 * based on Case Priority and custom SLA times.
 * This version uses a continuous clock for Urgent cases and business hours for Regular cases.
 */
public class FirstResponseSLACalculator {

    @InvocableMethod(label='Calculate First Response Due Date' description='Calculates and sets the first response due date on a Case record.')
    public static void calculateFirstResponseDueDate(List<Id> caseIds) {
        try {
            if (caseIds == null || caseIds.isEmpty()) {
                System.debug('No valid record ID provided.');
                return;
            }

            System.debug('Input caseIds: ' + caseIds);

            // Fetch TSTH Case Handling Business Hours
            List<BusinessHours> bhList;
            if (Test.isRunningTest()) {
                bhList = [SELECT Id, TimeZoneSidKey FROM BusinessHours WHERE IsDefault = true LIMIT 1];
            } else {
                bhList = [SELECT Id, TimeZoneSidKey FROM BusinessHours WHERE Name = 'TSTH Case Handling' LIMIT 1];
            }

            if (bhList.isEmpty()) {
                String errorMsg = 'Critical Error: Business Hours record not found. Please ensure "TSTH Case Handling" exists or a default is set.';
                System.debug(errorMsg);
                return;
            }
            BusinessHours bh = bhList[0];
            System.debug('Using BusinessHours: ' + bh.Id + ' (Timezone: ' + bh.TimeZoneSidKey + ')');

            // Get SLA hours from Custom Labels as fallbacks
            Decimal urgentSlaLabelHours = Decimal.valueOf(System.Label.FirstReponse_Urgent);
            Decimal regularSlaLabelHours = Decimal.valueOf(System.Label.FirstReponse_Other);
            System.debug('Fallback SLA (Urgent): ' + urgentSlaLabelHours + ' hours');
            System.debug('Fallback SLA (Regular): ' + regularSlaLabelHours + ' hours');

            List<Case> casesToUpdate = new List<Case>();
            List<Case> cases = [
                SELECT Id, CreatedDate, Priority, First_Response_Due_Date__c,
                       AccountId, Account.Name, Account.SLA_Number__c, 
                       Account.First_Response_SLA_Regular_Hours__c
                FROM Case
                WHERE Id IN :caseIds
            ];
            System.debug('Fetched Cases: ' + cases.size());

            for (Case c : cases) {
                System.debug('---');
                System.debug('Processing Case Id: ' + c.Id + ', Priority: ' + c.Priority);            

                Decimal slaHours;
                Datetime slaDueDate;

                if (c.Priority == 'Urgent') {
                    System.debug('Urgent case detected.');
                    if (c.Account != null) {
                        System.debug('Account linked: ' + c.Account.Name);
                        System.debug('SLA_Number__c: ' + c.Account.SLA_Number__c);
                    } else {
                        System.debug('No Account linked to this case.');
                    }

                    if (c.Account != null && c.Account.SLA_Number__c != null && c.Account.SLA_Number__c > 0) {
                        slaHours = c.Account.SLA_Number__c;
                        System.debug('Using Account SLA_Number__c: ' + slaHours);
                    } else {
                        slaHours = urgentSlaLabelHours;
                        System.debug('Using fallback SLA from label (Urgent): ' + slaHours);
                    }

                    slaDueDate = c.CreatedDate.addHours(slaHours.intValue());
                    System.debug('Calculated Urgent SLA DueDate: ' + slaDueDate);

                } else { // Regular / other priorities
                    System.debug('Regular or other priority case detected.');
                    if (c.Account != null) {
                        System.debug('Account linked: ' + c.Account.Name);
                        System.debug('First_Response_SLA_Regular_Hours__c: ' + c.Account.First_Response_SLA_Regular_Hours__c);
                    } else {
                        System.debug('No Account linked to this case.');
                    }

                    if (c.Account != null && c.Account.First_Response_SLA_Regular_Hours__c != null && c.Account.First_Response_SLA_Regular_Hours__c > 0) {
                        slaHours = c.Account.First_Response_SLA_Regular_Hours__c;
                        System.debug('Using Account First_Response_SLA_Regular_Hours__c: ' + slaHours);
                    } else {
                        slaHours = regularSlaLabelHours;
                        System.debug('Using fallback SLA from label (Regular): ' + slaHours);
                    }

                    slaDueDate = BusinessHours.add(
                        bh.Id,
                        c.CreatedDate,
                        slaHours.longValue() * 60 * 60 * 1000L
                    );
                    System.debug('Calculated Regular SLA DueDate: ' + slaDueDate);
                }

                c.First_Response_Due_Date__c = slaDueDate;
                casesToUpdate.add(c);
            }

            if (!casesToUpdate.isEmpty()) {
                update casesToUpdate;
                System.debug('Updated cases: ' + casesToUpdate.size());
            } else {
                System.debug('No cases needed updating.');
            }

        } catch (QueryException qe) {
            System.debug('Query Error: ' + qe.getMessage());
        } catch (Exception e) {
            System.debug('General Error: ' + e.getMessage());
        }
    }
}