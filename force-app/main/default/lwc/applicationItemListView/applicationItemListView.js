import { LightningElement, api, wire, track } from 'lwc';

// Import Navigation and Toast features
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

// Import refreshApex to refresh datatable after save
import { refreshApex } from '@salesforce/apex';

// Import Apex methods[cite: 36]
import getApplicationItems from '@salesforce/apex/TimesheetController.getApplicationItems';
import updateApplicationItem from '@salesforce/apex/TimesheetController.updateApplicationItem';

// Helper function to dynamically generate row actions based on row data[cite: 36]
const getDynamicRowActions = (row, doneCallback) => {
    const actions = [];
    const isDraftStatus = row.status === 'Draft';

    actions.push({
        label: 'Edit',
        name: 'edit',
        iconName: 'utility:edit',
        disabled: !isDraftStatus 
    });

    doneCallback(actions);
};

// Define datatable columns configuration[cite: 36]
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

// Extend NavigationMixin to allow standard page navigation
export default class ApplicationItemListView extends NavigationMixin(LightningElement) {
    
    @api targetUserId; 
    columns = COLUMNS;

    @track leaveData = [];
    @track lwopData = [];
    @track otData = [];

    // Variables to control Modal state and hold editing data
    @track isEditModalOpen = false;
    @track editRecord = {};

    // Variables to hold the raw wire results for refreshApex
    wiredLeaveResult;
    wiredLwopResult;
    wiredOtResult;

    // Wire adapter to fetch 'Leave' category records automatically[cite: 36]
    @wire(getApplicationItems, { category: 'Leave', employeeId: '$targetUserId', recordLimit: 50 })
    wiredLeave(result) {
        this.wiredLeaveResult = result; // Save result for refreshApex
        if (result.data) {
            this.leaveData = this.flattenData(result.data);
        } else if (result.error) {
            console.error('Error fetching Leave:', result.error);
        }
    }

    // Wire adapter to fetch 'LWOP' category records automatically[cite: 36]
    @wire(getApplicationItems, { category: 'LWOP', employeeId: '$targetUserId', recordLimit: 50 })
    wiredLwop(result) {
        this.wiredLwopResult = result;
        if (result.data) {
            this.lwopData = this.flattenData(result.data);
        } else if (result.error) {
            console.error('Error fetching LWOP:', result.error);
        }
    }

    // Wire adapter to fetch 'OT' category records automatically[cite: 36]
    @wire(getApplicationItems, { category: 'OT', employeeId: '$targetUserId', recordLimit: 50 })
    wiredOt(result) {
        this.wiredOtResult = result;
        if (result.data) {
            this.otData = this.flattenData(result.data);
        } else if (result.error) {
            console.error('Error fetching OT:', result.error);
        }
    }

    // Helper method to flatten nested objects for the datatable[cite: 36]
    flattenData(rawData) {
        return rawData.map(item => {
            return {
                ...item, 
                appNoUrl: `/${item.Id}`,
                appNumber: item.Name,
                requestType: item.Request_Type__c,
                periodLeave: item.Period_Leave__c,
                startDate: item.Term_From__c,
                endDate: item.Term_To__c ? item.Term_To__c : item.Term_From__c, 
                ownerUrl: `/${item.OwnerId}`,
                ownerName: (item.Owner && item.Owner.FirstName) ? item.Owner.FirstName : '', 
                reason: item.Remark__c,
                status: item.Status__c
            };
        });
    }

    // Handler for the 'New' button click
    handleNew() {
        // Navigate to the standard ApplicationItem__c creation page
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'ApplicationItem__c',
                actionName: 'new'
            }
        });
    }

    // Handler for row-level actions in the datatable[cite: 36]
    handleRowAction(event) {
        const actionName = event.detail.action.name; 
        const row = event.detail.row; 

        if (actionName === 'edit') {
            // Populate the editRecord object with existing row data
            this.editRecord = {
                Id: row.Id,
                Term_From__c: row.startDate,
                Term_To__c: row.endDate,
                Request_Type__c: row.requestType,
                Period_Leave__c: row.periodLeave,
                Remark__c: row.reason
            };
            
            // Open the modal
            this.isEditModalOpen = true;
        }
    }

    // Generic input change handler for the edit modal
    handleInputChange(event) {
        const field = event.target.dataset.field;
        this.editRecord[field] = event.target.value;
    }

    // Close modal and clear temporary data
    closeEditModal() {
        this.isEditModalOpen = false;
        this.editRecord = {};
    }

    // Call Apex to save the updated record
    async saveEditRecord() {
        try {
            // Call the Apex method and pass the constructed object
            await updateApplicationItem({ editedApplicationItem: this.editRecord });
            
            // Show success toast
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Success',
                    message: 'Application Item updated successfully.',
                    variant: 'success'
                })
            );

            // Close the modal
            this.closeEditModal();

            // Refresh the datatables so the new data appears immediately
            await refreshApex(this.wiredLeaveResult);
            await refreshApex(this.wiredLwopResult);
            await refreshApex(this.wiredOtResult);

        } catch (error) {
            // Show error toast if Apex throws an exception (e.g., validation rule fails)
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error updating record',
                    message: error.body ? error.body.message : error.message,
                    variant: 'error'
                })
            );
        }
    }

    handleViewAll() {
        console.log('User clicked View All');
    }
}