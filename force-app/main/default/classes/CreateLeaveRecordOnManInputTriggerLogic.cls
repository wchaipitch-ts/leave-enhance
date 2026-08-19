public class CreateLeaveRecordOnManInputTriggerLogic {

    private static final Decimal AM_HOURS       = 3.5;   // 08:30 - 12:00
    private static final Decimal PM_HOURS       = 4.0;   // 13:00 - 17:00
    private static final Decimal FULL_DAY_HOURS = 7.5;

    private static final String KIND_LEAVE    = 'Leave';
    private static final String KIND_OVERTIME = 'Overtime';

    /*
     * One booking: a request paired with one of the dates it covers, and the hours
     * that date is worth.
     *
     * generalised this from the old leave-only LeaveDay. Leave and overtime
     * differ only in which dates they expand to, how many hours each date carries and
     * which yearly project they hang off; the machinery that resolves the project, the
     * monthly assignment and the Man_hour__c is identical, and duplicating it was the
     * alternative.
     */
    private class Booking {
        ApplicationItem__c appl;
        Date performedOn;
        Decimal hours;
        String kind;   // KIND_LEAVE or KIND_OVERTIME - picks the yearly project
        String work;   // what lands in Man_hour__c.Work__c
        Id projectId;  // filled in by resolveProjects before the assignment is looked up
        Booking(ApplicationItem__c appl, Date performedOn, Decimal hours, String kind, String work) {
            this.appl = appl;
            this.performedOn = performedOn;
            this.hours = hours;
            this.kind = kind;
            this.work = work;
        }
    }

    // Single-record entry point, retained for existing callers and tests.
    public void createLeaveRecord(ApplicationItem__c appl) {
        createLeaveRecords(new List<ApplicationItem__c>{ appl });
    }

    /*
     * — the entry point the trigger uses. A batch can hold both kinds, so it
     * is split by record type here rather than making the caller do it twice.
     */
    public void createBookings(List<ApplicationItem__c> applications) {
        List<ApplicationItem__c> leave = new List<ApplicationItem__c>();
        List<ApplicationItem__c> overtime = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : applications) {
            if (appl == null) {
                continue;
            }
            if (ApplicationItemTriggerHandler.isOvertimeRequest(appl)) {
                overtime.add(appl);
            } else {
                leave.add(appl);
            }
        }
        createLeaveRecords(leave);
        createOvertimeRecords(overtime);
    }

    /*
     *  bulkified. Previously every record ran its own SOQL for the project
     * assignment, its own SOQL for the project, and up to three separate inserts,
     * so a batch of any size exhausted the query limit before the DML limit.
     *
     *  multi-day. A request is now expanded into one Man_hour__c per working
     * day. Before this, a five-day leave booked a single 7.5h record instead of 37.5h,
     * which understated the timesheet by the whole rest of the range — and disagreed
     * with the calendar Events, which were already one per day.
     */
    public void createLeaveRecords(List<ApplicationItem__c> applications) {
        List<ApplicationItem__c> approved = approvedOnly(applications);
        if (approved.isEmpty()) {
            return;
        }

        // Weekends and dated Holiday records are skipped by workingDaysFor, which is
        // shared with the day count and the calendar Events so the three agree.
        Set<Date> holidays = ApplicationItemTriggerLogic.holidaysForBatch(approved);
        List<Booking> bookings = new List<Booking>();
        for (ApplicationItem__c appl : approved) {
            Boolean singleDay = (appl.Term_To__c == null || appl.Term_To__c == appl.Term_From__c);
            for (Date d : ApplicationItemTriggerLogic.workingDaysFor(appl, holidays)) {
                // Period_Leave__c is only meaningful on a single-day request; every
                // day of a range is a full day.
                bookings.add(new Booking(
                    appl, d,
                    singleDay ? hoursFor(appl.Period_Leave__c) : FULL_DAY_HOURS,
                    KIND_LEAVE, appl.Request_Type__c
                ));
            }
        }
        book(bookings);
    }

    /*
     * — approved overtime books project time the same way leave does, so a
     * timesheet reflects the hours actually worked rather than only the contracted
     * ones.
     *
     * Every date in the range is booked, weekends and public holidays included:
     * workingDaysFor is deliberately not reused here, because those are exactly the
     * days overtime tends to fall on.
     *
     * The hours book against the project named on the request rather than against the
     * yearly "Overtime FYxx" catch-all, which made every overtime record in the org
     * indistinguishable in project reporting. Leave keeps its bucket: a day of absence
     * is not worked on anything.
     */
    public void createOvertimeRecords(List<ApplicationItem__c> applications) {
        List<ApplicationItem__c> approved = approvedOnly(applications);
        if (approved.isEmpty()) {
            return;
        }

        List<Booking> bookings = new List<Booking>();
        for (ApplicationItem__c appl : approved) {
            Decimal hours = ApplicationItemTriggerLogic.overtimeHoursPerDay(appl);
            if (hours <= 0) {
                continue; // no window, or an inverted one - the validation rules report it
            }
            for (Date d : ApplicationItemTriggerLogic.overtimeDatesFor(appl)) {
                Booking booking = new Booking(appl, d, hours, KIND_OVERTIME, KIND_OVERTIME);
                // The project the manager chose. Blank only on requests raised before the
                // field existed, which fall back to the yearly bucket in resolveProjects.
                booking.projectId = appl.Project__c;
                bookings.add(booking);
            }
        }
        book(bookings);
    }

    private static List<ApplicationItem__c> approvedOnly(List<ApplicationItem__c> applications) {
        List<ApplicationItem__c> approved = new List<ApplicationItem__c>();
        if (applications == null) {
            return approved;
        }
        for (ApplicationItem__c appl : applications) {
            if (appl != null && appl.Status__c == 'Approved' && appl.Term_From__c != null) {
                approved.add(appl);
            }
        }
        return approved;
    }

    /*
     * Each booking needs a Man_hour__c hung off a ProjectAssign__c, which hangs off a
     * per-year "Leave FYxx" or "Overtime FYxx" Project__c. Any of the three may be
     * missing, so the work runs in three passes: resolve or create projects, then
     * resolve or create assignments, then insert the man hours. A range crossing a
     * month boundary needs an assignment in each month, which is why pass 2 keys on
     * the booking date rather than on the request.
     */
    private void book(List<Booking> bookings) {
        if (bookings.isEmpty()) {
            return;
        }

        // Pass 1 - give every booking a concrete project, creating the yearly one on
        // first use. Split out so the rest of this method has a project Id to key on.
        resolveProjects(bookings);

        Set<Id> projectIds = new Set<Id>();
        Set<Id> ownerIds = new Set<Id>();
        for (Booking booking : bookings) {
            if (booking.projectId == null) {
                continue;
            }
            projectIds.add(booking.projectId);
            ownerIds.add(booking.appl.OwnerId);
        }
        if (projectIds.isEmpty()) {
            return;
        }

        /*
         * Queried after pass 1 rather than before it, because a project created moments
         * ago cannot appear in a query issued earlier. Keyed on Project_No__c rather
         * than on the project name: names are unique only among the yearly projects this
         * class invents, and keying on Id costs nothing extra.
         */
        List<ProjectAssign__c> existingAssigns = [
            SELECT Id, Project_No__c, Assignee__c, Start_Date__c, Due_Date__c
            FROM ProjectAssign__c
            WHERE Project_No__c IN :projectIds
              AND Assignee__c IN :ownerIds
            ORDER BY Id
        ];

        // Pass 2 - resolve one assignment per project / owner / month of the booking
        Map<String, ProjectAssign__c> assignByKey = new Map<String, ProjectAssign__c>();
        Map<String, ProjectAssign__c> assignsToCreate = new Map<String, ProjectAssign__c>();
        for (Booking booking : bookings) {
            if (booking.projectId == null) {
                continue;
            }
            Date monthStart = booking.performedOn.toStartOfMonth();
            Date monthEnd = Date.newInstance(
                monthStart.year(), monthStart.month(),
                Date.daysInMonth(monthStart.year(), monthStart.month())
            );
            String key = assignKey(booking.projectId, booking.appl.OwnerId, monthStart);
            if (assignByKey.containsKey(key) || assignsToCreate.containsKey(key)) {
                continue;
            }

            ProjectAssign__c match = findAssign(
                existingAssigns, booking.projectId, booking.appl.OwnerId, monthStart, monthEnd);
            if (match != null) {
                assignByKey.put(key, match);
                continue;
            }

            assignsToCreate.put(key, new ProjectAssign__c(
                Assignee__c   = booking.appl.OwnerId,
                Project_No__c = booking.projectId,
                Start_Date__c = monthStart,
                Due_Date__c   = monthEnd
            ));
        }
        if (!assignsToCreate.isEmpty()) {
            insert assignsToCreate.values();
            assignByKey.putAll(assignsToCreate);
        }

        // Pass 3 - one man hour record per booked date
        List<Man_hour__c> manHours = new List<Man_hour__c>();
        for (Booking booking : bookings) {
            if (booking.projectId == null) {
                continue;
            }
            ProjectAssign__c assign = assignByKey.get(assignKey(
                booking.projectId,
                booking.appl.OwnerId,
                booking.performedOn.toStartOfMonth()
            ));
            if (assign == null) {
                continue;
            }
            manHours.add(new Man_hour__c(
                Performed_Date__c   = booking.performedOn,
                Performed_Hours__c  = booking.hours,
                ProjectAssign_No__c = assign.Id,
                Work__c             = booking.work,
                Remark__c           = booking.appl.Remark__c,
                //  so undoing an approval can remove exactly the rows it made.
                Application_Item__c = booking.appl.Id
            ));
        }
        if (!manHours.isEmpty()) {
            insert manHours;
        }
    }

    /*
     * Sets Booking.projectId on every booking that does not already carry one, from the
     * per-year "Leave FYxx" / "Overtime FYxx" Project__c, which is created on first use.
     */
    private void resolveProjects(List<Booking> bookings) {
        Map<String, Date> sampleDateForProject = new Map<String, Date>();
        Map<String, String> kindForProject = new Map<String, String>();
        for (Booking booking : bookings) {
            if (booking.projectId != null) {
                continue;
            }
            String name = projectNameFor(booking.kind, booking.performedOn);
            sampleDateForProject.put(name, booking.performedOn);
            kindForProject.put(name, booking.kind);
        }
        if (sampleDateForProject.isEmpty()) {
            return;
        }

        Set<String> projectNames = sampleDateForProject.keySet();
        Map<String, Project__c> projectByName = new Map<String, Project__c>();
        for (Project__c p : [
            SELECT Id, Project_Name__c FROM Project__c
            WHERE Project_Name__c IN :projectNames ORDER BY Id
        ]) {
            if (!projectByName.containsKey(p.Project_Name__c)) {
                projectByName.put(p.Project_Name__c, p);
            }
        }

        List<Project__c> newProjects = new List<Project__c>();
        for (String name : projectNames) {
            if (projectByName.containsKey(name)) {
                continue;
            }
            Date sample = sampleDateForProject.get(name);
            String kind = kindForProject.get(name);
            newProjects.add(new Project__c(
                OwnerId           = UserInfo.getUserId(),
                RecordTypeId      = nonChargedRecordTypeId(),
                Project_Name__c   = name,
                Remark__c         = 'for ' + kind + ' in FY' + twoDigitYear(sample),
                Project_Detail__c = 'for user input a ' + kind + ' record',
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

        for (Booking booking : bookings) {
            if (booking.projectId != null) {
                continue;
            }
            Project__c parent = projectByName.get(projectNameFor(booking.kind, booking.performedOn));
            if (parent != null) {
                booking.projectId = parent.Id;
            }
        }
    }

    /*
     * Mirrors the original overlap test: an assignment counts as covering the month
     * if either end of it falls inside that month.
     */
    private ProjectAssign__c findAssign(List<ProjectAssign__c> assigns, Id projectId,
                                        Id ownerId, Date monthStart, Date monthEnd) {
        for (ProjectAssign__c pa : assigns) {
            if (pa.Project_No__c != projectId || pa.Assignee__c != ownerId) {
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

    private static String assignKey(Id projectId, Id ownerId, Date monthStart) {
        return projectId + '|' + ownerId + '|' + monthStart;
    }

    private static String twoDigitYear(Date d) {
        return String.valueOf(d.year()).substring(2, 4);
    }

    /** "Leave FY26" / "Overtime FY26". The leave name is unchanged from  */
    @TestVisible
    private static String projectNameFor(String kind, Date d) {
        return kind + ' FY' + twoDigitYear(d);
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