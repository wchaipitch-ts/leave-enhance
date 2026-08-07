public with sharing class createLeaveRecordQueueable implements Queueable {
    private ApplicationItem__c appitem;

    // Constructor
    public createLeaveRecordQueueable(ApplicationItem__c appitem) {
        this.appitem = appitem;
    }

    public void execute(QueueableContext context) {
        CreateLeaveRecordOnManInputTriggerLogic createLeaveLogic = new CreateLeaveRecordOnManInputTriggerLogic();
        createLeaveLogic.createLeaveRecord(appitem);
    }
}