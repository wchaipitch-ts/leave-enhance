import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';

import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import APPLICATION_ITEM_OBJECT from '@salesforce/schema/ApplicationItem__c';
import REQUEST_TYPE_FIELD from '@salesforce/schema/ApplicationItem__c.Request_Type__c';
import PERIOD_LEAVE_FIELD from '@salesforce/schema/ApplicationItem__c.Period_Leave__c';

import getApplicationItems from '@salesforce/apex/TimesheetController.getApplicationItems';
import updateApplicationItem from '@salesforce/apex/TimesheetController.updateApplicationItem';
import deleteApplicationItem from '@salesforce/apex/TimesheetController.deleteApplicationItem';
import getLeaveOverview from '@salesforce/apex/TimesheetController.getLeaveOverview';

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

const OT_COLUMNS = COLUMNS.map(col => {
    if (col.fieldName === 'startDate') return { ...col, label: 'OT Start' };
    if (col.fieldName === 'endDate') return { ...col, label: 'OT End' };
    return col;
});

const formatTime = (value) => {
    if (value === null || value === undefined || value === '') return '';
    const totalMinutes = Math.floor(Number(value) / 60000);
    const hours = Math.floor(totalMinutes / 60);
    const minutes = totalMinutes % 60;
    return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}`;
};

export default class ApplicationItemListView extends NavigationMixin(LightningElement) {
    
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
    otColumns = OT_COLUMNS;

    @track leaveData = [];
    @track lwopData = [];
    @track otData = [];

    wiredLeaveResult;
    wiredLwopResult;
    wiredOtResult;
    wiredLeaveOverviewResult;

    // Toggle flag for Child New Modal
    @track isNewModalOpen = false;

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

    @track isListExpanded = false;
    @track activeTab = 'Leave';
    @track recordLimit = PREVIEW_SIZE + 1;

    handleTabActive(event) {
        const selectedTab = event.target.value;
        if (this.activeTab !== selectedTab) {
            this.activeTab = selectedTab;
            this.isListExpanded = false;
            this.recordLimit = PREVIEW_SIZE + 1;
        }
    }

    get isPicklistReady() {
        return this.requestTypeOptions.length > 0 && this.periodLeaveOptions.length > 0;
    }

    get isSaveButtonDisabled() {
        return !this.isPicklistReady;
    }

    get viewAllLabel() {
        return this.isListExpanded ? 'Show Less' : 'View All';
    }

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
    
    handleViewAll() {
        this.isListExpanded = !this.isListExpanded;
        this.recordLimit = this.isListExpanded ? FULL_SIZE : PREVIEW_SIZE + 1;
    }

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
            const leaveRt = rtInfos.find(rt => rt.developerName === 'Leave_Request' || rt.name.includes('Leave'));
            this.leaveRecordTypeId = leaveRt ? leaveRt.recordTypeId : data.defaultRecordTypeId;
        }
    }

    @wire(getPicklistValues, { recordTypeId: '$leaveRecordTypeId', fieldApiName: REQUEST_TYPE_FIELD })
    wiredRequestType({ data }) {
        if (data) {
            this.requestTypeOptions = data.values
                .filter(item => item.value !== 'Unpaid leave')
                .map(item => ({ label: item.label, value: item.value }));
        }
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
    // REFACTORED RECORD CREATION HANDLERS
    // ==========================================================

    handleNew() {
        this.isNewModalOpen = true;
    }

    closeNewModal() {
        this.isNewModalOpen = false;
    }

    /**
     * @description Triggered when child component creates record successfully.
     * Closes modal and refreshes datatables.
     */
    handleNewSuccess() {
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
    // EDIT AND DELETE FLOWS
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