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
import deleteApplicationItem from '@salesforce/apex/TimesheetController.deleteApplicationItem';
import getLeaveOverview from '@salesforce/apex/TimesheetController.getLeaveOverview';

/**
 * HELPER: Dynamically generates row actions (Edit, Delete) for the datatable.
 * INPUT: row (current datatable row), doneCallback (function to pass actions back)
 * OUTPUT: None (invokes callback with available actions)
 */
const getDynamicRowActions = (row, doneCallback) => {
    const actions = [];
    const currentStatus = row.status ? row.status.trim().toLowerCase() : '';
    const isDraftStatus = currentStatus === 'draft';

    actions.push({ label: 'Edit', name: 'edit', iconName: 'utility:edit', disabled: !isDraftStatus });
    actions.push({ label: 'Delete', name: 'delete', iconName: 'utility:delete', disabled: !isDraftStatus });
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

    @track isDeleteModalOpen = false;
    @track isDeleting = false;
    @track deleteRecordId;
    @track deleteRecordNumber;
    @track deleteContinuationNumber;

    // ==========================================================
    // State variables for List Expansion
    // ==========================================================
    @track isListExpanded = false;
    @track activeTab = 'Leave';

    /**
     * HANDLER: Triggered when a user switches between the Leave, LWOP, or OT tabs.
     * INPUT: event - The UI event object containing the newly selected tab's value.
     * OUTPUT: None (Updates component state properties).
     */
    handleTabActive(event) {
        const selectedTab = event.target.value;
        
        // IMPORTANT: Check if the tab actually changed before resetting the state.
        // This prevents LWC from forcefully collapsing the list during UI re-renders.
        if (this.activeTab !== selectedTab) {
            this.activeTab = selectedTab;
            this.isListExpanded = false; 
        }
    }

    /**
     * GETTER: Checks if picklist data has successfully loaded from Salesforce.
     * OUTPUT: Boolean (true if both picklists have data)
     */
    get isPicklistReady() {
        return this.requestTypeOptions.length > 0 && this.periodLeaveOptions.length > 0;
    }

    /**
     * GETTER: Determines if the Save button should be disabled based on picklist readiness.
     * OUTPUT: Boolean
     */
    get isSaveButtonDisabled() {
        return !this.isPicklistReady;
    }

    /**
     * GETTER: Returns the dynamic label for the link based on expansion state.
     * OUTPUT: String ('Show Less' or 'View All')
     */
    get viewAllLabel() {
        return this.isListExpanded ? 'Show Less' : 'View All';
    }

    /**
     * GETTER: Provides Leave Data to the datatable.
     * INPUT: Component state (this.leaveData, this.isListExpanded)
     * OUTPUT: A new Array reference containing either 3 records or all records.
     */
    get displayedLeaveData() {
        if (!this.leaveData) return [];
        // Use spread syntax [...] to create a new array reference in memory.
        // This forces lightning-datatable to recognize the data change and re-render.
        return this.isListExpanded ? [...this.leaveData] : this.leaveData.slice(0, 3);
    }

    /**
     * GETTER: Provides LWOP Data to the datatable.
     * OUTPUT: A new Array reference containing either 3 records or all records.
     */
    get displayedLwopData() {
        if (!this.lwopData) return [];
        return this.isListExpanded ? [...this.lwopData] : this.lwopData.slice(0, 3);
    }

    /**
     * GETTER: Provides OT Data to the datatable.
     * OUTPUT: A new Array reference containing either 3 records or all records.
     */
    get displayedOtData() {
        if (!this.otData) return [];
        return this.isListExpanded ? [...this.otData] : this.otData.slice(0, 3);
    }

    /**
     * GETTER: Determines if the "View All" button should be visible.
     * INPUT: Component state (this.activeTab, data arrays)
     * OUTPUT: Boolean (true if the active tab has more than 3 records).
     */
    get showViewAllButton() {
        if (this.activeTab === 'Leave') {
            return this.leaveData && this.leaveData.length > 3;
        } else if (this.activeTab === 'LWOP') {
            return this.lwopData && this.lwopData.length > 3;
        } else if (this.activeTab === 'OT') {
            return this.otData && this.otData.length > 3;
        }
        return false;
    }

    /**
     * HANDLER: Toggles the list view between expanded (all records) and collapsed (3 records).
     */
    handleViewAll() {
        this.isListExpanded = !this.isListExpanded;
    }

    // ==========================================================
    // Fetch Data Methods (@wire)
    // ==========================================================

    /**
     * WIRE: Fetch Leave Balances independently to ensure validation works.
     * INPUT: Target User ID and Year
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
     * WIRE: Fetch Record Types for ApplicationItem__c.
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

    /**
     * WIRE: Fetch Picklist options dynamically based on RecordTypeId.
     */
    @wire(getPicklistValues, { recordTypeId: '$leaveRecordTypeId', fieldApiName: REQUEST_TYPE_FIELD })
    wiredRequestType({ data, error }) {
        if (data) this.requestTypeOptions = data.values.map(item => ({ label: item.label, value: item.value }));
    }

    @wire(getPicklistValues, { recordTypeId: '$leaveRecordTypeId', fieldApiName: PERIOD_LEAVE_FIELD })
    wiredPeriodLeave({ data, error }) {
        if (data) this.periodLeaveOptions = data.values.map(item => ({ label: item.label, value: item.value }));
    }

    /**
     * WIRE: Fetch Datatable lists for the 3 tabs from Apex.
     */
    @wire(getApplicationItems, { category: 'Leave', employeeId: '$targetUserId', year: '$filterYear', recordLimit: 50 })
    wiredLeave(result) {
        this.wiredLeaveResult = result;
        if (result.data) this.leaveData = this.flattenData(result.data, 'Leave');
    }

    @wire(getApplicationItems, { category: 'LWOP', employeeId: '$targetUserId', year: '$filterYear', recordLimit: 50 })
    wiredLwop(result) {
        this.wiredLwopResult = result;
        if (result.data) this.lwopData = this.flattenData(result.data, 'LWOP');
    }

    @wire(getApplicationItems, { category: 'OT', employeeId: '$targetUserId', year: '$filterYear', recordLimit: 50 })
    wiredOt(result) {
        this.wiredOtResult = result;
        if (result.data) this.otData = this.flattenData(result.data, 'OT');
    }

    /**
     * HELPER: Transforms complex nested Apex objects into a flat structure suitable for datatable.
     * INPUT: rawData (Array from Apex), category (String)
     * OUTPUT: Array of flattened objects
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
    // Handlers for "New Record" Flow
    // ==========================================================

    /**
     * HANDLER: Opens the 'New' modal and resets tracking variables.
     * LOGIC: Skips Record Type selection if only 1 option is available.
     */
    handleNew() {
        this.isNewModalOpen = true;

        if (this.recordTypeOptions && this.recordTypeOptions.length === 1) {
            this.selectedRecordTypeId = this.recordTypeOptions[0].value;
            this.isSelectingRecordType = false;
            this.isFormStep = true;

            if (this.recordTypeOptions[0].developerName === 'Overtime_Request') {
                this.isOvertimeForm = true;
                this.isLeaveForm = false;
            } else {
                this.isLeaveForm = true;
                this.isOvertimeForm = false;
            }
        } else {
            this.isSelectingRecordType = true;
            this.isFormStep = false;
        }
        
        // Reset tracking variables
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
     * HANDLER: Triggered when user modifies a field in the creation form.
     * LOGIC: Captures data to perform real-time balance validation.
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
     * HELPER: Calculates requested days and compares them against the available balance.
     * OUTPUT: Updates UI warning properties if balance is exceeded.
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
        // Handled securely by native lightning-record-edit-form.
    }

    /**
     * HANDLER: Triggers after successful record creation.
     * LOGIC: Refreshes all wired data grids.
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
    // Handlers for Existing Edit Flow
    // ==========================================================

    /**
     * HANDLER: Processes row actions from the datatable (e.g., clicking 'Edit').
     * INPUT: event containing action details and row data.
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

    findContinuationOf(recordId) {
        return [...this.leaveData, ...this.lwopData, ...this.otData]
            .find(item => item.Split_From__c === recordId);
    }

    /**
     * HANDLER: Updates the temporary editRecord object as the user types.
     */
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
     * HANDLER: Submits the updated record to Apex.
     * LOGIC: Uses asynchronous (async/await) call to Apex and refreshes datatables upon success.
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