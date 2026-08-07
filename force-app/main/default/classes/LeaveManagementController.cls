public with sharing class LeaveManagementController implements Schedulable {
    
    // TestVisible variable to allow testing different modes without relying on actual Custom Labels
    @TestVisible private static String testMode;

    // Method to increment Annual_Leave_Allocated__c for specific Users
    public static void adjustAnnualLeaveDay() {

        try {
            /* 
             * 2025/12/15 fix for Annual leave logic:
             * Implementation Update:
             * 1. Logic now updates 'Annual_Leave_Allocated__c' instead of 'Annual_Leave_Day__c'.
             * 2. Calculation Mode defaults to 'Anniversary' if no Custom Label is found.
             */

            // 1. Get Calculation Mode
            // Priority: Test Variable -> Custom Label -> Default 'Anniversary'
            String calculationMode = 'Anniversary'; // Default to Anniversary
            
            // Check for Test Mode first
            if (testMode != null) {
                calculationMode = testMode;
            } else {
                // Check Custom Label
                try {
                    // Implementation: Check if the custom label exists and use its value
                    String labelMode = System.Label.Leave_Calculation_Mode;
                    if (String.isNotBlank(labelMode)) {
                        calculationMode = labelMode;
                    }
                } catch (Exception e) {
                    // Implementation: If label is missing or throws error, we catch it here and keep the default 'Anniversary'
                    System.debug('Label Leave_Calculation_Mode not found or error accessing it, defaulting to Anniversary mode.');
                }
            }
            
            Date today = System.today();
            List<User> userList = new List<User>();

            // 2. Query Users based on Mode
            if (calculationMode == 'CalendarYear') {
                // Calendar Year Mode: Run only on Jan 1st for ALL active users
                if ((today.day() == 1 && today.month() == 1) || testMode != null) {
                    // 2025/12/15 fix: Changed field from Annual_Leave_Day__c to Annual_Leave_Allocated__c
                    // 2025/12/15 fix update: Added Annual_Leave_Day__c back to query validation for carry over logic
                    userList = [SELECT Id, Name, Annual_Leave_Allocated__c, Annual_Leave_Day__c, Start_Date__c FROM User WHERE IsActive = TRUE AND Start_Date__c != NULL];
                }
            } else {
                /*
                 * 2025/12/15 fix:
                 * Implementation Update:
                 * Anniversary Mode assumes this job is scheduled to run on the 1st of each month.
                 * It checks for users with anniversaries in the current month.
                 */
                // Anniversary Mode (Default)
                Integer currentMonth = today.month();
                Integer sixMonthsAgoMonth = today.addMonths(-6).month();
                
                // 2025/12/15 fix: Changed field from Annual_Leave_Day__c to Annual_Leave_Allocated__c
                // 2025/12/15 fix update: Added Annual_Leave_Day__c back to query validation for carry over logic
                userList = [
                    SELECT Id, Name, Annual_Leave_Allocated__c, Annual_Leave_Day__c, Start_Date__c 
                    FROM User 
                    WHERE IsActive = TRUE 
                    AND Start_Date__c != NULL
                    AND (CALENDAR_MONTH(Start_Date__c) = :currentMonth OR CALENDAR_MONTH(Start_Date__c) = :sixMonthsAgoMonth)
                ];
            }

            System.debug('Processing ' + userList.size() + ' users in mode: ' + calculationMode);

            List<User> usersToUpdate = new List<User>();
            String logDetails = 'Run Date: ' + System.now() + '\nMode: ' + calculationMode + '\n--------------------------------------\n';

            for (User usr : userList) {
                // 3. Calculate Tenure (Month-Based)
                Date effectiveStartDate = usr.Start_Date__c.toStartOfMonth();
                Date effectiveToday = today.toStartOfMonth();
                
                Integer monthsWorked = effectiveStartDate.monthsBetween(effectiveToday);
                
                System.debug('User: ' + usr.Name + ' | Start: ' + effectiveStartDate + ' | Today: ' + effectiveToday + ' | Months Worked: ' + monthsWorked);

                // Skip if tenure is negative (future start date)
                if (monthsWorked < 6) continue;

                // 4. Determine Entitlement
                Decimal newEntitlement = 0;
                boolean isGrantDue = false;

                // Logic for Anniversary Mode
                if (calculationMode != 'CalendarYear') {
                    // 6-Month Grant
                    if (monthsWorked == 6) {
                        System.debug('>> Granting 3 days (6 month tenure)');
                        newEntitlement = 3;
                        isGrantDue = true;
                    } 
                    // Annual Grants
                    else if (Math.mod(monthsWorked, 12) == 0 && monthsWorked >= 12) {
                        System.debug('>> Granting Annual Leave. Tenure: ' + monthsWorked);
                        if (monthsWorked >= 12 && monthsWorked < 36) {
                            newEntitlement = 6;
                        }
                        else if (monthsWorked >= 36 && monthsWorked < 72) {
                            newEntitlement = 8;
                        }
                        else if (monthsWorked >= 72) {
                            newEntitlement = 10;
                        }
                        isGrantDue = true;
                    } else {
                        System.debug('>> NO GRANT. Months (' + monthsWorked + ') is not 6 and not a multiple of 12 (Mod: ' + Math.mod(monthsWorked, 12) + ').');
                    }
                } 
                // Logic for Calendar Year Mode
                else {
                    if (monthsWorked >= 6 && monthsWorked < 12) newEntitlement = 3;
                    else if (monthsWorked >= 12 && monthsWorked < 36) newEntitlement = 6;
                    else if (monthsWorked >= 36 && monthsWorked < 72) newEntitlement = 8;
                    else if (monthsWorked >= 72) newEntitlement = 10;
                    
                    isGrantDue = true;
                }

                if (isGrantDue) {
                    // 5. Carry Over Logic
                    /* 
                     * 2025/12/15 fix: 
                     * Implementation: Logic now reads 'Annual_Leave_Day__c' (Remaining Balance) for carry over calculation.
                     * Maximum carry over is capped at 6 days.
                     * Updates are written to 'Annual_Leave_Allocated__c'.
                     * ALSO updates 'Annual_Leave_Day__c' to match the new allocation to prevent discrepancies.
                     */
                    Decimal currentBalance = (usr.Annual_Leave_Day__c != null) ? usr.Annual_Leave_Day__c : 0;
                    Decimal carryOver = (currentBalance > 6) ? 6 : currentBalance;
                    
                    usr.Annual_Leave_Allocated__c = carryOver + newEntitlement;
                    usr.Annual_Leave_Day__c = usr.Annual_Leave_Allocated__c; // Sync Balance
                    usersToUpdate.add(usr);
                    
                    String userLog = 'User: ' + usr.Name + ' (' + usr.Id + ')\n' +
                                     'Start Date: ' + usr.Start_Date__c + '\n' +
                                     'Tenure (Months): ' + monthsWorked + '\n' +
                                     'Old Balance: ' + currentBalance + '\n' +
                                     'Carry Over: ' + carryOver + '\n' +
                                     'New Entitlement: ' + newEntitlement + '\n' +
                                     'New Allocation: ' + usr.Annual_Leave_Allocated__c + '\n' +
                                     '--------------------------------------\n';
                    logDetails += userLog;
                    
                    System.debug('Updated User: ' + usr.Name + ' | Remaining Balance: ' + currentBalance + ' | CarryOver: ' + carryOver + ' | New Entitlement: ' + newEntitlement + ' | New Allocation: ' + usr.Annual_Leave_Allocated__c + ' | New Balance: ' + usr.Annual_Leave_Day__c);
                }
            }

            if (!usersToUpdate.isEmpty()) {
                update usersToUpdate;
                
                // Logging Implementation (Async to avoid Mixed DML with User object)
                createLogFile(logDetails);
            }

        } catch(Exception e) {
            System.debug('An unexpected error has occurred: ' + e.getMessage() + '\n' + e.getStackTraceString());
            // Rethrow exception in tests to ensure we catch logic/configuration errors (like missing Picklist values)
            if (Test.isRunningTest()) throw e;
        }
    }

    @future
    private static void createLogFile(String logDetails) {
        try {
            Error_Log__c log = new Error_Log__c();
            log.Process_Type__c = 'Annual Leave Calculation';
            insert log;
            
            ContentVersion cv = new ContentVersion();
            cv.Title = 'Leave_Calculation_Log_' + System.now().format('yyyyMMdd_HHmmss');
            cv.PathOnClient = 'Log_' + System.now().format('yyyyMMdd_HHmmss') + '.txt';
            cv.VersionData = Blob.valueOf(logDetails);
            cv.FirstPublishLocationId = log.Id;
            insert cv;
        } catch (Exception e) {
            System.debug('Failed to create log file: ' + e.getMessage());
        }
    }

    public void execute(SchedulableContext sc) {
        adjustAnnualLeaveDay();
    }
}