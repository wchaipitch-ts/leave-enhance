({
    doInit: function(component, event, helper) {
        component.set('v.newLine', 0);
        component.set('v.isEdited', false);
        component.set('v.isLoading', true);
        var recordId = component.get('v.recordId');
        if (!$A.util.isEmpty(recordId)) {
            helper.doInitHelper(component, helper, recordId);
        }
    },
    removeRow: function(component, event, helper) {
        var rowId = event.getSource().get('v.name');
        var records = component.get('v.records');
        var index = records.findIndex(x => x.Id === rowId);
        if (index != -1) {
            if (records[index].isNew) {
                records.splice(index, 1);
            } else {
                records[index]['editMode'] = false;
                records[index]['edited'] = true;
                records[index]['isDeleted'] = true;
            }
        }
        var index = records.findIndex(x => x.edited === true);
        if (index != -1) component.set('v.isEdited', true);
        else component.set('v.isEdited', false);
        component.set('v.isNoRecord', records.length == 0 || records == undefined);
        component.set('v.records', records);
    },
    resetRow: function(component, event, helper) {
        var rowId = event.getSource().get('v.name').split(',')[0];
        var resetRow;

        var recordsCopy = component.get('v.recordsCopy');
        var rowIndex = recordsCopy.findIndex(x => x.Id === rowId);
        if (rowIndex != -1)
            resetRow = JSON.parse(JSON.stringify(recordsCopy[rowIndex]));

        var records = component.get('v.records');
        var index = records.findIndex(x => x.Id === rowId);
        if (index != -1) {
            records[index] = resetRow;
        }
        component.set('v.records', records);

        var checkChanged = component.get('c.checkChanged');
        $A.enqueueAction(checkChanged);
    },
    addLine: function(component, event, helper) {
        var newLineCount = component.get('v.newLine');
        newLineCount++;
        component.set('v.newLine', newLineCount);

        var newLineData = {
            Id: "newLine" + newLineCount,
            editMode: true,
            edited: true,
            isNew: true,
            record: []
        };

        var fields = component.get('v.fields');
        for (var i = 0; i < fields.length; i++) {
            newLineData.record.push({
                dataType: fields[i].dataType,
                isEdit: fields[i].isEditable,
                isEdited: fields[i].isEditable,
                isRequired: fields[i].isRequired,
                label: fields[i].value,
                ltngType: fields[i].ltngType,
                value: null,
            });
        }
        var records = component.get('v.records');
        records.push(JSON.parse(JSON.stringify(newLineData)));
        component.set('v.isNoRecord', records.length == 0 || records == undefined);
        component.set('v.records', records);

        var checkChanged = component.get('c.checkChanged');
        $A.enqueueAction(checkChanged);

        var scrollDown = component.get('c.scrollDown');
        $A.enqueueAction(scrollDown);
    },
    save: function(component, event, helper) {
        var processRecords = [];
        var requiredFields = [];
        var recordId = component.get('v.recordId');
        var records = component.get('v.records');
        for (var parentIndex = 0; parentIndex < records.length; parentIndex++) {
            if (records[parentIndex].edited == true) {
                for (var childIndex = 0; childIndex < records[parentIndex].record.length; childIndex++) {

                    if ((records[parentIndex].record[childIndex].isRequired && records[parentIndex].record[childIndex].isEdit) &&
                        (records[parentIndex].record[childIndex].value === '' ||
                            records[parentIndex].record[childIndex].value === undefined ||
                            records[parentIndex].record[childIndex].value === null)
                    ) {
                        if (!requiredFields.includes(records[parentIndex].record[childIndex].label))
                            requiredFields.push(records[parentIndex].record[childIndex].label);
                    }
                }
                processRecords.push(records[parentIndex]);
            }
        }
        if (requiredFields.length > 0) {
            var toastEvent = $A.get("e.force:showToast");
            toastEvent.setParams({
                "type": "error",
                "title": "Error!",
                "message": "Please complete the required field " + JSON.stringify(requiredFields)
            });
            toastEvent.fire();
        } else {
            helper.saveRowHelper(component, recordId, processRecords);
        }
    },
    onEdit: function(component, event, helper) {
        component.set('v.isEdited', true);
        var recordId = event.getSource().get('v.name').split(',')[0];
        var fieldName = event.getSource().get('v.name').split(',')[1];

        var recordsCopy = component.get('v.recordsCopy');
        var records = component.get('v.records');
        var index = records.findIndex(x => x.Id === recordId);
        if (index != -1) {
            records[index].edited = true;
            var fieldIndex = records[index].record.findIndex(x => x.label === fieldName);
            if (fieldIndex != -1) {
                records[index].record[fieldIndex].isEdited = true;
                if (records[index].record[fieldIndex].label == "Performed_Date__c") {
                    const setDate = new Date(records[index].record[fieldIndex].value);
                    var vMin = component.get('v.minDate');
                    const minDate = new Date(vMin);
                    var vMax = component.get('v.maxDate');
                    const maxDate = new Date(vMax);
                    if (setDate > maxDate || setDate < minDate) {
                        helper.showToast('error', '"Performed Date" value must be between "' + vMin + '" - "' + vMax + '"');
                        if (records[index].isNew)
                            records[index].record[fieldIndex].value = vMin;
                        else
                            records[index].record[fieldIndex].value = recordsCopy[index].record[fieldIndex].value;
                    }
                }
            }
            component.set('v.records', records);
        }
    },
    checkChanged: function(component, event, helper) {
        var records = component.get('v.records');
        var index = records.findIndex(x => x.edited === true);

        if (index != -1) component.set('v.isEdited', true);
        else component.set('v.isEdited', false);
    },
    scrollDown: function(component, event, helper) {
        var scroller = document.getElementById("scroller");
        setTimeout(function() {
            scroller.scrollTop = scroller.scrollHeight;
        }, 100);
    }
})