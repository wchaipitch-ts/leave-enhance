/*
 *   the day cap, the document gate and the removal lock.
 *
 * Policies are overridden in memory rather than read from the org, matching LeaveSplitTest:
 * Custom Metadata cannot be inserted by DML, and the two fields these rules turn on are
 * manual edits nobody has necessarily made in the org the tests happen to run against.
 *
 * Counts_Toward_LWOP_Check__c is deliberately OFF for every type here. It is what makes
 * LeaveSplitService cut a request down, and a request quietly shortened mid-test would
 * change the very day count these assertions are about. The split has its own test class.
 *
 * WHAT THIS CLASS DOES NOT PROVE. The document gate is reached in real life by the approval
 * process writing Status__c = Pending through a workflow field update, and the tests below
 * reach it by updating the field directly. Both arrive at the same Draft -> Pending
 * transition in the same before-update trigger, so the logic is covered either way, but
 * that a workflow field update re-fires triggers at all is platform behaviour no unit test
 * here asserts. Verify a real Submit for Approval in the sandbox once.
 */
@isTest
private class LeaveRequestGuardTest {

    private static final Date MONDAY_EPOCH = Date.newInstance(1900, 1, 1);
    private static Id cachedUserId;

    private static Id employeeId() {
        if (cachedUserId == null) {
            cachedUserId = [SELECT Id FROM User WHERE CompanyName = 'GUARDTEST' LIMIT 1].Id;
        }
        return cachedUserId;
    }

    private static void useTestPolicies() {
        LeaveDocumentPolicy.bypassOverride = false;
        ApplicationItemTriggerLogic.policyOverride = new List<Leave_Type_Policy__mdt>{
            new Leave_Type_Policy__mdt(Leave_Type__c = 'Sick leave', Active__c = true,
                Deducts_Balance__c = true, Counts_Toward_LWOP_Check__c = false,
                Document_Required_From_Days__c = 3),
            new Leave_Type_Policy__mdt(Leave_Type__c = 'Personal leave', Active__c = true,
                Deducts_Balance__c = true, Counts_Toward_LWOP_Check__c = false,
                Document_Required_From_Days__c = 0, Max_Days_Per_Request__c = 1),
            new Leave_Type_Policy__mdt(Leave_Type__c = 'Annual leave', Active__c = true,
                Deducts_Balance__c = true, Counts_Toward_LWOP_Check__c = false)
        };
    }

    /*
     * Exactly n working days from start, so a range's day count is never in doubt.
     *
     * Memoised because it queries Holiday, and the bulk tests below build two hundred
     * requests from the same window - uncached, the helper alone exhausts the SOQL limit
     * before the code under test is ever reached.
     */
    private static Map<String, List<Date>> workingDayCache = new Map<String, List<Date>>();

    private static List<Date> nWorkingDays(Date startDay, Integer n) {
        String key = String.valueOf(startDay) + '/' + n;
        if (workingDayCache.containsKey(key)) {
            return workingDayCache.get(key);
        }
        Set<Date> holidays = ApplicationItemTriggerLogic.holidaysBetween(startDay, startDay.addDays(n * 3 + 10));
        List<Date> days = new List<Date>();
        Date cursor = startDay;
        while (days.size() < n) {
            if (Math.mod(MONDAY_EPOCH.daysBetween(cursor), 7) < 5 && !holidays.contains(cursor)) {
                days.add(cursor);
            }
            cursor = cursor.addDays(1);
        }
        workingDayCache.put(key, days);
        return days;
    }

    @testSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'guard' + DateTime.now().getTime();
        User u = new User(
            FirstName = 'Guard', LastName = 'Tester',
            Email = unique + '@example.com', Username = unique + '@example.com.guardtest',
            Alias = 'grdt', CompanyName = 'GUARDTEST', TimeZoneSidKey = 'Asia/Bangkok',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', ProfileId = p.Id,
            LanguageLocaleKey = 'en_US', Start_Date__c = Date.newInstance(2020, 1, 1)
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }

        Integer yr = System.today().year();
        insert new List<Leave_Balance__c>{
            row(u.Id, 'Sick leave',     yr, 30),
            row(u.Id, 'Personal leave', yr, 3),
            row(u.Id, 'Annual leave',   yr, 12)
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

    private static ApplicationItem__c raise(String type, Integer workingDays, String status) {
        List<Date> days = nWorkingDays(Date.newInstance(System.today().year(), 3, 2), workingDays);
        return new ApplicationItem__c(
            Request_Type__c = type, Period_Leave__c = 'All day',
            Term_From__c = days[0],
            Term_To__c = (workingDays == 1 ? null : days[workingDays - 1]),
            Remark__c = 'guard test', Status__c = status, OwnerId = employeeId()
        );
    }

    /** A file on the record, as the employee would attach it from the Files related list. */
    private static Id attachDocument(Id recordId, String title) {
        ContentVersion cv = new ContentVersion(
            Title = title, PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('medical certificate'), IsMajorVersion = true
        );
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(
            ContentDocumentId = docId, LinkedEntityId = recordId,
            ShareType = 'V', Visibility = 'AllUsers'
        );
        return docId;
    }

    private static void deleteDocument(Id docId) {
        delete [SELECT Id FROM ContentDocument WHERE Id = :docId];
    }

    private static String errorFrom(DmlException e) {
        return e.getDmlMessage(0);
    }

    /*
     * A three-day Personal leave request sitting in the org before the cap existed.
     *
     * Built through the bypass rather than by swapping policyOverride: the policy cache in
     * ApplicationItemTriggerLogic is filled once per transaction and never invalidated, so
     * a second override would be read from the first call's cache and silently ignored.
     */
    private static ApplicationItem__c oversizedLegacyRequest() {
        useTestPolicies();
        LeaveDocumentPolicy.bypassOverride = true;
        ApplicationItem__c appl = raise('Personal leave', 3, 'Draft');
        insert appl;
        LeaveDocumentPolicy.bypassOverride = false;
        return appl;
    }

    // ------------------------------------------------------------------ the day cap

    @isTest
    static void personalLeaveOfOneDayIsAllowed() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Personal leave', 1, 'Draft');
        insert appl;

        System.assertEquals(1, [SELECT Leave_Days__c FROM ApplicationItem__c WHERE Id = :appl.Id].Leave_Days__c,
            'a single day is exactly the cap and is left alone');
    }

    @isTest
    static void personalLeaveOfHalfADayIsAllowed() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Personal leave', 1, 'Draft');
        appl.Period_Leave__c = 'AM leave';
        insert appl;

        System.assertEquals(0.5, [SELECT Leave_Days__c FROM ApplicationItem__c WHERE Id = :appl.Id].Leave_Days__c,
            'half a day is under the cap, so a morning off is still one request');
    }

    @isTest
    static void personalLeaveOverOneDayIsRefused() {
        useTestPolicies();
        try {
            insert raise('Personal leave', 2, 'Draft');
            System.assert(false, 'a two-day personal leave request should not save');
        } catch (DmlException e) {
            System.assert(errorFrom(e).contains('at most 1 day'),
                'and should say so plainly: ' + errorFrom(e));
        }
    }

    /*
     * The hole the calendar span check exists to close. Saturday to Sunday counts no
     * working days at all, so Leave_Days__c reads 0 and the cap alone would wave it through
     * while it covers two dates.
     */
    @isTest
    static void personalLeaveAcrossAWeekendIsRefused() {
        useTestPolicies();
        Date saturday = Date.newInstance(System.today().year(), 3, 2);
        while (Math.mod(MONDAY_EPOCH.daysBetween(saturday), 7) != 5) {
            saturday = saturday.addDays(1);
        }
        ApplicationItem__c appl = new ApplicationItem__c(
            Request_Type__c = 'Personal leave', Period_Leave__c = 'All day',
            Term_From__c = saturday, Term_To__c = saturday.addDays(1),
            Remark__c = 'guard test', Status__c = 'Draft', OwnerId = employeeId()
        );
        try {
            insert appl;
            System.assert(false, 'two calendar dates is two days, whatever the day count says');
        } catch (DmlException e) {
            System.assert(errorFrom(e).contains('at most 1 day'), errorFrom(e));
        }
    }

    @isTest
    static void anUncappedTypeIsUnaffected() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Annual leave', 5, 'Draft');
        insert appl;

        System.assertEquals(5, [SELECT Leave_Days__c FROM ApplicationItem__c WHERE Id = :appl.Id].Leave_Days__c,
            'no cap configured, so five days is fine');
    }

    /*
     * The rule arrived after the data did. Somebody fixing a typo on a request that
     * predates it must not be made to redraw its dates first, which is why the cap is
     * scoped to saves that reshape the request.
     */
    @isTest
    static void anUnrelatedEditToAnOversizedRequestStillSaves() {
        ApplicationItem__c appl = oversizedLegacyRequest();

        appl.Remark__c = 'corrected remark';
        update appl;

        System.assertEquals('corrected remark',
            [SELECT Remark__c FROM ApplicationItem__c WHERE Id = :appl.Id].Remark__c,
            'the edit touched nothing the cap measures, so it saves');
    }

    @isTest
    static void reshapingAnOversizedRequestIsRefused() {
        ApplicationItem__c appl = oversizedLegacyRequest();

        appl.Term_To__c = appl.Term_To__c.addDays(1);
        try {
            update appl;
            System.assert(false, 'moving the dates is exactly when the cap should be applied');
        } catch (DmlException e) {
            System.assert(errorFrom(e).contains('at most 1 day'), errorFrom(e));
        }
    }

    // ------------------------------------------------------------- the document gate

    @isTest
    static void sickLeaveBelowTheThresholdSubmitsWithoutADocument() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Sick leave', 2, 'Draft');
        insert appl;

        appl.Status__c = 'Pending';
        update appl;

        System.assertEquals('Pending', [SELECT Status__c FROM ApplicationItem__c WHERE Id = :appl.Id].Status__c,
            'two days is under three, so no certificate is asked for');
    }

    @isTest
    static void sickLeaveAtTheThresholdIsRefusedWithoutADocument() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Sick leave', 3, 'Draft');
        insert appl;

        appl.Status__c = 'Pending';
        try {
            update appl;
            System.assert(false, 'three days needs a certificate');
        } catch (DmlException e) {
            System.assert(errorFrom(e).contains('requires a supporting document'), errorFrom(e));
            System.assert(errorFrom(e).contains('3 days or more'),
                'the message should name the threshold it is enforcing: ' + errorFrom(e));
        }

        System.assertEquals('Draft', [SELECT Status__c FROM ApplicationItem__c WHERE Id = :appl.Id].Status__c,
            'and the whole submission rolls back, leaving the request editable');
    }

    @isTest
    static void sickLeaveAtTheThresholdSubmitsWithADocument() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Sick leave', 3, 'Draft');
        insert appl;
        attachDocument(appl.Id, 'certificate');

        appl.Status__c = 'Pending';
        update appl;

        System.assertEquals('Pending', [SELECT Status__c FROM ApplicationItem__c WHERE Id = :appl.Id].Status__c,
            'the certificate is attached, so it goes to the manager');
    }

    @isTest
    static void personalLeaveAlwaysNeedsADocument() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Personal leave', 1, 'Draft');
        insert appl;

        appl.Status__c = 'Pending';
        try {
            update appl;
            System.assert(false, 'a zero threshold means every personal leave request needs one');
        } catch (DmlException e) {
            System.assert(errorFrom(e).contains('requires a supporting document'), errorFrom(e));
            System.assert(!errorFrom(e).contains('or more'),
                'and with no threshold to name, the message should not invent one: ' + errorFrom(e));
        }
    }

    @isTest
    static void aRequestCreatedAlreadyPendingIsRefused() {
        useTestPolicies();
        try {
            insert raise('Sick leave', 3, 'Pending');
            System.assert(false, 'nothing can be attached to a record that does not exist yet');
        } catch (DmlException e) {
            System.assert(errorFrom(e).contains('requires a supporting document'), errorFrom(e));
        }
    }

    @isTest
    static void editingAnAlreadyPendingRequestIsNotReChecked() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Sick leave', 3, 'Draft');
        insert appl;
        Id docId = attachDocument(appl.Id, 'certificate');

        appl.Status__c = 'Pending';
        update appl;

        // The manager annotating it is not a fresh submission, so the gate stays shut.
        appl.Remark__c = 'chased for details';
        update appl;

        System.assertEquals('chased for details',
            [SELECT Remark__c FROM ApplicationItem__c WHERE Id = :appl.Id].Remark__c,
            'a later edit to a pending request is not a second submission');
        System.assertNotEquals(null, docId);
    }

    // -------------------------------------------------------------- the removal lock

    @isTest
    static void theLastDocumentCannotBeRemovedWhilePending() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Sick leave', 3, 'Draft');
        insert appl;
        Id docId = attachDocument(appl.Id, 'certificate');
        appl.Status__c = 'Pending';
        update appl;

        try {
            deleteDocument(docId);
            System.assert(false, 'the approver is looking at this request right now');
        } catch (DmlException e) {
            System.assert(errorFrom(e).contains('cannot be removed'), errorFrom(e));
        }
    }

    @isTest
    static void oneOfSeveralDocumentsCanBeRemovedWhilePending() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Sick leave', 3, 'Draft');
        insert appl;
        Id first = attachDocument(appl.Id, 'certificate');
        attachDocument(appl.Id, 'replacement');
        appl.Status__c = 'Pending';
        update appl;

        deleteDocument(first);

        System.assertEquals(1,
            [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :appl.Id],
            'the invariant is that evidence exists, not that a particular file does');
    }

    /*
     * The other removal path. Deleting the ContentDocument takes its links with it as a
     * cascade, which fires no trigger on them, so unlinking is reached only through the
     * API - and is the only thing that exercises ContentDocumentLinkTrigger.
     */
    @isTest
    static void unlinkingTheLastDocumentIsRefusedWhilePending() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Sick leave', 3, 'Draft');
        insert appl;
        Id docId = attachDocument(appl.Id, 'certificate');
        appl.Status__c = 'Pending';
        update appl;

        try {
            delete [SELECT Id FROM ContentDocumentLink
                    WHERE LinkedEntityId = :appl.Id AND ContentDocumentId = :docId];
            System.assert(false, 'detaching the file leaves the request just as bare');
        } catch (DmlException e) {
            System.assert(errorFrom(e).contains('cannot be removed'), errorFrom(e));
        }
    }

    @isTest
    static void unlinkingOneOfSeveralDocumentsIsAllowed() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Sick leave', 3, 'Draft');
        insert appl;
        Id first = attachDocument(appl.Id, 'certificate');
        attachDocument(appl.Id, 'replacement');
        appl.Status__c = 'Pending';
        update appl;

        delete [SELECT Id FROM ContentDocumentLink
                WHERE LinkedEntityId = :appl.Id AND ContentDocumentId = :first];

        System.assertEquals(1,
            [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :appl.Id],
            'evidence still exists, so the link was free to go');
    }

    @isTest
    static void aDocumentCanBeRemovedWhileTheRequestIsStillDraft() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Sick leave', 3, 'Draft');
        insert appl;
        Id docId = attachDocument(appl.Id, 'certificate');

        deleteDocument(docId);

        System.assertEquals(0,
            [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :appl.Id],
            'nothing has been decided on the strength of it yet');
    }

    @isTest
    static void theLastDocumentCannotBeRemovedOnceApproved() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Sick leave', 3, 'Draft');
        insert appl;
        Id docId = attachDocument(appl.Id, 'certificate');

        Test.startTest();
        appl.Status__c = 'Approved';
        update appl;
        Test.stopTest();

        try {
            deleteDocument(docId);
            System.assert(false, 'the balance is spent on the strength of this document');
        } catch (DmlException e) {
            System.assert(errorFrom(e).contains('cannot be removed'), errorFrom(e));
        }
    }

    @isTest
    static void aTypeNeedingNoDocumentDoesNotLockItsFiles() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Annual leave', 3, 'Draft');
        insert appl;
        Id docId = attachDocument(appl.Id, 'itinerary');
        appl.Status__c = 'Pending';
        update appl;

        deleteDocument(docId);

        System.assertEquals(0,
            [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :appl.Id],
            'annual leave never required it, so nothing is being protected');
    }

    /*
     *  upports deleting an approved request, and the platform takes its
     * ContentDocumentLinks with it. Without the note taken in the before-delete context
     * that cascade reads as somebody stripping the certificate off an approved request.
     */
    @isTest
    static void deletingTheRequestItselfIsNotBlockedByItsOwnDocument() {
        useTestPolicies();
        ApplicationItem__c appl = raise('Sick leave', 3, 'Draft');
        insert appl;
        attachDocument(appl.Id, 'certificate');
        appl.Status__c = 'Pending';
        update appl;

        Test.startTest();
        delete appl;
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM ApplicationItem__c WHERE Id = :appl.Id],
            'the request goes, and its document goes with it');
    }

    @isTest
    static void aFileOnAnUnrelatedRecordIsUntouched() {
        useTestPolicies();
        // Not an Account: AccountTrigger fires a Gemini callout on insert, which has no
        // mock here. A balance row carries no trigger at all.
        Leave_Balance__c bal = [SELECT Id FROM Leave_Balance__c LIMIT 1];
        Id docId = attachDocument(bal.Id, 'unrelated');

        deleteDocument(docId);

        System.assertEquals(0, [SELECT COUNT() FROM ContentDocument WHERE Id = :docId],
            'the trigger fires org-wide and must let everything else through');
    }

    // -------------------------------------------------------------------- the bypass

    @isTest
    static void theBypassLiftsEveryRule() {
        useTestPolicies();
        LeaveDocumentPolicy.bypassOverride = true;

        ApplicationItem__c appl = raise('Personal leave', 3, 'Draft');
        insert appl; // over the cap

        Id docId = attachDocument(appl.Id, 'certificate');
        appl.Status__c = 'Pending';
        update appl;

        deleteDocument(docId); // and the document comes back off

        System.assertEquals('Pending', [SELECT Status__c FROM ApplicationItem__c WHERE Id = :appl.Id].Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :appl.Id],
            'HR can unpick a request that was filed wrongly');
    }

    // ---------------------------------------------------------------------- in bulk

    @isTest
    static void twoHundredValidRequestsSaveInOneTransaction() {
        useTestPolicies();
        List<ApplicationItem__c> batch = new List<ApplicationItem__c>();
        for (Integer i = 0; i < 200; i++) {
            batch.add(raise('Personal leave', 1, 'Draft'));
        }

        Test.startTest();
        insert batch;
        Test.stopTest();

        System.assertEquals(200, [SELECT COUNT() FROM ApplicationItem__c WHERE Status__c = 'Draft'],
            'the cap is evaluated in memory and costs no query per record');
    }

    @isTest
    static void aBulkSubmitCostsOneDocumentQuery() {
        useTestPolicies();
        List<ApplicationItem__c> batch = new List<ApplicationItem__c>();
        for (Integer i = 0; i < 100; i++) {
            batch.add(raise('Sick leave', 3, 'Draft'));
        }
        insert batch;

        for (ApplicationItem__c appl : batch) {
            appl.Status__c = 'Pending';
        }

        Test.startTest();
        Integer before = Limits.getQueries();
        List<Database.SaveResult> results = Database.update(batch, false);
        Integer spent = Limits.getQueries() - before;
        Test.stopTest();

        for (Database.SaveResult sr : results) {
            System.assert(!sr.isSuccess(), 'none of them has a certificate attached');
        }
        System.assert(spent <= 5,
            'the document lookup is one query for the batch, not one per record: ' + spent);
    }
}