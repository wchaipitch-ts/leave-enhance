public without sharing class WebToCaseServiceCtrl {
  @AuraEnabled
  public static Id createCase(Map<String, Object> caseData) {
    try {
      Case newCase = new Case();
      newCase.Subject = (String) caseData.get('subject');
      newCase.Description = (String) caseData.get('description');
      newCase.Priority = (String) caseData.get('priority');
      newCase.Origin = 'Web';
      newCase.SuppliedEmail = (String) caseData.get('email');
      newCase.SuppliedPhone = (String) caseData.get('phone');
      newCase.SuppliedCompany = (String) caseData.get('company');

      // Custom fields
      newCase.First_Name__c = caseData.get('firstName') != null? (String) caseData.get('firstName'): newCase.First_Name__c;
      newCase.Last_Name__c = caseData.get('lastName') != null? (String) caseData.get('lastName'): newCase.Last_Name__c;
      newCase.Nickname__c = caseData.get('nickName') != null? (String) caseData.get('nickName'): newCase.Nickname__c;
      newCase.Related_Product__c = caseData.get('product') != null? (String) caseData.get('product'): newCase.Related_Product__c;
      newCase.Source__c = caseData.get('source') != null? (String) caseData.get('source'): null;
      newCase.Status = caseData.get('status') != null? (String) caseData.get('status'): 'New';
      newCase.Case_Initiator_TSTH_Employee_name__c = caseData.get(
          'Initiator'
        ) != null? (String) caseData.get('initiator'): null;
      newCase.Comment__c = caseData.get('comment') != null? (String) caseData.get('comment'): null;

      insert newCase;

      System.debug('Case created successfully with ID: ' + newCase.Id);
      return newCase.Id;
    } catch (Exception e) {
      System.debug('Error creating case: ' + e.getMessage());
      throw new AuraHandledException('Error creating case: ' + e.getMessage());
    }
  }
}