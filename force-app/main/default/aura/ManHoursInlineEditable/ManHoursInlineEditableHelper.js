({
    doInitHelper: function(component, helper, recordId) {
        var action = component.get('c.fetchRecords');
        action.setParams({
            'parentRecordId': recordId
        });
        action.setCallback(this, function(response) {
            var result = response.getReturnValue();
            if (response.getState() === 'SUCCESS') {
                if (!$A.util.isEmpty(result)) {
                    var userId = $A.get("$SObjectType.CurrentUser.Id");
                    var editableUser = userId == result.parentRecord.OwnerId || userId == result.parentRecord.Assignee__c;
                    component.set('v.editableUser', editableUser);

                    var records = [];
                    var fieldToDTMap = new Map();
                    var fieldToLDTMap = new Map();
                    var fieldToEditMap = new Map();
                    var fieldToRequireMap = new Map();
                    for (var j = 0; j < result.fieldsList.length; j++) {
                        fieldToEditMap.set(result.fieldsList[j]['value'], result.fieldsList[j]['isEditable']);
                        fieldToRequireMap.set(result.fieldsList[j]['value'], result.fieldsList[j]['isRequired']);
                        fieldToDTMap.set(result.fieldsList[j]['value'], result.fieldsList[j]['dataType']);
                        fieldToLDTMap.set(result.fieldsList[j]['value'], result.fieldsList[j]['ltngType']);
                    }
                    for (var i = 0; i < result.recordList.length; i++) {
                        var cell = [];
                        var isWeekend = false;
                        for (var j = 0; j < result.fieldsList.length; j++) {
                            var value = '';
                            var fieldAPI = result.fieldsList[j]['value'];
                            for (var key in result.recordList[i]) {
                                if (key == fieldAPI) {
                                    value = result.recordList[i][key];
                                    if (result.fieldsList[j]['ltngType'] == 'datetime' || result.fieldsList[j]['ltngType'] == 'date') {
                                        var completeDate = new Date(value);
                                        isWeekend = completeDate.getDay() == 6 || completeDate.getDay() == 0;
                                    }
                                }
                            }
                            if (fieldToLDTMap.has(result.fieldsList[j]['value']))
                                cell.push({
                                    'label': fieldAPI,
                                    'value': value,
                                    'isEdited': false,
                                    'isEdit': fieldToEditMap.get(fieldAPI),
                                    'isRequired': fieldToRequireMap.get(fieldAPI),
                                    'dataType': result.fieldsList[j]['dataType'],
                                    'ltngType': result.fieldsList[j]['ltngType']
                                });
                        }
                        records.push({
                            'Id': result.recordList[i].Id,
                            'editMode': editableUser,
                            'edited': false,
                            'isWeekend': isWeekend,
                            'record': cell
                        });
                    }
                    component.set('v.fields', result.fieldsList);

                    var parseRec = JSON.parse(JSON.stringify(records));
                    component.set('v.isLoading', false);
                    component.set('v.isNoRecord', parseRec.length == 0 || parseRec == undefined);
                    component.set('v.minDate', result.parentRecord.Start_Date__c);
                    component.set('v.maxDate', result.parentRecord.Due_Date__c);
                    component.set('v.records', JSON.parse(JSON.stringify(parseRec)));
                    component.set('v.recordsCopy', JSON.parse(JSON.stringify(parseRec)));
                    $A.get('e.force:refreshView').fire();
                }
            } else {
                console.log(response.getError());
                component.set('v.isLoading', false);
                var errors = response.getError();
                if (errors && errors[0] && errors[0].message)
                    helper.showToast('error', errors[0].message);
            }
        });
        $A.enqueueAction(action);
    },
    saveRowHelper: function(component, parentRecordId, processRecords) {
        var self = this;
        var updateDatas = [];
        var insertDatas = [];
        var deleteDatas = [];
        for (var parentIndex = 0; parentIndex < processRecords.length; parentIndex++) {
            var recordData = {};
            var recordObj = processRecords[parentIndex];
            if (!recordObj.isNew) recordData['Id'] = recordObj.Id;
            for (var childIndex = 0; childIndex < recordObj.record.length; childIndex++) {
                if (recordObj.record[childIndex].isEdit) {
                    recordData[recordObj.record[childIndex].label] = recordObj.record[childIndex].value;
                }
            }
            if (recordObj.isNew) {
                insertDatas.push(JSON.stringify(recordData));
            } else if (recordObj.isDeleted) {
                deleteDatas.push(JSON.stringify(recordData));
            } else {
                updateDatas.push(JSON.stringify(recordData));
            }
        }

        var action = component.get('c.saveRecord');
        action.setParams({
            'parentRecordId': parentRecordId,
            'processRecords': {
                'insert': insertDatas,
                'update': updateDatas,
                'delete': deleteDatas
            }
        });
        action.setCallback(this, function(response) {
            if (response.getState() === 'SUCCESS') {
                self.showToast('Success', 'Records Process Successfully');
                var doInit = component.get('c.doInit');
                $A.enqueueAction(doInit);
            } else {
                console.log(response.getError());
                var errors = response.getError();
                if (errors && errors[0] && errors[0].message) {
                    self.showToast('error', errors[0].message);
                }
            }
        });
        $A.enqueueAction(action);
    },
    showToast: function(type, message) {
        var toastEvent = $A.get("e.force:showToast");
        toastEvent.setParams({ "type": type, "message": message }).fire();
    }
})