public class ApplicationItemTriggerHandler {

    private ApplicationItemTriggerLogic logic = new ApplicationItemTriggerLogic();

    /*
     * LEAVE-23 — record type gate.
     *
     * Leave and Overtime requests share ApplicationItem__c, but only a Leave Request
     * moves a balance, produces a leave calendar Event, or books a leave Man_hour__c.
     * Every one of those is wrong for overtime.
     *
     * Without this gate an Overtime Request either cannot be approved at all (its
     * Request_Type__c has no Leave Type Policy row, so deductLeaveBalance raises
     * addError) or, worse, silently deducts leave when it happens to carry a
     * leave type.
     *
     * Resolved by developer name rather than a hardcoded Id so the same code runs in
     * every org. If Overtime_Request is ever removed the lookup returns null and every
     * record is treated as a leave request, which is the behaviour that predates this.
     * Records still on the Master record type are leave requests for the same reason.
     */
    private static final Id OVERTIME_RECORD_TYPE_ID = resolveOvertimeRecordTypeId();

    private static Id resolveOvertimeRecordTypeId() {
        Schema.RecordTypeInfo info = Schema.SObjectType.ApplicationItem__c
            .getRecordTypeInfosByDeveloperName()
            .get('Overtime_Request');
        return info == null ? null : info.getRecordTypeId();
    }

    private static Boolean isLeaveRequest(ApplicationItem__c appl) {
        return !isOvertimeRequest(appl);
    }

    /*
     * Public so the Man_hour__c booking can route a mixed batch without resolving the
     * record type a second time. If Overtime_Request is missing the answer is always
     * false, which keeps the pre-record-type behaviour of treating everything as leave.
     */
    public static Boolean isOvertimeRequest(ApplicationItem__c appl) {
        return OVERTIME_RECORD_TYPE_ID != null
            && appl.RecordTypeId == OVERTIME_RECORD_TYPE_ID;
    }

    /*
     * LEAVE-13 / LEAVE-25 run in the before contexts so that Leave_Days__c and
     * Carry_Over_Days_Used__c are set on the in-flight record without any DML on
     * ApplicationItem__c.
     *
     * calculateLeaveDays runs over EVERY leave request, not just approved ones, so
     * the day count is right from Draft onward. It must run before deductLeaveBalance,
     * which reads the figure it writes.
     */
    public void onBeforeInsert(List<ApplicationItem__c> newList) {
        beforeSave(leaveRequests(newList), null);
        logic.calculateOvertimeHours(overtimeRequests(newList));
    }

    public void onBeforeUpdate(List<ApplicationItem__c> newList, Map<Id, ApplicationItem__c> oldMap) {
        beforeSave(leaveRequests(newList), oldMap);
        logic.calculateOvertimeHours(overtimeRequests(newList));
    }

    /*
     * LEAVE-30. The order of these four is load-bearing:
     *
     *   1. calculateLeaveDays  writes Leave_Days__c, which everything below reads.
     *   2. assess              forecasts the unpaid portion from Leave_Days__c and
     *                          flags the request for the Managing Director. Must come
     *                          after step 1 or it measures a stale day count.
     *   3. stampApproval       records the sign-off. After step 2 so that a Managing
     *                          Director approving a request whose length changed in
     *                          this same save signs for the new figure, not the old.
     *   4. deductLeaveBalance  settles the split for real and moves the balance.
     */
    private void beforeSave(List<ApplicationItem__c> requests, Map<Id, ApplicationItem__c> oldMap) {
        logic.calculateLeaveDays(requests);
        LeaveWithoutPayService.assess(requests, oldMap);
        LeaveWithoutPayService.stampApproval(requests, oldMap);
        logic.deductLeaveBalance(justApproved(requests, oldMap));
    }

    /*
     * LEAVE-12. A record inserted already Approved has no prior state, so every
     * approved row counts as newly approved.
     */
    public void onAfterInsert(List<ApplicationItem__c> newList) {
        afterSave(newList, null);
    }

    public void onAfterUpdate(List<ApplicationItem__c> newList, Map<Id, ApplicationItem__c> oldMap) {
        afterSave(newList, oldMap);
    }

    /*
     * LEAVE-31. Both kinds of request book a Man_hour__c on approval, so both travel
     * in the same Queueable and the logic class routes each by record type. Only leave
     * produces a calendar Event: an overtime claim is a record of hours already
     * worked, not an absence anyone needs to see blocked out in a diary.
     */
    private void afterSave(List<ApplicationItem__c> newList, Map<Id, ApplicationItem__c> oldMap) {
        List<ApplicationItem__c> approvedLeave = justApproved(leaveRequests(newList), oldMap);
        List<ApplicationItem__c> approvedOvertime = justApproved(overtimeRequests(newList), oldMap);

        if (!approvedLeave.isEmpty()) {
            logic.setLeaveDateTime(approvedLeave);
        }

        List<ApplicationItem__c> toBook = new List<ApplicationItem__c>();
        toBook.addAll(approvedLeave);
        toBook.addAll(approvedOvertime);
        process(toBook);
    }

    /*
     * Leave Requests: everything that is not explicitly an Overtime Request, so a
     * record on the Master record type is treated as leave.
     */
    private List<ApplicationItem__c> leaveRequests(List<ApplicationItem__c> newList) {
        List<ApplicationItem__c> requests = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : newList) {
            if (isLeaveRequest(appl)) {
                requests.add(appl);
            }
        }
        return requests;
    }

    private List<ApplicationItem__c> overtimeRequests(List<ApplicationItem__c> newList) {
        List<ApplicationItem__c> requests = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : newList) {
            if (!isLeaveRequest(appl)) {
                requests.add(appl);
            }
        }
        return requests;
    }

    /*
     * Only records crossing INTO Approved qualify. Previously any update to an
     * already-approved record re-fired this path and created a duplicate calendar
     * Event and a duplicate Man_hour__c — editing the remark was enough to do it.
     * The same check is what keeps the deduction from running twice, which is why no
     * Balance_Applied__c flag is needed.
     */
    private List<ApplicationItem__c> justApproved(List<ApplicationItem__c> requests,
                                                  Map<Id, ApplicationItem__c> oldMap) {
        List<ApplicationItem__c> approved = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : requests) {
            if (appl.Status__c != 'Approved') {
                continue;
            }
            if (oldMap == null) {
                approved.add(appl);
                continue;
            }
            ApplicationItem__c prior = oldMap.get(appl.Id);
            if (prior != null && prior.Status__c != 'Approved') {
                approved.add(appl);
            }
        }
        return approved;
    }

    /*
     * LEAVE-11. One Queueable for the whole batch rather than one per record:
     * the previous loop burned a job per row against a 50-job ceiling, and did so
     * even for records that were not approved.
     */
    private void process(List<ApplicationItem__c> approved) {
        if (approved.isEmpty()) {
            return;
        }
        System.enqueueJob(new createLeaveRecordQueueable(approved));
    }
}
