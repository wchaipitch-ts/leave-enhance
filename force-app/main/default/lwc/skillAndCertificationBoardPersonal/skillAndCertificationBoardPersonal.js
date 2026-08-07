import { LightningElement, wire, track } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import certificationList from '@salesforce/apex/SkillAndCertificationBoardController.certificationList';
import upcomingExam from '@salesforce/apex/SkillAndCertificationBoardController.upcomingExam';
import userAvatar from '@salesforce/apex/SkillAndCertificationBoardController.userAvatar';
import Id from '@salesforce/user/Id';
import NAME_FIELD from '@salesforce/schema/User.Name';
import TITLE_FIELD from '@salesforce/schema/User.Title';
import CERT_ICON from '@salesforce/resourceUrl/CertificationLogos';

const fields = [NAME_FIELD, TITLE_FIELD];

export default class SkillAndCertificationBoardPersonal extends LightningElement {
    userId = Id;
    avatar;
    certifications;
    datePass;
    countcert;
    loaded = false;
    @track showAnyMsg;
    showUpcomingExam;
    certificationIcon;
    certificationName;
    examinationDate;
    titleText;
    numberOfDays;
    endText;
    
    connectedCallback() {
        this.getUserAvatar();
    }

    @wire(getRecord, { recordId: '$userId', fields })
    wiredRecord({ error, data }) {
        if (data) {
            const fields = data.fields;
            this.name = fields.Name.value;
            this.title = (data.fields.Title.value!==null ? data.fields.Title.value : '');
        }
    }

    @wire(certificationList, { ownerId: '$userId' })
    wiredCert({ error, data}) {
        this.loaded = true;
        if (data) {
            this.certifications = this.setCertIcon(data);
            this.countcert = (this.certifications!==null ? this.certifications.length.toString() : '0');
            this.loaded = false;
        }
    }

    @wire(upcomingExam, { ownerId: '$userId' })
    wiredUpcomingExam({ error, data}) {
        this.loaded = true;
        if (data) {
            this.showUpcomingExam = true;
            this.certificationIcon = this.certIconPath(data.Certification_Name__c)
            this.certificationName = data.Certification_Name__c;
            this.examinationDate = this.dateFormat(new Date(data.Examination_Date__c));
            this.calculateUpcomingDays(data.Examination_Date__c);
        }
        this.loaded = false;
    }

    setCertIcon(certs) {
        const certWithIcon = [];
        certs.forEach(data => {
            certWithIcon.push({
                Name: data.Certification_Name__c,
                expr0: data.expr0,
                icon: this.certIconPath(data.Certification_Name__c)
            })
        });
        
        return certWithIcon.length<1?null:certWithIcon;
    }

    getUserAvatar() {
        userAvatar({id: this.userId})
        .then(result => {
            this.avatar = result.MediumPhotoUrl;
        })
        .catch(error => {
            console.log('Error >>>')
            console.log(error)
        })
    }

    closeShowAnyMsg(){
          this.showAnyMsg = false;
    }

    certIconPath(certName){
        return CERT_ICON + '/Logo/' + certName.split(" ").join("") + '.png';
    }

    dateFormat(date){
        const formattedDate = date.toLocaleDateString('en-GB', {
        day: 'numeric', month: 'short', year: 'numeric'
        }).replace(/ /g, ' ');

        return formattedDate;
    }

    calculateUpcomingDays(examinationDate){
        var today = new Date();
        var examDate = new Date(examinationDate);        
        // To calculate the time difference of two dates
        var differenceInTime = examDate.getTime() - today.getTime();        
        // To calculate the no. of days between two dates
        var  DifferenceInDays = differenceInTime / (1000 * 3600 * 24);
        if(parseInt(DifferenceInDays) < 6){
            this.showAnyMsg = true;
        }
        this.titleText = 'UPCOMING';
        this.numberOfDays = parseInt(DifferenceInDays).toString();
        this.endText = 'Days';
        //To display the final no. of days (result)
        if(DifferenceInDays<=1 && DifferenceInDays>0){
            this.numberOfDays = 'TOMORROW';
            this.endText = '';
        }else if(DifferenceInDays<=0){
            this.numberOfDays = 'TODAY';
            this.endText = '';
            this.titleText = '';
        }
    }
}