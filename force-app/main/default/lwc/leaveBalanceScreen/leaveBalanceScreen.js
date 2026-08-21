import { LightningElement, track, wire } from 'lwc';

// Import NavigationMixin to read URL parameters safely
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation'; 

// Import refreshApex to force the wire adapter to fetch fresh data from the server
import { refreshApex } from '@salesforce/apex';

// Import the Apex method to fetch leave balance overview
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
        typeAttributes: { 
            label: { fieldName: 'leaveType' }, 
            target: '_blank' 
        } 
    },
    { label: 'Entitlement / Allocation', fieldName: 'entitlementStr', type: 'text' },
    { label: 'Accrued to Date', fieldName: 'accruedStr', type: 'text' },
    { label: 'Used', fieldName: 'usedStr', type: 'text' },
    { label: 'Carry Over', fieldName: 'carriedInStr', type: 'text' },
    { label: 'Available', fieldName: 'availableStr', type: 'text' }
];

export default class LeaveBalanceScreen extends NavigationMixin(LightningElement) {
    
    // =========================================================
    // STATE VARIABLES
    // =========================================================
    @track receivedUserId = null;
    @track receivedYear = null;

    @track employee = {};
    @track selectedYear;
    @track availableYears = [];
    @track highlightCards = [];
    @track tableData = [];
    
    // 🌟 RESTORED: Variables for Annual & Refreshment UI (Prevents 'undefined' error)
    @track isOnProbation = false;
    @track annualLeave = { availableDays: 0, allocation: 0, accrued: 0, used: 0, carryOver: 0, period: '-' };
    @track refreshmentLeave = { availableDays: 0, allocation: 0, used: 0, nextRefresh: '-', daysUntilRefresh: 0 };
    
    // Variables for Monthly Working Hours formatted as HH:MM
    @track standardWorkStr = '00:00';
    @track workedHoursStr = '00:00';
    @track totalHoursStr = '00:00';
    @track overtimeHoursStr = '00:00';

    columns = COLUMNS;

    // Property to hold the wire provisioned value, necessary for refreshApex
    wiredLeaveOverviewResult;

    // =========================================================
    // GETTERS (Dynamic Properties)
    // =========================================================
    get yearOptions() {
        let options = [];
        for (let i = 2020; i <= 2040; i++) {
            options.push({ label: String(i), value: String(i) });
        }
        return options;
    }

    get selectedYearString() {
        return this.receivedYear ? String(this.receivedYear) : String(new Date().getFullYear());
    }

    // =========================================================
    // 1. EXTRACT URL PARAMETERS
    // =========================================================
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
    handleYearChange(event) {
        this.receivedYear = parseInt(event.detail.value, 10);
        console.log(`--- [DEBUG] User changed year to: ${this.receivedYear} ---`);
        
        if (this.wiredLeaveOverviewResult) {
            refreshApex(this.wiredLeaveOverviewResult);
        }
    }

    // =========================================================
    // 3. FETCH DATA FROM APEX
    // =========================================================
    @wire(getLeaveOverview, { employeeId: '$receivedUserId', year: '$receivedYear', month: null })
    wiredLeaveOverview(result) {
        this.wiredLeaveOverviewResult = result;
        
        if (result.data) {
            console.log('--- [DEBUG] LeaveBalanceScreen Data Received ---');
            this.processBackendData(result.data);
        } else if (result.error) {
            console.error('--- [DEBUG] LeaveBalanceScreen Error ---', result.error);
        }
    }

    // =========================================================
    // 4. DATA MAPPING AND TRANSFORMATION
    // =========================================================
    processBackendData(backendData) {
        
        // 1. Map Employee details securely
        this.employee = backendData.employee ?? {};
        this.isOnProbation = backendData.employee?.onProbation ?? false;
        
        if (this.employee.userId) {
            this.employee.userUrl = `/lightning/r/User/${this.employee.userId}/view`;
        } else {
            this.employee.userUrl = null; 
        }

        // Format Employee Start Date
        if (this.employee.startDate) {
            const sd = new Date(this.employee.startDate);
            this.employee.startDate = sd.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
        } else {
            this.employee.startDate = '-';
        }

        // 2. Format and Map Monthly Hours
        this.standardWorkStr = this.formatDecimalToTime(backendData.standardWork ?? 0);
        this.workedHoursStr = this.formatDecimalToTime(backendData.workedHours ?? 0);
        this.totalHoursStr = this.formatDecimalToTime(backendData.totalHours ?? 0);
        this.overtimeHoursStr = this.formatDecimalToTime(backendData.overtimeHours ?? 0);

        this.selectedYear = backendData.year;
        this.availableYears = backendData.availableYears ?? [];

        const balances = backendData.balances ?? [];

        // 🌟 RESTORED: 3. Map Annual Leave data specifically for the top-left UI Card
        const annualData = balances.find(item => item.leaveType === 'Annual leave');
        if (annualData) {
            this.annualLeave = {
                availableDays: annualData.available ?? 0,
                allocation: annualData.entitlement ?? 0,
                accrued: annualData.accrued ?? 0,
                used: annualData.used ?? 0,
                carryOver: annualData.carriedIn ?? 0,
                period: `1 Jan ${backendData.year} - 31 Dec ${backendData.year}`
            };
        } else {
            // Reset if no data found for this year
            this.annualLeave = { availableDays: 0, allocation: 0, accrued: 0, used: 0, carryOver: 0, period: '-' };
        }

        // 🌟 RESTORED: 4. Map Refreshment Leave data specifically for the top-right UI Card
        const refreshData = balances.find(item => item.leaveType === 'Refresh Leave');
        if (refreshData) {
            let daysUntil = 0;
            let formattedDate = '-';
            
            if (backendData.nextRefreshmentGrant) {
                const refreshDate = new Date(backendData.nextRefreshmentGrant);
                const today = new Date();
                const diffTime = refreshDate - today;
                
                daysUntil = diffTime > 0 ? Math.ceil(diffTime / (1000 * 60 * 60 * 24)) : 0;
                const options = { day: 'numeric', month: 'short', year: 'numeric' };
                formattedDate = refreshDate.toLocaleDateString('en-GB', options);
            }

            this.refreshmentLeave = {
                availableDays: refreshData.available ?? 0,
                allocation: refreshData.entitlement ?? 0,
                used: refreshData.used ?? 0,
                nextRefresh: formattedDate,
                daysUntilRefresh: daysUntil
            };
        } else {
            // Reset if no data found for this year
            this.refreshmentLeave = { availableDays: 0, allocation: 0, used: 0, nextRefresh: '-', daysUntilRefresh: 0 };
        }

        // 5. Map Summary Table Data and construct Leave Balance URLs
        this.tableData = balances.map((item, index) => {
            const recordId = item.id || item.Id || item.recordId || item.leaveBalanceId || item.balanceId;
            const url = recordId ? `/lightning/r/Leave_Balance__c/${recordId}/view` : null;

            return {
                ...item,
                rowNumber: String(index + 1),
                leaveTypeUrl: url,
                entitlementStr: `${item.entitlement ?? 0} Days`,
                accruedStr: `${item.accrued ?? 0} Days`,
                usedStr: `${item.used ?? 0} Days`,
                carriedInStr: `${item.carriedIn ?? 0} Days`,
                availableStr: `${item.available ?? 0} Days`
            };
        });

        // 6. Map Highlight Cards Data (This populates the dynamic colorful cards)
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

    /**
     * HELPER METHOD: Converts decimal hours to HH:MM format
     */
    formatDecimalToTime(decimalHours) {
        if (!decimalHours || isNaN(decimalHours)) return '00:00';
        const hours = Math.floor(decimalHours);
        const minutes = Math.round((decimalHours - hours) * 60);
        const paddedHours = String(hours).padStart(2, '0');
        const paddedMinutes = String(minutes).padStart(2, '0');
        return `${paddedHours}:${paddedMinutes}`;
    }

    // ==========================================
    // NAVIGATION METHODS (For 'View Details' buttons)
    // ==========================================
    handleViewAnnualDetails() {
        // Safe navigation check
        const targetId = this.employee?.userId || this.receivedUserId;
        if (!targetId) return;

        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Leave_Balance' },
            state: { c__userId: targetId, c__year: this.selectedYear }
        });
    }

    handleViewRefreshmentDetails() {
        const targetId = this.employee?.userId || this.receivedUserId;
        if (!targetId) return;

        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Leave_Balance' },
            state: { c__userId: targetId, c__year: this.selectedYear }
        });
    }
}