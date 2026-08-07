public with sharing class BulkLeadConvertScheduler implements Schedulable {
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new BulkLeadConvertBatch(), 200);
    }
}