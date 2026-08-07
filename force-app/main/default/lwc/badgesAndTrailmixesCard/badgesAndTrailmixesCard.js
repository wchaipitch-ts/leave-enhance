import { api, LightningElement, track } from 'lwc';

export default class BadgesAndTrailmixesCard extends LightningElement {
    @api cardData;
    @api selectedItems;
    @track isChecked;

    renderedCallback() {
        this.initCheck();
    }

    handleSelect(event) {
        const passEvent = new CustomEvent('selectedtrailorbadge', {
            detail: {
                id: this.cardData.id,
                name: this.cardData.name,
                url: this.cardData.url,
                icon: this.cardData.icon,
                externalId: this.cardData.externalId,
                checked: event.target.checked
            }
        });
        
        this.dispatchEvent(passEvent);
    }

    initCheck() {
        const index = this.selectedItems.findIndex(data => data.id == this.cardData.id);
        if (index == -1) return;

        const target = this.selectedItems.at(index);
        const wrapper = this.template.querySelector(`input[data-id="${target.id}"]`);

        wrapper.checked = true;
    }
}