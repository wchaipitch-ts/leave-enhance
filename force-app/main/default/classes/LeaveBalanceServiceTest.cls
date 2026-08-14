@isTest
private class LeaveBalanceServiceTest {

    /*
     * LEAVE-32 — the read side of Leave_Balance__c.
     *
     * Which types appear and in what order comes from the org's real
     * Leave_Type_Policy__mdt rows, so these tests assert on behaviour — Annual is
     * present, Maternity is not, order is non-decreasing — rather than on a count that
     * would break the next time a leave type is configured.
     */

    private static Id cachedEmployeeId;
    private static Id cachedOutsiderId;

    private static Id employeeId() {
        if (cachedEmployeeId == null) {
            cachedEmployeeId = [SELECT Id FROM User WHERE CompanyName = 'BALEMP' LIMIT 1].Id;
        }
        return cachedEmployeeId;
    }

    private static User outsider() {
        if (cachedOutsiderId == null) {
            cachedOutsiderId = [SELECT Id FROM User WHERE CompanyName = 'BALOUT' LIMIT 1].Id;
        }
        return new User(Id = cachedOutsiderId);
    }

    private static Integer testYear() {
        return System.today().year();
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String stamp = String.valueOf(DateTime.now().getTime());
        User employee = buildUser('balemp' + stamp, 'BALEMP', 'bemp', p.Id);
        User outsider = buildUser('balout' + stamp, 'BALOUT', 'bout', p.Id);

        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ employee, outsider };
        }

        Integer yr = System.today().year();
        insert new List<Leave_Balance__c>{
            balanceRow(employee.Id, 'Annual leave',  yr,     12, 2, 1),
            balanceRow(employee.Id, 'Sick leave',    yr,     30, 0, 0),
            // A prior year, so the year picker has something to choose between.
            balanceRow(employee.Id, 'Annual leave',  yr - 1, 10, 0, 4)
        };
    }

    private static User buildUser(String uniqueName, String company, String alias, Id profileId) {
        return new User(
            FirstName = 'Balance',
            LastName = company,
            Email = uniqueName + '@example.com',
            Username = uniqueName + '@example.com.baltest',
            Alias = alias,
            CompanyName = company,
            TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = profileId,
            LanguageLocaleKey = 'en_US',
            Start_Date__c = Date.newInstance(2020, 1, 1)
        );
    }

    private static Leave_Balance__c balanceRow(Id ownerId, String leaveType, Integer yr,
                                               Decimal entitlement, Decimal carryOver, Decimal used) {
        return new Leave_Balance__c(
            Employee__c         = ownerId,
            Leave_Type__c       = leaveType,
            Leave_Year__c       = yr,
            External_Key__c     = ownerId + '-' + leaveType + '-' + yr,
            Entitlement_Days__c = entitlement,
            Accrual_Method__c   = 'Upfront',
            Carry_Over_Days__c  = carryOver,
            Used_Days__c        = used,
            Pending_Days__c     = 0,
            Status__c           = 'Active'
        );
    }

    private static LeaveBalanceService.LeaveBalanceView viewFor(
            List<LeaveBalanceService.LeaveBalanceView> views, String leaveType) {
        for (LeaveBalanceService.LeaveBalanceView v : views) {
            if (leaveType.equals(v.leaveType)) {
                return v;
            }
        }
        return null;
    }

    private static ApplicationItem__c request(String type, String status, Date startOn) {
        return new ApplicationItem__c(
            Request_Type__c = type,
            Period_Leave__c = 'All day',
            Term_From__c    = startOn,
            Remark__c       = 'balance service test',
            Status__c       = status,
            OwnerId         = employeeId()
        );
    }

    // ------------------------------------------------------------------ shape

    @isTest
    static void everyVisibleTypeGetsARowInPolicyOrder() {
        List<LeaveBalanceService.LeaveBalanceView> views =
            LeaveBalanceService.getBalances(employeeId(), testYear());

        System.assertNotEquals(null, viewFor(views, 'Annual leave'),
            'a configured type must appear');
        System.assertEquals(null, viewFor(views, 'Maternity leave'),
            'Show On Balance Page is off for maternity, so it must not appear');
        System.assertEquals('Annual leave', views[0].leaveType,
            'sort order 1 comes first');
        System.assertEquals('Refresh Leave', views[1].leaveType,
            'then sort order 2');
    }

    @isTest
    static void figuresComeFromTheBalanceRow() {
        LeaveBalanceService.LeaveBalanceView annual =
            viewFor(LeaveBalanceService.getBalances(employeeId(), testYear()), 'Annual leave');

        System.assertEquals(true, annual.hasRecord, 'the row exists');
        System.assertEquals(12, annual.entitlement, 'entitlement carries through');
        System.assertEquals(2, annual.carriedIn, 'as does carried-in carry over');
        System.assertEquals(1, annual.used, 'and consumption');
        System.assertEquals(13, annual.available,
            'available is accrued 12 plus carried in 2 less used 1');
    }

    @isTest
    static void aTypeWithNoRowStillAppearsAtZero() {
        LeaveBalanceService.LeaveBalanceView personal =
            viewFor(LeaveBalanceService.getBalances(employeeId(), testYear()), 'Personal leave');

        System.assertNotEquals(null, personal,
            'a configured type with no row must not vanish from the page');
        System.assertEquals(false, personal.hasRecord, 'and must say the row is missing');
        System.assertEquals(0, personal.available, 'showing zero rather than null');
    }

    // ------------------------------------------------------------------ pending

    @isTest
    static void pendingCountsRequestsAwaitingApproval() {
        insert new List<ApplicationItem__c>{
            request('Annual leave', 'Pending', Date.newInstance(testYear(), 3, 2)),
            request('Annual leave', 'Draft',   Date.newInstance(testYear(), 3, 3))
        };

        LeaveBalanceService.LeaveBalanceView annual =
            viewFor(LeaveBalanceService.getBalances(employeeId(), testYear()), 'Annual leave');

        System.assertEquals(2, annual.pending, 'a draft and a pending day both count');
        System.assertEquals(13, annual.available,
            'pending is shown beside available, not subtracted from it');
    }

    @isTest
    static void pendingIgnoresSettledRequests() {
        ApplicationItem__c approved = request('Annual leave', 'Pending', Date.newInstance(testYear(), 3, 2));
        ApplicationItem__c rejected = request('Annual leave', 'Pending', Date.newInstance(testYear(), 3, 3));
        insert new List<ApplicationItem__c>{ approved, rejected };

        approved.Status__c = 'Approved';
        rejected.Status__c = 'Rejected';
        update new List<ApplicationItem__c>{ approved, rejected };

        System.assertEquals(0,
            viewFor(LeaveBalanceService.getBalances(employeeId(), testYear()), 'Annual leave').pending,
            'neither an approved nor a rejected request is still pending');
    }

    @isTest
    static void pendingIgnoresAnotherYear() {
        insert request('Annual leave', 'Pending', Date.newInstance(testYear() - 1, 3, 2));

        System.assertEquals(0,
            viewFor(LeaveBalanceService.getBalances(employeeId(), testYear()), 'Annual leave').pending,
            'last year\'s request does not sit against this year');
    }

    // ------------------------------------------------------------------ card figure

    @isTest
    static void availableDaysServesTheTimesheetCard() {
        System.assertEquals(13,
            LeaveBalanceService.getAvailableDays(employeeId(), 'Annual leave', testYear()),
            'the figure the card should show instead of the frozen User field');
    }

    @isTest
    static void availableDaysIsZeroWhenThereIsNoRow() {
        System.assertEquals(0,
            LeaveBalanceService.getAvailableDays(employeeId(), 'Personal leave', testYear()),
            'a card must still have something to render');
    }

    @isTest
    static void availableDaysRejectsMissingArguments() {
        try {
            LeaveBalanceService.getAvailableDays(employeeId(), null, testYear());
            System.assert(false, 'a blank leave type must be rejected');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    // ------------------------------------------------------------------ year picker

    @isTest
    static void yearPickerListsOnlyYearsWithBalances() {
        List<Integer> years = LeaveBalanceService.getAvailableYears(employeeId());

        System.assertEquals(2, years.size(), 'two years have rows');
        System.assertEquals(testYear(), years[0], 'newest first');
        System.assertEquals(testYear() - 1, years[1], 'then the prior year');
    }

    // ------------------------------------------------------------------ access

    @isTest
    static void anEmployeeCanSeeTheirOwnBalanceWithoutAnyPermission() {
        User self = [SELECT Id FROM User WHERE Id = :employeeId()];
        Test.startTest();
        System.runAs(self) {
            LeaveBalanceService.canViewOthersCache = null;
            System.assertNotEquals(null,
                LeaveBalanceService.getBalances(null, testYear()),
                'null means me, and I may always see my own');
        }
        Test.stopTest();
    }

    @isTest
    static void anEmployeeCannotSeeSomeoneElsesBalance() {
        Test.startTest();
        System.runAs(outsider()) {
            LeaveBalanceService.canViewOthersCache = null;
            try {
                LeaveBalanceService.getBalances(employeeId(), testYear());
                System.assert(false, 'one employee must not read another employee\'s balance');
            } catch (AuraHandledException e) {
                System.assert(true);
            }
        }
        Test.stopTest();
    }

    @isTest
    static void theRightPermissionOpensOtherPeoplesBalances() {
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Leave_Management_Admin' LIMIT 1];
        User viewer = outsider();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new PermissionSetAssignment(AssigneeId = viewer.Id, PermissionSetId = ps.Id);
        }

        Test.startTest();
        System.runAs(viewer) {
            LeaveBalanceService.canViewOthersCache = null;
            System.assertEquals(13,
                LeaveBalanceService.getAvailableDays(employeeId(), 'Annual leave', testYear()),
                'Leave Management Admin may look at anybody');
        }
        Test.stopTest();
    }

    @isTest
    static void aMissingYearIsRejected() {
        try {
            LeaveBalanceService.getBalances(employeeId(), null);
            System.assert(false, 'a null year must be rejected');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }
}
