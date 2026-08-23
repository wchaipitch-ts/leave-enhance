import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';

// Import UI API to securely fetch Object Info and Picklist Values without hardcoding
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import APPLICATION_ITEM_OBJECT from '@salesforce/schema/ApplicationItem__c';
import REQUEST_TYPE_FIELD from '@salesforce/schema/ApplicationItem__c.Request_Type__c';
import PERIOD_LEAVE_FIELD from '@salesforce/schema/ApplicationItem__c.Period_Leave__c';

// Import Apex methods for data retrieval and DML manipulations
import getApplicationItems from '@salesforce/apex/TimesheetController.getApplicationItems';
import updateApplicationItem from '@salesforce/apex/TimesheetController.updateApplicationItem';
import deleteApplicationItem from '@salesforce/apex/TimesheetController.deleteApplicationItem';
import getLeaveOverview from '@salesforce/apex/TimesheetController.getLeaveOverview';

/**
 * HELPER FUNCTION: Dynamically generates row actions (Edit, Delete) for the datatable.
 * Disables the Edit and Delete buttons if the record status is not 'Draft'.
 * 
 * @param {Object} row - The current datatable row data
 * @param {Function} doneCallback - A callback function provided by lightning-datatable
 */
const getDynamicRowActions = (row, doneCallback) => {
    const actions = [];
    const currentStatus = row.status ? row.status.trim().toLowerCase() : '';
    const isDraftStatus = currentStatus === 'draft';

    actions.push({ label: 'Edit', name: 'edit', iconName: 'utility:edit', disabled: !isDraftStatus });
    actions.push({ label: 'Delete', name: 'delete', iconName: 'utility:delete', disabled: !isDraftStatus });
    doneCallback(actions);
};

const PREVIEW_SIZE = 10;
const FULL_SIZE = 200;

// Datatable Configuration for Leave & LWOP tabs
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

// Re-map standard columns for Overtime tab, renaming 'Start Date' to 'OT Start'
const OT_COLUMNS = COLUMNS.map(col => {
    if (col.fieldName === 'startDate') return { ...col, label: 'OT Start' };
    if (col.fieldName === 'endDate') return { ...col, label: 'OT End' };
    return col;
});

/**
 * HELPER FUNCTION: Formats a millisecond time value into an HH:MM string.
 * This ensures Time fields sent from Apex display correctly in the datatable.
 * 
 * @param {Number} value - Milliseconds since midnight
 * @returns {String} Time in HH:MM format
 */
const formatTime = (value) => {
    if (value === null || value === undefined || value === '') return '';
    const totalMinutes = Math.floor(Number(value) / 60000);
    const hours = Math.floor(totalMinutes / 60);
    const minutes = totalMinutes % 60;
    return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}`;
};

export default class ApplicationItemListView extends NavigationMixin(LightningElement) {
    
    // External properties provided by parent components
    @api targetUserId;
    @api leaveBalances = [];

    /**
     * GETTER/SETTER: Safely parses the 'targetYear' parameter passed from the parent.
     * Prevents invalid SOQL queries by ensuring it's always an integer or null.
     */
    @api
    get targetYear() {
        return this.filterYear;
    }
    set targetYear(value) {
        const parsed = parseInt(value, 10);
        this.filterYear = Number.isNaN(parsed) ? null : parsed;
        this.currentYear = this.filterYear === null ? new Date().getFullYear() : this.filterYear;
    }

    @track filterYear = null;
    columns = COLUMNS;
    otColumns = OT_COLUMNS;

    // Arrays holding data for the three UI tabs
    @track leaveData = [];
    @track lwopData = [];
    @track otData = [];

    // Store raw wire results to allow manual refresh via refreshApex()
    wiredLeaveResult;
    wiredLwopResult;
    wiredOtResult;
    wiredLeaveOverviewResult;

    // State Variables for "New Record" Creation Modal
    @track isNewModalOpen = false;
    @track isSelectingRecordType = true;
    @track isFormStep = false; 
    @track isLeaveForm = false;
    @track isOvertimeForm = false;
    
    @track recordTypeOptions = [];
    @track selectedRecordTypeId = '';

    // Field Tracking for Real-time Leave Balance Warnings
    @track currentLeaveType = '';
    @track currentTermFrom = null;
    @track currentTermTo = null;
    @track currentPeriodLeave = '';
    @track showLeaveWarning = false;
    @track leaveWarningMessage = '';

    @track currentYear = new Date().getFullYear();
    @track selfFetchedBalances = [];

    // State Variables for "Edit" Modal
    @track isEditModalOpen = false;
    @track editRecord = {};
    @track leaveRecordTypeId;
    @track requestTypeOptions = [];
    @track periodLeaveOptions = [];

    // State Variables for "Delete" Modal
    @track isDeleteModalOpen = false;
    @track isDeleting = false;
    @track deleteRecordId;
    @track deleteRecordNumber;
    @track deleteContinuationNumber;

    // State Flags for Datatable List Expansion
    @track isListExpanded = false;
    @track activeTab = 'Leave';
    @track recordLimit = PREVIEW_SIZE + 1;

    // ==========================================================
    // GETTERS AND UI LOGIC HANDLERS
    // ==========================================================

    /**
     * Resets list view back to a collapsed preview state when the user switches tabs.
     * @param {Event} event - UI Tab active event
     */
    handleTabActive(event) {
        const selectedTab = event.target.value;
        if (this.activeTab !== selectedTab) {
            this.activeTab = selectedTab;
            this.isListExpanded = false;
            this.recordLimit = PREVIEW_SIZE + 1;
        }
    }

    /** Checks if UI API successfully returned picklist metadata. */
    get isPicklistReady() {
        return this.requestTypeOptions.length > 0 && this.periodLeaveOptions.length > 0;
    }

    get isSaveButtonDisabled() {
        return !this.isPicklistReady;
    }

    get viewAllLabel() {
        return this.isListExpanded ? 'Show Less' : 'View All';
    }

    // Dynamic Getters to slice data for preview mode or show all records
    get displayedLeaveData() {
        if (!this.leaveData) return [];
        return this.isListExpanded ? [...this.leaveData] : this.leaveData.slice(0, PREVIEW_SIZE);
    }

    get displayedLwopData() {
        if (!this.lwopData) return [];
        return this.isListExpanded ? [...this.lwopData] : this.lwopData.slice(0, PREVIEW_SIZE);
    }

    get displayedOtData() {
        if (!this.otData) return [];
        return this.isListExpanded ? [...this.otData] : this.otData.slice(0, PREVIEW_SIZE);
    }

    get activeData() {
        if (this.activeTab === 'LWOP') return this.lwopData || [];
        if (this.activeTab === 'OT') return this.otData || [];
        return this.leaveData || [];
    }

    get showViewAllButton() {
        return this.isListExpanded || this.activeData.length > PREVIEW_SIZE;
    }
    
    /** Expands or collapses the currently visible datatable. */
    handleViewAll() {
        this.isListExpanded = !this.isListExpanded;
        this.recordLimit = this.isListExpanded ? FULL_SIZE : PREVIEW_SIZE + 1;
    }

    // ==========================================================
    // SERVER DATA FETCHING (@wire)
    // ==========================================================

    @wire(getLeaveOverview, { employeeId: '$targetUserId', year: '$currentYear', month: null })
    wiredLeaveOverview(result) {
        this.wiredLeaveOverviewResult = result;
        if (result.data && result.data.balances) {
            this.selfFetchedBalances = result.data.balances;
        }
    }

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

            const leaveRt = rtInfos.find(rt => rt.developerName === 'Leave_Request' || rt.name.includes('Leave'));
            this.leaveRecordTypeId = leaveRt ? leaveRt.recordTypeId : data.defaultRecordTypeId;
        }
    }

    @wire(getPicklistValues, { recordTypeId: '$leaveRecordTypeId', fieldApiName: REQUEST_TYPE_FIELD })
    wiredRequestType({ data }) {
        if (data) this.requestTypeOptions = data.values.map(item => ({ label: item.label, value: item.value }));
    }

    @wire(getPicklistValues, { recordTypeId: '$leaveRecordTypeId', fieldApiName: PERIOD_LEAVE_FIELD })
    wiredPeriodLeave({ data }) {
        if (data) this.periodLeaveOptions = data.values.map(item => ({ label: item.label, value: item.value }));
    }

    @wire(getApplicationItems, { category: 'Leave', employeeId: '$targetUserId', year: '$filterYear', recordLimit: '$recordLimit' })
    wiredLeave(result) {
        this.wiredLeaveResult = result;
        if (result.data) this.leaveData = this.flattenData(result.data, 'Leave');
    }

    @wire(getApplicationItems, { category: 'LWOP', employeeId: '$targetUserId', year: '$filterYear', recordLimit: '$recordLimit' })
    wiredLwop(result) {
        this.wiredLwopResult = result;
        if (result.data) this.lwopData = this.flattenData(result.data, 'LWOP');
    }

    @wire(getApplicationItems, { category: 'OT', employeeId: '$targetUserId', year: '$filterYear', recordLimit: '$recordLimit' })
    wiredOt(result) {
        this.wiredOtResult = result;
        if (result.data) this.otData = this.flattenData(result.data, 'OT');
    }

    /**
     * Flattens nested Apex responses so lightning-datatable can render columns properly.
     * @param {Array} rawData - Apex List of objects
     * @param {String} category - Indicates which tab is rendering the data
     * @returns {Array} List of flattened JS objects
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
                startDate: isOvertime ? formatTime(item.OT_Start__c) : item.Term_From__c,
                endDate: isOvertime ? formatTime(item.OT_End__c) : (item.Term_To__c ? item.Term_To__c : item.Term_From__c), 
                ownerUrl: `/${item.OwnerId}`,
                ownerName: item.Owner?.FirstName || '', 
                reason: item.Remark__c,
                status: item.Status__c,
            };
        });
    }

    // ==========================================================
    // RECORD CREATION HANDLERS
    // ==========================================================

    /**
     * Opens the New Modal. If the user only has permission for 1 Record Type, 
     * it auto-skips the selection screen and loads the appropriate form immediately.
     */
    handleNew() {
        this.isNewModalOpen = true;

        if (this.recordTypeOptions && this.recordTypeOptions.length === 1) {
            this.selectedRecordTypeId = this.recordTypeOptions[0].value;
            this.isSelectingRecordType = false;
            this.isFormStep = true;
            this.evaluateFormType(this.recordTypeOptions[0]);
        } else {
            this.isSelectingRecordType = true;
            this.isFormStep = false;
        }
        
        // Reset properties to prevent stale data
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
            this.evaluateFormType(selectedRT);
        }
    }

    /**
     * Checks the DeveloperName securely to dynamically route to the correct layout (Leave vs OT).
     * @param {Object} selectedRT - The Record Type option chosen by the user
     */
    evaluateFormType(selectedRT) {
        const nameStr = (selectedRT.developerName + ' ' + selectedRT.label).toLowerCase();
        
        if (nameStr.includes('overtime') || nameStr.includes('ot')) {
            this.isOvertimeForm = true;
            this.isLeaveForm = false;
        } else {
            this.isLeaveForm = true;
            this.isOvertimeForm = false;
        }
    }
    
    /**
     * Triggered every time a user types in a field. Captures values to check for available balance.
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
     * Business Logic: Warns users if they attempt to request more days than their balance permits.
     */
    checkLeaveBalanceRealTime() {
        this.showLeaveWarning = false; 
        this.leaveWarningMessage = '';

        if (!this.currentLeaveType || !this.currentTermFrom) return;
        
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
        // Native lightning-record-edit-form handles DML insert securely via LDS.
    }

    /**
     * Executes when the record is successfully saved to the database.
     * Fires a toast notification and refreshes datatables so the new record appears immediately.
     */
    handleNewSuccess(event) {
        this.showToast('Success', 'Application Item created successfully.', 'success');
        this.closeNewModal();
        refreshApex(this.wiredLeaveResult);
        refreshApex(this.wiredLwopResult);
        refreshApex(this.wiredOtResult);
        refreshApex(this.wiredLeaveOverviewResult);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    // ==========================================================
    // UI HANDLERS: EDIT AND DELETE FLOWS
    // ==========================================================

    /**
     * Catches the row action (Edit/Delete) triggered from the lightning-datatable.
     * Opens the appropriate modal and stores the selected record's data.
     * 
     * @param {Event} event - Details containing action name and row data
     */
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

        if (actionName === 'delete') {
            this.deleteRecordId = row.Id;
            this.deleteRecordNumber = row.appNumber;
            
            const continuation = this.findContinuationOf(row.Id);
            this.deleteContinuationNumber = continuation ? continuation.appNumber : null;

            this.isDeleteModalOpen = true;
        }
    }

    /** Searches for an associated unpaid continuation request if one exists. */
    findContinuationOf(recordId) {
        return [...this.leaveData, ...this.lwopData, ...this.otData]
            .find(item => item.Split_From__c === recordId);
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

    /**
     * ASYNC HANDLER: Sends modified editRecord object to Apex for DML Update.
     */
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

    get hasContinuation() {
        return !!this.deleteContinuationNumber;
    }

    get deleteContinuationMessage() {
        return `${this.deleteContinuationNumber}, the unpaid leave raised automatically `
             + `because this request ran past your balance, will remain. Delete it `
             + `separately if those days are not being taken.`;
    }

    closeDeleteModal() {
        this.isDeleteModalOpen = false;
        this.deleteRecordId = null;
        this.deleteRecordNumber = null;
        this.deleteContinuationNumber = null;
    }

    /**
     * ASYNC HANDLER: Sends record ID to Apex for DML Deletion.
     * Blocks user interaction during deletion using the isDeleting track variable.
     */
    async handleDeleteConfirm() {
        this.isDeleting = true;
        try {
            await deleteApplicationItem({ requestId: this.deleteRecordId });
            this.showToast('Success', `${this.deleteRecordNumber} was deleted.`, 'success');
            this.closeDeleteModal();

            refreshApex(this.wiredLeaveResult);
            refreshApex(this.wiredLwopResult);
            refreshApex(this.wiredOtResult);
            refreshApex(this.wiredLeaveOverviewResult);
        } catch (error) {
            this.showToast('Error', error.body ? error.body.message : error.message, 'error');
        } finally {
            this.isDeleting = false;
        }
    }
}