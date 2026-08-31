import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation'; 

// Import the Apex method to fetch leave balance overview
import getLeaveOverview from '@salesforce/apex/TimesheetController.getLeaveOverview';

export default class LeaveSummaryCard extends NavigationMixin(LightningElement) {
    
    // ==========================================
    // INPUT PARAMETERS (Data from parent component)
    // ==========================================
    @api targetUserId; 
    @api targetYear = new Date().getFullYear(); 
    @api targetMonth = new Date().getMonth() + 1; 

    // ==========================================
    // STATE VARIABLES (UI Binding)
    // ==========================================
    @track isOnProbation = false;
    // @track annualLeave = { availableDays: 0, allocation: 0, accrued: 0, used: 0, carryOver: 0, period: '-' };
    @track annualLeave = { availableDays: 0, allocation: 0, accrued: 0, used: 0, carryOver: '0 / 0', period: '-' };
    @track refreshmentLeave = { availableDays: 0, allocation: 0, used: 0, nextRefresh: '-', daysUntilRefresh: 0 };

    // User Info variables
    @track userAvatar = '';
    @track userName = '';
    @track userPath = '';
    @track employeeNumber = '';
    @track userDepartment = '';
    @track userStartDate = '';

    // Variables for Monthly Working Hours
    @track standardWorkStr = '00:00';
    @track workedHoursStr = '00:00';
    @track totalHoursStr = '00:00';
    @track overtimeHoursStr = '00:00';

    @track rawEmployeeData = {}; 
    @track selectedYear = null;

    // ==========================================
    // WIRE METHOD: Fetch data from Apex
    // ==========================================
    @wire(getLeaveOverview, { employeeId: '$targetUserId', year: '$targetYear', month: '$targetMonth' })
    wiredLeaveOverview({ error, data }) {
        if (data) {
            this.processBackendData(data);
        } else if (error) {
            console.error('--- [DEBUG] Apex Error ---', JSON.parse(JSON.stringify(error)));
        }
    }

    // ==========================================
    // HELPER METHOD: Process and Map Backend Data
    // ==========================================
    processBackendData(backendData) {
        
        // Map User Info securely
        const emp = backendData.employee;
        if (emp) {
            this.userAvatar = emp.photoUrl ?? '';
            this.userName = emp.name ?? '-';
            this.userPath = emp.userId ? '/' + emp.userId : '#';
            this.employeeNumber = emp.employeeNumber ?? '-';
            this.userDepartment = emp.department ?? '-';
            
            if (emp.startDate) {
                const sd = new Date(emp.startDate);
                this.userStartDate = sd.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
            } else {
                this.userStartDate = '-';
            }
        }

        // Map Monthly Hours
        this.standardWorkStr = this.formatDecimalToTime(backendData.standardWork ?? 0);
        this.workedHoursStr = this.formatDecimalToTime(backendData.workedHours ?? 0);
        this.totalHoursStr = this.formatDecimalToTime(backendData.totalHours ?? 0);
        this.overtimeHoursStr = this.formatDecimalToTime(backendData.overtimeHours ?? 0);

        // Extract probation and year
        this.isOnProbation = backendData.employee?.onProbation ?? false;
        // 🌟 Fix: Store employee data safely to avoid Navigation Error
        this.rawEmployeeData = backendData.employee ?? { userId: this.targetUserId }; 
        this.selectedYear = backendData.year;

        const balances = backendData.balances ?? [];

        // Map Annual Leave data
        // const annualData = balances.find(item => item.leaveType === 'Annual leave');
        const annualData = balances.find(item => item.leaveType === 'Annual leave');
        if (annualData) {
            // @description Extract carryRemaining and carriedIn safely, defaulting to 0 if undefined.
            const carryRemaining = annualData.carryRemaining !== undefined ? annualData.carryRemaining : 0;
            const carriedIn = annualData.carriedIn !== undefined ? annualData.carriedIn : 0;

            this.annualLeave = {
                availableDays: annualData.available ?? 0,
                allocation: annualData.entitlement ?? 0,
                accrued: annualData.accrued ?? 0,
                used: annualData.used ?? 0,
                // carryOver: annualData.carriedIn ?? 0,
                carryOver: `${carryRemaining} / ${carriedIn}`,
                period: `1 Jan ${backendData.year} - 31 Dec ${backendData.year}`
            };
        }

        // Map Refreshment Leave data
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
        }
    }

    /**
     * HELPER METHOD: Converts decimal hours to HH:MM format
     * Example: 7.5 -> '07:30'
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
    // NAVIGATION METHODS
    // ==========================================
    handleViewAnnualDetails() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Leave_Balance' },
            state: { c__userId: this.rawEmployeeData.userId, c__year: this.selectedYear }
        });
    }

    handleViewRefreshmentDetails() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Leave_Balance' },
            state: { c__userId: this.rawEmployeeData.userId, c__year: this.selectedYear }
        });
    }
}