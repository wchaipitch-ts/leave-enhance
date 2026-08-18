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

            // Anything that overlaps the month, not just what starts inside it: a range
            // beginning in the previous month still covers days on this screen. A blank
            // Term_To__c is a single-day request, so it is matched on Term_From__c alone
            // — same convention as ApplicationItemTriggerLogic.endDateOf.
            List<ApplicationItem__c> applicationItem = [SELECT Id,
                                                                Name,
                                                                Term_From__c,
                                                                Term_To__c,
                                                                Request_Type__c,
                                                                Period_Leave__c,
                                                                Remark__c,
                                                                No_of_Days__c,
                                                                OwnerId,
                                                                Status__c
                                                            FROM ApplicationItem__c
                                                            WHERE OwnerId =:user
                                                                AND Status__c != 'Rejected'
                                                                AND Term_From__c <= :endDateTemp
                                                                AND (Term_To__c >= :startDateTemp
                                                                    OR (Term_To__c = null
                                                                        AND Term_From__c >= :startDateTemp))
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

    // ==================================================================== LEAVE-38
    /*
     * One call for everything the leave cards and the Leave Balance page need.
     *
     * The screens previously assembled themselves from getUserInfo plus a balance call
     * plus an overtime call, which is three round trips for one render and three chances
     * to show figures from different moments. getLeaveOverview returns the lot.
     *
     * Nothing above this line changed. getUserInfo still returns
     * User.Annual_Leave_Day__c, and anything still reading it keeps working until it is
     * moved across.
     *
     * The work is delegated rather than reimplemented: LeaveBalanceService owns the
     * balance rules and, importantly, the permission check that decides whether you may
     * look at somebody else's figures. Querying Leave_Balance__c directly from here
     * would bypass it.
     */

    public class EmployeeSummary {
        @AuraEnabled public Id      userId;
        @AuraEnabled public String  name;
        @AuraEnabled public String  employeeNumber;
        @AuraEnabled public String  title;
        @AuraEnabled public String  department;
        @AuraEnabled public String  managerName;
        @AuraEnabled public String  photoUrl;
        @AuraEnabled public Date    startDate;
        @AuraEnabled public Date    probationEndDate;
        /** Annual and Refreshment are withheld while true. Sick leave never is. */
        @AuraEnabled public Boolean onProbation;
    }

    public class LeaveOverview {
        @AuraEnabled public EmployeeSummary employee;
        @AuraEnabled public Integer year;
        @AuraEnabled public Integer month;
        /** Newest first, for the year picker. */
        @AuraEnabled public List<Integer> availableYears;
        /** Every type set to appear on the balance page, in policy sort order. */
        @AuraEnabled public List<LeaveBalanceService.LeaveBalanceView> balances;
        /** Approved overtime for the requested month only. */
        @AuraEnabled public Decimal overtimeHours;
        /*
         * The next service anniversary. Refreshment leave is granted on it - not on
         * 1 January, which is what the current card assumes and is only ever right for
         * a 1 January joiner.
         */
        @AuraEnabled public Date nextRefreshmentGrant;
        /*
         * Duplicated out of `balances` on purpose. This single figure is what the
         * timesheet card shows, and it is what replaces User.Annual_Leave_Day__c, so
         * lifting it here keeps that swap to one line.
         */
        @AuraEnabled public Decimal annualAvailable;
    }

    /**
     * @param employeeId whose figures; null means the running user
     * @param year       leave year; null means the current one
     * @param month      1-12, for the overtime total; null means the current month
     */
    @AuraEnabled(cacheable=true)
    public static LeaveOverview getLeaveOverview(Id employeeId, Integer year, Integer month) {
        /*
         * Deliberately not wrapped in the catch-and-return-null used above. A refused
         * lookup has to reach the user as a message about permission; swallowed, it
         * renders as an empty card and looks like missing data.
         */
        Date today = System.today();
        /*
         * LEAVE-39. Asserted here rather than left to the first balance call, which also
         * enforces it. Relying on that made the guard positional: reorder the four lines
         * below and it would disappear without a test noticing.
         */
        Id target = LeaveBalanceService.assertCanView(employeeId);
        Integer yr = year == null ? today.year() : year;
        Integer mo = month == null ? today.month() : month;

        LeaveOverview overview = new LeaveOverview();
        overview.year = yr;
        overview.month = mo;
        overview.balances = LeaveBalanceService.getBalances(target, yr);
        overview.availableYears = LeaveBalanceService.getAvailableYears(target);
        overview.overtimeHours = OvertimeSummaryService.getApprovedOvertimeHours(target, yr, mo);
        overview.employee = employeeSummary(target, today);
        overview.nextRefreshmentGrant =
            nextAnniversary(overview.employee.startDate, today);
        overview.annualAvailable = availableFor(overview.balances, 'Annual leave');
        return overview;
    }

    private static EmployeeSummary employeeSummary(Id target, Date today) {
        EmployeeSummary summary = new EmployeeSummary();
        for (User usr : [
            SELECT Id, Name, EmployeeNumber, Title, Department, Manager.Name,
                   MediumPhotoUrl, Start_Date__c, Probation_End_Date__c
            FROM User WHERE Id = :target LIMIT 1
        ]) {
            summary.userId           = usr.Id;
            summary.name             = usr.Name;
            summary.employeeNumber   = usr.EmployeeNumber;
            summary.title            = usr.Title;
            summary.department       = usr.Department;
            summary.managerName      = usr.Manager.Name;
            summary.photoUrl         = usr.MediumPhotoUrl;
            summary.startDate        = usr.Start_Date__c;
            summary.probationEndDate = usr.Probation_End_Date__c;
            summary.onProbation      = usr.Probation_End_Date__c != null
                                       && usr.Probation_End_Date__c >= today;
        }
        if (summary.userId == null) {
            summary.userId = target;
            summary.onProbation = false;
        }
        return summary;
    }

    private static Decimal availableFor(List<LeaveBalanceService.LeaveBalanceView> balances,
                                        String leaveType) {
        for (LeaveBalanceService.LeaveBalanceView view : balances) {
            if (leaveType.equals(view.leaveType)) {
                return view.available;
            }
        }
        return 0;
    }

    /*
     * The next time this employee's joining day comes round, today included. February 29
     * joiners fall on the 28th in a common year, which is the same concession the grant
     * engine makes so the anniversary is never skipped entirely.
     */
    private static Date nextAnniversary(Date startDate, Date today) {
        if (startDate == null) {
            return null;
        }
        Date thisYear = anniversaryIn(startDate, today.year());
        return thisYear >= today ? thisYear : anniversaryIn(startDate, today.year() + 1);
    }

    private static Date anniversaryIn(Date startDate, Integer yr) {
        Integer day = startDate.day();
        if (startDate.month() == 2 && day == 29 && !Date.isLeapYear(yr)) {
            day = 28;
        }
        return Date.newInstance(yr, startDate.month(), day);
    }

    // ==================================================================== list view
    /*
     * One call behind the three tabs on applicationItemListView: Leave, LWOP and OT.
     *
     * getLeaveRequestes above answers a different question — what overlaps one month of
     * the timesheet grid — so it is left alone. This is the record list: newest first,
     * every status including Rejected, capped rather than bounded by date.
     *
     * The three categories are kept disjoint so no request appears under two tabs.
     * Under the split model an over-balance request becomes two records - the shortened
     * paid one and an Unpaid leave continuation - so the request type is the whole test.
     * The tabs used to also read LWOP_Days__c, from the model LEAVE-33 replaced; that
     * field is deleted and its clause matched nothing, so it has gone with it.
     */

    public static final String CATEGORY_LEAVE = 'Leave';
    public static final String CATEGORY_LWOP  = 'LWOP';
    public static final String CATEGORY_OT    = 'OT';

    private static final Integer DEFAULT_LIMIT = 50;
    private static final Integer MAX_LIMIT     = 200;

    private static final String STATUS_DRAFT = 'Draft';

    /*
     * The row shape behind the three tabs. Shared with updateApplicationItem so an edit
     * hands the client back exactly the record it is already holding, rather than a
     * second field list that drifts from this one the first time either is changed.
     */
    private static final String ITEM_FIELDS =
        'Id, Name, RecordTypeId, RecordType.DeveloperName, Request_Type__c,'
      + ' Period_Leave__c, Term_From__c, Term_To__c, No_of_Days__c, Remark__c,'
      + ' Status__c, Split_From__c,'
      + ' OT_Start__c, OT_End__c, Overtime_Hours__c,'
      + ' OwnerId, Owner.Name, Owner.FirstName';

    /** Requests with no pay behind them, and its exact complement for the Leave tab. */
    private static final String IS_UNPAID     = 'Request_Type__c = \'Unpaid leave\'';
    private static final String IS_NOT_UNPAID = 'Request_Type__c != \'Unpaid leave\'';

    /**
     * @param category    Leave, LWOP or OT — see the CATEGORY_ constants
     * @param employeeId  whose requests; null means the running user
     * @param recordLimit how many rows; null means 50, and 200 is the ceiling
     */
    @AuraEnabled(cacheable=true)
    public static List<ApplicationItem__c> getApplicationItems(String category,
                                                              Id employeeId,
                                                              Integer recordLimit) {
        /*
         * Not swallowed into an empty list, for the same reason getLeaveOverview is not:
         * a refusal has to reach the user as a message about permission rather than as a
         * tab that looks merely empty.
         *
         * ApplicationItem__c is Public Read Only, so sharing alone would let anyone pass
         * any Id and read back somebody else's requests. Gated on the rule
         * LeaveBalanceService owns, as OvertimeSummaryService is, so the screens cannot
         * disagree about who may look at whom.
         */
        Id target = LeaveBalanceService.assertCanView(employeeId);
        Integer rowLimit = recordLimit == null || recordLimit <= 0
                           ? DEFAULT_LIMIT
                           : Math.min(recordLimit, MAX_LIMIT);

        // Bound to a local so it is a bind variable below, not concatenated text.
        String filter = filterFor(category);

        return Database.query(
            'SELECT ' + ITEM_FIELDS
          + ' FROM ApplicationItem__c'
          + ' WHERE OwnerId = :target AND ' + filter
          + ' ORDER BY Term_From__c DESC NULLS LAST, Name DESC'
          + ' LIMIT :rowLimit'
        );
    }

    /*
     * Every fragment returned here is a literal in this file. Nothing the caller sends
     * reaches the query text — an unrecognised category is refused rather than passed
     * through, so the dynamic SOQL above cannot be steered from the client.
     */
    private static String filterFor(String category) {
        if (CATEGORY_LEAVE.equalsIgnoreCase(category)) {
            // Written out rather than NOT (...) so the two tabs stay provable complements.
            return 'RecordType.DeveloperName = \'Leave_Request\' AND ' + IS_NOT_UNPAID;
        }
        if (CATEGORY_LWOP.equalsIgnoreCase(category)) {
            return 'RecordType.DeveloperName = \'Leave_Request\' AND ' + IS_UNPAID;
        }
        if (CATEGORY_OT.equalsIgnoreCase(category)) {
            return 'RecordType.DeveloperName = \'Overtime_Request\'';
        }
        throw new AuraHandledException(
            'Unknown request category "' + category + '". Expected Leave, LWOP or OT.');
    }

    // ==================================================================== editing
    /**
     * An employee correcting a request from the list view.
     *
     * Only a Draft can be changed. A Pending request is already in front of an approver,
     * and an Approved one has spent its balance and booked its days. The database
     * refuses that second case through Approved_Request_Is_Locked, but nothing refuses
     * the first, and the approval process's own record lock does not apply to Apex
     * running in system mode — so the status is re-read here and checked against the
     * database rather than trusted from the payload.
     *
     * The editable fields are taken exactly as posted, blanks included: clearing
     * Term_To__c is how a range becomes a single-day request. Remark__c is required at
     * the schema level, so posting it blank is refused by the database rather than
     * silently ignored here — the message reaches the user through the DmlException
     * catch below. Everything else on the record — Status__c, OwnerId, the split lookup,
     * the balance lookup, the calculated day counts — belongs to the approval path and the
     * triggers and is not writable from a client. That is a whitelist rather than a
     * blacklist because this class runs without sharing and no profile in this org holds
     * edit access on ApplicationItem__c at all: an update assembled from whatever was
     * posted would write every field it named, field-level security included.
     *
     * @param editedApplicationItem Id plus the editable fields. The rest is ignored.
     * @return the saved record, in the same shape getApplicationItems returns. Worth
     *         reading back rather than assuming the edit landed verbatim: the triggers
     *         recount the days, and LeaveSplitService can shorten a request that no
     *         longer fits the balance and raise the remainder as its own Unpaid record.
     */
    @AuraEnabled
    public static ApplicationItem__c updateApplicationItem(ApplicationItem__c editedApplicationItem) {
        if (editedApplicationItem == null || editedApplicationItem.Id == null) {
            throw new AuraHandledException('A request Id is required.');
        }

        List<ApplicationItem__c> found = [
            SELECT Id, OwnerId, Status__c, RecordTypeId
            FROM ApplicationItem__c
            WHERE Id = :editedApplicationItem.Id
            LIMIT 1
        ];
        if (found.isEmpty()) {
            throw new AuraHandledException('That request no longer exists.');
        }
        ApplicationItem__c existing = found[0];

        /*
         * Gated on the rule LeaveBalanceService owns, exactly as getApplicationItems and
         * getLeaveOverview are: your own requests always, somebody else's only with the
         * permission that unlocks the timesheet's user picker.
         */
        LeaveBalanceService.assertCanView(existing.OwnerId);

        if (!STATUS_DRAFT.equals(existing.Status__c)) {
            throw new AuraHandledException('Only a Draft request can be edited. This one is '
                + existing.Status__c + '.');
        }

        ApplicationItem__c toSave = new ApplicationItem__c(Id = existing.Id);
        toSave.Term_From__c = editedApplicationItem.Term_From__c;
        toSave.Term_To__c   = editedApplicationItem.Term_To__c;
        toSave.Remark__c    = editedApplicationItem.Remark__c;

        // An overtime claim is a clock window on a date; a leave request is a type and a
        // period. Neither set means anything on the other record type, so a payload
        // carrying the wrong one has it ignored rather than saved.
        if (ApplicationItemTriggerHandler.isOvertimeRequest(existing)) {
            toSave.OT_Start__c = editedApplicationItem.OT_Start__c;
            toSave.OT_End__c   = editedApplicationItem.OT_End__c;
        } else {
            toSave.Request_Type__c = editedApplicationItem.Request_Type__c;
            toSave.Period_Leave__c = editedApplicationItem.Period_Leave__c;
        }

        try {
            update toSave;
        } catch (DmlException e) {
            /*
             * The validation rules carry the message the user actually needs — the
             * probation block, the no-year-span rule, the required-field rule. Left raw,
             * a DmlException reaches the browser with that message buried in a stack
             * trace, so it is lifted out here.
             */
            throw new AuraHandledException(
                e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage());
        }

        Id recordId = existing.Id;
        List<ApplicationItem__c> saved = Database.query(
            'SELECT ' + ITEM_FIELDS + ' FROM ApplicationItem__c WHERE Id = :recordId LIMIT 1');
        return saved.isEmpty() ? null : saved[0];
    }
}