import { LightningElement, api, wire, track } from 'lwc';
import IMAGES from "@salesforce/resourceUrl/TerraSky_Logo";
import getAllHoliday from "@salesforce/apex/HolidayListController.getAllHoliday";
import getFiscalYearOptions from '@salesforce/apex/HolidayListController.getFiscalYearOptions';

const monthNames = ["January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"
];
const dayNames = [
    "Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"
];

export default class HolidayList extends LightningElement {
    
    terraSkyLogo = IMAGES;
    holidayDate;
    holidayMonth;
    selectedYear = '2023';

    @track holidayList = [];
    @track fiscalYearOptions = [];

    connectedCallback() {
        console.log('this.selectedYear:', this.selectedYear);
        this.getAllHolidys();        
    }

    @wire(getFiscalYearOptions)
    wiredFiscalYearOptions({ error, data }) {
        if (data) {
            this.fiscalYearOptions = data;
        } else if (error) {
            // Handle error
        }
    }

    get options() {
        return this.fiscalYearOptions.map(option => ({
            label: option.Name,
            value: option.Name
        }));
    }

    handleChange(event) {
        this.selectedYear = event.detail.value;
        this.getAllHolidys();
    }

    getAllHolidys(){
        getAllHoliday({ year: this.selectedYear })
            .then(result => {
                this.holidayList = result.map((data, index) => {
                    const date = new Date(data.ActivityDate);
                    const activaityDate = date.getDate();
                    const activaityMonth = date.getMonth();
                    const activaityDay = date.getDay();
                    return {
                        ...data,
                        activaityDay: dayNames[activaityDay],
                        activaityDate: activaityDate,
                        activaityMonth: monthNames[activaityMonth],
                        holidayIndex: index + 1
                    };
                });
                console.log(this.holidayList);
                console.log(activaityDate);
            })
            .catch(error => {
                // Handle any errors
            });
    }
}