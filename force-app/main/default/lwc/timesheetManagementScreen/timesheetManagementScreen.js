import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';

import Id from '@salesforce/user/Id';
import checkPermissionUser from '@salesforce/apex/TimesheetController.checkPermissionUser';
import getActiveUser from '@salesforce/apex/TimesheetController.getActiveUser';
import getUserInfo from '@salesforce/apex/TimesheetController.getUserInfo';
import getHolidays from '@salesforce/apex/TimesheetController.getHolidays';
import getLeaveRequestes from '@salesforce/apex/TimesheetController.getLeaveRequestes';
import getTimeStamps from '@salesforce/apex/TimesheetController.getTimeStamps';
import createTimeStamps from '@salesforce/apex/TimesheetController.createTimeStamps';
import updateTimeStamps from '@salesforce/apex/TimesheetController.updateTimeStamps';
import MaxHourPerDay from '@salesforce/label/c.MaxHourPerDay';

import TimeIn from '@salesforce/label/c.TimeIn';
import TimeOut from '@salesforce/label/c.TimeOut';
import TimeBreakIn from '@salesforce/label/c.TimeBreakIn';
import TimeBreakOut from '@salesforce/label/c.TimeBreakOut';
import TimeLeaveFirstHalf from '@salesforce/label/c.TimeLeaveFirstHalf';
import TimeLeaveSecondHalf from '@salesforce/label/c.TimeLeaveSecondHalf';

const ONE_HOUR = 3600000;
const ONE_MINUTE = 60000;

export default class timesheetManagementScreen extends NavigationMixin(LightningElement) {
	// Default Screen Factor
	@track isShowLog = true;
	@track isLoading = false;
	@track isNoData = true;

	// Current User Variable
	@track currentUserId = Id;
	@track isNotCurrentUser = false;
	@track isPermissionUser = false;
	@track userList = [];
	@track userOptions = [];

	// Default User Variable
	@track userId = Id;
	@track userPath = '/' + Id;
	@track userName = null;
	@track employeeNumber = null;
	@track userTitle = null;
	@track userDepartment = null;
	@track userManagerName = null;
	@track userManagerPath = null;
	@track userAvatar = null;
	@track Start_Date__c = null;
	@track Next_Action_Date__c = null;
	@track userAnnualDate = null;

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

	// Leave Time Set
	@track leaveFirstHalf_Flo = parseFloat(TimeLeaveFirstHalf);
	@track leaveFirstHalf_Int = this.leaveFirstHalf_Flo * ONE_HOUR;
	@track leaveFirstHalf_Str = this.timeConverter(this.leaveFirstHalf_Int, 'HH:MM');

	@track leaveSecondHalf_Flo = parseFloat(TimeLeaveSecondHalf);
	@track leaveSecondHalf_Int = this.leaveSecondHalf_Flo * ONE_HOUR;
	@track leaveSecondHalf_Str = this.timeConverter(this.leaveSecondHalf_Int, 'HH:MM');

	// Break Time Set (In&Out)
	@track breakTimeIn_Flo = parseFloat(TimeBreakIn);
	@track breakTimeIn_Int = this.breakTimeIn_Flo * ONE_HOUR;
	@track breakTimeIn_Str = this.timeConverter(this.breakTimeIn_Int, 'HH:MM');

	@track breakTimeOut_Flo = parseFloat(TimeBreakOut);
	@track breakTimeOut_Int = this.breakTimeOut_Flo * ONE_HOUR;
	@track breakTimeOut_Str = this.timeConverter(this.breakTimeOut_Int, 'HH:MM');

	@track defaultLunchBreak = this.breakTimeIn_Str + ' ~ ' + this.breakTimeOut_Str;
	@track defaultTimeFormat = 'HH:MM';

	// Default Inform Variable
	@track standardWork = '0:00';
	@track workedHours = '0:00';
	@track overtimeHours = '0:00';
	@track leaveHours = '0:00';
	@track totalHours = '0:00';

	// Default Date Variable
	@track todayDate = new Date();
	@track firstOfMonth = new Date(this.todayDate.getFullYear(), this.todayDate.getMonth(), 1);
	@track lastOfMonth = new Date(this.todayDate.getFullYear(), this.todayDate.getMonth() + 1, 0);

	// Month Selector
	@track selectedMonth = null;
	@track selectedMonthLabel = null;
	@track monthOptions = [
		{ key: 'month_01', label: 'January', value: '01', class: 'month-item' },
		{ key: 'month_02', label: 'Febuary', value: '02', class: 'month-item' },
		{ key: 'month_03', label: 'March', value: '03', class: 'month-item' },
		{ key: 'month_04', label: 'April', value: '04', class: 'month-item' },
		{ key: 'month_05', label: 'May', value: '05', class: 'month-item' },
		{ key: 'month_06', label: 'June', value: '06', class: 'month-item' },
		{ key: 'month_07', label: 'July', value: '07', class: 'month-item' },
		{ key: 'month_08', label: 'August', value: '08', class: 'month-item' },
		{ key: 'month_09', label: 'September', value: '09', class: 'month-item' },
		{ key: 'month_10', label: 'October', value: '10', class: 'month-item' },
		{ key: 'month_11', label: 'November', value: '11', class: 'month-item' },
		{ key: 'month_12', label: 'December', value: '12', class: 'month-item' }
	];

	// Year Selector
	@track selectedYear = null;

	// Timesheet Data
	@track dateList = [];
	@track timesheetDataList = [];

	connectedCallback() {
		if (this.isShowLog) console.log('connectedCallback Loaded');

		this.setPermissionUser();
		this.setUserAvatar();
		this.setDefaultData();
	}

	showToast(message, title) {
		const event = new ShowToastEvent({
			title: title,
			message: message,
			variant: title.toLowerCase(),
			mode: 'dismissable'
		});
		this.dispatchEvent(event);
	}

	timeConverter(timeNumber, format) {
		if (format == 'HH:MM') return new Date(timeNumber).toISOString().slice(11, 16);
		else if (format == 'HH:MM:SS.sss') return new Date(timeNumber).toISOString().slice(11, 23);
		else if (format == 'HHHH:MM') return parseInt(timeNumber / ONE_HOUR, 10) + ':' + new Date(timeNumber).toISOString().slice(14, 16);
		else return new Date(timeNumber).toISOString();
	}

	setUserAvatar() {
		if (this.isShowLog) console.log('setUserAvatar Start!');

		getUserInfo({ Id: this.userId })
			.then((user) => {
				this.userAvatar = user.MediumPhotoUrl;
				this.userName = user.Name && user.Name !== '' ? user.Name : '-undefined-';
				this.employeeNumber = user.EmployeeNumber && user.EmployeeNumber !== '' ? user.EmployeeNumber : '-undefined-';
				this.userTitle = user.Title && user.Title !== '' ? user.Title : '-undefined-';
				this.userDepartment = user.Department !== '' ? user.Department : '-undefined-';
				if (user.Manager) {
					this.userManagerPath = user.Manager.Id;
					this.userManagerName = user.Manager.Name;
				} else {
					this.userManagerPath = '-undefined-';
					this.userManagerName = '-undefined-';
				}
				this.userStartDate = user.Start_Date__c && user.Start_Date__c !== '' ? user.Start_Date__c : '-undefined-';
				this.userAcctionDate = user.Next_Action_Date__c && user.Next_Action_Date__c !== '' ? user.Next_Action_Date__c : '-undefined-';
				this.userAnnualDate = user.Annual_Leave_Day__c !== null ? String(user.Annual_Leave_Day__c) : '-undefined-';
				console.log("user annual date" + this.userAnnualDate);
				console.log("user annual leave day custom record" + String(user.Annual_Leave_Day__c));
			})
			.catch((err) => {
				console.log(err);
			});
	}

	onBack() {
		if (this.isShowLog) console.log('onBack Start!');

		this.onUserChanged({ target: { value: this.currentUserId } });
	}

	onUserRefresh() {
		if (this.isShowLog) console.log('onUserRefresh Start!');
		this.setDateList();
	}

	async setPermissionUser() {
		if (this.isShowLog) console.log('setPermissionUser Start!');
		await checkPermissionUser()
			.then((isPermissionUser) => {
				this.isPermissionUser = isPermissionUser;
			})
			.catch((err) => {
				console.log(err);
			});

		if (this.isPermissionUser) {
			await getActiveUser()
				.then((userList) => {
					for (var i in userList) {
						var user = userList[i];
						if (user.Id == this.userId) {
							user.selected = true;
						} else {
							user.selected = false;
						}
					}
					this.userList = userList;
				})
				.catch((err) => {
					console.log(err);
				});
		}
	}

	onUserChanged(event) {
		if (this.isShowLog) console.log('onUserChanged Start!');

		const options = this.template.querySelectorAll('option');
		for (const option of options) {
			if (option.value == event.target.value) {
				option.selected = true;
			} else {
				option.selected = false;
			}
		}

		this.userId = event.target.value;
		this.userPath = '/' + event.target.value;
		this.isNotCurrentUser = this.userId == this.currentUserId;

		this.setUserAvatar();
		this.setDateList();
	}

	setDefaultData() {
		if (this.isShowLog) console.log('setDefaultYear Start!');

		this.selectedYear = parseInt(new Intl.DateTimeFormat('en', { year: 'numeric' }).format(this.todayDate), 10);
		this.setSelectedMonth({
			target: {
				dataset: {
					id: new Intl.DateTimeFormat('en', { month: '2-digit' }).format(this.todayDate)
				}
			}
		});
	}

	setDateList() {
		if (this.isShowLog) console.log('setDateList Start!');

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
				timestamp: {},
				leaveRequeste: {},
				shortdate: `${mo}/${da}`,
				date: `${ye}-${mo}-${da}`,
				year: ye,
				month: mo,
				day: da,
				weekday: wd,
				issat: wd == 'Sat',
				issun: wd == 'Sun',
				isweekday: wd !== 'Sat' || wd !== 'Sun',
				isweekend: wd == 'Sat' || wd == 'Sun',
				isholiday: false,
				isreachtarget: true,
				//data leave
				isleave: false,
				ispendingleave: false,
				isapprovedleave: false,
				//data row
				row_data: 'row-data row-data-nor',
				row_wk: 'row-WK',
				row_oh: 'row-OH',
				row_ti: 'row-TI',
				row_to: 'row-TO',
				row_wh: 'row-WH',
				row_ot: 'row-OT'
			});
		}

		this.dateList.map((date) => {
			if (date.issat) {
				date.row_data = 'row-data row-data-sat';
				date.row_oh = 'OH-sat row-OH';
				date.row_wk = 'WK-sat row-WK';
			} else if (date.issun) {
				date.row_data = 'row-data row-data-sun';
				date.row_oh = 'OH-sun row-OH';
				date.row_wk = 'WK-sun row-WK';
			}
			return date;
		});
		this.setTimestamp();
	}

	async setTimestamp() {
		if (this.isShowLog) console.log('setTimestamp Start!');

		this.isLoading = true;
		this.timesheetDataList = await this.setHoliday([...this.dateList]);
		this.timesheetDataList = await this.setLeaveRequestes([...this.timesheetDataList]);
		getTimeStamps({ userId: this.userId, year: this.selectedYear, month: this.selectedMonth })
			.then((timestamps) => {
				var tempTotalStandardHours = 0;
				var tempTotalWorkHours = 0;
				var tempTotalOvertimeHours = 0;
				var tempTotalLeaveHours = 0;

				this.timesheetDataList.map((timesheetData) => {
					if (this.isNotCurrentUser) {
						timesheetData.row_oh += '-not-owner';
					}

					// Set Startdard Hours
					if (!timesheetData.isholiday && timesheetData.isweekday) {
						tempTotalStandardHours += this.regularTime_Int;
					}
					// Set Total Leave Hours
					if (timesheetData.isapprovedleave) {
						if (timesheetData.leaveRequeste.Period_Leave__c == 'AM leave') {
							tempTotalLeaveHours += this.leaveFirstHalf_Int;
						} else if (timesheetData.leaveRequeste.Period_Leave__c == 'PM leave') {
							tempTotalLeaveHours += this.leaveSecondHalf_Int;
						} else {
							tempTotalLeaveHours += this.regularTime_Int;
						}
					}
					for (var i in timestamps) {
						var timestamp = timestamps[i];
						if (timesheetData.date === timestamp.Stamped_Date__c) {
							// Set Time In & Time Out
							var STI =
								timestamp.Stamped_TimeIn__c != undefined
									? timestamp.Stamped_TimeIn__c - (timestamp.Stamped_TimeIn__c % ONE_MINUTE)
									: undefined;
							var STO =
								timestamp.Stamped_TimeOut__c != undefined
									? timestamp.Stamped_TimeOut__c - (timestamp.Stamped_TimeOut__c % ONE_MINUTE)
									: undefined;

							timestamp.Stamped_TimeIn = STI != undefined ? this.timeConverter(STI, 'HH:MM') : undefined;
							timestamp.Stamped_TimeOut = STO != undefined ? this.timeConverter(STO, 'HH:MM') : undefined;

							// Set Warning Time In
							//timestamp.isWarningTimeIn = this.timeIn_Int < STI;
							// Set Warning Time Out
							//timestamp.isWarningTimeOut = this.timeOut_Int > STO;

							// Is Manual Edited
							//timesheetData.row_ti = timestamp.is_Manual_Edit_TimeIn__c ? 'row-TI row-TI-edited' : 'row-TI';
							//timesheetData.row_to = timestamp.is_Manual_Edit_TimeOut__c ? 'row-TO row-TO-edited' : 'row-TO';

							// Is Manual Edited and Late Checkin or Checkout Warning
							if(this.timeIn_Int < STI && timestamp.is_Manual_Edit_TimeIn__c) {
								timesheetData.row_ti = 'row-TI row-TI-edited row-TI-TO-warning';
							} else if(!this.timeIn_Int < STI && timestamp.is_Manual_Edit_TimeIn__c) {
								timesheetData.row_ti = 'row-TI row-TI-edited';
							} else if(this.timeIn_Int < STI && !timestamp.is_Manual_Edit_TimeIn__c) {
								timestamp.isWarningTimeIn = true;
								timesheetData.row_ti = 'row-TI row-TI-TO-warning';

								if((timestamp.Maunal_Input_Reason__c != null || timestamp.Maunal_Input_Reason__c != '') && timestamp.Maunal_Input_Reason__c != undefined){
									timestamp.isWarningTimeIn = false;
								}
							} else {
								timesheetData.row_ti = 'row-TI';
							}

							if(this.timeOut_Int > STO && timestamp.is_Manual_Edit_TimeOut__c) {
								timesheetData.row_to = 'row-TO row-TO-edited row-TI-TO-warning';
							} else if(!this.timeOut_Int > STO && timestamp.is_Manual_Edit_TimeOut__c) {
								timesheetData.row_to = 'row-TO row-TO-edited';
							} else if(this.timeOut_Int > STO && !timestamp.is_Manual_Edit_TimeOut__c) {
								timestamp.isWarningTimeOut = true;
								timesheetData.row_to = 'row-TO row-TI-TO-warning';

								if((timestamp.Maunal_Input_Reason__c != null || timestamp.Maunal_Input_Reason__c != '') && timestamp.Maunal_Input_Reason__c != undefined){
									timestamp.isWarningTimeOut = false;
								}
							} else {
								timesheetData.row_to = 'row-TO';
							}

							// Set Worked Hours
							if (STI != undefined && STO != undefined && this.timeOut_Int >= STI) {
								var moringWorkTime = 0;
								var afternoonWorkTime = 0;
								if (timesheetData.isapprovedleave) {
									// First Half Calculation
									if (timesheetData.leaveRequeste.Period_Leave__c == 'AM leave') {
										var lastIn = STI > this.breakTimeOut_Int ? STI : this.breakTimeOut_Int;
										afternoonWorkTime = STO < lastIn ? 0 : STO < this.timeOut_Int ? STO - lastIn : this.timeOut_Int - lastIn;
										// Second Half Calculation
									} else if (timesheetData.leaveRequeste.Period_Leave__c == 'PM leave') {
										var lastOut = STO < this.breakTimeIn_Int ? STO : this.breakTimeIn_Int;
										moringWorkTime = STI > lastOut ? 0 : STI > this.timeIn_Int ? lastOut - STI : lastOut - this.timeIn_Int;
									}
								} else {
									// First Half Calculation
									var lastOut = STO < this.breakTimeIn_Int ? STO : this.breakTimeIn_Int;
									moringWorkTime = STI > lastOut ? 0 : STI > this.timeIn_Int ? lastOut - STI : lastOut - this.timeIn_Int;

									// Second Half Calculation
									var lastIn = STI > this.breakTimeOut_Int ? STI : this.breakTimeOut_Int;
									afternoonWorkTime = STO < lastIn ? 0 : STO < this.timeOut_Int ? STO - lastIn : STO - lastIn;
									//afternoonWorkTime = STO < lastIn ? 0 : STO < this.timeOut_Int ? STO - lastIn : this.timeOut_Int - lastIn;
								}

								timestamp.workedHours_Int = moringWorkTime + afternoonWorkTime;
								timestamp.workedHours_Str = this.timeConverter(timestamp.workedHours_Int, 'HH:MM');

								//TSTHHQ 追加　開始
								if(timestamp.workedHours_Int < this.regularTime_Int) {
									if (this.isShowLog) console.log('WorkedHourBelow7.5 Start!');

									timestamp.isWarningWorkedHours = true;

									if((timestamp.WorkHour_Reason__c != null || timestamp.WorkHour_Reason__c != '') && timestamp.WorkHour_Reason__c != undefined) {
										timestamp.isWarningWorkedHours = false;
									} 
									this.setRequireField();
								}
								//TSTHHQ 追加　終了

								// Set Total Worked Hours
								if (!timesheetData.isholiday) {
									tempTotalWorkHours += timestamp.workedHours_Int;
								}

								// Set Reach Target
								if (!timesheetData.isholiday) {
									if (timesheetData.isapprovedleave) {
										// First Half Calculation
										if (timesheetData.leaveRequeste.Period_Leave__c == 'AM leave') {
											timesheetData.isreachtarget = timestamp.workedHours_Int + this.leaveFirstHalf_Int >= this.regularTime_Int;
											timesheetData.row_wh = timesheetData.isreachtarget ? 'row-WH' : 'row-WH row-WH-warning';
											// Second Half Calculation
										} else if (timesheetData.leaveRequeste.Period_Leave__c == 'PM leave') {
											timesheetData.isreachtarget =
												timestamp.workedHours_Int + this.leaveSecondHalf_Int >= this.regularTime_Int;
											timesheetData.row_wh = timesheetData.isreachtarget ? 'row-WH' : 'row-WH row-WH-warning';
										} else {
											timesheetData.isreachtarget = true;
											timesheetData.row_wh = 'row-WH';
										}
									} else {
										timesheetData.isreachtarget = timestamp.workedHours_Int >= this.regularTime_Int;
										timesheetData.row_wh = timesheetData.isreachtarget ? 'row-WH' : 'row-WH row-WH-warning';
									}
								}
							} else {
								timestamp.workedHours_Int = 0;
								timestamp.workedHours_Str = '00:00';
							}

							// Set OverTime
							if (STO != undefined && STO >= this.timeOut_Int) {
								timestamp.overTime_Int = STO - this.timeOut_Int;
								timestamp.overTime_Str = this.timeConverter(timestamp.overTime_Int, 'HH:MM');

								//TSTHHQ 追加　開始
								if(timestamp.workedHours_Int >= this.regularTime_Int) {
									if(timestamp.overTime_Int > ONE_HOUR) {
										if (this.isShowLog) console.log('OverTimeAove1Hr Start!');
										
										timestamp.isWarningOT = true;
										timesheetData.row_ot = 'row-OT row-OT-warning'; 

										if((timestamp.Overtime_Reason__c != null || timestamp.Overtime_Reason__c != '') && timestamp.Overtime_Reason__c != undefined) {
											timestamp.isWarningOT = false;
										}
									}
								}
								//TSTHHQ 追加　終了

								// Set Total Overtime Hours
								tempTotalOvertimeHours += timestamp.overTime_Int;
							} else {
								timestamp.overTime_Int = 0;
								timestamp.overTime_Str = '00:00';
							}

							// Set Weekend Overtime Hours
							if (!timesheetData.isweekday && timestamp.workedHours_Int > 0) {
								timestamp.overTime_Int += timestamp.workedHours_Int;
								timestamp.overTime_Str = this.timeConverter(timestamp.overTime_Int, 'HH:MM');

								tempTotalWorkHours -= timestamp.workedHours_Int;
								timestamp.workedHours_Str = '00:00';
							}

							// Set Location
							timestamp.isLocated = timestamp.Stamped_Location__c != undefined;

							// Set Remark
							var remark = timestamp.Remark__c;
							timestamp.Remark = remark != undefined ? (remark.length <= 30 ? remark : remark.slice(0, 27) + '...') : undefined;


							timesheetData.timestamp = timestamp;
							timesheetData.date_id = timesheetData.date + ':' + timestamp.Id;
							break;
						}
					}
					timesheetData.date_id = timesheetData.date_id == undefined ? timesheetData.date + ':' + 'undefined' : timesheetData.date_id;
					return timesheetData;
				});

				this.standardWork = this.timeConverter(tempTotalStandardHours, 'HHHH:MM');
				this.workedHours = this.timeConverter(tempTotalWorkHours, 'HHHH:MM');
				this.overtimeHours = this.timeConverter(tempTotalOvertimeHours, 'HHHH:MM');
				this.leaveHours = this.timeConverter(tempTotalLeaveHours, 'HHHH:MM');
				this.totalHours = this.timeConverter(tempTotalWorkHours + tempTotalLeaveHours, 'HHHH:MM');

				this.isLoading = false;
			})
			.catch((err) => {
				console.log(err);
				this.isLoading = false;
			});
	}

	async setHoliday(timesheetDataList) {
		if (this.isShowLog) console.log('setHoliday Start!');
		await getHolidays({ year: this.selectedYear, month: this.selectedMonth })
			.then((holidays) => {
				timesheetDataList.map((timesheetData) => {
					for (var i in holidays) {
						var holiday = holidays[i];
						if (timesheetData.date === holiday.ActivityDate) {
							timesheetData.isholiday = true;
							timesheetData.holiday = holiday;
							timesheetData.row_data = 'row-data row-data-holiday';
							break;
						}
					}
					return timesheetData;
				});
			})
			.catch((err) => {
				console.log(err);
			});
		return timesheetDataList;
	}

	/*
	 * Which days a request actually covers. Mirrors ApplicationItemTriggerLogic.workingDaysFor
	 * so the screen and the server agree: a range skips weekends and holidays, while a
	 * single-day request is taken at face value even on a weekend. Blank Term_To__c means
	 * a single day.
	 *
	 * Dates are the ISO YYYY-MM-DD strings both sides already use, so they compare
	 * directly and no Date parsing (and no timezone shift) is involved. Leave may not
	 * span a calendar year - enforced by the Leave_Request_No_Year_Span validation rule.
	 */
	isCoveredByLeave(timesheetData, leaveRequeste) {
		const from = leaveRequeste.Term_From__c;
		const to = leaveRequeste.Term_To__c ? leaveRequeste.Term_To__c : from;
		if (!from || to < from) return false;

		if (from === to) return timesheetData.date === from;
		if (timesheetData.date < from || timesheetData.date > to) return false;
		return !timesheetData.isweekend && !timesheetData.isholiday;
	}

	async setLeaveRequestes(timesheetDataList) {
		if (this.isShowLog) console.log('setLeaveRequestes Start!');

		await getLeaveRequestes({ userId: this.userId, year: this.selectedYear, month: this.selectedMonth })
			.then((leaveRequestes) => {
				timesheetDataList.map((timesheetData) => {
					for (var i in leaveRequestes) {
						var leaveRequeste = leaveRequestes[i];
						if (this.isCoveredByLeave(timesheetData, leaveRequeste)) {
							if (leaveRequeste.Status__c == 'Approved') {
								timesheetData.isapprovedleave = true;
								timesheetData.ispendingleave = false;
								timesheetData.row_data = 'row-data row-data-leave';
							} else {
								timesheetData.isapprovedleave = false;
								timesheetData.ispendingleave = true;
							}
							var remark = leaveRequeste.Request_Type__c + '(' + leaveRequeste.Period_Leave__c + ') : ' + leaveRequeste.Remark__c;
							remark = remark != undefined ? (remark.length <= 35 ? remark : remark.slice(0, 32) + '...') : undefined;
							leaveRequeste.remark = remark;
							timesheetData.isleave = true;
							timesheetData.leaveRequeste = leaveRequeste;
							break;
						}
					}
					return timesheetData;
				});
			})
			.catch((err) => {
				console.log(err);
			});
		return timesheetDataList;
	}

	previousYear() {
		if (this.isShowLog) console.log('previousYear Start!');

		this.selectedYear -= 1;
		this.firstOfMonth = new Date(parseInt(this.selectedYear), parseInt(this.selectedMonth) - 1, 1);
		this.lastOfMonth = new Date(parseInt(this.selectedYear), parseInt(this.selectedMonth), 0);
		this.setDateList();
	}

	nextYear() {
		if (this.isShowLog) console.log('nextYear Start!');

		this.selectedYear += 1;
		this.firstOfMonth = new Date(parseInt(this.selectedYear), parseInt(this.selectedMonth) - 1, 1);
		this.lastOfMonth = new Date(parseInt(this.selectedYear), parseInt(this.selectedMonth), 0);
		this.setDateList();
	}

	setSelectedMonth(event) {
		if (this.isShowLog) console.log('setSelectedMonth Start!');

		this.selectedMonth = event.target.dataset.id;
		this.selectedMonthLabel = this.monthOptions[this.monthOptions.findIndex((item) => item.value === this.selectedMonth)].label;

		this.firstOfMonth = new Date(parseInt(this.selectedYear), parseInt(this.selectedMonth) - 1, 1);
		this.lastOfMonth = new Date(parseInt(this.selectedYear), parseInt(this.selectedMonth), 0);
		this.resetMonth();
		this.setDateList();
	}
	resetMonth() {
		if (this.isShowLog) console.log('resetMonth Start!');

		this.monthOptions.map((month) => {
			if (month.value === this.selectedMonth) {
				month.class = 'selected-month-item';
			} else {
				month.class = 'month-item';
			}
			return month;
		});
	}

	/////////////////   Modal Area   /////////////////////

	// Show Modal flag
	@track isShowModal = false;
	@track isNew = false;
	@track modalHeader = '';

	@track selectedDate = '';
	@track selectedRecordId = '';

	// Record Value
	@track timestampNumber = '';
	@track isEditedTimeIn = false;
	@track stampedTimeIn = '';
	@track isEditedTimeOut = false;
	@track stampedTimeOut = '';
	@track remark = '';
	@track requireRemark = false;
	@track manualInputReason = '';
	@track requireManualInput = false;
	@track workHourReason = '';
	@track requireWorkHour = false;
	@track overTimeReason = '';
	@track requireOverTime = false;

	@track overTimeHours = '';
	@track workedHours = '';

	@track isFieldVisible = true;               //TSTHHQ 追加
	@track isRemarksFieldVisible = true;        //TSTHHQ 追加

	openRemarkModal(event) {
		this.isFieldVisible = false;
		this.isRemarksFieldVisible = true;
		if (this.isShowLog) console.log('openRemarkModal Start!');

		this.selectedDate = event.target.dataset.id.split(':')[0];
		this.selectedRecordId = event.target.dataset.id.split(':')[1];

		this.openMdl(this.selectedDate, this.selectedRecordId);
	}

	openModal(event) {
		this.isFieldVisible = true;
		this.isRemarksFieldVisible = false;
		this.isWorkHourReasonVisible = false;
		this.isOverTimeReasonVisible = false;
		if (this.isShowLog) console.log('openModal Start!');

		this.selectedDate = event.target.dataset.id.split(':')[0];
		this.selectedRecordId = event.target.dataset.id.split(':')[1];

		this.openMdl(this.selectedDate, this.selectedRecordId);
	}

	openMdl(selDate, selRecordId) {
		this.setRequireField();
		if (this.isNotCurrentUser) return;

		this.isEditedTimeIn = false;
		this.isEditedTimeOut = false;
		this.requireWorkHour = false;
		this.requireOverTime = false;

		// New record
		if (selRecordId == 'undefined') {
			this.modalHeader = 'New Timestamp';
			this.isNew = true;
			this.selectedDate = selDate;

			this.timestampNumber = null;
			this.stampedTimeIn = null;
			this.stampedTimeOut = null;
			this.remark = null;
			this.manualInputReason = null;
			this.workHourReason = null;
			this.overTimeReason = null;
		}
		// Edit record
		else {
			var timesheetDataList = [...this.timesheetDataList];
			var index = timesheetDataList.findIndex((item) => item.timestamp.Id == selRecordId);
			var timesheetData = timesheetDataList[index];
			this.modalHeader = 'Edit ' + timesheetData.timestamp.Name;
			this.isNew = false;

			var tempTimeIn = timesheetData.timestamp.Stamped_TimeIn__c;
			var tempTimeOut = timesheetData.timestamp.Stamped_TimeOut__c;

			this.isEditedTimeIn = timesheetData.timestamp.is_Manual_Edit_TimeIn__c;
			this.isEditedTimeOut = timesheetData.timestamp.is_Manual_Edit_TimeOut__c;

			this.timestampNumber = timesheetData.timestamp.Name;
			this.stampedTimeIn = tempTimeIn == undefined ? null : this.timeConverter(tempTimeIn, 'HH:MM:SS.sss');
			this.stampedTimeOut = tempTimeOut == undefined ? null : this.timeConverter(tempTimeOut, 'HH:MM:SS.sss');

			this.remark = timesheetData.timestamp.Remark__c;
			this.manualInputReason = timesheetData.timestamp.Maunal_Input_Reason__c;
			this.workHourReason = timesheetData.timestamp.WorkHour_Reason__c;
			this.overTimeReason = timesheetData.timestamp.Overtime_Reason__c;

			this.overTimeHours = timesheetData.timestamp.overTime_Int;
			this.workedHours = timesheetData.timestamp.workedHours_Int;

			if(this.workedHours < this.regularTime_Int) {
				this.requireWorkHour = true;
			} else {
				this.requireWorkHour = false;
			}

			if(this.workedHours >= this.regularTime_Int) {
				if(this.overTimeHours > ONE_HOUR) {
					this.requireOverTime = true;
				} else {
					this.requireOverTime = false;
				}
			}

			if(tempTimeIn > this.timeIn_Int) {
				this.isEditedTimeIn = true;
			}
			if(tempTimeOut < this.timeOut_Int) {
				this.isEditedTimeOut = true;
			}
		}
		this.isShowModal = true;
	}

	/*openModal(event) {
		this.isFieldVisible = true;
		this.isRemarksFieldVisible = false;
		this.isWorkHourReasonVisible = false;
		this.isOverTimeReasonVisible = false;
		if (this.isShowLog) console.log('openModal Start!');

		this.setRequireField();
		if (this.isNotCurrentUser) return;

		this.isEditedTimeIn = false;
		this.isEditedTimeOut = false;
		this.requireWorkHour = false;
		this.requireOverTime = false;

		this.selectedDate = event.target.dataset.id.split(':')[0];
		this.selectedRecordId = event.target.dataset.id.split(':')[1];

		// New record
		if (this.selectedRecordId == 'undefined') {
			this.modalHeader = 'New Timestamp';
			this.isNew = true;
			this.selectedDate = this.selectedDate;

			this.timestampNumber = null;
			this.stampedTimeIn = null;
			this.stampedTimeOut = null;
			this.remark = null;
			this.manualInputReason = null;
			this.workHourReason = null;
			this.overTimeReason = null;
		}
		// Edit record
		else {
			var timesheetDataList = [...this.timesheetDataList];
			var index = timesheetDataList.findIndex((item) => item.timestamp.Id == this.selectedRecordId);
			var timesheetData = timesheetDataList[index];
			this.modalHeader = 'Edit ' + timesheetData.timestamp.Name;
			this.isNew = false;

			var tempTimeIn = timesheetData.timestamp.Stamped_TimeIn__c;
			var tempTimeOut = timesheetData.timestamp.Stamped_TimeOut__c;

			this.isEditedTimeIn = timesheetData.timestamp.is_Manual_Edit_TimeIn__c;
			this.isEditedTimeOut = timesheetData.timestamp.is_Manual_Edit_TimeOut__c;

			this.timestampNumber = timesheetData.timestamp.Name;
			this.stampedTimeIn = tempTimeIn == undefined ? null : this.timeConverter(tempTimeIn, 'HH:MM:SS.sss');
			this.stampedTimeOut = tempTimeOut == undefined ? null : this.timeConverter(tempTimeOut, 'HH:MM:SS.sss');

			this.remark = timesheetData.timestamp.Remark__c;
			this.manualInputReason = timesheetData.timestamp.Maunal_Input_Reason__c;
			this.workHourReason = timesheetData.timestamp.WorkHour_Reason__c;
			this.overTimeReason = timesheetData.timestamp.Overtime_Reason__c;

			this.overTimeHours = timesheetData.timestamp.overTime_Int;
			this.workedHours = timesheetData.timestamp.workedHours_Int;

			if(this.workedHours < this.regularTime_Int) {
				this.requireWorkHour = true;
			} else {
				this.requireWorkHour = false;
			}

			if(this.workedHours >= this.regularTime_Int) {
				if(this.overTimeHours > ONE_HOUR) {
					this.requireOverTime = true;
				} else {
					this.requireOverTime = false;
				}
			}

			if(tempTimeIn > this.timeIn_Int) {
				this.isEditedTimeIn = true;
			}
			if(tempTimeOut < this.timeOut_Int) {
				this.isEditedTimeOut = true;
			}
		}
		this.isShowModal = true;
	}*/

	setRequireField() {
		if (this.isShowLog) console.log('setRequireField Start!');
		console.log(this.isEditedTimeIn);
		console.log(this.isEditedTimeOut);

		if (this.isEditedTimeIn || this.isEditedTimeOut) {
			this.requireManualInput = true;
		} else {
			this.requireManualInput = false;
		}
	}

	onTimeChange(event) {
		if (this.isShowLog) console.log('onTimeInChange Start!');
		const editTime = event.detail.value;
		switch (event.target.dataset.id) {
			case 'timeIn':
				this.isEditedTimeIn = true;
				this.stampedTimeIn = editTime;
				console.log(this.stampedTimeIn);
				break;
			case 'timeOut':
				this.isEditedTimeOut = true;
				this.stampedTimeOut = editTime;
				console.log(this.stampedTimeOut);
				break;
		}

		this.setRequireField();
	}

	onRemarkChange(event) {
		if (this.isShowLog) console.log('onRemarkChange Start!');

		this.remark = event.detail.value;
		this.setRequireField();
	}

	onManualInputReasonChange(event) {
		if (this.isShowLog) console.log('onManualInputReasonChange Start!');

		this.manualInputReason = event.detail.value;
		this.setRequireField();
	}

	onWorkHourReasonChange(event) {
		if (this.isShowLog) console.log('onWorkHourReasonChange Start!');

		this.workHourReason = event.detail.value;
		this.setRequireField();
	}

	onOverTimeReasonChange(event) {
		if (this.isShowLog) console.log('onOverTimeReasonChange Start!');

		this.overTimeReason = event.detail.value;
		this.setRequireField();
	}

	handleStamped(event) {
		if (this.isShowLog) console.log('onhandleStamped Start!');

		this.setDateList();
	}

	onSave() {
		if (this.isShowLog) console.log('onSave Start!');
		/*if (this.requireRemark && !this.remark) {
			const message = 'Please input REMARK everytime you update Timestamp!';
			this.showToast(message, 'ERROR');
			return;
		}*/

		if (this.requireManualInput && !this.manualInputReason) {
			const message = 'Please input reason for MANUAL INPUT or LATE CHECKIN/CHECKOUT !';
			this.showToast(message, 'ERROR');
			return;
		}

		if(this.isRemarksFieldVisible) {
			if (this.requireWorkHour && !this.workHourReason) {
				const message = 'Please input reason for WORKING LESS THAN 7.5 HOURS !';
				this.showToast(message, 'ERROR');
				return;
			}

			if (this.requireOverTime && !this.overTimeReason) {
				const message = 'Please input reason for OVERTIME !';
				this.showToast(message, 'ERROR');
				return;
			}
		}

		var result = '';
		if (this.manualInputReason !== null && this.manualInputReason !== undefined) {
			result += this.manualInputReason + "\n";
		}
		if (this.requireWorkHour && (this.workHourReason !== null && this.workHourReason !== undefined)) {
			result += this.workHourReason + "\n";
		}
		if (this.requireOverTime && (this.overTimeReason !== null && this.overTimeReason !== undefined)) {
			result += this.overTimeReason + "\n";
		}

		if (this.isNew) {
			if (!this.stampedTimeIn && !this.stampedTimeOut) {
				const message = 'Please input TimeIn or TimeOut!';
				this.showToast(message, 'ERROR');
			} else {
				createTimeStamps({
					stampedDate: this.selectedDate,
					timeIn: this.isEditedTimeIn ? this.stampedTimeIn : null,
					timeOut: this.isEditedTimeOut ? this.stampedTimeOut : null,
					//remark: this.remark,
					remark : result,
					manualInputReason: this.manualInputReason,
					workHourReason: this.workHourReason,
					overTimeReason: this.overTimeReason
				})
					.then((value) => {
						if (value.includes('FIELD_CUSTOM_VALIDATION_EXCEPTION')) {
							const message = 'Can NOT input TimeIn to be greater than TimeOut!';
							this.showToast(message, 'ERROR');
						} else {
							this.setDateList();
							this.isShowModal = false;
							const message = 'Record created successful!';
							this.showToast(message, 'SUCCESS');
						}
					})
					.catch((err) => {
						console.log(err);

						this.setDateList();
						this.isShowModal = false;
						const message = 'Error occur when trying to create the record!';
						this.showToast(message, 'ERROR');
					});
			}
		} else {
			if (!this.stampedTimeIn && !this.stampedTimeOut) {
				const message = 'Please input TimeI or TimeOut!';
				this.showToast(message, 'ERROR');
			} else {
				updateTimeStamps({
					timestampNumber: this.timestampNumber,
					isEditedTimeIn: this.isEditedTimeIn,
					isEditedTimeOut: this.isEditedTimeOut,
					timeIn: this.stampedTimeIn,
					timeOut: this.stampedTimeOut,
					//remark: this.remark,
					remark : result,
					manualInputReason: this.manualInputReason,
					workHourReason: this.workHourReason,
					overTimeReason: this.overTimeReason
				})
					.then((value) => {
						if (value.includes('FIELD_CUSTOM_VALIDATION_EXCEPTION')) {
							const message = 'Can NOT input TimeIn to be greater than TimeOut!';
							this.showToast(message, 'ERROR');
						} else {
							this.setDateList();
							this.isShowModal = false;
							const message = 'Record updated successful!';
							this.showToast(message, 'SUCCESS');
						}
					})
					.catch((err) => {
						console.log(err);

						this.setDateList();
						this.isShowModal = false;
						const message = 'Error occur when trying to update the record!';
						this.showToast(message, 'ERROR');
					});
			}
		}

		if (this.requireWorkHour && (this.workHourReason != null ||  this.workHourReason != '')) {
			this.requireWorkHour = false;
		}

		if (this.requireOverTime && (this.overTimeReason != null || this.overTimeReason != '')) {
			this.requireOverTime = false;
		}
	}

	onCancel() {
		this.isShowModal = false;
	}

	/////////////////   Map Area   /////////////////////
	@track isShowMap = false;
	@track zoomLevel = 15;
	@track mapMarkers = null;

	onMapOpen(event) {
		if (this.isShowLog) console.log('onMapOpen Start!');

		this.selectedDate = event.target.dataset.id.split(':')[0];
		this.selectedRecordId = event.target.dataset.id.split(':')[1];

		// New record
		if (this.selectedRecordId == 'undefined') {
			this.mapMarkers = null;
		}
		// Edit record
		else {
			var timesheetDataList = [...this.timesheetDataList];
			var index = timesheetDataList.findIndex((item) => item.timestamp.Id == this.selectedRecordId);
			this.mapMarkers = [
				{
					location: {
						Latitude: timesheetDataList[index].timestamp.Stamped_Location__c.latitude,
						Longitude: timesheetDataList[index].timestamp.Stamped_Location__c.longitude
					}
				}
			];
		}
		this.isShowMap = true;
	}

	onMapCancel() {
		this.mapMarkers = null;
		this.isShowMap = false;
	}

	/////////////////   ApplicationItem Area   /////////////////////
	@track leaveRecordId = '';

	openViewAIModal(event) {
		if (this.isShowLog) console.log('openViewAIModal Start!');

		this.leaveRecordId = event.target.dataset.id;
		this[NavigationMixin.Navigate]({
			type: 'standard__recordPage',
			attributes: {
				recordId: this.leaveRecordId,
				actionName: 'view'
			}
		});
	}

	openCreateAIModal(event) {
		if (this.isShowLog) console.log('openCreateAIModal Start!');

		this.selectedDate = event.target.dataset.id.split(':')[0];
		this.selectedRecordId = event.target.dataset.id.split(':')[1];

		const defaultValues = encodeDefaultFieldValues({
			Term_From__c: this.selectedDate
		});

		this[NavigationMixin.Navigate]({
			type: 'standard__objectPage',
			attributes: {
				objectApiName: 'ApplicationItem__c',
				actionName: 'new'
			},
			state: {
				defaultFieldValues: defaultValues
			}
		});
	}

	onLeaveCancel() {
		this.isShowLeave = false;
	}
}