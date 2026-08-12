public class ApplicationItemTriggerHandler {

    private ApplicationItemTriggerLogic logic = new ApplicationItemTriggerLogic();

    /*
     * LEAVE-23 — record type gate.
     *
     * Leave and Overtime requests share ApplicationItem__c, but only a Leave Request
     * moves a balance, produces a leave calendar Event, or books a leave Man_hour__c.
     * Every one of those is wrong for overtime.
     *
     * Without this gate an Overtime Request cannot be approved at all: its
     * Request_Type__c is not a leave type, so deductLeaveBalance falls through to its
     * addError branch and blocks the save.
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
        return OVERTIME_RECORD_TYPE_ID == null
            || appl.RecordTypeId != OVERTIME_RECORD_TYPE_ID;
    }

    /*
     * LEAVE-13 runs in the before contexts so that Carry_Over_Days_Used__c can be set
     * on the in-flight record without any DML on ApplicationItem__c.
     */
    public void onBeforeInsert(List<ApplicationItem__c> newList) {
        logic.deductLeaveBalance(leaveRequestsJustApproved(newList, null));
    }

    public void onBeforeUpdate(List<ApplicationItem__c> newList, Map<Id, ApplicationItem__c> oldMap) {
        logic.deductLeaveBalance(leaveRequestsJustApproved(newList, oldMap));
    }

    /*
     * LEAVE-12. A record inserted already Approved has no prior state, so every
     * approved row counts as newly approved.
     */
    public void onAfterInsert(List<ApplicationItem__c> newList) {
        process(leaveRequestsJustApproved(newList, null));
    }

    public void onAfterUpdate(List<ApplicationItem__c> newList, Map<Id, ApplicationItem__c> oldMap) {
        process(leaveRequestsJustApproved(newList, oldMap));
    }

    /*
     * Leave Requests crossing INTO Approved, and nothing else.
     *
     * The approval transition is what prevents duplicate work: previously any update to
     * an already-approved record re-fired this path and created a second calendar Event
     * and a second Man_hour__c — editing the remark was enough to do it. The same check
     * is what keeps LEAVE-13 from deducting a balance twice, which is why no
     * Balance_Applied__c flag is needed.
     *
     * The record type filter (LEAVE-23) lives here because this method is the single
     * chokepoint feeding all three side effects. Overtime will need its own approval
     * path; it does not belong on this one.
     */
    private List<ApplicationItem__c> leaveRequestsJustApproved(List<ApplicationItem__c> newList,
                                                               Map<Id, ApplicationItem__c> oldMap) {
        List<ApplicationItem__c> justApproved = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : newList) {
            if (!isLeaveRequest(appl)) {
                continue;
            }
            if (appl.Status__c != 'Approved') {
                continue;
            }
            if (oldMap == null) {
                justApproved.add(appl);
                continue;
            }
            ApplicationItem__c prior = oldMap.get(appl.Id);
            if (prior != null && prior.Status__c != 'Approved') {
                justApproved.add(appl);
            }
        }
        return justApproved;
    }

    /*
     * LEAVE-11. One Queueable for the whole batch rather than one per record:
     * the previous loop burned a job per row against a 50-job ceiling, and did so
     * even for records that were not approved.
     */
    private void process(List<ApplicationItem__c> justApproved) {
        if (justApproved.isEmpty()) {
            return;
        }
        logic.setLeaveDateTime(justApproved);
        System.enqueueJob(new createLeaveRecordQueueable(justApproved));
    }
}
