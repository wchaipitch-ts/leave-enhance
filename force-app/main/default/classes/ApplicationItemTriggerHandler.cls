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
     * LEAVE-13 / LEAVE-25 run in the before contexts so that Leave_Days__c,
     * Carry_Over_Days_Used__c and the balance lookup are set on the in-flight record
     * without any DML on ApplicationItem__c.
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
        // LEAVE-34. Entering and leaving Approved are disjoint sets, so this cannot
        // collide with the deduction above.
        LeaveReversalService.restoreBalances(justUnapproved(newList, oldMap));
    }

    /*
     * Order matters: calculateLeaveDays writes Leave_Days__c, and deductLeaveBalance
     * reads it to decide how much balance to move.
     */
    private void beforeSave(List<ApplicationItem__c> requests, Map<Id, ApplicationItem__c> oldMap) {
        logic.calculateLeaveDays(requests);
        logic.deductLeaveBalance(justApproved(requests, oldMap));
    }

    /*
     * LEAVE-12. A record inserted already Approved has no prior state, so every
     * approved row counts as newly approved.
     */
    /*
     * LEAVE-33. The split runs after insert, not on approval: the unpaid record has to
     * point back at a saved parent, and the employee should see what will not be paid
     * at the moment they save rather than after somebody signs it.
     */
    public void onAfterInsert(List<ApplicationItem__c> newList) {
        LeaveSplitService.splitOverBalance(leaveRequests(newList));
        afterSave(newList, null);
    }

    public void onAfterUpdate(List<ApplicationItem__c> newList, Map<Id, ApplicationItem__c> oldMap) {
        afterSave(newList, oldMap);

        /*
         * LEAVE-34. Both run in the after context on purpose. EventTriggerLogic refuses
         * a delete while the request still reads Approved; by here it reads Rejected and
         * the guard lets it through. Promotion likewise needs the freed balance to have
         * been written, which happened in the before context above.
         */
        Set<Id> unapproved = idsOf(justUnapproved(newList, oldMap));
        if (!unapproved.isEmpty()) {
            LeaveReversalService.clearBookings(unapproved);
            LeaveReversalService.promoteUnpaidSiblings(unapproved);
        }
    }

    /*
     * LEAVE-34. Deleting an approved request has to give the balance back too. The
     * trigger declared after delete from the beginning but never routed it, so until
     * now a delete silently kept the days spent.
     */
    public void onBeforeDelete(List<ApplicationItem__c> oldList) {
        // The lookup from Man_hour__c is nulled as part of the delete, so the rows have
        // to be identified while it still points somewhere.
        LeaveReversalService.rememberBookingsOf(oldList);
    }

    public void onAfterDelete(List<ApplicationItem__c> oldList) {
        List<ApplicationItem__c> approved = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : oldList) {
            if (appl.Status__c == 'Approved') {
                approved.add(appl);
            }
        }
        LeaveReversalService.restoreBalancesForDeleted(approved);
        LeaveReversalService.clearBookings(new Map<Id, ApplicationItem__c>(oldList).keySet());
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
    /*
     * LEAVE-34. The mirror of justApproved: records crossing OUT of Approved. Only a
     * transition counts, so editing an already-rejected record cannot give the days
     * back a second time.
     */
    private List<ApplicationItem__c> justUnapproved(List<ApplicationItem__c> newList,
                                                    Map<Id, ApplicationItem__c> oldMap) {
        List<ApplicationItem__c> leaving = new List<ApplicationItem__c>();
        if (oldMap == null) {
            return leaving;
        }
        for (ApplicationItem__c appl : newList) {
            ApplicationItem__c prior = oldMap.get(appl.Id);
            if (prior != null && prior.Status__c == 'Approved' && appl.Status__c != 'Approved') {
                leaving.add(appl);
            }
        }
        return leaving;
    }

    private Set<Id> idsOf(List<ApplicationItem__c> records) {
        return new Map<Id, ApplicationItem__c>(records).keySet();
    }

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
