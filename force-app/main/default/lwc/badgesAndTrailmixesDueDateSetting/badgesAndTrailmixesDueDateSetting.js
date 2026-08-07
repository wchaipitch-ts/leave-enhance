import { api, LightningElement } from 'lwc';

export default class BadgesAndTrailmixesDueDateSetting extends LightningElement {
    @api selectedItems;

    handleDueDateSelected(event) {
        const data = event.detail;
        const passEvent = new CustomEvent('duedateset', {
            detail: {
                id: data.id,
                type: data.type,
                duedate: data.duedate,
                externalId: data.externalId
            }
        });

        this.dispatchEvent(passEvent);
    }
}