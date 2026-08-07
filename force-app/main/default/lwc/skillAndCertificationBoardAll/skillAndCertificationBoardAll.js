import { LightningElement} from 'lwc';
import getAllCertification from '@salesforce/apex/SkillAndCertificationBoardController.getAllCertification';
import CERT_ICON from '@salesforce/resourceUrl/CertificationLogos';

const columns = [
    { label: 'Cert. Name', fieldName: 'certName', type: 'text'},
    { label: 'Cert. Icon', fieldName: 'certIcon', type: 'image'},
    { label: 'Cert. Category', fieldName: 'certCat', type: 'text'},
    { label: 'Date of Passing', fieldName: 'dateOfPassing', type: 'date'}
];
export default class SkillAndCertificationBoardAll extends LightningElement {
    columns = columns;
    certUsers;
    certIcons;
    loaded = false;
    
    connectedCallback() {
        this.allCert();
    }

    allCert() {
        this.loaded = true;
        getAllCertification()
        .then(value => {
            this.loaded = false;
            const certData = JSON.parse(value);
            const keys = Object.keys(certData);
            const certsData = [];
            for (let k in keys) {
                const data = keys[k];
                const cert = this.setCertIcon(certData[data]);
                const title = cert[0].ownerTitle;
                certsData.push({ user: `${data} (${cert.length})`, title: title, certs: cert });
            }
            this.certUsers = certsData;

            // TODO :: Log data ready to display on html
            this.certUsers.forEach(certUser => {
                // console.log(certUser.user);
                // console.log(certUser.certs);
            })
        })  
    }

    setCertIcon(certsName) {
        const certWithIcon = [];
        certsName.forEach(data => {
            certWithIcon.push({
                ownerTitle: data.ownerTitle,
                dateOfPassing: data.dateOfPassing,
                certName: data.certName,
                certCat: data.certCat,
                certIcon: CERT_ICON + '/Logo/' + data.certName.split(" ").join("") + '.png'
            })
        });
        console.log(certWithIcon);
        return certWithIcon;
    }

}