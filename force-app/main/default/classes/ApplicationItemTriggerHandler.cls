public class ApplicationItemTriggerHandler {

    private ApplicationItemTriggerLogic logic = new ApplicationItemTriggerLogic();

    /*
     * LEAVE-13 runs in the before contexts so that Carry_Over_Days_Used__c can be set
     * on the in-flight record without any DML on ApplicationItem__c.
     */
    public void onBeforeInsert(List<ApplicationItem__c> newList) {
        logic.deductLeaveBalance(newlyApproved(newList, null));
    }

    public void onBeforeUpdate(List<ApplicationItem__c> newList, Map<Id, ApplicationItem__c> oldMap) {
        logic.deductLeaveBalance(newlyApproved(newList, oldMap));
    }

    /*
     * LEAVE-12. A record inserted already Approved has no prior state, so every
     * approved row counts as newly approved.
     */
    public void onAfterInsert(List<ApplicationItem__c> newList) {
        process(newlyApproved(newList, null));
    }

    public void onAfterUpdate(List<ApplicationItem__c> newList, Map<Id, ApplicationItem__c> oldMap) {
        process(newlyApproved(newList, oldMap));
    }

    /*
     * Only records crossing INTO Approved qualify. Previously any update to an
     * already-approved record re-fired this path and created a duplicate calendar
     * Event and a duplicate Man_hour__c — editing the remark was enough to do it.
     * The same check is what keeps LEAVE-13 from deducting a balance twice, which is
     * why no Balance_Applied__c flag is needed.
     */
    private List<ApplicationItem__c> newlyApproved(List<ApplicationItem__c> newList,
                                                   Map<Id, ApplicationItem__c> oldMap) {
        List<ApplicationItem__c> justApproved = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : newList) {
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