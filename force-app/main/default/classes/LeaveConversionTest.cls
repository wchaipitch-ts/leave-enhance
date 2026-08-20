@isTest
private class LeaveConversionTest {

    /*
     * LEAVE-44 — turning unpaid days back into Annual leave.
     *
     * Policies are overridden in memory for the same reason LeaveSplitTest overrides
     * them: Unpaid leave deducting a balance and granting its entitlement on use are
     * Custom Metadata edits, and a test that reads the org's rows proves whatever
     * somebody last ticked rather than the code in front of it.
     *
     * Balances use Upfront accrual so Accrued_Days__c does not drift with the calendar.
     */

    private static final Date MONDAY_EPOCH = Date.newInstance(1900, 1, 1);
    private static Id cachedUserId;

    private static Id employeeId() {
        if (cachedUserId == null) {
            cachedUserId = [SELECT Id FROM User WHERE CompanyName = 'CONVTEST' LIMIT 1].Id;
        }
        return cachedUserId;
    }

    private static Integer testYear() {
        return System.today().year();
    }

    private static List<Date> nWorkingDays(Date startDay, Integer n) {
        Set<Date> holidays = ApplicationItemTriggerLogic.holidaysBetween(
            startDay, startDay.addDays(n * 3 + 10));
        List<Date> days = new List<Date>();
        Date cursor = startDay;
        while (days.size() < n) {
            if (Math.mod(MONDAY_EPOCH.daysBetween(cursor), 7) < 5 && !holidays.contains(cursor)) {
                days.add(cursor);
            }
            cursor = cursor.addDays(1);
        }
        return days;
    }

    private static void useTestPolicies() {
        ApplicationItemTriggerLogic.policyOverride = new List<Leave_Type_Policy__mdt>{
            new Leave_Type_Policy__mdt(Leave_Type__c = 'Annual leave', Active__c = true,
                Deducts_Balance__c = true, Overflow_To__c = 'Unpaid leave'),
            new Leave_Type_Policy__mdt(Leave_Type__c = 'Unpaid leave', Active__c = true,
                Deducts_Balance__c = true, Grants_On_Use__c = true)
        };
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'conv' + DateTime.now().getTime();
        User u = new User(
            FirstName = 'Convert', LastName = 'Tester',
            Email = unique + '@example.com', Username = unique + '@example.com.convtest',
            Alias = 'conv', CompanyName = 'CONVTEST', TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', ProfileId = p.Id,
            LanguageLocaleKey = 'en_US', Start_Date__c = Date.newInstance(2020, 1, 1)
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }

        Integer yr = System.today().year();
        insert new List<Leave_Balance__c>{
            row(u.Id, 'Annual leave', yr, 2),  // two days back in hand
            row(u.Id, 'Unpaid leave', yr, 0)   // no entitlement; granted as it is used
        };
    }

    private static Leave_Balance__c row(Id ownerId, String leaveType, Integer yr, Decimal entitlement) {
        return new Leave_Balance__c(
            Employee__c = ownerId, Leave_Type__c = leaveType, Leave_Year__c = yr,
            External_Key__c = ownerId + '-' + leaveType + '-' + yr,
            Entitlement_Days__c = entitlement, Accrual_Method__c = 'Upfront',
            Carry_Over_Days__c = 0, Used_Days__c = 0, Pending_Days__c = 0, Status__c = 'Active'
        );
    }

    /** An unpaid request of `workingDays` days, in the state it is being converted from. */
    private static ApplicationItem__c raiseUnpaid(Integer workingDays, String status) {
        List<Date> days = nWorkingDays(Date.newInstance(testYear(), 3, 2), workingDays);
        ApplicationItem__c appl = new ApplicationItem__c(
            Request_Type__c = 'Unpaid leave', Period_Leave__c = 'All day',
            Term_From__c = days[0],
            Term_To__c = (workingDays == 1 ? null : days[workingDays - 1]),
            Remark__c = 'conversion test', Status__c = status, OwnerId = employeeId()
        );
        insert appl;
        return appl;
    }

    private static ApplicationItem__c reload(Id applId) {
        return [SELECT Request_Type__c, Status__c, Leave_Days__c, Term_From__c, Term_To__c,
                       Converted_From_Unpaid__c, Converted_From_Status__c, Converted_On__c,
                       Converted_By__c, Split_From__c
                FROM ApplicationItem__c WHERE Id = :applId];
    }

    private static List<ApplicationItem__c> childrenOf(Id parentId) {
        return [SELECT Request_Type__c, Status__c, Leave_Days__c, Term_From__c, Term_To__c,
                       Converted_From_Unpaid__c, Converted_From_Status__c, Converted_By__c
                FROM ApplicationItem__c WHERE Split_From__c = :parentId
                ORDER BY Term_From__c];
    }

    /** What a revert put back: the unpaid records raised beside a revoked conversion. */
    private static List<ApplicationItem__c> restoredUnpaidUnder(Id parentId) {
        return [SELECT Request_Type__c, Status__c, Leave_Days__c, Term_From__c, Term_To__c
                FROM ApplicationItem__c
                WHERE Split_From__c = :parentId
                  AND Request_Type__c = 'Unpaid leave'
                  AND Status__c != 'Rejected'
                ORDER BY Term_From__c];
    }

    private static Leave_Balance__c balance(String leaveType) {
        return [SELECT Entitlement_Days__c, Used_Days__c, Available_Days__c
                FROM Leave_Balance__c
                WHERE Employee__c = :employeeId() AND Leave_Type__c = :leaveType LIMIT 1];
    }

    // ------------------------------------------------------------------ the figures

    @isTest
    static void theCardCountsWhatTheBalanceCanAffordRatherThanWhatWasAsked() {
        useTestPolicies();
        ApplicationItem__c appl = raiseUnpaid(3, 'Approved');

        Test.startTest();
        LeaveConversionService.ConversionView v = TimesheetController.getUnpaidConversion(appl.Id);
        Test.stopTest();

        System.assertEquals(3, v.remainingUnpaidDays, 'three days are being taken unpaid');
        System.assertEquals(2, v.convertibleDays, 'but only two Annual days exist to pay for them');
        System.assertEquals(0, v.convertedDays, 'and nothing has been converted yet');
        System.assertEquals(true, v.canConvert, 'so the button is live');
        System.assertEquals('Draft', v.conversionStatus, 'which is what the card calls that');
    }

    @isTest
    static void aRequestWithAnApproverOnItCannotBeConverted() {
        useTestPolicies();
        ApplicationItem__c appl = raiseUnpaid(2, 'Pending');

        Test.startTest();
        LeaveConversionService.ConversionView v = TimesheetController.getUnpaidConversion(appl.Id);
        Test.stopTest();

        System.assertEquals(false, v.canConvert, 'a request in front of an approver is not ours to cut');
        System.assertEquals(0, v.convertibleDays, 'and nothing is offered');
        System.assert(v.blockedReason.contains('approver'), 'the reason says why: ' + v.blockedReason);
    }

    // ------------------------------------------------------------ approved, in full

    @isTest
    static void convertingAnApprovedRequestInFullGivesBackTheUnpaidDaysAndRaisesADraft() {
        useTestPolicies();
        ApplicationItem__c appl = raiseUnpaid(2, 'Approved');
        System.assertEquals(2, balance('Unpaid leave').Used_Days__c, 'taken unpaid to begin with');

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, null);
        Test.stopTest();

        System.assertEquals('Rejected', reload(appl.Id).Status__c,
            'the settled unpaid request is reversed, which is the only edit it allows');
        Leave_Balance__c unpaid = balance('Unpaid leave');
        System.assertEquals(0, unpaid.Used_Days__c, 'the unpaid days come back');
        System.assertEquals(0, unpaid.Entitlement_Days__c,
            'and the entitlement granted on use unwinds with them');

        List<ApplicationItem__c> raised = childrenOf(appl.Id);
        System.assertEquals(1, raised.size(), 'one request replaces it');
        System.assertEquals('Annual leave', raised[0].Request_Type__c, 'now a paid one');
        System.assertEquals('Draft', raised[0].Status__c, 'which the owner still has to submit');
        System.assertEquals(2, raised[0].Leave_Days__c, 'for the days that were unpaid');
        System.assertEquals(true, raised[0].Converted_From_Unpaid__c, 'and it says where it came from');
        System.assertEquals('Approved', raised[0].Converted_From_Status__c,
            'including what the days were, which is what reverting has to put back');

        System.assertEquals(0, balance('Annual leave').Used_Days__c,
            'nothing is spent until that Draft is approved');
    }

    // ------------------------------------------------------------ approved, in part

    @isTest
    static void aPartialConversionLeavesTheRestUnpaidAndStillApproved() {
        useTestPolicies();
        ApplicationItem__c appl = raiseUnpaid(5, 'Approved');
        List<Date> days = nWorkingDays(Date.newInstance(testYear(), 3, 2), 5);

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, 2);
        Test.stopTest();

        System.assertEquals('Rejected', reload(appl.Id).Status__c, 'the original is reversed whole');

        List<ApplicationItem__c> raised = childrenOf(appl.Id);
        System.assertEquals(2, raised.size(), 'and rebuilt as the two things it now is');

        System.assertEquals('Annual leave', raised[0].Request_Type__c,
            'the earliest days convert first, as the split consumes balance in date order');
        System.assertEquals('Draft', raised[0].Status__c, 'awaiting the owner');
        System.assertEquals(2, raised[0].Leave_Days__c, 'two days paid');
        System.assertEquals(days[0], raised[0].Term_From__c, 'starting where the absence did');
        System.assertEquals(days[1], raised[0].Term_To__c, 'and stopping at the second day');

        System.assertEquals('Unpaid leave', raised[1].Request_Type__c, 'the rest stays unpaid');
        System.assertEquals('Approved', raised[1].Status__c,
            'and stays approved: nobody is asked to sign again for days already signed for');
        System.assertEquals(3, raised[1].Leave_Days__c, 'three days of it');
        System.assertEquals(days[2], raised[1].Term_From__c, 'picking up the day after the paid ones');

        Leave_Balance__c unpaid = balance('Unpaid leave');
        System.assertEquals(3, unpaid.Used_Days__c, 'only the days still unpaid are charged');
        System.assertEquals(3, unpaid.Entitlement_Days__c, 'and only those are granted');
    }

    @isTest
    static void moreDaysThanTheBalanceHoldsIsRefused() {
        useTestPolicies();
        ApplicationItem__c appl = raiseUnpaid(5, 'Approved');

        Test.startTest();
        try {
            TimesheetController.convertUnpaidLeave(appl.Id, 5);
            System.assert(false, 'five days cannot be converted against a two day balance');
        } catch (AuraHandledException e) {
            // expected
        }
        Test.stopTest();

        System.assertEquals('Approved', reload(appl.Id).Status__c, 'and nothing was disturbed');
        System.assertEquals(0, childrenOf(appl.Id).size(), 'no half-made family left behind');
    }

    // ---------------------------------------------------------------------- drafts

    @isTest
    static void aDraftConvertsInPlaceBecauseItHasSpentNothing() {
        useTestPolicies();
        ApplicationItem__c appl = raiseUnpaid(2, 'Draft');

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, null);
        Test.stopTest();

        ApplicationItem__c after = reload(appl.Id);
        System.assertEquals('Annual leave', after.Request_Type__c, 'the request itself becomes the paid one');
        System.assertEquals('Draft', after.Status__c, 'still the owner\'s to submit');
        System.assertEquals(true, after.Converted_From_Unpaid__c, 'marked as converted');
        System.assertEquals(UserInfo.getUserId(), after.Converted_By__c, 'by whoever did it');
        System.assertEquals(0, childrenOf(appl.Id).size(),
            'and no second record: there was nothing settled to reverse');
    }

    @isTest
    static void aPartialDraftConversionShortensTheUnpaidRequestRatherThanReversingIt() {
        useTestPolicies();
        ApplicationItem__c appl = raiseUnpaid(4, 'Draft');
        List<Date> days = nWorkingDays(Date.newInstance(testYear(), 3, 2), 4);

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, 2);
        Test.stopTest();

        ApplicationItem__c after = reload(appl.Id);
        System.assertEquals('Unpaid leave', after.Request_Type__c, 'the remainder is still unpaid');
        System.assertEquals('Draft', after.Status__c, 'and never left Draft');
        System.assertEquals(days[2], after.Term_From__c, 'it starts after the days that were converted');
        System.assertEquals(2, after.Leave_Days__c, 'leaving two unpaid days');

        List<ApplicationItem__c> raised = childrenOf(appl.Id);
        System.assertEquals(1, raised.size(), 'with the paid days beside it');
        System.assertEquals('Annual leave', raised[0].Request_Type__c, 'as Annual leave');
        System.assertEquals(2, raised[0].Leave_Days__c, 'for the two earliest days');
        System.assertEquals(days[0], raised[0].Term_From__c, 'starting where the absence did');
    }

    @isTest
    static void theCardReadsPartiallyConvertedOnceSomeDaysHaveMoved() {
        useTestPolicies();
        ApplicationItem__c appl = raiseUnpaid(4, 'Draft');

        Test.startTest();
        LeaveConversionService.ConversionView v = TimesheetController.convertUnpaidLeave(appl.Id, 2);
        Test.stopTest();

        System.assertEquals(2, v.convertedDays, 'two days converted');
        System.assertEquals(2, v.remainingUnpaidDays, 'two still unpaid');
        System.assertEquals('Partially Converted', v.conversionStatus, 'which is what that is called');
        System.assertEquals(1, v.convertedRequests.size(), 'and the card can link to what it made');
        System.assertEquals('Draft', v.convertedRequests[0].status, 'which is still waiting on the owner');
        System.assertEquals(true, v.convertedRequests[0].awaitingApproval, 'nobody is paid for it yet');
        System.assertEquals(false, v.canConvert,
            'the balance is spoken for by the Draft, so nothing more is offered');
    }

    // --------------------------------------------------------------------- revert

    /*
     * Reverting is not rejecting the absence. It revokes the paid request the conversion
     * produced and puts the days back as unpaid — and because these days had been
     * approved unpaid, they come back approved unpaid. Sending the employee round for a
     * second signature on days they already took, because somebody tried a correction
     * and undid it, would be an odd thing to do to them.
     */
    @isTest
    static void revertingAnApprovedConversionPutsTheDaysBackAsTheyWere() {
        useTestPolicies();
        ApplicationItem__c appl = raiseUnpaid(2, 'Approved');

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, null);
        System.assertEquals(0, balance('Unpaid leave').Used_Days__c,
            'the conversion gave the unpaid days back first');
        TimesheetController.revertConversion(appl.Id, 'converted by mistake');
        Test.stopTest();

        List<ApplicationItem__c> paid = [
            SELECT Status__c FROM ApplicationItem__c
            WHERE Split_From__c = :appl.Id AND Request_Type__c = 'Annual leave'
        ];
        System.assertEquals(1, paid.size(), 'the paid request is still there');
        System.assertEquals('Rejected', paid[0].Status__c, 'but revoked');

        List<ApplicationItem__c> back = restoredUnpaidUnder(appl.Id);
        System.assertEquals(1, back.size(), 'and the days are unpaid again');
        System.assertEquals('Approved', back[0].Status__c,
            'approved, as they were before anybody converted them');
        System.assertEquals(2, back[0].Leave_Days__c, 'all of them');

        Leave_Balance__c unpaid = balance('Unpaid leave');
        System.assertEquals(2, unpaid.Used_Days__c, 'charged to the unpaid balance again');
        System.assertEquals(2, unpaid.Entitlement_Days__c, 'with the entitlement granted to match');
    }

    /*
     * A Draft was shortened rather than replaced, so undoing it can put the days back on
     * the record they came off and leave the absence as one request again — the shape it
     * had before anybody pressed anything.
     */
    @isTest
    static void revertingADraftConversionGivesTheRequestItsDaysBack() {
        useTestPolicies();
        ApplicationItem__c appl = raiseUnpaid(4, 'Draft');
        List<Date> days = nWorkingDays(Date.newInstance(testYear(), 3, 2), 4);

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, 2);
        System.assertEquals(days[2], reload(appl.Id).Term_From__c, 'shortened by the conversion');
        TimesheetController.revertConversion(appl.Id, 'not needed after all');
        Test.stopTest();

        ApplicationItem__c after = reload(appl.Id);
        System.assertEquals(days[0], after.Term_From__c, 'and given its start date back');
        System.assertEquals(4, after.Leave_Days__c, 'all four days unpaid again');
        System.assertEquals('Unpaid leave', after.Request_Type__c, 'on the original record');
        System.assertEquals(0, restoredUnpaidUnder(appl.Id).size(),
            'with nothing raised beside it: the absence is one request, as it started');
    }

    /*
     * A Draft converted in full became the paid request itself. The card follows it there
     * — otherwise a conversion made in error on a Draft would be undoable only by hand,
     * which is exactly the case somebody is most likely to want back.
     */
    @isTest
    static void revertingAConversionMadeInPlaceTurnsTheRequestBack() {
        useTestPolicies();
        ApplicationItem__c appl = raiseUnpaid(2, 'Draft');

        Test.startTest();
        TimesheetController.convertUnpaidLeave(appl.Id, null);
        System.assertEquals('Annual leave', reload(appl.Id).Request_Type__c, 'converted in place');
        LeaveConversionService.ConversionView v =
            TimesheetController.getUnpaidConversion(appl.Id);
        System.assertEquals(true, v.showsConversion,
            'and the card stays on it, because this record is now the conversion');
        System.assertEquals(true, v.canRevert, 'offering the way back');

        TimesheetController.revertConversion(appl.Id, 'wrong request');
        Test.stopTest();

        ApplicationItem__c after = reload(appl.Id);
        System.assertEquals('Unpaid leave', after.Request_Type__c, 'and back it goes');
        System.assertEquals('Draft', after.Status__c, 'to the state it was converted from');
        System.assertEquals(false, after.Converted_From_Unpaid__c, 'with the stamp cleared');
    }

    @isTest
    static void thereIsNothingToRevertOnARequestNobodyConverted() {
        useTestPolicies();
        ApplicationItem__c appl = raiseUnpaid(2, 'Approved');

        Test.startTest();
        LeaveConversionService.ConversionView v = TimesheetController.getUnpaidConversion(appl.Id);
        System.assertEquals(false, v.canRevert, 'nothing has been converted, so nothing to revoke');

        try {
            TimesheetController.revertConversion(appl.Id, 'no reason');
            System.assert(false, 'and pressing it anyway is refused');
        } catch (AuraHandledException e) {
            // expected
        }
        Test.stopTest();

        System.assertEquals('Approved', reload(appl.Id).Status__c,
            'the absence itself is untouched: reverting is about the conversion, not the leave');
    }

    @isTest
    static void aRequestThatIsNotUnpaidIsNotTheCardSBusiness() {
        useTestPolicies();
        ApplicationItem__c appl = new ApplicationItem__c(
            Request_Type__c = 'Annual leave', Period_Leave__c = 'All day',
            Term_From__c = nWorkingDays(Date.newInstance(testYear(), 3, 2), 1)[0],
            Remark__c = 'conversion test', Status__c = 'Draft', OwnerId = employeeId()
        );
        insert appl;

        Test.startTest();
        LeaveConversionService.ConversionView v = TimesheetController.getUnpaidConversion(appl.Id);
        Test.stopTest();

        System.assertEquals(false, v.canConvert, 'paid leave has nothing to convert');
        System.assertEquals(false, v.showsConversion,
            'and no conversion produced it either, so the card removes itself');
    }
}