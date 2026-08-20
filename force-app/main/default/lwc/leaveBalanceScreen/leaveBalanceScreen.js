import { LightningElement, track, wire } from 'lwc';

// Import NavigationMixin to read URL parameters
import { CurrentPageReference } from 'lightning/navigation'; 

// Import the Apex method to fetch leave balance overview
import getLeaveOverview from '@salesforce/apex/TimesheetController.getLeaveOverview';

// Define datatable columns configuration
const COLUMNS = [
    { label: 'No.', fieldName: 'rowNumber', type: 'text', initialWidth: 80 },
    { label: 'Leave Type', fieldName: 'leaveType', type: 'text' },
    { label: 'Entitlement / Allocation', fieldName: 'entitlementStr', type: 'text' },
    { label: 'Accrued to Date', fieldName: 'accruedStr', type: 'text' },
    { label: 'Used', fieldName: 'usedStr', type: 'text' },
    { label: 'Carry Over', fieldName: 'carriedInStr', type: 'text' },
    { label: 'Available', fieldName: 'availableStr', type: 'text' }
];

export default class LeaveBalanceScreen extends LightningElement {
    
    // Properties to store parameters received from URL
    @track receivedUserId = null;
    @track receivedYear = null;

    // Reactive properties for UI binding
    @track employee = {};
    @track selectedYear;
    @track availableYears = [];
    @track highlightCards = [];
    @track tableData = [];
    columns = COLUMNS;

    // =========================================================
    // 1. Extract Parameters from URL (State)
    // =========================================================
    @wire(CurrentPageReference)
    getStateParameters(currentPageReference) {
        if (currentPageReference && currentPageReference.state) {
            this.receivedUserId = currentPageReference.state.c__userId || null;
            
            // Parse year to Integer or use current year as fallback
            this.receivedYear = currentPageReference.state.c__year ? parseInt(currentPageReference.state.c__year, 10) : new Date().getFullYear();
        }
    }

    // =========================================================
    // 2. Fetch Data from Apex using the extracted URL parameters
    // Note: 'month' is passed as null so Apex handles it by default
    // =========================================================
    @wire(getLeaveOverview, { employeeId: '$receivedUserId', year: '$receivedYear', month: null })
    wiredLeaveOverview({ error, data }) {
        if (data) {
            console.log('--- [DEBUG] LeaveBalanceScreen Data ---', JSON.parse(JSON.stringify(data)));
            this.processBackendData(data);
        } else if (error) {
            console.error('--- [DEBUG] LeaveBalanceScreen Error ---', error);
        }
    }

    // =========================================================
    // 3. Helper method to map and format data for the UI
    // =========================================================
    processBackendData(backendData) {
        // Map Employee details
        this.employee = backendData.employee ?? {};
        this.selectedYear = backendData.year;
        this.availableYears = backendData.availableYears ?? [];

        const balances = backendData.balances ?? [];

        // Map Summary Table Data (Bottom Section)
        this.tableData = balances.map((item, index) => {
            return {
                ...item,
                rowNumber: String(index + 1),
                entitlementStr: `${item.entitlement ?? 0} Days`,
                accruedStr: `${item.accrued ?? 0} Days`,
                usedStr: `${item.used ?? 0} Days`,
                carriedInStr: `${item.carriedIn ?? 0} Days`,
                availableStr: `${item.available ?? 0} Days`
            };
        });

        // Map Highlight Cards Data (Top Section)
        const highlightTypes = ['Annual leave', 'Refresh Leave', 'Sick leave', 'Personal leave'];
        let tempCards = [];

        balances.forEach(item => {
            if (highlightTypes.includes(item.leaveType)) {
                
                let cssClass = 'highlight-card ';
                let numberCssClass = '';

                if (item.leaveType === 'Annual leave') {
                    cssClass += 'card-annual';
                    numberCssClass = 'text-green';
                } else if (item.leaveType === 'Refresh Leave') {
                    cssClass += 'card-refreshment';
                    numberCssClass = 'text-blue';
                } else if (item.leaveType === 'Sick leave') {
                    cssClass += 'card-sick';
                    numberCssClass = 'text-pink';
                } else if (item.leaveType === 'Personal leave') {
                    cssClass += 'card-personal';
                    numberCssClass = 'text-teal';
                }

                tempCards.push({
                    leaveType: item.leaveType,
                    available: item.available ?? 0,
                    entitlement: item.entitlement ?? 0,
                    cssClass: cssClass,
                    numberCssClass: numberCssClass
                });
            }
        });
        
        this.highlightCards = tempCards;
    }
}