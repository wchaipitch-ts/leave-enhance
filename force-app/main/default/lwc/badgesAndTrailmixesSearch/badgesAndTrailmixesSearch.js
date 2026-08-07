import { api, LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import searchBadgesAndTrail from '@salesforce/apex/CertificationBoardingTrailhead.searchBadgesAndTrail'
import saveBadgeAndTrail from '@salesforce/apex/CertificationBoardingTrailhead.saveBadgeAndTrail';

const TRAILMIX_TYPE = 'trailmix';
const BADGE_TYPE = 'badge';
const ESCAPE_KEY = 'Escape';
const ENTER_KEY_CODE = 13;

export default class BadgesAndTrailmixesSearch extends LightningElement {
    @api recordId;
    @track searchInputText = '';
    @track badgesData;
    @track trailmixesData;
    @track isModalOpen = false;
    @track isNextStep = false;
    @track isLoad = false;

    handleInputChange(event) {
        this.searchInputText = event.target.value;
    }

    closeModal() {
        this.searchInputText = '';
        this.trailmixesData = null;
        this.badgesData = null;
        this.selectedBadges = null;
        this.selectedTrailmixes = null;
        this.isModalOpen = false;
        this.isNextStep = false;
    }

    handleClick() {
        searchBadgesAndTrail({ searchText: this.searchInputText })
        .then(result => {
            this.badgesData = result.badges;
            this.trailmixesData = result.trailmixes;
            this.isModalOpen = true;
        })
        .catch(error => {
            this.isModalOpen = false;
            console.log(error);
        })
    }

    handleEnter(event) {
        if (event.keyCode != ENTER_KEY_CODE) return;

        searchBadgesAndTrail({ searchText: this.searchInputText })
        .then(result => {
            this.badgesData = result.badges;
            this.trailmixesData = result.trailmixes;
            this.isModalOpen = true;
        })
        .catch(error => {
            this.isModalOpen = false;
            console.log(error);
        })
    }

    handleNextStep() {
        this.isModalOpen = false;
        this.isNextStep = true;
    }

    handleBackStep() {
        this.isModalOpen = true;
        this.isNextStep = false;
    }

    @track selectedTrailmixes = [];
    @track selectedBadges = [];
    handleSelectedItem(event) {
        const data = event.detail;
        const selectedItem = {
            id: data.id,
            name: data.name,
            url: data.url,
            icon: data.icon,
            externalId: data.externalId,
            type: data.type
        };

        if (data.type == TRAILMIX_TYPE) {
            if (data.checked) {
                this.selectedTrailmixes.push(selectedItem);
            } else {
                var index = this.selectedTrailmixes.findIndex(data => data.id == selectedItem.id);
                if (index != -1) this.selectedTrailmixes.splice(index, 1);
            }
        } else if (data.type == BADGE_TYPE) {
            if (data.checked) {
                this.selectedBadges.push(selectedItem);
            } else {
                var index = this.selectedBadges.findIndex(data => data.id == selectedItem.id);
                if (index != -1) this.selectedBadges.splice(index, 1);
            }
        }
    }

    handleEscKey(event) {
        if(event.code != ESCAPE_KEY) return;
        this.searchInputText = '';
        this.trailmixesData = null;
        this.badgesData = null;
        this.selectedBadges = null;
        this.selectedTrailmixes = null;
        this.isModalOpen = false;
        this.isNextStep = false;
    }

    handleDueDateSet(event) {
        const data = event.detail;

        if (data.type == TRAILMIX_TYPE) {
            const index = this.selectedTrailmixes.findIndex(item => item.id == data.id);
            this.selectedTrailmixes.at(index).duedate = data.duedate;
        } else if (data.type == BADGE_TYPE) {
            const index = this.selectedBadges.findIndex(item => item.id == data.id);
            this.selectedBadges.at(index).duedate = data.duedate;
        }
    }

    handleSaveBadgeAndTrail() {
        this.isLoad = true;
        const saveTarget = this.selectedBadges.concat(this.selectedTrailmixes);

        saveBadgeAndTrail({ saveData: saveTarget, skillAndCertId: this.recordId })
        .then(result => {
            console.log(result);
            this.isLoad = false;
            this.closeModal();
            this.showToast();
            eval("$A.get('e.force:refreshView').fire();");
        })
        .catch(error => {
            this.isLoad = false;
            console.log('Error');
            console.log(error);
            this.closeModal();
        });
    }

    showToast() {
        const event = new ShowToastEvent({
            title: 'Success',
            message: 'Assign badges and trailmixes success',
            variant: 'success'
        });
        this.dispatchEvent(event);
    }
}