import { LightningElement } from 'lwc';
import certificationChart from '@salesforce/apex/SkillAndCertificationBoardController.certificationChart';

const columns = [
    { label: 'Max Count Cert', fieldName: 'maxCountCert', type: 'text' },
    { label: 'Max Cert Type', fieldName: 'maxCertType', type: 'text' },
    { label: 'All Cert Pass', fieldName: 'allCertPass', type: 'text' },
    { label: 'Max Cert User', fieldName: 'maxCertUser', type: 'text' },
    { label: 'Cert Count Top 5', fieldName: 'certTypeCountTopFive', type: 'text' },
    { label: 'Cert Type Top 5', fieldName: 'certTypeNameTopFive', type: 'text' }
];

export default class SkillAndCertificationBoardChart extends LightningElement {
    chartBgDonut = '["rgba(25,25,128, 1)", "rgba(93,71,139, 1)", "rgba(137,104,205, 1)", "rgba(159,121,238, 1)", "rgba(147,112,219, 1)", "rgba(122,55,139, 1)", "rgba(180,82,205, 1)", "rgba(186,85,211, 1)", "rgba(139,28,98, 1)", "rgba(238,48,167, 1)", "rgba(139,0,139, 1)", "rgba(205,0,205, 1)"]';
    borderColorDonut = "rgba(7, 62, 146, 0.7)";
    chartBgHorizon = '["rgba(112, 124, 212, 1)", "rgba(82, 183, 216, 1)", "rgba(225, 96, 50, 1)", "rgba(255, 176, 59, 1)", "rgba(84, 167, 123, 1)" ]';
    borderColorHorizon = "rgba(0, 0, 0, 0.7)";

    columns = columns;
    maxCountCert;
    maxCertType;
    allCertPass;
    maxCertUser;
    certTypeAmountTopFive;
    certTypeNameTopFive;
    certTypeAmountAll;
    certTypeNameAll;
    // loaded = false;

    connectedCallback() {
        this.getCertificationChart();
    }

    getCertificationChart() {
        certificationChart()
        .then(data => {
            console.log('HELLO')
            console.log(data)
            const myData = JSON.parse(data);
            this.maxCountCert = myData.maxCountCert;
            this.maxCertType = myData.maxCertType;
            this.allCertPass = myData.allCertPass;
            this.maxCertUser = myData.maxCertUser;
            this.certTypeAmountTopFive = myData.topFiveAmount;
            this.certTypeNameTopFive = myData.topFiveName;
            this.certTypeAmountAll = myData.allCertAmount;
            this.certTypeNameAll = myData.allCertName;
        })
    }


}