import { LightningElement, track, wire } from 'lwc';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation'; 
import { refreshApex } from '@salesforce/apex';
import getLeaveOverview from '@salesforce/apex/TimesheetController.getLeaveOverview';

// =========================================================
// DATATABLE CONFIGURATION
// =========================================================
const COLUMNS = [
    { label: 'No.', fieldName: 'rowNumber', type: 'text', initialWidth: 80 },
    { 
        label: 'Leave Type', 
        fieldName: 'leaveTypeUrl', 
        type: 'url', 
        typeAttributes: { label: { fieldName: 'leaveType' }, target: '_blank' } 
    },
    { 
        label: 'Entitlement / Allocation', 
        fieldName: 'entitlementStr', 
        type: 'text',
        cellAttributes: { class: { fieldName: 'entitlementColor' } }
    },
    { label: 'Accrued to Date', fieldName: 'accruedStr', type: 'text' },
    { 
        label: 'Used', 
        fieldName: 'usedStr', 
        type: 'text',
        cellAttributes: { class: { fieldName: 'usedColor' } }
    },
    { label: 'Carry Over', fieldName: 'carriedInStr', type: 'text' },
    { 
        label: 'Available', 
        fieldName: 'availableStr', 
        type: 'text',
        cellAttributes: { class: { fieldName: 'availableColor' } }
    }
];

export default class LeaveBalanceScreen extends NavigationMixin(LightningElement) {
    
    // =========================================================
    // STATE VARIABLES (@track)
    // =========================================================
    @track receivedUserId = null;
    @track receivedYear = null;

    @track employee = {};
    @track selectedYear;
    @track availableYears = [];
    
    @track highlightCards = [];
    @track tableData = [];
    
    columns = COLUMNS;

    // Cache variable required as input for refreshApex().
    wiredLeaveOverviewResult;

    // =========================================================
    // GETTERS (Dynamic Properties)
    // =========================================================

    /**
     * @description Generates a dropdown list of years (2020 - 2040).
     * @input None.
     * @output {Array} List of objects { label: String, value: String } for lightning-combobox.
     */
    get yearOptions() {
        let options = [];
        for (let i = 2020; i <= 2040; i++) {
            options.push({ label: String(i), value: String(i) });
        }
        return options;
    }

    /**
     * @description Safely returns the selected year as a string format for UI binding.
     * @input this.receivedYear (Integer).
     * @output {String} The formatted year (e.g., '2026').
     */
    get selectedYearString() {
        return this.receivedYear ? String(this.receivedYear) : String(new Date().getFullYear());
    }

    // =========================================================
    // 1. EXTRACT URL PARAMETERS
    // =========================================================
    
    /**
     * @description @wire service to extract URL query parameters automatically on load.
     * @input currentPageReference {Object} Standard Salesforce object containing URL state.
     * @output Updates this.receivedUserId and this.receivedYear state variables.
     */
    @wire(CurrentPageReference)
    getStateParameters(currentPageReference) {
        if (currentPageReference && currentPageReference.state) {
            this.receivedUserId = currentPageReference.state.c__userId || null;
            this.receivedYear = currentPageReference.state.c__year ? parseInt(currentPageReference.state.c__year, 10) : new Date().getFullYear();
        }
    }

    // =========================================================
    // 2. USER INTERACTION HANDLERS
    // =========================================================

    /**
     * @description Triggered when the user selects a new year from the combobox.
     * @input event {Object} UI Event containing the selected value in event.detail.value.
     * @output Updates this.receivedYear and triggers refreshApex() to fetch new data from the server.
     */
    handleYearChange(event) {
        this.receivedYear = parseInt(event.detail.value, 10);
        
        if (this.wiredLeaveOverviewResult) {
            refreshApex(this.wiredLeaveOverviewResult);
        }
    }

    // =========================================================
    // 3. FETCH DATA FROM APEX
    // =========================================================
    
    /**
     * @description @wire automatically calls the Apex backend when reactive variables ($) change.
     * @input employeeId {String} & year {Integer} (Bound reactively).
     * @output result {Object} containing { data, error }. Calls processBackendData() if successful.
     */
    @wire(getLeaveOverview, { employeeId: '$receivedUserId', year: '$receivedYear', month: null })
    wiredLeaveOverview(result) {
        this.wiredLeaveOverviewResult = result;
        
        if (result.data) {
            this.processBackendData(result.data);
        } else if (result.error) {
            console.error('Error fetching data:', result.error);
        }
    }

    // =========================================================
    // 4. DATA MAPPING AND TRANSFORMATION
    // =========================================================

    /**
     * @description Transforms raw read-only Apex data into a mutable, flattened structure for the UI.
     * @input backendData {Object} Raw Object returned from the Apex controller.
     * @output Populates this.employee, this.tableData, and this.highlightCards arrays for HTML rendering.
     */
    processBackendData(backendData) {
        
        // Clone object using spread operator to bypass read-only restrictions
        this.employee = backendData.employee ? { ...backendData.employee } : {};
        
        if (this.employee.userId) {
            this.employee.userUrl = `/lightning/r/User/${this.employee.userId}/view`;
        } else {
            this.employee.userUrl = null; 
        }

        if (this.employee.startDate) {
            const sd = new Date(this.employee.startDate);
            this.employee.startDate = sd.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
        } else {
            this.employee.startDate = '-';
        }

        this.selectedYear = backendData.year || this.receivedYear;
        this.availableYears = backendData.availableYears || [];
        const balances = backendData.balances || [];

        // Flatten data and inject SLDS color classes for standard datatables
        this.tableData = balances.map((item, index) => {
            const recordId = item.id || item.Id || item.recordId || item.leaveBalanceId || item.balanceId;
            const url = recordId ? `/${recordId}` : null;
        const carryOverRemaining = item.carryRemaining !== undefined ? item.carryRemaining : 0;

            return {
                ...item,
                rowNumber: String(index + 1),
                leaveTypeUrl: url,
                entitlementStr: `${item.entitlement || 0} Days`,
                accruedStr: `${item.accrued || 0} Days`,
                usedStr: `${item.used || 0} Days`,
                // carriedInStr: `${item.carriedIn || 0} Days`,
                carriedInStr: `${carryOverRemaining} / ${item.carriedIn || 0} Days`,
                availableStr: `${item.available || 0} Days`,
                
                
                entitlementColor: 'slds-text-link',
                usedColor: 'slds-text-color_error',
                availableColor: 'slds-text-color_success'
            };
        });

        // Map highlight cards and inject CSS classes for background colors
        const highlightTypes = ['Annual leave', 'Refresh Leave', 'Sick leave', 'Personal leave'];
        let tempCards = [];

        balances.forEach(item => {
            if (highlightTypes.includes(item.leaveType)) {
                
                let cssClass = 'highlight-card ';
                let numberCssClass = '';
                
                // FIX: Initialize the full class string for the bubble here.
                let bubbleCssClass = 'slds-col slds-text-align_center ';

                if (item.leaveType === 'Annual leave') {
                    cssClass += 'card-annual';
                    numberCssClass = 'text-green';
                    bubbleCssClass += 'bg-light-green';
                } else if (item.leaveType === 'Refresh Leave') {
                    cssClass += 'card-refreshment';
                    numberCssClass = 'text-blue';
                    bubbleCssClass += 'bg-light-blue';
                } else if (item.leaveType === 'Sick leave') {
                    cssClass += 'card-sick';
                    numberCssClass = 'text-pink';
                    bubbleCssClass += 'bg-light-pink';
                } else if (item.leaveType === 'Personal leave') {
                    cssClass += 'card-personal';
                    numberCssClass = 'text-teal';
                    bubbleCssClass += 'bg-light-teal';
                }

                tempCards.push({
                    leaveType: item.leaveType,
                    available: item.available || 0,
                    entitlement: item.entitlement || 0,
                    cssClass: cssClass,
                    numberCssClass: numberCssClass,
                    bubbleCssClass: bubbleCssClass // Export as a single complete string
                });
            }
        });
        
        this.highlightCards = tempCards;
    }
}