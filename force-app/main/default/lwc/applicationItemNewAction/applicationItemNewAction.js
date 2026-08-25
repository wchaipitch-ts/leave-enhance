import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';

import USER_ID from '@salesforce/user/Id';
import APPLICATION_ITEM_OBJECT from '@salesforce/schema/ApplicationItem__c';
import REQUEST_TYPE_FIELD from '@salesforce/schema/ApplicationItem__c.Request_Type__c';
import PERIOD_LEAVE_FIELD from '@salesforce/schema/ApplicationItem__c.Period_Leave__c';
import getLeaveOverview from '@salesforce/apex/TimesheetController.getLeaveOverview';

/**
 * @description Reusable Modal LWC for ApplicationItem__c record creation.
 * Handles both Embedded parent calls and Action Override execution modes securely.
 */
export default class ApplicationItemNewAction extends NavigationMixin(LightningElement) {
    
    /**
     * @description Record Type ID passed from Aura Wrapper during Action Override.
     * @type {String}
     */
    @api recordTypeId;

    /**
     * @description Explicit flag to determine if the component is running via Action Override.
     * Set to true by the Aura wrapper. Defaults to false (Embedded Mode).
     * @type {Boolean}
     */
    @api isStandalone = false;

    // UI State flags
    @track isSelectingRecordType = true;
    @track isFormStep = false; 
    @track isLeaveForm = false;
    @track isOvertimeForm = false;
    
    // Metadata states
    @track recordTypeOptions = [];
    @track selectedRecordTypeId = '';
    @track leaveRecordTypeId;
    @track requestTypeOptions = [];
    @track periodLeaveOptions = [];

    // Reactive input properties
    @track currentLeaveType = '';
    @track currentTermFrom = null;
    @track currentTermTo = null;
    @track currentPeriodLeave = '';
    @track showLeaveWarning = false;
    @track leaveWarningMessage = '';

    @track selfFetchedBalances = [];
    currentYear = new Date().getFullYear();

    // ==========================================================
    // SERVER DATA FETCHING (@wire)
    // ==========================================================

    /**
     * @description Fetches context user's leave quota balance from Apex.
     * @param {Object} wiredResult Destructured Apex response containing data or error.
     */
    @wire(getLeaveOverview, { employeeId: USER_ID, year: '$currentYear', month: null })
    wiredLeaveOverview({ error, data }) {
        if (data && data.balances) {
            this.selfFetchedBalances = data.balances;
        }
    }

    /**
     * @description Fetches Object Info and handles auto-navigation.
     * @param {Object} wiredResult Destructured UI API object info.
     */
    @wire(getObjectInfo, { objectApiName: APPLICATION_ITEM_OBJECT })
    wiredObjectInfo({ error, data }) {
        if (data) {
            const rtInfos = Object.values(data.recordTypeInfos);
            this.recordTypeOptions = rtInfos
                .filter(rt => rt.name !== 'Master' && rt.available)
                .map(rt => ({ label: rt.name, value: rt.recordTypeId, developerName: rt.developerName }));
                
            const leaveRt = rtInfos.find(rt => rt.developerName === 'Leave_Request' || rt.name.includes('Leave'));
            this.leaveRecordTypeId = leaveRt ? leaveRt.recordTypeId : data.defaultRecordTypeId;

            if (this.recordTypeId) {
                this.selectedRecordTypeId = this.recordTypeId;
                this.handleNextToForm();
            } else if (this.recordTypeOptions.length === 1) {
                this.selectedRecordTypeId = this.recordTypeOptions[0].value;
                this.handleNextToForm();
            } else if (this.recordTypeOptions.length > 0) {
                this.selectedRecordTypeId = this.recordTypeOptions[0].value;
            }
        }
    }

    /**
     * @description Fetches dynamic Picklist values for Request_Type__c.
     * @param {Object} wiredResult Destructured Picklist values.
     */
    @wire(getPicklistValues, { recordTypeId: '$leaveRecordTypeId', fieldApiName: REQUEST_TYPE_FIELD })
    wiredRequestType({ data }) {
        if (data) {
            this.requestTypeOptions = data.values
                .filter(item => item.value !== 'Unpaid leave')
                .map(item => ({ label: item.label, value: item.value }));
        }
    }

    /**
     * @description Fetches active Picklist values for Period_Leave__c.
     * @param {Object} wiredResult Destructured Picklist values.
     */
    @wire(getPicklistValues, { recordTypeId: '$leaveRecordTypeId', fieldApiName: PERIOD_LEAVE_FIELD })
    wiredPeriodLeave({ data }) {
        if (data) {
            this.periodLeaveOptions = data.values.map(item => ({ label: item.label, value: item.value }));
        }
    }

    // ==========================================================
    // UI HANDLERS & BUSINESS LOGIC
    // ==========================================================

    /**
     * @description Updates selected Record Type ID from radio button input.
     * @param {Event} event Change event.
     */
    handleRecordTypeSelection(event) {
        this.selectedRecordTypeId = event.detail.value;
    }

    /**
     * @description Evaluates Record Type developerName to switch layout.
     */
    handleNextToForm() {
        const selectedRT = this.recordTypeOptions.find(rt => rt.value === this.selectedRecordTypeId);
        
        const rtDeveloperName = selectedRT ? selectedRT.developerName : '';
        const rtLabel = selectedRT ? selectedRT.label : '';
        const nameStr = (rtDeveloperName + ' ' + rtLabel).toLowerCase();

        this.isSelectingRecordType = false;
        this.isFormStep = true;
        
        this.isOvertimeForm = nameStr.includes('overtime') || nameStr.includes('ot');
        this.isLeaveForm = !this.isOvertimeForm;
    }

    /**
     * @description Dynamic field handler tracking changes to calculate leave balance real-time.
     * @param {Event} event Input change event.
     */
    handleFieldChange(event) {
        const fieldName = event.target.fieldName || event.target.name;
        const value = event.target.value;

        if (fieldName === 'Request_Type__c') this.currentLeaveType = value;
        if (fieldName === 'Term_From__c') this.currentTermFrom = value;
        if (fieldName === 'Term_To__c') this.currentTermTo = value;
        if (fieldName === 'Period_Leave__c') this.currentPeriodLeave = value;

        this.checkLeaveBalanceRealTime();
    }

    /**
     * @description Calculates requested leave duration and evaluates against available balance.
     */
    checkLeaveBalanceRealTime() {
        this.showLeaveWarning = false; 
        this.leaveWarningMessage = '';

        if (!this.currentLeaveType || !this.currentTermFrom || this.selfFetchedBalances.length === 0) return;

        const balanceRecord = this.selfFetchedBalances.find(b => b.leaveType === this.currentLeaveType);
        if (!balanceRecord) return; 

        const availableDays = parseFloat(balanceRecord.available || 0);
        let requestedDays = 1; 

        const start = new Date(this.currentTermFrom);
        const end = this.currentTermTo ? new Date(this.currentTermTo) : start;

        if (end >= start) {
            const diffTime = Math.abs(end - start);
            requestedDays = Math.ceil(diffTime / (1000 * 60 * 60 * 24)) + 1;

            if (this.currentPeriodLeave === 'AM leave' || this.currentPeriodLeave === 'PM leave') {
                requestedDays = 0.5; 
            }
        }

        if (requestedDays > availableDays) {
            this.showLeaveWarning = true;
            this.leaveWarningMessage = `You are requesting ${requestedDays} day(s), but you only have ${availableDays} day(s) of ${this.currentLeaveType} available. The excess will be calculated as Leave Without Pay.`;
        }
    }

    /**
     * @description Intercepts form submit to inject custom combobox value before save.
     * @param {Event} event Submit event from lightning-record-edit-form.
     */
    handleNewSubmit(event) {
        event.preventDefault(); 
        const fields = event.detail.fields;
        
        if (this.isLeaveForm) {
            if (!this.currentLeaveType) {
                this.dispatchEvent(new ShowToastEvent({ title: 'Error', message: 'Please select a Request Type.', variant: 'error' }));
                return;
            }
            fields.Request_Type__c = this.currentLeaveType;
        }
        
        this.template.querySelector('lightning-record-edit-form').submit(fields);
    }

    /**
     * @description Routes post-success behavior explicitly based on execution mode.
     * @param {Event} event Success event payload containing new record ID.
     */
    handleSuccess(event) {
        const newRecordId = event.detail.id;
        this.dispatchEvent(new ShowToastEvent({ title: 'Success', message: 'Application Item created successfully.', variant: 'success' }));
        
        if (this.isStandalone) {
            // Action Override Mode: Redirect to the newly created record page
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: newRecordId,
                    objectApiName: 'ApplicationItem__c',
                    actionName: 'view'
                }
            });
        } else {
            // Embedded Mode: Notify parent LWC to close modal and refresh table
            this.dispatchEvent(new CustomEvent('recordsuccess', { detail: { id: newRecordId } }));
        }
    }

    /**
     * @description Routes cancellation behavior explicitly based on execution mode.
     */
    handleCancel() {
        if (this.isStandalone) {
            // Action Override Mode: Execute Navigation to escape the standard override screen safely
            this[NavigationMixin.Navigate]({
                type: 'standard__objectPage',
                attributes: {
                    objectApiName: 'ApplicationItem__c',
                    actionName: 'home'
                }
            });
        } else {
            // Embedded Mode: Dispatch custom event 'close' so parent LWC can hide modal without redirecting
            this.dispatchEvent(new CustomEvent('close'));
        }
    }
}