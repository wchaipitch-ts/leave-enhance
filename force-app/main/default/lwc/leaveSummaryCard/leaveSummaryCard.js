import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation'; 

// Import the Apex method to fetch leave balance overview[cite: 34, 35]
import getLeaveOverview from '@salesforce/apex/TimesheetController.getLeaveOverview';

export default class LeaveSummaryCard extends NavigationMixin(LightningElement) {
    
    // ==========================================
    // Public properties to receive parameters from the parent component
    // We set default values using JavaScript Date object to ensure 
    // the component always has a valid year and month on initial load.
    // ==========================================
    @api targetUserId; 
    
    // Set default targetYear to the current year (e.g., 2026)
    @api targetYear = new Date().getFullYear(); 
    
    // Set default targetMonth to the current month (e.g., 8 for August)
    // Note: getMonth() returns 0-11 (Jan = 0), so we add 1 to match Salesforce (1-12)
    @api targetMonth = new Date().getMonth() + 1; 

    // Reactive properties for UI binding[cite: 35]
    @track isOnProbation = false;
    
    // Initialize with default values to prevent UI rendering issues before data arrives[cite: 35]
    @track annualLeave = { availableDays: 0, allocation: 0, accrued: 0, used: 0, carryOver: 0, period: '-' };
    @track refreshmentLeave = { availableDays: 0, allocation: 0, used: 0, nextRefresh: '-', daysUntilRefresh: 0 };

    // Properties to store data for navigation[cite: 35]
    @track rawEmployeeData = {}; 
    @track selectedYear = null;

    // Wire adapter to fetch Leave Overview data from Apex[cite: 34, 35]
    // Executes automatically when $targetUserId, $targetYear, or $targetMonth changes
    @wire(getLeaveOverview, { employeeId: '$targetUserId', year: '$targetYear', month: '$targetMonth' })
    wiredLeaveOverview({ error, data }) {
        if (data) {
            this.processBackendData(data);
        } else if (error) {
            console.error('--- [DEBUG] Apex Error ---', JSON.parse(JSON.stringify(error)));
        }
    }

    // Helper method to extract and map backend data to UI properties[cite: 35]
    processBackendData(backendData) {
        
        // Evaluate probation status securely using optional chaining and nullish coalescing[cite: 35]
        this.isOnProbation = backendData.employee?.onProbation ?? false;
        
        this.rawEmployeeData = backendData.employee ?? {};
        this.selectedYear = backendData.year;

        const balances = backendData.balances ?? [];

        // Map Annual Leave data[cite: 35]
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
        }

        // Map Refreshment Leave data[cite: 35]
        const refreshData = balances.find(item => item.leaveType === 'Refresh Leave');

        if (refreshData) {
            let daysUntil = 0;
            let formattedDate = '-';
            
            if (backendData.nextRefreshmentGrant) {
                const refreshDate = new Date(backendData.nextRefreshmentGrant);
                const today = new Date();
                const diffTime = refreshDate - today;
                
                // Convert milliseconds to days and round up[cite: 35]
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

    // Navigation handler for Annual Leave "View Details" button[cite: 35]
    handleViewAnnualDetails() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Leave_Balance' },
            state: { c__userId: this.rawEmployeeData.userId, c__year: this.selectedYear }
        });
    }

    // Navigation handler for Refreshment Leave "View Details" button[cite: 35]
    handleViewRefreshmentDetails() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'Leave_Balance' },
            state: { c__userId: this.rawEmployeeData.userId, c__year: this.selectedYear }
        });
    }
}