/*
 * LEAVE-44 — the Unpaid Leave Conversion card, on an ApplicationItem__c record page.
 *
 * Shows what of this unpaid absence the Annual balance could pay for now, and turns
 * those days into an Annual leave request in Draft for the owner to submit.
 *
 * Every figure comes from TimesheetController.getUnpaidConversion and none of them is
 * stored on the record, so nothing is calculated here: doing the arithmetic twice, once
 * in Apex for the save and once in JavaScript for the display, is how the two come to
 * disagree. The card renders what it is given and nothing else.
 */
import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';

import getUnpaidConversion from '@salesforce/apex/TimesheetController.getUnpaidConversion';
import convertUnpaidLeave from '@salesforce/apex/TimesheetController.convertUnpaidLeave';
import rejectUnpaidLeave from '@salesforce/apex/TimesheetController.rejectUnpaidLeave';

const UNPAID = 'Unpaid leave';

export default class UnpaidLeaveConversion extends NavigationMixin(LightningElement) {
    @api recordId;

    @track view;
    wiredView;
    error;
    busy = false;

    showConvertModal = false;
    showRejectModal = false;
    daysToConvert;
    rejectReason = '';

    @wire(getUnpaidConversion, { requestId: '$recordId' })
    wiredConversion(result) {
        this.wiredView = result;
        if (result.data) {
            this.view = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.view = undefined;
            this.error = this.messageOf(result.error);
        }
    }

    // ------------------------------------------------------------------ what to show

    /*
     * The card is meaningless on anything but an unpaid request, so it removes itself
     * rather than sitting there explaining why it has nothing to say. A record page can
     * carry both kinds — the split raises the paid and unpaid halves of one absence as
     * two records of the same object.
     */
    get isUnpaidRequest() {
        return !!this.view && this.view.requestType === UNPAID;
    }

    get hasError() {
        return !!this.error;
    }

    get stats() {
        const v = this.view;
        return [
            { key: 'convertible', label: 'Convertible Days',     value: this.days(v.convertibleDays) },
            { key: 'converted',   label: 'Converted Days',       value: this.days(v.convertedDays) },
            { key: 'remaining',   label: 'Remaining Unpaid Days', value: this.days(v.remainingUnpaidDays) },
            { key: 'status',      label: 'Conversion Status',    value: v.conversionStatus }
        ];
    }

    get convertedRequests() {
        return (this.view && this.view.convertedRequests) || [];
    }

    get hasConvertedRequests() {
        return this.convertedRequests.length > 0;
    }

    get convertDisabled() {
        return this.busy || !this.view || !this.view.canConvert;
    }

    get rejectDisabled() {
        return this.busy || !this.view || !this.view.canReject;
    }

    /* Only worth saying when the button it explains is the one that is off. */
    get blockedNote() {
        return this.view && !this.view.canConvert ? this.view.blockedReason : undefined;
    }

    get convertHelp() {
        const v = this.view;
        return `${this.days(v.convertibleDays)} of the ${this.days(v.remainingUnpaidDays)} unpaid `
             + `day(s) on this request can be converted, against ${this.days(v.annualAvailable)} `
             + `Annual leave day(s) available in ${v.leaveYear}.`;
    }

    /*
     * An approved request is not simply marked rejected: its balance, its calendar
     * entries and its timesheet bookings all come back with it. Somebody about to press
     * the button should be told that before they do, not after.
     */
    get rejectWarning() {
        return this.view && this.view.status === 'Approved'
            ? 'This request is approved. Rejecting it gives the unpaid days back to the '
              + 'balance and removes the calendar entries and timesheet bookings it created.'
            : 'This request has not been approved, so nothing has been booked against it yet.';
    }

    days(value) {
        return `${Number(value || 0).toFixed(2)} Days`;
    }

    // ------------------------------------------------------------------ convert

    openConvertModal() {
        this.daysToConvert = this.view.convertibleDays;
        this.showConvertModal = true;
    }

    closeConvertModal() {
        this.showConvertModal = false;
    }

    handleDaysChange(event) {
        this.daysToConvert = event.detail.value;
    }

    async handleConvert() {
        const days = Number(this.daysToConvert);
        if (!days || days <= 0) {
            this.toast('Enter how many days to convert', '', 'warning');
            return;
        }

        this.busy = true;
        try {
            await convertUnpaidLeave({ requestId: this.recordId, days });
            this.showConvertModal = false;
            this.toast(
                'Converted to Annual leave',
                'The converted days are a Draft request. Submit it for approval to have them paid.',
                'success'
            );
            await this.refresh();
        } catch (e) {
            this.toast('Could not convert these days', this.messageOf(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    // ------------------------------------------------------------------ reject

    openRejectModal() {
        this.rejectReason = '';
        this.showRejectModal = true;
    }

    closeRejectModal() {
        this.showRejectModal = false;
    }

    handleReasonChange(event) {
        this.rejectReason = event.detail.value;
    }

    async handleReject() {
        /*
         * Required here rather than in Apex, which accepts a blank reason: the service
         * has other callers and a missing note is not a data error. On this button it
         * is the only record of why a settled absence was taken back.
         */
        if (!this.rejectReason || !this.rejectReason.trim()) {
            this.toast('A reason is required', 'Say why this request is being reverted.', 'warning');
            return;
        }

        this.busy = true;
        try {
            await rejectUnpaidLeave({ requestId: this.recordId, reason: this.rejectReason });
            this.showRejectModal = false;
            this.toast('Request reverted', 'The unpaid days have been given back.', 'success');
            await this.refresh();
        } catch (e) {
            this.toast('Could not revert this request', this.messageOf(e), 'error');
        } finally {
            this.busy = false;
        }
    }

    // ------------------------------------------------------------------ plumbing

    handleOpenRequest(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: event.currentTarget.dataset.id,
                objectApiName: 'ApplicationItem__c',
                actionName: 'view'
            }
        });
    }

    /*
     * Both refreshes are needed. refreshApex brings the card's own figures back, and
     * notifyRecordUpdateAvailable brings the rest of the page with it — converting an
     * approved request rejects it, so the status in the highlights panel above this card
     * is stale the moment the call returns.
     */
    async refresh() {
        await refreshApex(this.wiredView);
        notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
    }

    messageOf(e) {
        if (!e) {
            return 'Something went wrong.';
        }
        if (e.body) {
            return Array.isArray(e.body) ? e.body[0].message : e.body.message;
        }
        return e.message || String(e);
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
