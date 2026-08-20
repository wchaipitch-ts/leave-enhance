import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';

// Import UI API to securely fetch Object Info and Picklist Values
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import APPLICATION_ITEM_OBJECT from '@salesforce/schema/ApplicationItem__c';
import REQUEST_TYPE_FIELD from '@salesforce/schema/ApplicationItem__c.Request_Type__c';
import PERIOD_LEAVE_FIELD from '@salesforce/schema/ApplicationItem__c.Period_Leave__c';

// Import Apex methods for data retrieval and manipulation
import getApplicationItems from '@salesforce/apex/TimesheetController.getApplicationItems';
import updateApplicationItem from '@salesforce/apex/TimesheetController.updateApplicationItem';
import getLeaveOverview from '@salesforce/apex/TimesheetController.getLeaveOverview';

// Helper function to dynamically generate row actions in the datatable
const getDynamicRowActions = (row, doneCallback) => {
    const actions = [];
    const currentStatus = row.status ? row.status.trim().toLowerCase() : '';
    const isDraftStatus = currentStatus === 'draft';

    // Only allow editing if the status is 'Draft'
    actions.push({ label: 'Edit', name: 'edit', iconName: 'utility:edit', disabled: !isDraftStatus });
    doneCallback(actions);
};

// Define datatable columns configuration
const COLUMNS = [
    { label: 'ApplicationItem No.', fieldName: 'appNoUrl', type: 'url', typeAttributes: { label: { fieldName: 'appNumber' }, target: '_blank' } },
    { label: 'Request Type', fieldName: 'requestType', type: 'text' },
    { label: 'Period Leave', fieldName: 'periodLeave', type: 'text' },
    { label: 'Start Date', fieldName: 'startDate', type: 'text' },
    { label: 'End Date', fieldName: 'endDate', type: 'text' },
    { label: 'Owner First Name', fieldName: 'ownerUrl', type: 'url', typeAttributes: { label: { fieldName: 'ownerName' }, target: '_blank' } },
    { label: 'Reason', fieldName: 'reason', type: 'text' },
    { label: 'Status', fieldName: 'status', type: 'text' },
    { type: 'action', typeAttributes: { rowActions: getDynamicRowActions } }
];

export default class ApplicationItemListView extends NavigationMixin(LightningElement) {
    
    // INPUT: Received from parent components (Timesheet or Leave Balance Screen)
    @api targetUserId; 
    @api leaveBalances = []; 

    columns = COLUMNS;

    // OUTPUT: Arrays to hold data for the 3 datatables
    @track leaveData = [];
    @track lwopData = [];
    @track otData = [];

    // Variables to store wire results for refreshApex functionality
    wiredLeaveResult;
    wiredLwopResult;
    wiredOtResult;
    wiredLeaveOverviewResult;

    // ==========================================================
    // State variables for Custom "New Record" Modal Flow
    // ==========================================================
    @track isNewModalOpen = false;
    @track isSelectingRecordType = true;
    @track isFormStep = false; 
    @track isLeaveForm = false;
    @track isOvertimeForm = false;
    @track recordTypeOptions = [];
    @track selectedRecordTypeId = '';

    // Real-time tracking variables for validation
    @track currentLeaveType = '';
    @track currentTermFrom = null;
    @track currentTermTo = null;
    @track currentPeriodLeave = '';
    @track showLeaveWarning = false;
    @track leaveWarningMessage = '';

    // Self-sufficient balance tracking (In case parent does not provide leaveBalances)
    @track currentYear = new Date().getFullYear();
    @track selfFetchedBalances = [];

    // ==========================================================
    // State variables for Edit Modal & Picklists
    // ==========================================================
    @track isEditModalOpen = false;
    @track editRecord = {};
    @track leaveRecordTypeId;
    @track requestTypeOptions = [];
    @track periodLeaveOptions = [];

    /**
     * GETTER: Checks if picklist data has successfully loaded from Salesforce.
     * Used to prevent rendering the form prematurely.
     */
    get isPicklistReady() {
        return this.requestTypeOptions.length > 0 && this.periodLeaveOptions.length > 0;
    }

    /**
     * GETTER: Replaces the invalid {!isPicklistReady} in HTML.
     * Returns true (disabled) if picklists are NOT ready.
     */
    get isSaveButtonDisabled() {
        return !this.isPicklistReady;
    }

    // ==========================================================
    // Fetch Data Methods (@wire)
    // ==========================================================

    /**
     * Fetch Leave Balances independently to ensure validation works 
     * even if the parent component doesn't pass the data.
     */
    @wire(getLeaveOverview, { employeeId: '$targetUserId', year: '$currentYear', month: null })
    wiredLeaveOverview(result) {
        this.wiredLeaveOverviewResult = result;
        if (result.data && result.data.balances) {
            this.selfFetchedBalances = result.data.balances;
        } else if (result.error) {
            console.error('Error fetching balances in child component', result.error);
        }
    }

    /**
     * Fetch Record Types for ApplicationItem__c.
     * Essential for identifying the 'Leave_Request' RecordTypeId.
     */
    @wire(getObjectInfo, { objectApiName: APPLICATION_ITEM_OBJECT })
    wiredObjectInfo({ error, data }) {
        if (data) {
            const rtInfos = Object.values(data.recordTypeInfos);
            this.recordTypeOptions = rtInfos
                .filter(rt => rt.name !== 'Master' && rt.available)
                .map(rt => ({ label: rt.name, value: rt.recordTypeId, developerName: rt.developerName }));
                
            if (this.recordTypeOptions.length > 0) {
                this.selectedRecordTypeId = this.recordTypeOptions[0].value;
            }

            // Find and store the specific RecordTypeId for Leave requests to fetch its picklists later
            const leaveRt = rtInfos.find(rt => rt.developerName === 'Leave_Request' || rt.name.includes('Leave'));
            this.leaveRecordTypeId = leaveRt ? leaveRt.recordTypeId : data.defaultRecordTypeId;
        }
    }

    // Fetch Picklist options dynamically based on the resolved RecordTypeId
    @wire(getPicklistValues, { recordTypeId: '$leaveRecordTypeId', fieldApiName: REQUEST_TYPE_FIELD })
    wiredRequestType({ data, error }) {
        if (data) this.requestTypeOptions = data.values.map(item => ({ label: item.label, value: item.value }));
    }

    @wire(getPicklistValues, { recordTypeId: '$leaveRecordTypeId', fieldApiName: PERIOD_LEAVE_FIELD })
    wiredPeriodLeave({ data, error }) {
        if (data) this.periodLeaveOptions = data.values.map(item => ({ label: item.label, value: item.value }));
    }

    // Fetch Datatable lists for the 3 tabs
    @wire(getApplicationItems, { category: 'Leave', employeeId: '$targetUserId', recordLimit: 50 })
    wiredLeave(result) {
        this.wiredLeaveResult = result; 
        if (result.data) this.leaveData = this.flattenData(result.data, 'Leave');
    }

    @wire(getApplicationItems, { category: 'LWOP', employeeId: '$targetUserId', recordLimit: 50 })
    wiredLwop(result) {
        this.wiredLwopResult = result;
        if (result.data) this.lwopData = this.flattenData(result.data, 'LWOP');
    }

    @wire(getApplicationItems, { category: 'OT', employeeId: '$targetUserId', recordLimit: 50 })
    wiredOt(result) {
        this.wiredOtResult = result;
        if (result.data) this.otData = this.flattenData(result.data, 'OT');
    }

    /**
     * Transforms complex nested Apex objects into a flat structure 
     * suitable for the lightning-datatable component.
     */
    flattenData(rawData, category) {
        return rawData.map(item => {
            const isOvertime = item.RecordType?.DeveloperName === 'Overtime_Request' || category === 'OT';
            return {
                ...item, 
                appNoUrl: `/${item.Id}`,
                appNumber: item.Name,
                requestType: item.Request_Type__c || (isOvertime ? 'Overtime' : ''),
                periodLeave: item.Period_Leave__c,
                startDate: isOvertime ? item.OT_Start__c : item.Term_From__c,
                endDate: isOvertime ? item.OT_End__c : (item.Term_To__c ? item.Term_To__c : item.Term_From__c), 
                ownerUrl: `/${item.OwnerId}`,
                ownerName: item.Owner?.FirstName || '', 
                reason: item.Remark__c,
                status: item.Status__c,
            };
        });
    }

    // ==========================================================
    // Handlers for "New Record" Flow with Real-Time Validation
    // ==========================================================
    handleNew() {
        this.isNewModalOpen = true;
        this.isSelectingRecordType = true;
        this.isFormStep = false;
        
        // Clear previous tracking data
        this.currentLeaveType = '';
        this.currentTermFrom = null;
        this.currentTermTo = null;
        this.currentPeriodLeave = '';
        this.showLeaveWarning = false;
    }

    closeNewModal() {
        this.isNewModalOpen = false;
    }

    handleRecordTypeSelection(event) {
        this.selectedRecordTypeId = event.detail.value;
    }

    handleNextToForm() {
        const selectedRT = this.recordTypeOptions.find(rt => rt.value === this.selectedRecordTypeId);
        if (selectedRT) {
            this.isSelectingRecordType = false;
            this.isFormStep = true;

            // Route UI to the correct form layout
            if (selectedRT.developerName === 'Overtime_Request') {
                this.isOvertimeForm = true;
                this.isLeaveForm = false;
            } else {
                this.isLeaveForm = true;
                this.isOvertimeForm = false;
            }
        }
    }

    /**
     * Triggered every time a user modifies a field in the creation form.
     * Captures data in real-time to perform balance validation.
     */
    handleFieldChange(event) {
        const fieldName = event.target.fieldName;
        const value = event.target.value;

        if (fieldName === 'Request_Type__c') this.currentLeaveType = value;
        if (fieldName === 'Term_From__c') this.currentTermFrom = value;
        if (fieldName === 'Term_To__c') this.currentTermTo = value;
        if (fieldName === 'Period_Leave__c') this.currentPeriodLeave = value;

        this.checkLeaveBalanceRealTime();
    }

    /**
     * Calculates requested days and compares them against the available balance.
     * Displays a warning UI if requested days exceed the balance.
     */
    checkLeaveBalanceRealTime() {
        this.showLeaveWarning = false; 
        this.leaveWarningMessage = '';

        if (!this.currentLeaveType || !this.currentTermFrom) return;
        
        // Determine which balance source to use (Parent override vs Self-fetched)
        const balancesToUse = (this.leaveBalances && this.leaveBalances.length > 0) ? this.leaveBalances : this.selfFetchedBalances;
        if (!balancesToUse || balancesToUse.length === 0) return;

        const balanceRecord = balancesToUse.find(b => b.leaveType === this.currentLeaveType);
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

    handleNewSubmit(event) {
        // Native lightning-record-edit-form will handle the database submission.
    }

    handleNewSuccess(event) {
        this.showToast('Success', 'Application Item created successfully.', 'success');
        this.closeNewModal();
        
        // Refresh all data grids and the balance overview cache
        refreshApex(this.wiredLeaveResult);
        refreshApex(this.wiredLwopResult);
        refreshApex(this.wiredOtResult);
        refreshApex(this.wiredLeaveOverviewResult);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    // ==========================================================
    // Handlers for Existing Edit Flow
    // ==========================================================
    handleRowAction(event) {
        const actionName = event.detail.action.name; 
        const row = event.detail.row; 

        if (actionName === 'edit') {
            this.editRecord = {
                Id: row.Id,
                Term_From__c: row.startDate,
                Term_To__c: row.endDate,
                Request_Type__c: row.requestType,
                Period_Leave__c: row.periodLeave,
                Remark__c: row.reason
            };
            this.isEditModalOpen = true;
        }
    }

    handleInputChange(event) {
        const field = event.target.dataset.field;
        const value = event.detail.value;
        this.editRecord = { ...this.editRecord, [field]: value };
    }

    closeEditModal() {
        this.isEditModalOpen = false;
        this.editRecord = {};
    }

    async saveEditRecord() {
        try {
            await updateApplicationItem({ editedApplicationItem: this.editRecord });
            this.showToast('Success', 'Updated successfully.', 'success');
            this.closeEditModal();
            refreshApex(this.wiredLeaveResult);
            refreshApex(this.wiredLwopResult);
            refreshApex(this.wiredOtResult);
        } catch (error) {
            this.showToast('Error', error.body ? error.body.message : error.message, 'error');
        }
    }

    handleViewAll() {
        console.log('User clicked View All');
    }
}