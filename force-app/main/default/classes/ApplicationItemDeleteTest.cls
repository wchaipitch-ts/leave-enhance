@isTest
private class ApplicationItemDeleteTest {

    /*
     * TimesheetController.deleteApplicationItem — removing a request from the list view.
     *
     * A separate class for the same reason ApplicationItemEditTest is one: it belongs to
     * the one method rather than to the timesheet work TimesheetControllerTest covers.
     *
     * The fixtures follow ApplicationItemEditTest exactly — March of next year, so the
     * record is always in the future and always inside one calendar year, and no
     * Leave_Balance__c rows, so LeaveSplitService finds nothing to measure against and
     * leaves the records alone. That matters more here than it does for the edit: the
     * continuation records these tests need are built by hand, so that a test about the
     * cascade is testing the cascade rather than the splitting.
     *
     * Each fixture is identified by its remark, because several of them share a status.
     */

    private static final Date FROM_DATE = Date.newInstance(System.today().year() + 1, 3, 10);
    private static final Date TO_DATE   = Date.newInstance(System.today().year() + 1, 3, 12);

    private static final String SOLO        = 'a draft on its own';
    private static final String PENDING     = 'submitted already';
    private static final String REJECTED    = 'turned down';
    private static final String HAS_DRAFT   = 'a draft with a draft continuation';
    private static final String HAS_LIVE    = 'a draft with a live continuation';
    private static final String CHILD_DRAFT = 'the draft continuation';
    private static final String CHILD_LIVE  = 'the live continuation';

    private static Id cachedEmployeeId;
    private static Id cachedOutsiderId;

    private static Id employeeId() {
        if (cachedEmployeeId == null) {
            cachedEmployeeId = [SELECT Id FROM User WHERE CompanyName = 'ADLEMP' LIMIT 1].Id;
        }
        return cachedEmployeeId;
    }

    private static User outsider() {
        if (cachedOutsiderId == null) {
            cachedOutsiderId = [SELECT Id FROM User WHERE CompanyName = 'ADLOUT' LIMIT 1].Id;
        }
        return new User(Id = cachedOutsiderId);
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String stamp = String.valueOf(DateTime.now().getTime());
        User employee = buildUser('adlemp' + stamp, 'ADLEMP', 'demp', p.Id);
        User outsider = buildUser('adlout' + stamp, 'ADLOUT', 'dout', p.Id);

        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ employee, outsider };
        }

        insert new List<ApplicationItem__c>{
            leaveRequest(employee.Id, 'Draft',    SOLO),
            leaveRequest(employee.Id, 'Pending',  PENDING),
            leaveRequest(employee.Id, 'Rejected', REJECTED),
            leaveRequest(employee.Id, 'Draft',    HAS_DRAFT),
            leaveRequest(employee.Id, 'Draft',    HAS_LIVE)
        };

        // Split_From__c can only be set once the parents have Ids, so the continuations
        // go in as a second pass.
        ApplicationItem__c draftChild = unpaidContinuation(
            employee.Id, 'Draft', CHILD_DRAFT, requestFor(HAS_DRAFT).Id);
        ApplicationItem__c liveChild = unpaidContinuation(
            employee.Id, 'Pending', CHILD_LIVE, requestFor(HAS_LIVE).Id);
        insert new List<ApplicationItem__c>{ draftChild, liveChild };
    }

    private static User buildUser(String uniqueName, String company, String alias, Id profileId) {
        return new User(
            FirstName = 'Delete', LastName = company,
            Email = uniqueName + '@example.com',
            Username = uniqueName + '@example.com.adltest',
            Alias = alias, CompanyName = company, TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', ProfileId = profileId,
            LanguageLocaleKey = 'en_US', Start_Date__c = Date.newInstance(2022, 8, 1)
        );
    }

    private static Id leaveRecordTypeId() {
        Schema.RecordTypeInfo info = Schema.SObjectType.ApplicationItem__c
            .getRecordTypeInfosByDeveloperName().get('Leave_Request');
        return info == null ? null : info.getRecordTypeId();
    }

    private static ApplicationItem__c leaveRequest(Id ownerId, String status, String remark) {
        return new ApplicationItem__c(
            RecordTypeId    = leaveRecordTypeId(),
            OwnerId         = ownerId,
            Status__c       = status,
            Request_Type__c = 'Annual leave',
            Period_Leave__c = 'All day',
            Term_From__c    = FROM_DATE,
            Term_To__c      = TO_DATE,
            Remark__c       = remark
        );
    }

    private static ApplicationItem__c unpaidContinuation(Id ownerId, String status,
                                                        String remark, Id parentId) {
        ApplicationItem__c child = leaveRequest(ownerId, status, remark);
        child.Request_Type__c = 'Unpaid leave';
        child.Split_From__c   = parentId;
        return child;
    }

    /** The one request carrying the given remark. */
    private static ApplicationItem__c requestFor(String remark) {
        return [
            SELECT Id, Name, Status__c, OwnerId, Remark__c, Split_From__c, Request_Type__c
            FROM ApplicationItem__c
            WHERE Remark__c = :remark
            LIMIT 1
        ];
    }

    private static Boolean stillExists(String remark) {
        return [SELECT COUNT() FROM ApplicationItem__c WHERE Remark__c = :remark] > 0;
    }

    // ------------------------------------------------------------------ the delete

    @isTest
    static void aDraftIsDeleted() {
        Id draftId = requestFor(SOLO).Id;

        Test.startTest();
        TimesheetController.deleteApplicationItem(draftId);
        Test.stopTest();

        System.assertEquals(0,
            [SELECT COUNT() FROM ApplicationItem__c WHERE Id = :draftId],
            'the draft is gone');
    }

    // ------------------------------------------------------------------ Draft only

    @isTest
    static void aPendingRequestIsRefused() {
        Id pendingId = requestFor(PENDING).Id;
        try {
            TimesheetController.deleteApplicationItem(pendingId);
            System.assert(false, 'a submitted request must not be deletable');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        System.assert(stillExists(PENDING), 'and it is still there');
    }

    @isTest
    static void aRejectedRequestIsRefused() {
        Id rejectedId = requestFor(REJECTED).Id;
        try {
            TimesheetController.deleteApplicationItem(rejectedId);
            System.assert(false, 'a refused request must not be deletable');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        System.assert(stillExists(REJECTED), 'and it is still there');
    }

    // ------------------------------------------------------------------ the continuation

    /*
     * Deleting the original takes only the original. The unpaid days are leave the
     * employee is still taking, so the continuation survives as an ordinary unpaid
     * request - orphaned, because Split_From__c is deleteConstraint=SetNull and there is
     * no longer anything for it to point at.
     */
    @isTest
    static void aDraftContinuationSurvivesItsParent() {
        Id parentId = requestFor(HAS_DRAFT).Id;

        Test.startTest();
        TimesheetController.deleteApplicationItem(parentId);
        Test.stopTest();

        System.assert(!stillExists(HAS_DRAFT), 'the request is gone');
        System.assert(stillExists(CHILD_DRAFT), 'but its unpaid continuation stayed');

        ApplicationItem__c child = requestFor(CHILD_DRAFT);
        System.assertEquals(null, child.Split_From__c, 'and the platform emptied the lookup');
        System.assertEquals('Unpaid leave', child.Request_Type__c, 'still unpaid leave');
    }

    /*
     * The same, for a continuation already through to the approval path. This is the
     * case the behaviour exists for: cascading would have cancelled a live request as a
     * side effect of tidying up a different one.
     */
    @isTest
    static void aLiveContinuationSurvivesItsParent() {
        Id parentId = requestFor(HAS_LIVE).Id;

        Test.startTest();
        TimesheetController.deleteApplicationItem(parentId);
        Test.stopTest();

        System.assert(!stillExists(HAS_LIVE), 'the request is gone');
        System.assert(stillExists(CHILD_LIVE), 'and the live continuation is untouched');

        ApplicationItem__c child = requestFor(CHILD_LIVE);
        System.assertEquals(null, child.Split_From__c, 'beyond the emptied lookup');
        System.assertEquals('Pending', child.Status__c, 'its status is its own business');
    }

    // ------------------------------------------------------------------ permission

    @isTest
    static void anotherEmployeeCannotDeleteYourDraft() {
        Id draftId = requestFor(SOLO).Id;

        Test.startTest();
        System.runAs(outsider()) {
            LeaveBalanceService.canViewOthersCache = null;
            try {
                TimesheetController.deleteApplicationItem(draftId);
                System.assert(false, 'one employee must not delete another employee\'s request');
            } catch (AuraHandledException e) {
                System.assert(true);
            }
        }
        Test.stopTest();

        System.assert(stillExists(SOLO), 'and nothing moved');
    }

    /*
     * No profile in this org holds delete access on ApplicationItem__c, and the owner
     * still gets to remove their own draft - which is the whole reason the DML lives in
     * a without sharing class rather than behind an object permission.
     */
    @isTest
    static void theOwnerCanDeleteTheirOwn() {
        Id draftId = requestFor(SOLO).Id;

        Test.startTest();
        System.runAs(new User(Id = employeeId())) {
            LeaveBalanceService.canViewOthersCache = null;
            TimesheetController.deleteApplicationItem(draftId);
        }
        Test.stopTest();

        System.assert(!stillExists(SOLO), 'no permission set is needed for your own draft');
    }

    // ------------------------------------------------------------------ bad input

    @isTest
    static void aNullIdIsRejected() {
        try {
            TimesheetController.deleteApplicationItem(null);
            System.assert(false, 'a delete with no Id must be rejected');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @isTest
    static void anAlreadyDeletedRequestIsReportedAsGone() {
        Id draftId = requestFor(SOLO).Id;
        delete new ApplicationItem__c(Id = draftId);

        try {
            TimesheetController.deleteApplicationItem(draftId);
            System.assert(false, 'a request that no longer exists must be reported as such');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }
}