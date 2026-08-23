/*
 * LEAVE-49 — TEMPORARY. Delete with LeaveJobRunnerController before production.
 *
 * Drives LeaveManagementController.runDaily for a chosen date so the yearly cycle -
 * the January grant, carry over, the June sweep, refreshment - can be signed off by
 * somebody who does not write Apex. Preview rolls back; running for real does not.
 */
import { LightningElement, track, wire } from 'lwc';
import isAvailable from '@salesforce/apex/LeaveJobRunnerController.isAvailable';
import getEmployees from '@salesforce/apex/LeaveJobRunnerController.getEmployees';
import runJob from '@salesforce/apex/LeaveJobRunnerController.run';

const COLUMNS = ['Entitlement', 'Accrued', 'Carried In', 'Carry Over Left', 'Used',
                 'Available', 'Granted On', 'Carry Expiry', 'Window Expiry'];

export default class LeaveJobRunner extends LightningElement {
    @track employees = [];
    @track result = null;
    employeeId = null;
    runDate = new Date().toISOString().slice(0, 10);
    year = new Date().getFullYear();
    busy = false;
    error = null;

    /*
     * Hidden until proved otherwise. The component sits on the Leave Balance tab
     * alongside the employee-facing screen, so anybody without the Run Leave Job
     * permission - which is nearly everybody - must see no trace of it.
     */
    available = false;

    columns = COLUMNS;

    @wire(isAvailable)
    wiredAvailability({ data }) {
        this.available = data === true;
    }

    @wire(getEmployees)
    wiredEmployees({ data, error }) {
        if (data) {
            this.employees = data;
            this.error = null;
        } else if (error && this.available) {
            // Swallowed when unavailable: the guard throwing is the expected path for
            // anybody who is not meant to see the component at all.
            this.error = this.messageOf(error);
        }
    }

    get summaryClass() {
        const base = 'slds-box slds-m-top_medium slds-text-body_regular ';
        return base + (this.result && this.result.applied
            ? 'slds-theme_warning' : 'slds-theme_success');
    }

    handleDate(e) { this.runDate = e.target.value; }
    handleEmployee(e) { this.employeeId = e.detail.value; }
    handleYear(e) { this.year = parseInt(e.target.value, 10); }
    handleClear() { this.result = null; this.error = null; }

    handlePreview() { this.execute(false); }

    /*
     * A committed run writes to every employee in the org, so it asks first. The
     * browser confirm is deliberately plain - this is a sandbox tool and a custom
     * modal would be more code than the warning is worth.
     */
    handleCommit() {
        /* eslint-disable no-alert */
        const ok = window.confirm(
            'This saves the changes for EVERY employee, not just the one you are watching.\n\n' +
            'Preview first if you have not already. Continue?');
        if (ok) {
            this.execute(true);
        }
    }

    execute(commitRun) {
        this.busy = true;
        this.error = null;
        runJob({
            runDate: this.runDate,
            employeeId: this.employeeId,
            year: this.year,
            commitRun
        })
            .then((res) => {
                this.result = this.decorate(res);
            })
            .catch((err) => {
                this.error = this.messageOf(err);
                this.result = null;
            })
            .finally(() => {
                this.busy = false;
            });
    }

    /* Styling is computed here rather than in the template, which cannot call methods. */
    decorate(res) {
        const rows = (res.rows || []).map((row) => ({
            ...row,
            rowClass: row.changed ? 'moved-row' : '',
            cells: (row.cells || []).map((cell) => ({
                ...cell,
                cellClass: cell.changed ? 'moved' : ''
            }))
        }));
        return { ...res, rows };
    }

    messageOf(err) {
        if (!err) return 'Something went wrong.';
        if (err.body && err.body.message) return err.body.message;
        if (err.message) return err.message;
        return JSON.stringify(err);
    }
}
