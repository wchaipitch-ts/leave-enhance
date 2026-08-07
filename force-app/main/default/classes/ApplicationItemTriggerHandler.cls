public class ApplicationItemTriggerHandler {

    ApplicationItemTriggerLogic logic = new ApplicationItemTriggerLogic();

    CreateLeaveRecordOnManInputTriggerLogic createLeaveLogic = new CreateLeaveRecordOnManInputTriggerLogic();

    public void onAfterUpdate (List<ApplicationItem__c> newList) {
        logic.setLeaveDateTime(newList);
        for (ApplicationItem__c appl : newList) {
            System.enqueueJob(new createLeaveRecordQueueable(appl));
            // createLeaveLogic.createLeaveRecord(appl);
        }
    }

}