public without sharing class FlowApprovalAction {
    @InvocableMethod(label='Approve Workitems')
    public static List<String> approveItems(List<List<Id>> flowWorkitemIds) {
        List<String> results = new List<String>();
		//Savepoint sp = Database.setSavepoint();
        try {
            System.debug('flowWorkitemIds[0] : ' + flowWorkitemIds);
            List<Id> workitemIds = flowWorkitemIds[0];
            List<Approval.ProcessWorkitemRequest> reqs = new List<Approval.ProcessWorkitemRequest>();

            for (Id workitemId : workitemIds) {
                Approval.ProcessWorkitemRequest req = new Approval.ProcessWorkitemRequest();
                req.setComments('Auto-approved via flow');
                req.setAction('Approve');
                req.setWorkitemId(workitemId);
                reqs.add(req);
            }

            if (!reqs.isEmpty()) {
                List<Approval.ProcessResult> resultsList = Approval.process(reqs);
                Boolean hasError = false;
                for (Approval.ProcessResult result : resultsList) {
                    if (!result.isSuccess()) {
                        hasError = true;
                        results.add('Failure: ' + result.getInstanceStatus() + ' - ' + result.getErrors());
                    }
                }

                if (!hasError) {
                    results.add('Success');
                }
            } else {
                results.add('No work items provided');
            }
             //Database.rollback(sp);
        } catch (Exception ex) {
            results.add('Failure: ' + ex.getMessage());
        }
        //results.add('Failure');
        return results;
    }
}