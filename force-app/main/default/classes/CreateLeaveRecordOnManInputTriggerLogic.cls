public class CreateLeaveRecordOnManInputTriggerLogic {

    private static final Decimal AM_HOURS       = 3.5;   // 08:30 - 12:00
    private static final Decimal PM_HOURS       = 4.0;   // 13:00 - 17:00
    private static final Decimal FULL_DAY_HOURS = 7.5;

    /*
     * One booking: a request paired with one of the working days it covers.
     * A single-day request produces one; a range produces one per working day.
     */
    private class LeaveDay {
        ApplicationItem__c appl;
        Date performedOn;
        Boolean singleDay;
        LeaveDay(ApplicationItem__c appl, Date performedOn, Boolean singleDay) {
            this.appl = appl;
            this.performedOn = performedOn;
            this.singleDay = singleDay;
        }
    }

    // Single-record entry point, retained for existing callers and tests.
    public void createLeaveRecord(ApplicationItem__c appl) {
        createLeaveRecords(new List<ApplicationItem__c>{ appl });
    }

    /*
     * LEAVE-11: bulkified. Previously every record ran its own SOQL for the project
     * assignment, its own SOQL for the project, and up to three separate inserts,
     * so a batch of any size exhausted the query limit before the DML limit.
     *
     * LEAVE-26: multi-day. A request is now expanded into one Man_hour__c per working
     * day. Before this, a five-day leave booked a single 7.5h record instead of 37.5h,
     * which understated the timesheet by the whole rest of the range — and disagreed
     * with the calendar Events, which were already one per day.
     *
     * Each booking needs a Man_hour__c hung off a ProjectAssign__c, which hangs off a
     * per-year "Leave FYxx" Project__c. Any of the three may be missing, so the work
     * runs in three passes: resolve or create projects, then resolve or create
     * assignments, then insert the man hours. A range crossing a month boundary needs
     * an assignment in each month, which is why pass 2 keys on the booking date rather
     * than on the request.
     */
    public void createLeaveRecords(List<ApplicationItem__c> applications) {
        List<ApplicationItem__c> approved = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : applications) {
            if (appl != null && appl.Status__c == 'Approved' && appl.Term_From__c != null) {
                approved.add(appl);
            }
        }
        if (approved.isEmpty()) {
            return;
        }

        // Weekends and dated Holiday records are skipped by workingDaysFor, which is
        // shared with the day count and the calendar Events so the three agree.
        Set<Date> holidays = ApplicationItemTriggerLogic.holidaysForBatch(approved);
        List<LeaveDay> bookings = new List<LeaveDay>();
        for (ApplicationItem__c appl : approved) {
            Boolean singleDay = (appl.Term_To__c == null || appl.Term_To__c == appl.Term_From__c);
            for (Date d : ApplicationItemTriggerLogic.workingDaysFor(appl, holidays)) {
                bookings.add(new LeaveDay(appl, d, singleDay));
            }
        }
        if (bookings.isEmpty()) {
            return;
        }

        Set<String> projectNames = new Set<String>();
        Set<Id> ownerIds = new Set<Id>();
        Map<String, Date> anyDateForProject = new Map<String, Date>();
        for (LeaveDay booking : bookings) {
            String name = projectNameFor(booking.performedOn);
            projectNames.add(name);
            ownerIds.add(booking.appl.OwnerId);
            anyDateForProject.put(name, booking.performedOn);
        }

        List<ProjectAssign__c> existingAssigns = [
            SELECT Id, Project_Name__c, Assignee__c, Start_Date__c, Due_Date__c
            FROM ProjectAssign__c
            WHERE Project_Name__c IN :projectNames
              AND Assignee__c IN :ownerIds
            ORDER BY Id
        ];

        Map<String, Project__c> projectByName = new Map<String, Project__c>();
        for (Project__c p : [
            SELECT Id, Project_Name__c FROM Project__c
            WHERE Project_Name__c IN :projectNames ORDER BY Id
        ]) {
            if (!projectByName.containsKey(p.Project_Name__c)) {
                projectByName.put(p.Project_Name__c, p);
            }
        }

        // Pass 1 - create any missing yearly leave project
        List<Project__c> newProjects = new List<Project__c>();
        for (String name : projectNames) {
            if (projectByName.containsKey(name)) {
                continue;
            }
            Date sample = anyDateForProject.get(name);
            newProjects.add(new Project__c(
                OwnerId           = UserInfo.getUserId(),
                RecordTypeId      = nonChargedRecordTypeId(),
                Project_Name__c   = name,
                Remark__c         = 'for Leave in FY' + twoDigitYear(sample),
                Project_Detail__c = 'for user input a Leave record',
                Start_Date__c     = Date.newInstance(sample.year(), 1, 1),
                Close_Date__c     = Date.newInstance(sample.year(), 12, 31)
            ));
        }
        if (!newProjects.isEmpty()) {
            insert newProjects;
            for (Project__c p : newProjects) {
                projectByName.put(p.Project_Name__c, p);
            }
        }

        // Pass 2 - resolve one assignment per project / owner / month of the booking
        Map<String, ProjectAssign__c> assignByKey = new Map<String, ProjectAssign__c>();
        Map<String, ProjectAssign__c> assignsToCreate = new Map<String, ProjectAssign__c>();
        for (LeaveDay booking : bookings) {
            String name = projectNameFor(booking.performedOn);
            Date monthStart = booking.performedOn.toStartOfMonth();
            Date monthEnd = Date.newInstance(
                monthStart.year(), monthStart.month(),
                Date.daysInMonth(monthStart.year(), monthStart.month())
            );
            String key = assignKey(name, booking.appl.OwnerId, monthStart);
            if (assignByKey.containsKey(key) || assignsToCreate.containsKey(key)) {
                continue;
            }

            ProjectAssign__c match = findAssign(existingAssigns, name, booking.appl.OwnerId, monthStart, monthEnd);
            if (match != null) {
                assignByKey.put(key, match);
                continue;
            }

            Project__c parent = projectByName.get(name);
            if (parent == null) {
                continue;
            }
            assignsToCreate.put(key, new ProjectAssign__c(
                Assignee__c   = booking.appl.OwnerId,
                Project_No__c = parent.Id,
                Start_Date__c = monthStart,
                Due_Date__c   = monthEnd
            ));
        }
        if (!assignsToCreate.isEmpty()) {
            insert assignsToCreate.values();
            assignByKey.putAll(assignsToCreate);
        }

        // Pass 3 - one man hour record per booked working day
        List<Man_hour__c> manHours = new List<Man_hour__c>();
        for (LeaveDay booking : bookings) {
            String key = assignKey(
                projectNameFor(booking.performedOn),
                booking.appl.OwnerId,
                booking.performedOn.toStartOfMonth()
            );
            ProjectAssign__c assign = assignByKey.get(key);
            if (assign == null) {
                continue;
            }
            // Period_Leave__c is only meaningful on a single-day request; every day of
            // a range is a full day.
            manHours.add(new Man_hour__c(
                Performed_Date__c   = booking.performedOn,
                Performed_Hours__c  = booking.singleDay
                    ? hoursFor(booking.appl.Period_Leave__c)
                    : FULL_DAY_HOURS,
                ProjectAssign_No__c = assign.Id,
                Work__c             = booking.appl.Request_Type__c,
                Remark__c           = booking.appl.Remark__c
            ));
        }
        if (!manHours.isEmpty()) {
            insert manHours;
        }
    }

    /*
     * Mirrors the original overlap test: an assignment counts as covering the month
     * if either end of it falls inside that month.
     */
    private ProjectAssign__c findAssign(List<ProjectAssign__c> assigns, String name,
                                        Id ownerId, Date monthStart, Date monthEnd) {
        for (ProjectAssign__c pa : assigns) {
            if (pa.Project_Name__c != name || pa.Assignee__c != ownerId) {
                continue;
            }
            Boolean startsInMonth = pa.Start_Date__c != null
                && pa.Start_Date__c >= monthStart && pa.Start_Date__c <= monthEnd;
            Boolean endsInMonth = pa.Due_Date__c != null
                && pa.Due_Date__c >= monthStart && pa.Due_Date__c <= monthEnd;
            if (startsInMonth || endsInMonth) {
                return pa;
            }
        }
        return null;
    }

    private static String assignKey(String projectName, Id ownerId, Date monthStart) {
        return projectName + '|' + ownerId + '|' + monthStart;
    }

    private static String twoDigitYear(Date d) {
        return String.valueOf(d.year()).substring(2, 4);
    }

    private static String projectNameFor(Date d) {
        return 'Leave FY' + twoDigitYear(d);
    }

    private static Decimal hoursFor(String periodLeave) {
        if ('AM leave' == periodLeave) {
            return AM_HOURS;
        }
        if ('PM leave' == periodLeave) {
            return PM_HOURS;
        }
        return FULL_DAY_HOURS;
    }

    private static Id nonChargedRecordTypeId() {
        return Schema.SObjectType.Project__c
            .getRecordTypeInfosByDeveloperName()
            .get('non_Charged')
            .getRecordTypeId();
    }
}
