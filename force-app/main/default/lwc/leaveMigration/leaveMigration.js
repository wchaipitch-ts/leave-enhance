/*
 * LEAVE-50 — the six migration steps, run from a screen.
 *
 * Preview writes nothing and always runs first. Outside a sandbox, Apply stays disabled
 * until the org's name has been typed back - checked again server-side, because a
 * client-side gate protects nobody.
 */
import { LightningElement, track, wire } from 'lwc';
import isAvailable from '@salesforce/apex/LeaveMigrationController.isAvailable';
import getContext from '@salesforce/apex/LeaveMigrationController.getContext';
import getSteps from '@salesforce/apex/LeaveMigrationController.getSteps';
import preview from '@salesforce/apex/LeaveMigrationController.preview';
import applyStep from '@salesforce/apex/LeaveMigrationController.apply';
import snapshot from '@salesforce/apex/LeaveMigrationController.snapshot';

export default class LeaveMigration extends LightningElement {
    @track steps = [];
    @track context = {};
    available = false;
    year = new Date().getFullYear();
    confirmation = '';
    busy = false;
    error = null;

    @wire(isAvailable)
    wiredAvailability({ data }) {
        this.available = data === true;
        if (this.available) {
            this.load();
        }
    }

    @wire(getContext)
    wiredContext({ data }) {
        if (data) {
            this.context = data;
            this.year = data.defaultYear;
        }
    }

    load() {
        getSteps()
            .then((data) => {
                this.steps = data.map((s) => this.decorate(s, null));
            })
            .catch((e) => {
                this.error = this.messageOf(e);
            });
    }

    get orgBadge() {
        if (!this.context.orgName) return '';
        return this.context.isSandbox
            ? 'sandbox · ' + this.context.orgName
            : 'PRODUCTION · ' + this.context.orgName;
    }

    get orgBadgeClass() {
        return this.context.isSandbox
            ? 'slds-badge slds-badge_lightest'
            : 'slds-badge slds-theme_error';
    }

    /*
     * Apply is off until the step has been previewed in this session. The preview is the
     * only thing standing between a reader and a migration they have not seen the size of,
     * so it is a precondition rather than a suggestion.
     */
    decorate(s, outcome) {
        const blocked = Boolean(s.blockedReason);
        const previewed = Boolean(outcome);
        const confirmed = !this.context.confirmationRequired
            || this.confirmation === this.context.orgName;
        const lines = outcome && outcome.lines ? outcome.lines : [];
        return {
            ...s,
            outcome,
            hasLines: lines.length > 0,
            detail: lines.join('\n'),
            applyDisabled: this.busy || blocked || !previewed || !confirmed,
            boxClass: 'slds-box slds-m-bottom_small' + (blocked ? ' blocked' : ''),
            outcomeClass:
                'slds-box slds-box_xx-small slds-m-top_x-small slds-text-body_small ' +
                (outcome && outcome.applied ? 'slds-theme_warning' : 'slds-theme_success')
        };
    }

    refreshDecorations() {
        this.steps = this.steps.map((s) => this.decorate(s, s.outcome));
    }

    handleYear(e) { this.year = parseInt(e.target.value, 10); }

    handleConfirmation(e) {
        this.confirmation = e.target.value;
        this.refreshDecorations();
    }

    handlePreview(e) {
        const step = e.target.dataset.step;
        this.run(preview({ step, year: this.year }), step);
    }

    handleApply(e) {
        const step = e.target.dataset.step;
        /* eslint-disable no-alert */
        const ok = window.confirm(
            'Apply step ' + step + '? This writes to leave data for every employee.\n\n' +
            (step === '03'
                ? 'Step 03 re-seeds consumption from the frozen User fields. It cannot be undone.\n\n'
                : '') +
            'Continue?');
        if (ok) {
            this.run(applyStep({ step, year: this.year, confirmation: this.confirmation }), step);
        }
    }

    run(promise, step) {
        this.busy = true;
        this.error = null;
        promise
            .then((outcome) => {
                this.steps = this.steps.map((s) =>
                    s.step === step ? this.decorate(s, outcome) : s);
            })
            .catch((e) => {
                this.error = this.messageOf(e);
            })
            .finally(() => {
                this.busy = false;
                this.refreshDecorations();
            });
    }

    /*
     * The User leave fields are the frozen fallback every step reads from, and nothing
     * recreates them once overwritten. Downloading is client-side because the file should
     * land on the operator's machine, not in Salesforce where the migration could reach it.
     */
    handleSnapshot() {
        this.busy = true;
        snapshot()
            .then((csv) => {
                const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-');
                const link = document.createElement('a');
                link.href = 'data:text/csv;charset=utf-8,' + encodeURIComponent(csv);
                link.download = 'leave-user-fields-' + stamp + '.csv';
                link.click();
            })
            .catch((e) => {
                this.error = this.messageOf(e);
            })
            .finally(() => {
                this.busy = false;
            });
    }

    messageOf(err) {
        if (!err) return 'Something went wrong.';
        if (err.body && err.body.message) return err.body.message;
        if (err.message) return err.message;
        return JSON.stringify(err);
    }
}