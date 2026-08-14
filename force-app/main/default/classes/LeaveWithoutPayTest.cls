@isTest
private class LeaveWithoutPayTest {

    /*
     * LEAVE-30 — Leave Without Pay.
     *
     * Balances here use the Upfront accrual method on purpose. Accrued_Days__c is a
     * formula over TODAY(), so a Monthly row would make every figure in this class
     * depend on the month the suite happens to run in; Upfront credits the whole
     * entitlement and keeps the arithmetic fixed.
     *
     * Approvals run as a separate Managing Director user holding the
     * Leave_Without_Pay_Approver permission set, because the
     * Leave_Request_LWOP_Approval_Permission validation rule would otherwise reject
     * them. That makes these tests exercise the real permission wiring rather than
     * assuming it away.
     */

    private static final Date MONDAY_EPOCH = Date.newInstance(1900, 1, 1);

    private static Id cachedRequesterId;
    private static User cachedMd;

    private static Id requesterId() {
        if (cachedRequesterId == null) {
            cachedRequesterId = [SELECT Id FROM User WHERE CompanyName = 'LWOPREQ' LIMIT 1].Id;
        }
        return cachedRequesterId;
    }

    private static User managingDirector() {
        if (cachedMd == null) {
            cachedMd = [SELECT Id FROM User WHERE CompanyName = 'LWOPMD' LIMIT 1];
        }
        return cachedMd;
    }

    private static Integer testYear() {
        return System.today().year();
    }

    /** Single-day requests are taken at face value, so the weekday does not matter. */
    private static Date singleDate() {
        return Date.newInstance(testYear(), 3, 2);
    }

    private static Date mondayInTestYear() {
        Date d = Date.newInstance(testYear(), 3, 2);
        Integer dayOfWeek = Math.mod(MONDAY_EPOCH.daysBetween(d), 7);
        return d.addDays(Math.mod(7 - dayOfWeek, 7));
    }

    /** Mirrors the expansion in workingDaysFor so ranges stay holiday-proof. */
    private static Integer workingDaysBetween(Date startDay, Date endDay) {
        Set<Date> holidays = ApplicationItemTriggerLogic.holidaysBetween(startDay, endDay);
        Integer count = 0;
        for (Date cursor = startDay; cursor <= endDay; cursor = cursor.addDays(1)) {
            if (Math.mod(MONDAY_EPOCH.daysBetween(cursor), 7) < 5 && !holidays.contains(cursor)) {
                count++;
            }
        }
        return count;
    }

    @testSetup
    static void setup() {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String stamp = String.valueOf(DateTime.now().getTime());

        User requester = buildUser('lwopreq' + stamp, 'LWOPREQ', 'lwpr', standard.Id);
        User md = buildUser('lwopmd' + stamp, 'LWOPMD', 'lwpm', admin.Id);

        // User and PermissionSetAssignment are both setup objects; runAs keeps them
        // out of MIXED_DML with the Leave_Balance__c inserts below.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ requester, md };
            insert new PermissionSetAssignment(
                AssigneeId = md.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet
                                   WHERE Name = 'Leave_Without_Pay_Approver' LIMIT 1].Id
            );
        }

        Integer yr = System.today().year();
        insert new List<Leave_Balance__c>{
            // 2 days available, so a five-day request leaves a shortfall.
            balanceRow(requester.Id, 'Annual leave', yr, 2),
            // Nothing available at all: every sick day is unpaid.
            balanceRow(requester.Id, 'Sick leave', yr, 0),
            // Deducts a balance but sits outside the LWOP check.
            balanceRow(requester.Id, 'Personal leave', yr, 3)
        };
    }

    private static User buildUser(String uniqueName, String company, String alias, Id profileId) {
        return new User(
            FirstName = 'LWOP',
            LastName = company,
            Email = uniqueName + '@example.com',
            Username = uniqueName + '@example.com.lwoptest',
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

    private static Leave_Balance__c balanceRow(Id ownerId, String leaveType, Integer yr, Decimal entitlement) {
        return new Leave_Balance__c(
            Employee__c         = ownerId,
            Leave_Type__c       = leaveType,
            Leave_Year__c       = yr,
            External_Key__c     = ownerId + '-' + leaveType + '-' + yr,
            Entitlement_Days__c = entitlement,
            Accrual_Method__c   = 'Upfront',
            Carry_Over_Days__c  = 0,
            Used_Days__c        = 0,
            Pending_Days__c     = 0,
            Status__c           = 'Active'
        );
    }

    private static ApplicationItem__c request(String type) {
        return new ApplicationItem__c(
            Request_Type__c = type,
            Period_Leave__c = 'All day',
            Term_From__c    = singleDate(),
            Remark__c       = 'lwop test',
            Status__c       = 'Pending',
            OwnerId         = requesterId()
        );
    }

    private static ApplicationItem__c reload(Id applId) {
        return [
            SELECT Leave_Days__c, LWOP_Days__c, Paid_Days__c, LWOP_Status__c,
                   LWOP_Approved_By__c, LWOP_Approved_On__c, LWOP_Approved_Days__c
            FROM ApplicationItem__c WHERE Id = :applId
        ];
    }

    private static Decimal used(String leaveType) {
        return [
            SELECT Used_Days__c FROM Leave_Balance__c
            WHERE Employee__c = :requesterId() AND Leave_Type__c = :leaveType LIMIT 1
        ].Used_Days__c;
    }

    /** The Managing Director signing off the unpaid days, permission and all. */
    private static void signOff(ApplicationItem__c appl, String decision) {
        System.runAs(managingDirector()) {
            appl.LWOP_Status__c = decision;
            update appl;
        }
    }

    private static void approve(ApplicationItem__c appl) {
        appl.Status__c = 'Approved';
        update appl;
    }

    /** A range long enough that no plausible holiday count removes the shortfall. */
    private static ApplicationItem__c fiveDayAnnualRequest() {
        Date mon = mondayInTestYear();
        ApplicationItem__c appl = request('Annual leave');
        appl.Term_From__c = mon;
        appl.Term_To__c   = mon.addDays(4);
        return appl;
    }

    // ------------------------------------------------------------------ forecasting

    @isTest
    static void requestInsideTheBalanceNeedsNoApproval() {
        ApplicationItem__c appl = request('Annual leave');
        insert appl;

        ApplicationItem__c saved = reload(appl.Id);
        System.assertEquals(0, saved.LWOP_Days__c, 'one day against two available is fully paid');
        System.assertEquals('Not Required', saved.LWOP_Status__c,
            'a request the balance covers must never reach the Managing Director');
        System.assertEquals(1, saved.Paid_Days__c, 'the whole day is paid');
    }

    @isTest
    static void requestOverTheBalanceIsFlaggedForTheManagingDirector() {
        ApplicationItem__c appl = fiveDayAnnualRequest();
        insert appl;

        Integer days = workingDaysBetween(appl.Term_From__c, appl.Term_To__c);
        System.assert(days > 2, 'the range must exceed the two available days for this test to mean anything');

        ApplicationItem__c saved = reload(appl.Id);
        System.assertEquals(days - 2, saved.LWOP_Days__c, 'only the shortfall is unpaid');
        System.assertEquals(2, saved.Paid_Days__c, 'the available balance is still paid');
        System.assertEquals('Pending MD Approval', saved.LWOP_Status__c,
            'the unpaid portion needs the Managing Director');
    }

    @isTest
    static void shorteningTheRequestClearsTheFlag() {
        ApplicationItem__c appl = fiveDayAnnualRequest();
        insert appl;
        System.assertEquals('Pending MD Approval', reload(appl.Id).LWOP_Status__c, 'flagged to begin with');

        appl.Term_To__c = null;
        update appl;

        ApplicationItem__c saved = reload(appl.Id);
        System.assertEquals(0, saved.LWOP_Days__c, 'a single day fits inside the balance');
        System.assertEquals('Not Required', saved.LWOP_Status__c,
            'shortening the request must withdraw it from the Managing Director');
    }

    @isTest
    static void typesOutsideTheCheckAreNeverFlagged() {
        ApplicationItem__c appl = request('Personal leave');
        insert appl;

        System.assertEquals(0, reload(appl.Id).LWOP_Days__c,
            'personal leave has Counts Toward LWOP Check off, so it is never assessed');
    }

    // ------------------------------------------------------------------ the gate

    @isTest
    static void approvalIsBlockedUntilTheManagingDirectorSignsOff() {
        ApplicationItem__c appl = fiveDayAnnualRequest();
        insert appl;

        try {
            approve(appl);
            System.assert(false, 'a request with unpaid days must not be approvable on its own');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('Managing Director'),
                'the error should point at the missing sign-off: ' + e.getMessage());
        }
        System.assertEquals(0, used('Annual leave'), 'a blocked approval moves no balance');
    }

    @isTest
    static void rejectedLeaveWithoutPayCannotBeApproved() {
        ApplicationItem__c appl = fiveDayAnnualRequest();
        insert appl;
        signOff(appl, 'Rejected');

        try {
            approve(appl);
            System.assert(false, 'a refused unpaid portion must keep the request unapprovable');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('Managing Director'),
                'the error should still name the Managing Director: ' + e.getMessage());
        }
        System.assertEquals(0, used('Annual leave'), 'nothing is consumed');
    }

    // ------------------------------------------------------------------ settlement

    @isTest
    static void signedOffRequestDeductsOnlyThePaidPortion() {
        ApplicationItem__c appl = fiveDayAnnualRequest();
        insert appl;
        Integer days = workingDaysBetween(appl.Term_From__c, appl.Term_To__c);

        signOff(appl, 'Approved');
        approve(appl);

        System.assertEquals(2, used('Annual leave'),
            'the balance gives up everything it has and no more - the rest is unpaid');

        ApplicationItem__c saved = reload(appl.Id);
        System.assertEquals(days - 2, saved.LWOP_Days__c, 'the shortfall stands on the record');
        System.assertEquals(2, saved.Paid_Days__c, 'paid and unpaid add up to the days requested');
    }

    @isTest
    static void fullyUnpaidRequestMovesNoBalance() {
        ApplicationItem__c appl = request('Sick leave');
        insert appl;

        System.assertEquals(1, reload(appl.Id).LWOP_Days__c,
            'with nothing accrued the whole day is unpaid');

        signOff(appl, 'Approved');
        approve(appl);

        System.assertEquals(0, used('Sick leave'),
            'an entirely unpaid request must not push the balance negative');
        System.assertEquals(0, reload(appl.Id).Paid_Days__c, 'no part of it is paid');
    }

    @isTest
    static void signOffRecordsWhoApprovedAndForHowMany() {
        ApplicationItem__c appl = fiveDayAnnualRequest();
        insert appl;
        Integer days = workingDaysBetween(appl.Term_From__c, appl.Term_To__c);

        signOff(appl, 'Approved');

        ApplicationItem__c saved = reload(appl.Id);
        System.assertEquals(managingDirector().Id, saved.LWOP_Approved_By__c,
            'the approver is taken from the running user, not from the record');
        System.assertNotEquals(null, saved.LWOP_Approved_On__c, 'the sign-off is timestamped');
        System.assertEquals(days - 2, saved.LWOP_Approved_Days__c,
            'the sign-off is for a specific number of unpaid days');
    }

    @isTest
    static void withdrawnSignOffClearsTheApprover() {
        ApplicationItem__c appl = fiveDayAnnualRequest();
        insert appl;
        signOff(appl, 'Approved');
        signOff(appl, 'Rejected');

        ApplicationItem__c saved = reload(appl.Id);
        System.assertEquals(null, saved.LWOP_Approved_By__c,
            'a rejected request must not still carry an approver name');
        System.assertEquals(null, saved.LWOP_Approved_Days__c, 'nor a signed-off figure');
    }

    // ------------------------------------------------------------------ integrity

    @isTest
    static void lengtheningAnApprovedRequestNeedsApprovingAgain() {
        ApplicationItem__c appl = fiveDayAnnualRequest();
        insert appl;
        signOff(appl, 'Approved');

        // Same start, three weeks longer: far more unpaid days than were signed off.
        appl.Term_To__c = appl.Term_From__c.addDays(25);
        update appl;

        ApplicationItem__c saved = reload(appl.Id);
        System.assertEquals('Pending MD Approval', saved.LWOP_Status__c,
            'growing the unpaid portion past what was signed off must reopen the approval');
        System.assertEquals(null, saved.LWOP_Approved_By__c,
            'the old approver must not appear to have signed for the larger amount');
    }

    @isTest
    static void approvingAnApprovedRequestDoesNotReassessIt() {
        ApplicationItem__c appl = fiveDayAnnualRequest();
        insert appl;
        Integer days = workingDaysBetween(appl.Term_From__c, appl.Term_To__c);
        signOff(appl, 'Approved');
        approve(appl);

        // Editing a settled request must not measure it against the balance its own
        // deduction has already emptied.
        appl.Remark__c = 'edited after approval';
        update appl;

        ApplicationItem__c saved = reload(appl.Id);
        System.assertEquals(days - 2, saved.LWOP_Days__c, 'the settled split is history and stands');
        System.assertEquals('Approved', saved.LWOP_Status__c,
            'a settled request must not be sent back to the Managing Director');
        System.assertEquals(2, used('Annual leave'), 'and must not deduct a second time');
    }

    @isTest
    static void aRequestApprovedFirstTakesTheBalanceWithIt() {
        /*
         * Three single-day requests created while two days are available. Each one is
         * forecast on its own and looks fully paid; only two of them can actually be.
         * The third has to be caught at approval, which is the whole reason settle
         * recomputes instead of trusting the forecast.
         */
        List<ApplicationItem__c> batch = new List<ApplicationItem__c>();
        for (Integer i = 0; i < 3; i++) {
            ApplicationItem__c appl = request('Annual leave');
            appl.Term_From__c = singleDate().addDays(i);
            batch.add(appl);
        }
        insert batch;

        for (ApplicationItem__c appl : batch) {
            System.assertEquals(0, reload(appl.Id).LWOP_Days__c,
                'each request on its own fits inside the balance');
        }

        approve(batch[0]);
        approve(batch[1]);
        System.assertEquals(2, used('Annual leave'), 'the first two consume everything there is');

        try {
            approve(batch[2]);
            System.assert(false, 'the third must not be allowed to overdraw the balance');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('Managing Director'),
                'the third request becomes unpaid days and needs a sign-off: ' + e.getMessage());
        }
        System.assertEquals(2, used('Annual leave'), 'and the balance is left where it was');
    }

    @isTest
    static void typesOutsideTheCheckStillOverdraw() {
        Date mon = mondayInTestYear();
        ApplicationItem__c appl = request('Personal leave');
        appl.Term_From__c = mon;
        appl.Term_To__c   = mon.addDays(4);
        insert appl;
        approve(appl);

        Integer days = workingDaysBetween(mon, mon.addDays(4));
        System.assert(days > 3, 'the range must exceed the three available days');
        System.assertEquals(days, used('Personal leave'),
            'a type outside the LWOP check keeps its pre-LEAVE-30 behaviour and overdraws');
        System.assertEquals(0, reload(appl.Id).LWOP_Days__c, 'and records no unpaid days');
    }
}
