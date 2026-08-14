public with sharing class createLeaveRecordQueueable implements Queueable {
    private List<ApplicationItem__c> appitems;

    /*
     * LEAVE-11: the batch now travels in one job. The handler used to enqueue one
     * of these per record, against a ceiling of 50 jobs per transaction.
     */
    public createLeaveRecordQueueable(List<ApplicationItem__c> appitems) {
        this.appitems = appitems;
    }

    // Single-record form retained for existing callers and tests.
    public createLeaveRecordQueueable(ApplicationItem__c appitem) {
        this.appitems = new List<ApplicationItem__c>{ appitem };
    }

    /*
     * LEAVE-31: createBookings rather than createLeaveRecords. The batch can now hold
     * both leave and overtime, and the logic class routes each by record type.
     */
    public void execute(QueueableContext context) {
        new CreateLeaveRecordOnManInputTriggerLogic().createBookings(appitems);
    }
}