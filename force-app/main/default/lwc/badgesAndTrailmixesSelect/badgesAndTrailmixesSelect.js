import { api, LightningElement } from 'lwc';

export default class BadgesAndTrailmixesSelect extends LightningElement {
    @api recordId;
    @api trailsOrBadgesData;
    @api selectedItems; 
    @api type;

    handleSelectedTrailOrBadge(event) {
        const data = event.detail;
        const passEvent = new CustomEvent('selecteditem', {
            detail: {
                type: this.type,
                id: data.id,
                name: data.name,
                url: data.url,
                icon: data.icon,
                externalId: data.externalId,
                checked: data.checked
            }
        });
        this.dispatchEvent(passEvent);
    }
}