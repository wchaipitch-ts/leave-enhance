import { api, LightningElement } from 'lwc';

export default class BadgesAndTrailmixesDueDateDeatil extends LightningElement {
    @api selectedItems;

    handleInputDueDate(event) {
        const data = event.target;
        
        const passEvent = new CustomEvent('duedateselected', {
            detail: {
                id: data.dataset.id,
                type: data.dataset.type,
                duedate: data.value,
                externalId: data.externalId
            }
        });

        this.dispatchEvent(passEvent);
    }
}