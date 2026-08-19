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
import revertConversion from '@salesforce/apex/TimesheetController.revertConversion';

export default class UnpaidLeaveConversion extends NavigationMixin(LightningElement) {
    @api recordId;

    @track view;
    wiredView;
    error;
    busy = false;

    showConvertModal = false;
    showRevertModal = false;
    daysToConvert;
    revertReason = '';

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
     * Whether this record has anything to do with conversion at all — an unpaid request,
     * or a paid one a conversion produced. Apex decides, because the second case is what
     * keeps a conversion made in error reachable, and a rule about which records that
     * covers belongs beside the rule that produced them.
     */
    get showsCard() {
        return !!this.view && this.view.showsConversion;
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

    get revertDisabled() {
        return this.busy || !this.view || !this.view.canRevert;
    }

    /*
     * Only worth saying when the button it explains is the one that is off. The revert
     * note is held back while conversion is still available, because "nothing to revert"
     * is the ordinary state of a request nobody has converted yet, not a problem.
     */
    get blockedNote() {
        return this.view && !this.view.canConvert ? this.view.blockedReason : undefined;
    }

    get revertNote() {
        return this.view && !this.view.canConvert && !this.view.canRevert
            ? this.view.revertBlockedReason
            : undefined;
    }

    get convertHelp() {
        const v = this.view;
        return `${this.days(v.convertibleDays)} of the ${this.days(v.remainingUnpaidDays)} unpaid `
             + `day(s) on this request can be converted, against ${this.days(v.annualAvailable)} `
             + `Annual leave day(s) available in ${v.leaveYear}.`;
    }

    /*
     * What reverting is about to do, in the terms the person pressing it is thinking in.
     * "Reject" on its own reads as refusing the absence; what it refuses is the paid
     * request the conversion made, and the days themselves stay exactly where they were.
     */
    get revertWarning() {
        const spent = this.convertedRequests.some((made) => !made.awaitingApproval);
        return spent
            ? 'The converted request has been approved. Revoking it gives those Annual leave '
              + 'days back to the balance and removes the calendar entries and timesheet '
              + 'bookings it created. The days go back to being unpaid, as they were before '
              + 'the conversion.'
            : 'The converted request has not been approved, so no Annual leave has been spent. '
              + 'The days go back to being unpaid, as they were before the conversion.';
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

    // ------------------------------------------------------------------ revert

    openRevertModal() {
        this.revertReason = '';
        this.showRevertModal = true;
    }

    closeRevertModal() {
        this.showRevertModal = false;
    }

    handleReasonChange(event) {
        this.revertReason = event.detail.value;
    }

    async handleRevert() {
        /*
         * Required here rather than in Apex, which accepts a blank reason: the service
         * has other callers and a missing note is not a data error. On this button it is
         * the only record of why a conversion somebody made deliberately was undone.
         */
        if (!this.revertReason || !this.revertReason.trim()) {
            this.toast('A reason is required', 'Say why this conversion is being reverted.', 'warning');
            return;
        }

        this.busy = true;
        try {
            await revertConversion({ requestId: this.recordId, reason: this.revertReason });
            this.showRevertModal = false;
            this.toast(
                'Conversion reverted',
                'The paid request has been rejected and the days are unpaid again.',
                'success'
            );
            await this.refresh();
        } catch (e) {
            this.toast('Could not revert this conversion', this.messageOf(e), 'error');
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