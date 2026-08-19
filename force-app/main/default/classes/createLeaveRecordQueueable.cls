public with sharing class createLeaveRecordQueueable implements Queueable {
    private List<ApplicationItem__c> appitems;

    /*
     * the batch now travels in one job. The handler used to enqueue one
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
     * createBookings rather than createLeaveRecords. The batch can now hold
     * both leave and overtime, and the logic class routes each by record type.
     *
     * re-read before booking. This job runs after the transaction that
     * enqueued it, and a request can be rejected in between — the reversal then finds
     * no bookings to remove, and this job goes on to create them for an absence that
     * was refused. The in-memory copies still say Approved, so only the database can
     * settle it.
     */
    public void execute(QueueableContext context) {
        Set<Id> ids = new Set<Id>();
        for (ApplicationItem__c appl : appitems) {
            if (appl != null && appl.Id != null) {
                ids.add(appl.Id);
            }
        }

        List<ApplicationItem__c> toBook = appitems;
        if (!ids.isEmpty()) {
            toBook = [
                SELECT Id, RecordTypeId, Request_Type__c, Period_Leave__c, Status__c,
                       Term_From__c, Term_To__c, Remark__c, OwnerId, OT_Start__c, OT_End__c,
                       Project__c
                FROM ApplicationItem__c
                WHERE Id IN :ids AND Status__c = 'Approved'
            ];
        }
        new CreateLeaveRecordOnManInputTriggerLogic().createBookings(toBook);
    }
}