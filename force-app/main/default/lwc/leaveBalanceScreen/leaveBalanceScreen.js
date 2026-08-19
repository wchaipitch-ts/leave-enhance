import { LightningElement, track, wire } from 'lwc';
// 🌟 1. นำเข้าโมดูลสำหรับอ่านค่าจาก URL
import { CurrentPageReference } from 'lightning/navigation'; 

// =========================================================
// [1] กำหนดโครงสร้างคอลัมน์ของตารางด้านล่าง (Summary Table)
// =========================================================
const COLUMNS = [
    { label: 'No.', fieldName: 'rowNumber', type: 'text', initialWidth: 80 },
    { label: 'Leave Type', fieldName: 'leaveType', type: 'text' },
    { label: 'Entitlement / Allocation', fieldName: 'entitlementStr', type: 'text' },
    { label: 'Accrued to Date', fieldName: 'accruedStr', type: 'text' },
    { label: 'Used', fieldName: 'usedStr', type: 'text' },
    { label: 'Carry Over', fieldName: 'carriedInStr', type: 'text' },
    { label: 'Available', fieldName: 'availableStr', type: 'text' }
];

// =========================================================
// [2] MOCK DATA ที่ทีม Backend ส่งมาให้ (จำลองเสมือนได้จาก Apex)
// =========================================================
const MOCK_LEAVE_OVERVIEW = {
    "year": 2026,
    "overtimeHours": 2.25,
    "nextRefreshmentGrant": "2027-03-15",
    "month": 8,
    "employee": {
        "userId": "0055i000003aPoyAAE",
        "title": "Engineer",
        "startDate": "2024-03-15",
        "probationEndDate": "2024-07-12",
        "photoUrl": "https://terraskyth--dev5.sandbox.file.force.com/profilephoto/005/M",
        "onProbation": false,
        "name": "Pacharoenwong Chatchapon",
        "managerName": "Kuribayashi Yuta",
        "employeeNumber": "E0001",
        "department": "Engineer"
    },
    "balances": [
        { "used": 2, "leaveType": "Annual leave", "entitlement": 12, "carriedIn": 2, "available": 8, "accrued": 8 },
        { "used": 1, "leaveType": "Refresh Leave", "entitlement": 2, "carriedIn": 0, "available": 1, "accrued": 2 },
        { "used": 30, "leaveType": "Sick leave", "entitlement": 30, "carriedIn": 0, "available": 0, "accrued": 30 },
        { "used": 0, "leaveType": "Personal leave", "entitlement": 3, "carriedIn": 0, "available": 2, "accrued": 3 },
        { "used": 0, "leaveType": "Bereavement leave", "entitlement": 0, "carriedIn": 0, "available": 0, "accrued": 0 },
        { "used": 0, "leaveType": "Marriage leave", "entitlement": 0, "carriedIn": 0, "available": 0, "accrued": 0 },
        { "used": 0, "leaveType": "Military service leave", "entitlement": 0, "carriedIn": 0, "available": 0, "accrued": 0 },
        { "used": 0, "leaveType": "Ordination leave", "entitlement": 0, "carriedIn": 0, "available": 0, "accrued": 0 },
        { "used": 0, "leaveType": "Sterilization leave", "entitlement": 0, "carriedIn": 0, "available": 0, "accrued": 0 },
        { "used": 0, "leaveType": "Training or knowledge leave", "entitlement": 0, "carriedIn": 0, "available": 0, "accrued": 0 },
        { "used": 0, "leaveType": "Leave Without Pay", "entitlement": 0, "carriedIn": 0, "available": 0, "accrued": 0 }
    ],
    "availableYears": [ 2026 ],
    "annualAvailable": 8
};

export default class LeaveBalanceScreen extends LightningElement {
    
    // -------------------------------------------------------------
    // ตัวแปรสำหรับรับค่าที่ส่งมาจากหน้าจอเก่า (ผ่าน URL)
    // -------------------------------------------------------------
    @track receivedUserId = null;
    @track receivedYear = null;

    // -------------------------------------------------------------
    // ตัวแปรสำหรับผูก (Bind) ข้อมูลไปแสดงบนหน้าจอ HTML
    // -------------------------------------------------------------
    @track employee = {};
    @track selectedYear;
    @track availableYears = [];
    @track highlightCards = [];
    @track tableData = [];
    columns = COLUMNS;

    // =========================================================
    // [3] ดักจับพารามิเตอร์จาก URL ด้วย @wire
    // หน้าที่: รับกระเป๋าเดินทาง (State) ที่หน้า Timesheet ส่งมาให้
    // =========================================================
    @wire(CurrentPageReference)
    getStateParameters(currentPageReference) {
        if (currentPageReference && currentPageReference.state) {
            // ดึงค่าจาก URL (ถ้าไม่มีให้เป็น null)
            this.receivedUserId = currentPageReference.state.c__userId || null;
            this.receivedYear = currentPageReference.state.c__year || null;

            console.log('📌 Received UserId from URL:', this.receivedUserId);
            console.log('📌 Received Year from URL:', this.receivedYear);

            // เมื่อได้ ID มาแล้ว ก็เริ่มประมวลผลข้อมูลจำลองเพื่อนำไปวาดหน้าจอ
            this.processMockData();
        }
    }

    // =========================================================
    // [4] ฟังก์ชันสำหรับแกะกล่อง JSON และแจกจ่ายข้อมูลลงหน้าจอ
    // =========================================================
    processMockData() {
        // 1. นำข้อมูลส่วนตัวพนักงาน และ ปี ไปแปะที่มุมซ้ายบน
        this.employee = MOCK_LEAVE_OVERVIEW.employee;
        this.selectedYear = MOCK_LEAVE_OVERVIEW.year;
        this.availableYears = MOCK_LEAVE_OVERVIEW.availableYears;

        // 2. แปลงข้อมูลสำหรับทำ "ตาราง (Summary Table)" ด้านล่าง
        // วนลูปเพื่อเพิ่ม Row Number และเติมคำว่า 'Days' ต่อท้ายตัวเลขให้ตรง Design
        this.tableData = MOCK_LEAVE_OVERVIEW.balances.map((item, index) => {
            return {
                ...item,
                rowNumber: String(index + 1), // ลำดับที่ 1, 2, 3...
                entitlementStr: `${item.entitlement}.00 Days`,
                accruedStr: `${item.accrued}.00 Days`,
                usedStr: `${item.used}.00 Days`,
                carriedInStr: `${item.carriedIn}.00 Days`,
                availableStr: `${item.available}.00 Days`
            };
        });

        // 3. แปลงข้อมูลสำหรับทำ "การ์ด 4 ใบ (Highlight Cards)" ด้านบน
        // กรองเอาเฉพาะ 4 ประเภทหลักที่ต้องการนำมาโชว์ในกล่องด้านบน
        const highlightTypes = ['Annual leave', 'Refresh Leave', 'Sick leave', 'Personal leave'];
        let tempCards = [];

        MOCK_LEAVE_OVERVIEW.balances.forEach(item => {
            if (highlightTypes.includes(item.leaveType)) {
                
                // กำหนดสีของเส้นขอบการ์ดซ้ายมือตามประเภทของวันลา (เชื่อมกับไฟล์ CSS)
                let cssClass = 'highlight-card ';
                let numberCssClass = '';

                // เช็คเงื่อนไขเพื่อสลับสีตาม Design
                if (item.leaveType === 'Annual leave') {
                    cssClass += 'card-annual';
                    numberCssClass = 'text-green';
                } else if (item.leaveType === 'Refresh Leave') {
                    cssClass += 'card-refreshment';
                    numberCssClass = 'text-blue';
                } else if (item.leaveType === 'Sick leave') {
                    cssClass += 'card-sick';
                    numberCssClass = 'text-pink';
                } else if (item.leaveType === 'Personal leave') {
                    cssClass += 'card-personal';
                    numberCssClass = 'text-teal';
                }

                // แพ็คของใส่ Array เพื่อส่งไปให้ HTML วนลูป <template for:each>
                tempCards.push({
                    leaveType: item.leaveType,
                    available: item.available,
                    entitlement: item.entitlement,
                    cssClass: cssClass,
                    numberCssClass: numberCssClass
                });
            }
        });
        
        this.highlightCards = tempCards;
    }
}