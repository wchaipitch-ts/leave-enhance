public with sharing class ManHoursInlineEditableController {

	@AuraEnabled
    public static ReturnWrapper fetchRecords(String parentRecordId) {

        ReturnWrapper result = new ReturnWrapper();
        List<FieldWrapper> fieldsWP = new List<FieldWrapper>();

        try {
            // Name
            Schema.DescribeFieldResult nameDesc = Man_hour__c.Name.getDescribe();
            fieldsWP.add(new FieldWrapper(nameDesc.getLabel(), nameDesc.getName(), String.valueof(nameDesc.getType()), apexTypetoJSType.get(String.valueof(nameDesc.getType())), !nameDesc.isNillable(), nameDesc.isUpdateable()));
            // Work__c
            Schema.DescribeFieldResult workDesc = Man_hour__c.Work__c.getDescribe();
            fieldsWP.add(new FieldWrapper(workDesc.getLabel(), workDesc.getName(), String.valueof(workDesc.getType()), apexTypetoJSType.get(String.valueof(workDesc.getType())), !workDesc.isNillable(), workDesc.isUpdateable()));
            // Performed_Date__c
            Schema.DescribeFieldResult performedDateDesc = Man_hour__c.Performed_Date__c.getDescribe();
            fieldsWP.add(new FieldWrapper(performedDateDesc.getLabel(), performedDateDesc.getName(), String.valueof(performedDateDesc.getType()), apexTypetoJSType.get(String.valueof(performedDateDesc.getType())), !performedDateDesc.isNillable(), performedDateDesc.isUpdateable()));
            // Performed_Hours__c
            Schema.DescribeFieldResult performedHoursDesc = Man_hour__c.Performed_Hours__c.getDescribe();
            fieldsWP.add(new FieldWrapper(performedHoursDesc.getLabel(), performedHoursDesc.getName(), String.valueof(performedHoursDesc.getType()), apexTypetoJSType.get(String.valueof(performedHoursDesc.getType())), !performedHoursDesc.isNillable(), performedHoursDesc.isUpdateable()));
            // Remark__c
            Schema.DescribeFieldResult remarkDesc = Man_hour__c.Remark__c.getDescribe();
            fieldsWP.add(new FieldWrapper(remarkDesc.getLabel(), remarkDesc.getName(), String.valueof(remarkDesc.getType()), apexTypetoJSType.get(String.valueof(remarkDesc.getType())), !remarkDesc.isNillable(), remarkDesc.isUpdateable()));
            
 			result.fieldsList = fieldsWP;
            result.parentRecord = [SELECT Id,
                                          Name,
                                          Start_Date__c,
                                          Due_Date__c,
                                          OwnerId,
                                          Assignee__c
                                    FROM ProjectAssign__c
                                    WHERE Id = :parentRecordId
                                    LIMIT 1
            ];
            result.recordList = [SELECT Id,
                                        Name,
                                        Work__c,
                                        Performed_Date__c,
                                        Performed_Hours__c,
                                        Remark__c
                                FROM Man_hour__c
                                WHERE ProjectAssign_No__c = :parentRecordId
                                ORDER BY Performed_Date__c ASC
            ];
            return result;
	    } catch (Exception err) {
            throw new AuraHandledException(err.getMessage());
	    }
    }

    @AuraEnabled
    public static String saveRecord(String parentRecordId, Map<String, List<String>> processRecords) {
        try {
            List<SObject> insertDatas = new List<SObject>();
            List<SObject> updateDatas = new List<SObject>();
            List<SObject> deleteDatas = new List<SObject>();

            for(String operateKey : processRecords.keySet()) {
                for(String record : processRecords.get(operateKey)) {
                    Map<String, Object> fieldMap = (Map<String, Object>)JSON.deserializeUntyped(record);

                    Man_hour__c manHour = new Man_hour__c();
                    // Work__c
                    manHour.put('Work__c', fieldMap.get('Work__c'));
                    // Performed_Date__c
                    String performedDateValue = (String)fieldMap.get('Performed_Date__c');
                    manHour.put('Performed_Date__c', Date.valueOf(performedDateValue));
                    // Performed_Hours__c
                    Object performedHoursValue = fieldMap.get('Performed_Hours__c');
                    if (performedHoursValue instanceof String) {
                        manHour.put('Performed_Hours__c', Double.valueOf((String)performedHoursValue));
                    } else {
                        manHour.put('Performed_Hours__c', performedHoursValue);
                    }
                    // Remark__c
                    manHour.put('Remark__c', fieldMap.get('Remark__c'));

                    if(operateKey == 'insert') {
                        manHour.ProjectAssign_No__c = parentRecordId;
                        insertDatas.add(manHour);
                    } else if(operateKey == 'update') {
                        manHour.Id = (Id)fieldMap.get('Id');
                        updateDatas.add(manHour);
                    } else if(operateKey == 'delete') {
                        manHour.Id = (Id)fieldMap.get('Id');
                        deleteDatas.add(manHour);
                    }
                }
            }

            insert insertDatas;
            update updateDatas;
            delete deleteDatas;

            return 'success';
        } catch(Exception err) {
            throw new AuraHandledException(err.getMessage());
        }
    }

    public static Map<String, String> apexTypetoJSType = new Map<String, String> {
        'ID' => 'id',
        'PHONE' => 'tel',
        'URL' => 'url',
        'EMAIL' => 'email',
        'ADDRESS' => 'text',
        'TEXTAREA' => 'text',
        'STRING' => 'text',
        'REFERENCE' => 'text',
        'MULTIPICKLIST' => 'text',
        'PICKLIST' => 'picklist',
        'BOOLEAN' => 'checkbox',
        'DATE' => 'date',
        'DATETIME' => 'datetime',
        'TIME' => 'time',
        'DOUBLE' => 'number',
        'INTEGER' => 'number',
        'CURRENCY' => 'number',
        'PERCENT' => 'number'
    };

    public class ReturnWrapper {
        @AuraEnabled public ProjectAssign__c parentRecord;
        @AuraEnabled public List<Man_hour__c> recordList;
        @AuraEnabled public List<FieldWrapper> fieldsList;
    }
    
    public class FieldWrapper {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public String dataType;
        @AuraEnabled public String ltngType;
        @AuraEnabled public Boolean isRequired;
        @AuraEnabled public Boolean isEditable;
        public FieldWrapper(String label, String value, String dataType, String ltngType, Boolean isRequired, Boolean isEditable) {
            this.label = label;
            this.value = value;
            this.dataType = dataType;
            this.ltngType = ltngType;
            this.isRequired = isRequired;
            this.isEditable = isEditable;
        }
    }
}