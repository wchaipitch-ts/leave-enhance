@isTest
public with sharing class ManHoursInlineEditableControllerTest {

    @TestSetup
    static void prepareData(){

        // Prepare User data
        Profile profile = [SELECT Id FROM Profile WHERE Name='Standard User']; 
        User user = new User(
            Alias = 'standard',
            Email='standarduser@test.com.dev1', 
            EmailEncodingKey='UTF-8',
            LastName='Testing',
            LanguageLocaleKey='en_US', 
            LocaleSidKey='ja_JP',
            ProfileId = profile.Id, 
            TimeZoneSidKey='Asia/Bangkok',
            UserName='standarduser@test.com.dev1'
        );
        insert user;

        // Prepare Project__c data
        Date startDate = Date.valueOf('2022-12-31');
        Date dueDate = Date.valueOf('2022-12-31');
        Project__c project = new Project__c(
            Project_Name__c='Test Project',
            Project_Status__c='Not Started',
            Project_Detail__c='Test Project',
            Start_Date__c=startDate,
            Due_Date__c=dueDate,
            Remark__c='Test Project'
        );
        insert project;

        // Prepare ProjectAssign__c data
        ProjectAssign__c projectAssign = new ProjectAssign__c(
            Project_No__c=project.Id,
            Assignee__c=user.Id,
            Start_Date__c=startDate,
            Due_Date__c=dueDate,
            Planning_Hours__c=1,
            Remark__c='Test ProjectAssign'
        );
        insert projectAssign;

        // Prepare Man_hour__c data
        Date performedDate = Date.valueOf('2022-12-31');
        Man_hour__c manHour = new Man_hour__c(
            ProjectAssign_No__c=projectAssign.Id,
            Work__c='Test ProjectAssign 01',
            Performed_Date__c=performedDate,
            Performed_Hours__c=1,
            Remark__c='Test ProjectAssign'
        );
        insert manHour;
        Man_hour__c manHour2 = new Man_hour__c(
            ProjectAssign_No__c=projectAssign.Id,
            Work__c='Test ProjectAssign 02',
            Performed_Date__c=performedDate,
            Performed_Hours__c=2,
            Remark__c='Test ProjectAssign'
        );
        insert manHour2;

    }

    @isTest
    static void fetchRecordsSuccessTest(){
        Project__c project = [SELECT Id FROM Project__c WHERE Project_Name__c='Test Project' LIMIT 1];
        ProjectAssign__c projectAssign = [SELECT Id, Name, Start_Date__c, Due_Date__c, OwnerId, Assignee__c FROM ProjectAssign__c WHERE Project_No__c=:project.Id LIMIT 1];
        List<Man_hour__c> manHours = [SELECT Id, Name, Work__c, Performed_Date__c, Performed_Hours__c, Remark__c FROM Man_hour__c WHERE ProjectAssign_No__c=:projectAssign.Id];

        List<ManHoursInlineEditableController.FieldWrapper> fieldWrapperList = new List<ManHoursInlineEditableController.FieldWrapper>();
        fieldWrapperList.add(new ManHoursInlineEditableController.FieldWrapper(
            'Man hour No.',
            'Name',
            'STRING',
            'text',
            true,
            false
        ));
        fieldWrapperList.add(new ManHoursInlineEditableController.FieldWrapper(
            'Work',
            'Work__c',
            'STRING',
            'text',
            false,
            true
        ));
        fieldWrapperList.add(new ManHoursInlineEditableController.FieldWrapper(
            'Performed Date',
            'Performed_Date__c',
            'DATE',
            'date',
            true,
            true
        ));
        fieldWrapperList.add(new ManHoursInlineEditableController.FieldWrapper(
            'Performed Hour',
            'Performed_Hours__c',
            'DOUBLE',
            'number',
            true,
            true
        ));
        fieldWrapperList.add(new ManHoursInlineEditableController.FieldWrapper(
            'Remask',
            'Remark__c',
            'STRING',
            'text',
            true,
            false
        ));

        Test.startTest();
        ManHoursInlineEditableController.ReturnWrapper returnWrapper = new ManHoursInlineEditableController.ReturnWrapper();
        returnWrapper = ManHoursInlineEditableController.fetchRecords(projectAssign.Id);
        
        System.assert(projectAssign.Id == returnWrapper.parentRecord.Id);
        System.assert(projectAssign.Name == returnWrapper.parentRecord.Name);
        System.assert(projectAssign.Start_Date__c == returnWrapper.parentRecord.Start_Date__c);
        System.assert(projectAssign.Due_Date__c == returnWrapper.parentRecord.Due_Date__c);
        System.assert(projectAssign.OwnerId == returnWrapper.parentRecord.OwnerId);
        System.assert(projectAssign.Assignee__c == returnWrapper.parentRecord.Assignee__c);

        for(Man_hour__c manHour: manHours) {
            for(Man_hour__c record: returnWrapper.recordList) {
                if(manHour.Id == record.Id) {
                    System.assert(manHour.Id == record.Id);
                    System.assert(manHour.Name == record.Name);
                    System.assert(manHour.Work__c == record.Work__c);
                    System.assert(manHour.Performed_Date__c == record.Performed_Date__c);
                    System.assert(manHour.Performed_Hours__c == record.Performed_Hours__c);
                    System.assert(manHour.Remark__c == record.Remark__c);
                }
            }
        }
        for(ManHoursInlineEditableController.FieldWrapper fieldWrapper: fieldWrapperList) {
            for(ManHoursInlineEditableController.FieldWrapper field: returnWrapper.fieldsList) {
                if(fieldWrapper.label == field.label) {
                    System.assert(fieldWrapper.label == field.label);
                    System.assert(fieldWrapper.value == field.value);
                    System.assert(fieldWrapper.dataType == field.dataType);
                    System.assert(fieldWrapper.ltngType == field.ltngType);
                    System.assert(fieldWrapper.isRequired == field.isRequired);
                    System.assert(fieldWrapper.isEditable == field.isEditable);
                }
            }
        }
        Test.stopTest();
    }

    @isTest
    static void fetchRecordsErrorrTest(){
        Project__c project = [SELECT Id FROM Project__c WHERE Project_Name__c='Test Project' LIMIT 1];

        ManHoursInlineEditableController.ReturnWrapper expectWrapper = new ManHoursInlineEditableController.ReturnWrapper();

        Test.startTest();
        ManHoursInlineEditableController.ReturnWrapper returnWrapper = new ManHoursInlineEditableController.ReturnWrapper();
        try {
            returnWrapper = ManHoursInlineEditableController.fetchRecords(project.Id);
        } catch (Exception err) {
            System.assert('Script-thrown exception' == err.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void saveRecordSuccessTest(){
        Project__c project = [SELECT Id FROM Project__c WHERE Project_Name__c='Test Project' LIMIT 1];
        ProjectAssign__c projectAssign = [SELECT Id FROM ProjectAssign__c WHERE Project_No__c=:project.Id LIMIT 1];

        Man_hour__c manHour1 = [SELECT Id FROM Man_hour__c WHERE Work__c='Test ProjectAssign 01' LIMIT 1];
        Man_hour__c manHour2 = [SELECT Id FROM Man_hour__c WHERE Work__c='Test ProjectAssign 02' LIMIT 1];

        Map<String, List<String>> processRecords = new Map<String, List<String>>();
        processRecords.put('insert', new List<String>{
            '{"Work__c":"Test ProjectAssign 03","Performed_Date__c":"2022-10-31","Performed_Hours__c":3,"Remark__c":"Test ProjectAssign"}'
        });
        processRecords.put('update', new List<String>{
            '{"Id":"' + manHour2.Id + '","Work__c":"Test ProjectAssign 02","Performed_Date__c":"2022-10-31","Performed_Hours__c":"2","Remark__c":"Test ProjectAssign"}'
        });
        processRecords.put('delete', new List<String>{
            '{"Id":"' + manHour1.Id + '","Work__c":"Test ProjectAssign 01","Performed_Date__c":"2022-10-31","Performed_Hours__c":"1","Remark__c":"Test ProjectAssign"}'
        });

        Test.startTest();
        String saveStatus = ManHoursInlineEditableController.saveRecord(projectAssign.Id, processRecords);
        System.assert('success' == saveStatus);
        Test.stopTest();
    }

    @isTest
    static void saveRecordErrorTest(){
        Project__c project = [SELECT Id FROM Project__c WHERE Project_Name__c='Test Project' LIMIT 1];
        ProjectAssign__c projectAssign = [SELECT Id FROM ProjectAssign__c WHERE Project_No__c=:project.Id LIMIT 1];

        Map<String, List<String>> processRecords = new Map<String, List<String>>();
        processRecords.put('update', new List<String>{
            '{"Work__c":"Test ProjectAssign 02","Performed_Date__c":"2022-10-31","Performed_Hours__c":"2","Remark__c":"Test ProjectAssign"}'
        });

        Test.startTest();
        try {
            String saveStatus = ManHoursInlineEditableController.saveRecord(projectAssign.Id, processRecords);
        } catch (Exception err) {
            System.assert('Script-thrown exception' == err.getMessage());
        }
        Test.stopTest();
    }
}