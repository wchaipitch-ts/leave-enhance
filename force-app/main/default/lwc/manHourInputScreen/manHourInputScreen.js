import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import Id from '@salesforce/user/Id';
import getUserAvatar from '@salesforce/apex/ManHoursInputController.getUserAvatar';
import MaxHourPerDay from '@salesforce/label/c.MaxHourPerDay';

import getProjectList from '@salesforce/apex/ManHoursInputController.getProjectList';
import addManhour from '@salesforce/apex/ManHoursInputController.addManhour';
import deleteManhour from '@salesforce/apex/ManHoursInputController.deleteManhour';
import editManhour from '@salesforce/apex/ManHoursInputController.editManhour';
import getManhourList from '@salesforce/apex/ManHoursInputController.getManhourList';
import canEditManhour from '@salesforce/customPermission/Edit_Manhour';

const columns = [
    { label: 'Performed Date', fieldName: 'Performed_Date__c', type: 'date', editable: false },
    { label: 'Work', fieldName: 'Work__c', type: 'text', editable: true },
    { label: 'Remark', fieldName: 'Remark__c', type: 'text', editable: true },
    { label: 'Performed Hours', fieldName: 'Performed_Hours__c', type: 'number', editable: true, typeAttributes: { step: '0.5', minimumFractionDigits: '0', maximumFractionDigits: '1' } },
];

export default class ManHourInputScreen extends LightningElement {

    // Default Screen Factor
    @track loaded = true;
    @track isNoData = true;

    // Default User Variable
    @track userId = Id;
    @track userPath = "/" + Id;
    @track userName = null;
    @track userTitle = null;
    @track userDepartment = null;
    @track userManagerName = null;
    @track userManagerPath = null;
    @track userAvatar = null;

    // Default Date Variable
    @track todayDate = new Date();
    @track firstOfMonth = new Date(this.todayDate.getFullYear(), this.todayDate.getMonth(), 1);
    @track lastOfMonth = new Date(this.todayDate.getFullYear(), this.todayDate.getMonth() + 1, 0);

    // Default Month Selector
    @track monthSelected = '';
    @track monthLabel = '';
    @track monthOptions = [];
    @track monthCalendarLabel = '';

    // Default Year Selector
    @track yearSelected = '';
    @track yearOptions = [];
    @track yearCalendarLabel = '';

    // Default Max Hour Per Day (7.5)
    @track maxHourPerDay = parseFloat(MaxHourPerDay);

    // Degault Display Data
    @track dateList = [];
    @track projectList = [];
    @track summaryList = [];
    @track totalHours = 0;

    @track isEditManhour = canEditManhour ? true : false;
    connectedCallback() {
        console.log("connectedCallback Loaded");
        this.loaded = true;
        
        this.setUserAvatar();
        this.setDateSelector();
        this.setDateList();
        this.setProjectData();
    }


    setUserAvatar() {
        getUserAvatar({ Id: this.userId }).then(res => {
            this.userAvatar = res.MediumPhotoUrl;
            this.userName = res.Name && res.Name !== "" ? res.Name : "-undefined-";
            this.userTitle = res.Title && res.Title !== "" ? res.Title : "-undefined-";
            this.userDepartment = res.Department && res.Department !== "" ? res.Department : "-undefined-";
            this.userManagerPath = res.Manager.Id && res.Manager.Id !== "" ? "/" + res.Manager.Id : "-undefined-";
            this.userManagerName = res.Manager.Name && res.Manager.Name !== "" ? res.Manager.Name : "-undefined-";
        }).catch(err => {
            console.log(err);
        });
    }

    setProjectData() {
        console.log('Start setProjectData');
        
        this.loaded = false;
        getProjectList({ userId: this.userId, year: this.yearSelected, month: this.monthSelected }).then(value => {
            this.isNoData = value.length == 0;
            this.totalHours = 0;
            var tmpSummaryList = JSON.parse(JSON.stringify(this.dateList));
            var tmpProjectList = [...value];

            tmpProjectList.map((projectItem, index) => {
                projectItem['path'] = '/' + projectItem.Id;
                projectItem['Project_No__r']['path'] = '/' + projectItem['Project_No__r'].Id;
                projectItem['actual'] = projectItem['Actual_Hours__c'];
                projectItem['planning'] = projectItem['Planning_Hours__c'];
                projectItem['apCSS'] = projectItem['Actual_Hours__c'] > projectItem['Planning_Hours__c'] ? 'actual-over' : '';
                projectItem['trCSS'] = index == value.length - 1 ? 'link-data-1-last' : 'link-data-1';
                projectItem['manHourDate'] = JSON.parse(JSON.stringify(this.dateList));
                projectItem['manHourDate'] = projectItem['manHourDate'].map(manHourItem => {
                    manHourItem['isoutofscope'] = new Date(manHourItem['date']) < new Date(projectItem['Start_Date__c']) || new Date(manHourItem['date']) > new Date(projectItem['Due_Date__c']);
                    manHourItem['cellCssClass'] = manHourItem['isoutofscope'] ? 'gray-cell' : manHourItem['cellCssClass'];
                    manHourItem['cellCssClass'] = manHourItem['istoday'] ? manHourItem['cellCssClass'] + ' today-border' : manHourItem['cellCssClass'];
                    manHourItem['addButtonId'] = projectItem.Id + '&&' + manHourItem.date;
                    if (projectItem['Man_hours__r']) {
                        manHourItem['Man_hours__r'] = [...projectItem['Man_hours__r'].filter(mhr => mhr.Performed_Date__c === manHourItem.date)];
                        manHourItem['manHourExist'] = manHourItem['Man_hours__r'].length > 0;
                        manHourItem['totalHours'] = manHourItem['Man_hours__r'].reduce((a, b) => a + b.Performed_Hours__c, 0);
                        this.totalHours += manHourItem['totalHours'];

                        //Sum of totalHours in each day
                        var manIndex = tmpSummaryList.findIndex(x => x.date === manHourItem.date);
                        if (manIndex != -1) {
                            if (tmpSummaryList[manIndex].hasOwnProperty('total')) tmpSummaryList[manIndex]['total'] += manHourItem['totalHours'];
                            else tmpSummaryList[manIndex]['total'] = manHourItem['totalHours'];
                        }
                        if (tmpSummaryList[manIndex]['total'] == undefined) tmpSummaryList[manIndex]['total'] = 0;
                    }
                    return {...manHourItem };
                });
                return projectItem;
            });

            // Set CSS class for Summary Row of Datatable
            tmpSummaryList.map(item => {
                if (item['total'] < this.maxHourPerDay) {
                    item['summaryCssClass'] = 'summary-less-cell';
                } else if (item['total'] == this.maxHourPerDay) {
                    item['summaryCssClass'] = 'summary-equal-cell';
                } else if (item['total'] > this.maxHourPerDay) {
                    item['summaryCssClass'] = 'summary-more-cell';
                } else {
                    item['summaryCssClass'] = 'summary-future-cell';
                }
                if (item['isfuture']) item['summaryCssClass'] = 'summary-future-cell';
                return item;
            });

            this.summaryList = tmpSummaryList;
            this.projectList = tmpProjectList;
            this.loaded = true;
        })
    }

    setDateList() {
        console.log('Start setDateList');

        this.dateList = [];
        var firstOfMonth = new Date(this.firstOfMonth.getFullYear(), this.firstOfMonth.getMonth(), this.firstOfMonth.getDate());
        var lastOfMonth = new Date(this.lastOfMonth.getFullYear(), this.lastOfMonth.getMonth(), this.lastOfMonth.getDate());

        for (var d = firstOfMonth; d <= lastOfMonth; d.setDate(d.getDate() + 1)) {
            let ye = new Intl.DateTimeFormat('en', { year: 'numeric' }).format(d);
            let mo = new Intl.DateTimeFormat('en', { month: '2-digit' }).format(d);
            let da = new Intl.DateTimeFormat('en', { day: '2-digit' }).format(d);
            let wd = new Intl.DateTimeFormat('en', { weekday: 'short' }).format(d);

            let tye = new Intl.DateTimeFormat('en', { year: 'numeric' }).format(this.todayDate);
            let tmo = new Intl.DateTimeFormat('en', { month: '2-digit' }).format(this.todayDate);
            let tda = new Intl.DateTimeFormat('en', { day: '2-digit' }).format(this.todayDate);

            this.dateList.push({
                'date': `${ye}-${mo}-${da}`,
                'year': ye,
                'month': mo,
                'day': da,
                'weekday': wd,
                'isfuture': d > new Date(this.todayDate.getFullYear(), this.todayDate.getMonth(), this.todayDate.getDate()) || wd == 'Sat' || wd == 'Sun',
                'istoday' : `${ye}-${mo}-${da}` == `${tye}-${tmo}-${tda}`,
                'isoutofscope': undefined,
                'issat': wd == 'Sat',
                'issun': wd == 'Sun',
                'isweekday': wd == 'Sat' ? false : (wd == 'Sun' ? false : true),
                'cellCssClass': (wd == 'Sat' ? 'sat-cell' : (wd == 'Sun' ? 'sun-cell' : 'normal-cell')) +
                    (`${ye}-${mo}-${da}` == `${tye}-${tmo}-${tda}` ? ' today-border' : ''),
                'footerCssClass': (wd == 'Sat' ? 'sat-cell' : (wd == 'Sun' ? 'sun-cell' : 'normal-cell')) +
                    (`${ye}-${mo}-${da}` == `${tye}-${tmo}-${tda}` ? ' today-border-footer' : ''),
                'headerCssClass': (`${ye}-${mo}-${da}` == `${tye}-${tmo}-${tda}` ? ' today-border-header ' : ''),
                'footerDivCssClass': 'summary-box slds-box slds-box_body slds-p-around_medium slds-text-align_center' +
                    (`${ye}-${mo}-${da}` == `${tye}-${tmo}-${tda}` ? ' today-border-footer-div' : '')
            });
        }
    }

    previousMonth() {
        console.log('----- previousMonth -----');

        var index = this.monthOptions.findIndex(month => month.value == this.monthSelected);
        if (this.monthSelected == '01') {
            this.monthSelected = this.monthOptions[11].value
            this.monthLabel = this.monthOptions[11].label;
            this.monthCalendarLabel = this.monthLabel.substring(4);
            this.yearSelected = (parseInt(this.yearSelected) - 1).toString();
            this.yearCalendarLabel = 'FY' + this.yearSelected.substring(2);
            var indexY = this.yearOptions.findIndex(month => month.value == this.yearSelected);
            if (indexY < 0) this.yearOptions.splice(0, 0, { label: this.yearSelected, value: this.yearSelected })
        } else if (index > -1) {
            this.monthSelected = this.monthOptions[index - 1].value
            this.monthLabel = this.monthOptions[index - 1].label;
            this.monthCalendarLabel = this.monthLabel.substring(4);
        }
        this.firstOfMonth = new Date(parseInt(this.yearSelected), parseInt(this.monthSelected) - 1, 1);
        this.lastOfMonth = new Date(parseInt(this.yearSelected), parseInt(this.monthSelected), 0);
        this.setDateList();
        this.setProjectData();
    }

    nextMonth() {
        console.log('----- nextMonth -----');

        var index = this.monthOptions.findIndex(month => month.value == this.monthSelected);
        if (this.monthSelected == '12') {
            this.monthSelected = this.monthOptions[0].value
            this.monthLabel = this.monthOptions[0].label;
            this.monthCalendarLabel = this.monthLabel.substring(4);
            this.yearSelected = (parseInt(this.yearSelected) + 1).toString();
            this.yearCalendarLabel = 'FY' + this.yearSelected.substring(2);
            var indexY = this.yearOptions.findIndex(month => month.value == this.yearSelected);
            if (indexY < 0) this.yearOptions.push({ label: this.yearSelected, value: this.yearSelected })
        } else if (index > -1) {
            this.monthSelected = this.monthOptions[index + 1].value
            this.monthLabel = this.monthOptions[index + 1].label;
            this.monthCalendarLabel = this.monthLabel.substring(4);
        }
        this.firstOfMonth = new Date(parseInt(this.yearSelected), parseInt(this.monthSelected) - 1, 1);
        this.lastOfMonth = new Date(parseInt(this.yearSelected), parseInt(this.monthSelected), 0);
        this.setDateList();
        this.setProjectData();
    }

    yearChange(event) {
        console.log('----- yearChange -----');
        this.yearSelected = event.detail.value;
        this.yearCalendarLabel = 'FY' + this.yearSelected.substring(2);

        this.firstOfMonth = new Date(parseInt(this.yearSelected), parseInt(this.monthSelected) - 1, 1);
        this.lastOfMonth = new Date(parseInt(this.yearSelected), parseInt(this.monthSelected), 0);

        this.setDateList();
        this.setProjectData();
    }

    setDateSelector() {
        console.log('Start setDateSelector');

        this.monthOptions = [
            { label: '01. January', value: '01' },
            { label: '02. Febuary', value: '02' },
            { label: '03. March', value: '03' },
            { label: '04. April', value: '04' },
            { label: '05. May', value: '05' },
            { label: '06. June', value: '06' },
            { label: '07. July', value: '07' },
            { label: '08. August', value: '08' },
            { label: '09. September', value: '09' },
            { label: '10. October', value: '10' },
            { label: '11. November', value: '11' },
            { label: '12. December', value: '12' }
        ];
        this.monthSelected = new Intl.DateTimeFormat('en', { month: '2-digit' }).format(this.todayDate);
        var index = this.monthOptions.findIndex(month => month.value == this.monthSelected);
        if (index > -1) {
            this.monthLabel = this.monthOptions[index].label;
            this.monthCalendarLabel = this.monthLabel.substring(4);
        }

        for (var y = -7; y <= 0; y++) {
            var tempYear = y + parseInt(new Intl.DateTimeFormat('en', { year: 'numeric' }).format(this.todayDate));
            this.yearOptions.push({ label: tempYear.toString(), value: tempYear.toString() })
        }
        this.yearSelected = new Intl.DateTimeFormat('en', { year: 'numeric' }).format(this.todayDate);
        this.yearCalendarLabel = 'FY' + this.yearSelected.substring(2);
    }

    onClickAddButton(event) {
        console.log('Start onClickAddButton');

        var tempId = event.currentTarget.name.split('&&');
        var projectAssignId = tempId[0];
        var perFormedDate = tempId[1];
        addManhour({ projectAssignId: projectAssignId, performedDate: perFormedDate }).then(res => {
            this.setProjectData();
            const event = new ShowToastEvent({
                title: 'SUCCESS',
                message: 'Create Man-hour record successful!',
                variant: 'success', //info/success/warning/error
                mode: 'dismissable'
            });
            this.dispatchEvent(event);
            this.onOpenModal({ currentTarget: { id: projectAssignId + '&&' + perFormedDate } });
        }).catch(err => {
            console.log(err);
            const event = new ShowToastEvent({
                title: 'SUCCESS',
                message: 'Error occur when trying to create Man-hour record!',
                variant: 'error', //info/success/warning/error
                mode: 'dismissable'
            });
            this.dispatchEvent(event);
        });
    }

    onRefresh() {
        console.log('Start onRefresh');
        this.setProjectData();
    }

    onToday() {
        console.log('Start onToday');
        this.firstOfMonth = new Date(this.todayDate.getFullYear(), this.todayDate.getMonth(), 1);
        this.lastOfMonth = new Date(this.todayDate.getFullYear(), this.todayDate.getMonth() + 1, 0);
        this.setDateSelector();
        this.setDateList();
        this.setProjectData();
    }


    // Variable for Modal
    @track projectSelected = '';
    @track projectSelectedShow = '';
    @track dateSelected = '';
    @track dateSelectedShow = '';
    @track projectAssignIdSelected = '';
    @track selectedRows = [];
    @track isNoSelected = true;

    @track manHourData = [];
    @track isNoManHourData = true;
    @track draftValues = [];
    @track manHourDataSize = 0;
    @track manHourTotalHours = 0;

    @track isShowModal = false;
    @track isEdited = false;

    @track columns = columns;
    @track rowOffset = 0;

    showModalBox() {
        this.isShowModal = true;
    }

    hideModalBox() {
        this.isShowModal = false;

        this.projectSelected = ''
        this.projectSelectedShow = ''
        this.dateSelected = '';
        this.dateSelectedShow = '';
        this.projectAssignIdSelected = '';
        this.selectedRows = [];
        this.isNoSelected = true;
        this.manHourData = [];
        this.isNoManHourData = true;
        this.draftValues = [];
        this.manHourDataSize = 0;

        if (this.isEdited) this.setProjectData();
        this.isEdited = false;
    }

    handleSave(event) {
        console.log('manHourData');
        if(!this.lockDeletebtn){
        var editRecords = event.detail.draftValues;
                editRecords.map(record => {
                    record.Performed_Hours__c = (record.Performed_Hours__c !== '' ? record.Performed_Hours__c : 0);
                    if (record.Performed_Hours__c) {

                    }
                    return record;
                });
                editManhour({ editRecords: editRecords }).then(res => {
                    this.manHourData = res;
                    this.manHourDataSize = this.manHourData.length;
                    this.isNoManHourData = this.manHourData.length == 0;
                    const event = new ShowToastEvent({
                        title: 'SUCCESS',
                        message: 'Update Man-hour records successful!',
                        variant: 'success', //info/success/warning/error
                        mode: 'dismissable'
                    });
                    this.dispatchEvent(event);
                    this.sumManHour();
                    this.draftValues = [];
                    this.hideModalBox();
                }).catch(err => {
                    console.log(err);
                    const marker = 'FIELD_CUSTOM_VALIDATION_EXCEPTION, ';
                    let err_msg = '';
                    let idx = err?.body?.message?.indexOf(marker);
                    if (idx !== -1) {
                        // Extract substring after marker
                        err_msg = err?.body?.message?.substring(idx + marker.length).trim();

                        // Remove any trailing colon
                        if (err.body.message.endsWith(':')) {
                            err_msg = err?.body?.message?.slice(0, -1);
                        }
                    }

                    const event = new ShowToastEvent({
                        title: 'SUCCESS',
                        message: 'Error occur when trying to update Man-hour record! : ' + err_msg,
                        variant: 'error', //info/success/warning/error
                        mode: 'dismissable'
                    });
                    this.dispatchEvent(event);
                    this.sumManHour();
                });
        }else{
            const event = new ShowToastEvent({
                title: 'Error',
                message: 'You cannot edit this record because it is overdue.',
                variant: 'error', //info/success/warning/error
                mode: 'dismissable'
            });
            this.dispatchEvent(event);
        }
        
    }

    handleCancel() {
        console.log('handleCancel');
        this.sumManHour('cancel');
    }

    handleSelected() {
        console.log('handleSelected');

        this.selectedRows = [...this.template.querySelector('lightning-datatable').getSelectedRows()];
        this.isNoSelected = this.selectedRows.length == 0 || this.lockDeletebtn;
    }

    //handler to handle cell changes & update values in draft values
    handleCellChange(event) {
        console.log('handleCellChange');

        this.sumManHour();
    }

    onSelectedDelete() {
        console.log('onSelectedDelete');

        deleteManhour({ deleteRecords: this.selectedRows }).then(res => {
            this.manHourData = res;
            this.manHourDataSize = this.manHourData.length;
            this.isNoManHourData = this.manHourData.length == 0;
            this.selectedRows = [];
            this.isNoSelected = this.selectedRows.length == 0 || this.lockDeletebtn;
            this.manHourTotalHours = this.manHourData.reduce((a, b) => a + b.Performed_Hours__c, 0);
            this.isEdited = true;
            const event = new ShowToastEvent({
                title: 'SUCCESS',
                message: 'Delete Man-hour records successful!',
                variant: 'success', //info/success/warning/error
                mode: 'dismissable'
            });
            this.dispatchEvent(event);
            this.sumManHour();
        }).catch(err => {
            console.log(err);
            const marker = 'FIELD_CUSTOM_VALIDATION_EXCEPTION, ';
            let err_msg = '';
            let idx = err?.body?.message?.indexOf(marker);
            if (idx !== -1) {
                // Extract substring after marker
                err_msg = err?.body?.message?.substring(idx + marker.length).trim();

                // Remove any trailing colon
                if (err.body.message.endsWith(':')) {
                    err_msg = err?.body?.message?.slice(0, -1);
                }
            }

            const event = new ShowToastEvent({
                title: 'SUCCESS',
                message: 'Error occur when trying to delete Man-hour record! : ' + err_msg,
                variant: 'error', //info/success/warning/error
                mode: 'dismissable'
            });
        });
    }

    @track lockDeletebtn = false;
    onOpenModal(event) {
        console.log('Start onOpenModal');

        this.loaded = false;

        var tempId = event.currentTarget.id.substring(0, 30).split('&&');
        var projectAssignId = tempId[0];
        var perFormedDate = tempId[1];
        // console.log('perFormedDate :::: ',perFormedDate);
        // console.log('(new Date(perFormedDate) : ',(new Date(perFormedDate)));
        // console.log('(new Date : ',(new Date(new Date().getFullYear(), new Date().getMonth(), 3)));
        // console.log('(new Date + 1 : ',new Date(new Date().getFullYear(), new Date().getMonth(), 1));
        // console.log('true ;::: ',( new Date(perFormedDate) ==  new Date(new Date().getFullYear(), new Date().getMonth(), 1) ));
        
       if(canEditManhour){ //bypass
            this.lockDeletebtn = false;
        }else{
            // this.lockDeletebtn = (new Date(perFormedDate) < new Date(new Date().getFullYear(), new Date().getMonth(), 3));
            // if( ( new Date(perFormedDate).toDateString() ==  new Date(new Date().getFullYear(), new Date().getMonth(), 1).toDateString()||  new Date(perFormedDate).toDateString() ==  new Date(new Date().getFullYear(), new Date().getMonth(), 2).toDateString())){
            //     this.lockDeletebtn = false
            // }
            const performed = new Date(perFormedDate); // วันที่ของข้อมูล
            const today = new Date();

            const isSameMonth = performed.getMonth() === today.getMonth() &&
                                performed.getFullYear() === today.getFullYear();

            const isPreviousMonth = (
            performed.getMonth() === today.getMonth() - 1 ||
            (today.getMonth() === 0 && performed.getMonth() === 11 && performed.getFullYear() === today.getFullYear() - 1) // Dec to Jan case
            );

            const isAfter2nd = today.getDate() > 2;

            if (isSameMonth) {
                this.lockDeletebtn = false; // เดือนเดียวกัน แก้ได้
            } else if (isPreviousMonth && isAfter2nd) {
                this.lockDeletebtn = true; // เดือนก่อน + วันนี้ > 2 → ห้ามแก้
            } else {
                this.lockDeletebtn = false; // เดือนก่อน + วันนี้ <= 2 → แก้ได้
            }
        }
        console.log('===> this.lockDeletebtn : ',this.lockDeletebtn);
        
        this.projectAssignIdSelected = projectAssignId;
        this.dateSelected = perFormedDate;
        this.dateSelectedShow = perFormedDate.replaceAll('-', '/');

        this.showModalBox();
        getManhourList({ projectAssignId: projectAssignId, dateSelected: perFormedDate }).then(res => {
            var projectAssign = res;
            this.manHourData = projectAssign.Man_hours__r ? projectAssign.Man_hours__r : [];
            this.manHourDataSize = this.manHourData.length;
            this.isNoManHourData = this.manHourData.length == 0;
            this.projectSelected = projectAssign.Project_No__r.Project_Name__c;
            this.projectSelectedShow = this.projectSelected.length <= 33 ? this.projectSelected : this.projectSelected.substring(0, 30) + '...';
            this.isNoSelected = this.selectedRows.length == 0 || this.lockDeletebtn;
            this.manHourTotalHours = this.manHourData.reduce((a, b) => a + b.Performed_Hours__c, 0);
            this.isEdited = true;
            this.loaded = true;
        }).catch(err => {
            console.log(err);
            const event = new ShowToastEvent({
                title: 'SUCCESS',
                message: 'Error occur when trying to get Man-hour record!',
                variant: 'error', //info/success/warning/error
                mode: 'dismissable'
            });
            this.dispatchEvent(event);
            this.loaded = true;
        });
    }

    onClickManHourAddButton() {
        console.log('Start onClickManHourAddButton');

        addManhour({ projectAssignId: this.projectAssignIdSelected, performedDate: this.dateSelected }).then(res => {
            this.manHourData = res ? res : [];;
            this.manHourDataSize = this.manHourData.length;
            this.isNoManHourData = this.manHourData.length == 0;
            this.isNoSelected = this.selectedRows.length == 0;
            this.manHourTotalHours = this.manHourData.reduce((a, b) => a + b.Performed_Hours__c, 0);
            this.isEdited = true;
            const event = new ShowToastEvent({
                title: 'SUCCESS',
                message: 'Create Man-hour record successful!',
                variant: 'success', //info/success/warning/error
                mode: 'dismissable'
            });
            this.dispatchEvent(event);
            this.sumManHour();
        }).catch(err => {
            console.log(err);
            const marker = 'FIELD_CUSTOM_VALIDATION_EXCEPTION, ';
            let err_msg = '';
            let idx = err?.body?.message?.indexOf(marker);
            if (idx !== -1) {
                // Extract substring after marker
                err_msg = err?.body?.message?.substring(idx + marker.length).trim();

                // Remove any trailing colon
                if (err.body.message.endsWith(':')) {
                    err_msg = err?.body?.message?.slice(0, -1);
                }
            }

            const event = new ShowToastEvent({
                title: 'SUCCESS',
                message: 'Error occur when trying to create Man-hour record! : ' + err_msg,
                variant: 'error', //info/success/warning/error
                mode: 'dismissable'
            });
            this.dispatchEvent(event);
            this.sumManHour();
        });
    }

    sumManHour(event) {
        console.log('sumManHour');

        var draftValues = this.template.querySelector('lightning-datatable') ? this.template.querySelector('lightning-datatable').draftValues : [];
        this.manHourTotalHours = this.manHourData.reduce((a, b) => {
            var total = a;
            var index = draftValues.findIndex(item => item.Id === b.Id);
            if (index > -1 && event != 'cancel') {
                if (draftValues[index].hasOwnProperty('Performed_Hours__c')) {
                    total += draftValues[index].Performed_Hours__c ? parseFloat(draftValues[index].Performed_Hours__c) : 0;
                } else {
                    total += parseFloat(b.Performed_Hours__c);
                }
            } else {
                total += parseFloat(b.Performed_Hours__c);
            }
            return total;
        }, 0);
    }
}