public class CreateLeaveRecordOnManInputTriggerLogic {

    private static final Decimal AM_HOURS       = 3.5;   // 08:30 - 12:00
    private static final Decimal PM_HOURS       = 4.0;   // 13:00 - 17:00
    private static final Decimal FULL_DAY_HOURS = 7.5;

    // Single-record entry point, retained for existing callers and tests.
    public void createLeaveRecord(ApplicationItem__c appl) {
        createLeaveRecords(new List<ApplicationItem__c>{ appl });
    }

    /*
     * LEAVE-11: bulkified. Previously every record ran its own SOQL for the project
     * assignment, its own SOQL for the project, and up to three separate inserts,
     * so a batch of any size exhausted the query limit before the DML limit.
     *
     * Each approved request needs a Man_hour__c hung off a ProjectAssign__c, which
     * hangs off a per-year "Leave FYxx" Project__c. Any of the three may be missing,
     * so the work runs in three passes: resolve or create projects, then resolve or
     * create assignments, then insert the man hours.
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

        Set<String> projectNames = new Set<String>();
        Set<Id> ownerIds = new Set<Id>();
        Map<String, Date> anyDateForProject = new Map<String, Date>();
        for (ApplicationItem__c appl : approved) {
            String name = projectNameFor(appl.Term_From__c);
            projectNames.add(name);
            ownerIds.add(appl.OwnerId);
            anyDateForProject.put(name, appl.Term_From__c);
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

        // Pass 2 - resolve one assignment per project / owner / month
        Map<String, ProjectAssign__c> assignByKey = new Map<String, ProjectAssign__c>();
        Map<String, ProjectAssign__c> assignsToCreate = new Map<String, ProjectAssign__c>();
        for (ApplicationItem__c appl : approved) {
            String name = projectNameFor(appl.Term_From__c);
            Date monthStart = appl.Term_From__c.toStartOfMonth();
            Date monthEnd = Date.newInstance(
                monthStart.year(), monthStart.month(),
                Date.daysInMonth(monthStart.year(), monthStart.month())
            );
            String key = assignKey(name, appl.OwnerId, monthStart);
            if (assignByKey.containsKey(key) || assignsToCreate.containsKey(key)) {
                continue;
            }

            ProjectAssign__c match = findAssign(existingAssigns, name, appl.OwnerId, monthStart, monthEnd);
            if (match != null) {
                assignByKey.put(key, match);
                continue;
            }

            Project__c parent = projectByName.get(name);
            if (parent == null) {
                continue;
            }
            assignsToCreate.put(key, new ProjectAssign__c(
                Assignee__c   = appl.OwnerId,
                Project_No__c = parent.Id,
                Start_Date__c = monthStart,
                Due_Date__c   = monthEnd
            ));
        }
        if (!assignsToCreate.isEmpty()) {
            insert assignsToCreate.values();
            assignByKey.putAll(assignsToCreate);
        }

        // Pass 3 - one man hour record per approved request
        List<Man_hour__c> manHours = new List<Man_hour__c>();
        for (ApplicationItem__c appl : approved) {
            String key = assignKey(
                projectNameFor(appl.Term_From__c),
                appl.OwnerId,
                appl.Term_From__c.toStartOfMonth()
            );
            ProjectAssign__c assign = assignByKey.get(key);
            if (assign == null) {
                continue;
            }
            manHours.add(new Man_hour__c(
                Performed_Date__c   = appl.Term_From__c,
                Performed_Hours__c  = hoursFor(appl.Period_Leave__c),
                ProjectAssign_No__c = assign.Id,
                Work__c             = appl.Request_Type__c,
                Remark__c           = appl.Remark__c
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