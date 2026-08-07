import { LightningElement, track, api } from 'lwc';
import Id from '@salesforce/user/Id';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';


/*　Added by TSJP Raman - Start　*/
import checkTimeRecord from '@salesforce/apex/TimestampController.checkTimeRecord';
import setTimeStamp from '@salesforce/apex/TimestampController.setTimeStamp';
import MaxHourPerDay from '@salesforce/label/c.MaxHourPerDay';
import TimeIn from '@salesforce/label/c.TimeIn';
import TimeOut from '@salesforce/label/c.TimeOut';
import TimeBreakIn from '@salesforce/label/c.TimeBreakIn';
import TimeBreakOut from '@salesforce/label/c.TimeBreakOut';

const ONE_HOUR = 3600000;
const ONE_MINUTE = 60000;
/*　Added by TSJP Raman - End*/

export default class Timestamp extends LightningElement {

    @api stamp;
    @track loaded = true;
    @track userId = Id;

    @track todayDate = new Date();
    @track stampedIn = true;
    @track stampedOut = true;

    @track todayString = '';
    @track weekString = '';
    @track hoursString = '';
    @track minuesString = '';
    @track dotString = ':';
    @track hours;
    @track minutes;
    @track tempDate;
    @track showDotString = true;

    @track latitude = null;
    @track longitude = null;

    /*　Added by TSJP Raman - Start　*/
    // Default Max Hour Per Day (7.5)
	@track regularTime_Flo = parseFloat(MaxHourPerDay);
	@track regularTime_Int = this.regularTime_Flo * ONE_HOUR;
	@track regularTime_Str = this.timeConverter(this.regularTime_Int, 'HH:MM');

	// Default TimeIn (08.30)
	@track timeIn_Flo = parseFloat(TimeIn);
	@track timeIn_Int = this.timeIn_Flo * ONE_HOUR;
	@track timeIn_Str = this.timeConverter(this.timeIn_Int, 'HH:MM');

	// Default TimeOut (17.00)
	@track timeOut_Flo = parseFloat(TimeOut);
	@track timeOut_Int = this.timeOut_Flo * ONE_HOUR;
	@track timeOut_Str = this.timeConverter(this.timeOut_Int, 'HH:MM');

    // Break Time Set (In&Out)
	@track breakTimeIn_Flo = parseFloat(TimeBreakIn);
	@track breakTimeIn_Int = this.breakTimeIn_Flo * ONE_HOUR;
	@track breakTimeIn_Str = this.timeConverter(this.breakTimeIn_Int, 'HH:MM');

	@track breakTimeOut_Flo = parseFloat(TimeBreakOut);
	@track breakTimeOut_Int = this.breakTimeOut_Flo * ONE_HOUR;
	@track breakTimeOut_Str = this.timeConverter(this.breakTimeOut_Int, 'HH:MM');

	@track defaultLunchBreak = this.breakTimeIn_Str + ' ~ ' + this.breakTimeOut_Str;
	@track defaultTimeFormat = 'HH:MM';

    @track currentPageUrl;
    @track timeIn;
    @track timeOut;
    @track descriptionValue;
    @track stTimeIn = 0;
    @track stTimeOut = 0;
    @track dispRemarkFlg = false;
    @track remarkType;
    @track remarks;
    @track isShowModal = false;
    @track modalHeader = '';
    @track modalName = '';

    @track totalWorkedHours_int = 0;
    @track overTime_int = 0;
    @track toastMsg;
    /*　Added by TSJP Raman - End　*/

    connectedCallback() {
        this.getTime();
        this.checkTimeStampRecord();
		setInterval(() => {
			this.getTime();
		}, 1000);

        this.currentPageUrl = window.location.href.includes('home');  //Added by TSJP Raman

        const options = {
            enableHighAccuracy: true,
            timeout: 5000,
            maximumAge: 0,
        };
        navigator.geolocation.getCurrentPosition(
            pos => {
                this.latitude = pos.coords.latitude;
                this.longitude = pos.coords.longitude;
            },
            err => {
                console.warn(`ERROR(${err.code}): ${err.message}`);
            },
            options
        );
	}

    getTime() {
		this.todayDate = new Date();

        this.todayString = new Intl.DateTimeFormat('ja', { year: 'numeric', month: '2-digit', day: '2-digit' }).format(this.todayDate);
        this.weekString = new Intl.DateTimeFormat('en', { weekday: 'short' }).format(this.todayDate);

        //TSJP Raman Modification Start
        this.tempDate = new Intl.DateTimeFormat('th', { hour: '2-digit', minute: '2-digit'}).format(this.todayDate);
        this.hours = this.tempDate.slice(0, 2);
        this.minutes = this.tempDate.slice(3, 5);
        //TSJP Raman Modification End
	}

    checkTimeStampRecord() {
        this.loaded = false;
        checkTimeRecord({ userId: this.userId })
            .then(value => {
                var tempValue = JSON.parse(JSON.stringify(value));
                if(tempValue.length == 0){
                    this.stampedIn = false;
                    this.stampedOut = false;
                }else{ 
                    //TSJP Raman Modification Start
                    this.modalName = tempValue[0].Name;
                    if(tempValue[0].Stamped_TimeIn__c){
                        this.stampedIn = true;
                        this.stampedOut = false;
                        this.stTimeIn = tempValue[0].Stamped_TimeIn__c;
                        this.timeIn = this.timeConverter(tempValue[0].Stamped_TimeIn__c, 'HH:MM');
                    }
                    if(tempValue[0].Stamped_TimeOut__c && tempValue[0].Stamped_TimeOut__c){
                        this.stampedIn = true;
                        this.stampedOut = true;
                        this.stTimeOut = tempValue[0].Stamped_TimeOut__c;
                        this.timeOut = this.timeConverter(this.stTimeOut, 'HH:MM');
                    }
                    if(tempValue[0].Remark__c){
                        this.remarks = tempValue[0].Remark__c;
                    }
                    //TSJP Raman Modification End
                }
                this.loaded = true;
            }).catch(err => {
                console.log(err);
                this.loaded = true;
            });
    }

    //TSJP Raman Modification Start
    setTimeStampIn(event) {
        var tempIN_Flo = this.tempDate.replace(/:/g, '.');
        var tempIN_Int = tempIN_Flo * ONE_HOUR;
        this.loaded = false;
        this.dispRemarkFlg = tempIN_Int > this.timeIn_Int;

        if(tempIN_Int <= this.timeOut_Int) {
            if(this.dispRemarkFlg) {
            this.isShowModal = true;
            this.loaded = true;
            this.modalHeader = 'Edit ' + this.modalName;
            this.remarkType = 'Late Check-In Reason';
            } else {
                this.remarkType = 'in';
                this.toastMsg = 'Check-In successful!';
                this.setTimeStampRecord();
            }
        } else {
            const message = 'Error occur when trying to Check-In, Please enter the time manually!';
            this.showToast(message, 'ERROR');
            this.loaded = true;
        }
    }

    setTimeStampOut(event) {
        this.descriptionValue = null;
        var tempOUT_Flo = this.tempDate.replace(/:/g, '.');
        var tempOUT_Int = tempOUT_Flo * ONE_HOUR;
        this.loaded = false;

        //Check if StampedIn or Not
        if(this.stampedIn) {
            if (this.stTimeIn != undefined && tempOUT_Int != undefined && this.timeOut_Int >= this.stTimeIn) {
                var moringWorkTime = 0;
                var afternoonWorkTime = 0;
                
                // First Half Calculation
                var lastOut = tempOUT_Int < this.breakTimeIn_Int ? tempOUT_Int : this.breakTimeIn_Int;
                moringWorkTime = this.stTimeIn > lastOut ? 0 : this.stTimeIn > this.timeIn_Int ? lastOut - this.stTimeIn : lastOut - this.timeIn_Int;

                // Second Half Calculation
                var lastIn = this.stTimeIn > this.breakTimeOut_Int ? this.stTimeIn : this.breakTimeOut_Int;
                afternoonWorkTime = tempOUT_Int < lastIn ? 0 : tempOUT_Int < this.timeOut_Int ? tempOUT_Int - lastIn : this.timeOut_Int - lastIn;

                this.totalWorkedHours_int = moringWorkTime + afternoonWorkTime;
                //2025/10/03 Updated by Raman Start
                this.overTime_int = tempOUT_Int - this.timeOut_Int;

                //Open Popup when WorkHour Under 7.5hrs
                if (this.totalWorkedHours_int < this.regularTime_Int) {
                    this.dispRemarkFlg = true;
                    this.isShowModal = true;
                    this.loaded = true;
                    this.modalHeader = 'Edit ' + this.modalName;
                    this.remarkType = 'WorkHour under 7.5 Hours Reason';
                } 
                //Open Popup when Overtime Exceeds 1 hr
                else if (this.totalWorkedHours_int >= this.regularTime_Int && this.overTime_int > ONE_HOUR) {
                    this.dispRemarkFlg = true;
                    this.isShowModal = true;
                    this.loaded = true;
                    this.modalHeader = 'Edit ' + this.modalName;
                    this.remarkType = 'Over Time Reason';
                } else {
                    this.remarkType = 'out';
                    this.toastMsg = 'Check-Out successful!';
                    this.setTimeStampRecord();
                }
                //2025/10/03 Updated by Raman End
            } else {
                const message = 'Error occur when trying to Check-Out, Please enter the time manually!';
                this.showToast(message, 'ERROR');
                this.loaded = true;
            }
        //202051002 Added by Raman Start
        } else {
            const message = 'Please Check-In before Check-Out!';
            this.showToast(message, 'ERROR');
            this.loaded = true;
        }
        //202051002 Added by Raman End
    }

    //Modal Windown Save button Click function
    onSave() {
        //2025/10/03 Updated by Raman Start
        if (this.dispRemarkFlg && (this.descriptionValue != undefined || this.descriptionValue != null)) {
            if (this.remarkType == 'Late Check-In Reason') {
                this.toastMsg = 'Check-In & REMARKS Update successful!';
            } else if (this.remarkType == 'WorkHour under 7.5 Hours Reason' || this.remarkType == 'Over Time Reason') {
                this.toastMsg = 'Check-Out & REMARKS Update successful!';
            }
            this.setTimeStampRecord();
        } else {
            const message = 'Please Enter ' + this.remarkType + ' in Remarks !';
            this.showToast(message, 'ERROR');
            this.loaded = true;
        }
        //2025/10/03 Updated by Raman End
    }

    //Common Fuction after Checkin・Checkout button pressed. 
    //To call controller method for Inserting・Updating data into TimeStamp__c object
    setTimeStampRecord() {
        setTimeStamp({ userId: this.userId, type: this.remarkType, latitude: this.latitude, longitude: this.longitude, remarks: this.descriptionValue})
        .then(response => {
            //20251006 TSJP Raman Start Process To Avoid Double Checkin/out 
            if(response == 'SUCCESS'){
                const message = this.toastMsg;
                this.showToast(message, 'SUCCESS');
            } else if(response == 'DOUBLE_CHECKIN') {
                const message = 'Already Checked IN. Skipped the Double CheckIN Attempt';
                this.showToast(message, 'ERROR');
            } else if(response == 'DOUBLE_CHECKOUT') {
                const message = 'Already Checked OUT. Skipped the Double CheckOUT Attempt';
                this.showToast(message, 'ERROR');
            } else {
                const message = 'Error occur when trying to Check-In/Check-Out!';
                this.showToast(message, 'ERROR');
            }
            //20251006 TSJP Raman End Process To Avoid Double Checkin/out 
            const stampEvent = new CustomEvent('stamped', {
                detail: null
            });
            this.dispatchEvent(stampEvent);
            this.checkTimeStampRecord();
            this.isShowModal = false;
        })
        .catch(err => {
            const message = 'Error occur when trying to Check-In/Check-Out!';
            this.showToast(message, 'ERROR');
            this.loaded = true;
        });
    }

    //Close Modal window
    hideModalBox() {  
        this.descriptionValue = ''; 
        this.isShowModal = false;
    }

    //Common Toast Message
    showToast(message, title) {
        const event = new ShowToastEvent({
            title: title,
            message: message,
            variant: title.toLowerCase(),
            mode: 'dismissable'
        });
        this.dispatchEvent(event);
    }

    //Popup Window Remark Field Onchange event
    handleDescriptionChange(event) {
        this.descriptionValue = event.target.value;
    }

    //To Convert Time Format
    timeConverter(timeNumber, format) {
		if (format == 'HH:MM') return new Date(timeNumber).toISOString().slice(11, 16);
		else if (format == 'HH:MM:SS.sss') return new Date(timeNumber).toISOString().slice(11, 23);
		else if (format == 'HHHH:MM') return parseInt(timeNumber / ONE_HOUR, 10) + ':' + new Date(timeNumber).toISOString().slice(14, 16);
		else return new Date(timeNumber).toISOString();
	}
    //TSJP Raman Modification End
}