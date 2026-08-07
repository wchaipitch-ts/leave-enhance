import { LightningElement, api } from 'lwc';

export default class JobCard extends LightningElement {
    @api jobTitle;
    @api jobLevel;
    @api jobLocation;
    @api jobSchedule;
    @api jobRequirements;
    @api jobDetail;

    handleMoreDetail() {
        const jobDetail = {
            title: this.jobTitle,
            level: this.jobLevel,
            location: this.jobLocation,
            schedule: this.jobSchedule,
            requirements: this.jobRequirements,
            detail:this.jobDetail
        };
        const event = new CustomEvent('showdetails', { detail: jobDetail });
        this.dispatchEvent(event);
    }
}