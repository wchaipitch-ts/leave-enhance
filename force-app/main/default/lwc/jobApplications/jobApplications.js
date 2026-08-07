import { LightningElement, track, api, wire } from 'lwc';
import getContent from '@salesforce/apex/JobApplicationsCtrl.getManagedContentByTopicsAndContentKeys';
import createJobApplication from '@salesforce/apex/JobApplicationsCtrl.createJobApplication';
import { createRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import uploadFileToSalesforce from '@salesforce/apex/JobApplicationsCtrl.uploadFileToSalesforce';

export default class JobApplicationsPage extends LightningElement {
    @api id;
    @track richText = '<p><span style="font-size: 10pt;">Responsibilities:</span></p>...'; // Truncated for brevity
    @track searchQuery = '';
    @track selectedJob = null;
    @track isApplying = false;
    @track applicantName = '';
    @track applicantEmail = '';
    @track applicantPhone = '';
    @track applicantLinkedIn = '';
    @track expectedSalary = '';
    @track applicantMessage = '';
    @track resumeFileName = '';
    @track jobApplicantId;
    @track jobList = [];
    @track fileObj;
    @track isFormValid = true; // Track form validity

    checkFormValidity() {
        // console.log('fullName.reportValidity()  : ',fullName.reportValidity());
        // console.log('email.reportValidity()  : ',email.reportValidity());
        // console.log('phone.reportValidity()  : ',phone.reportValidity());
        // console.log('message.reportValidity()  : ',message.reportValidity());
        // console.log('resume.reportValidity()  : ',resume.reportValidity());
        
         // Get all required fields
         const requiredFields = this.template.querySelectorAll('lightning-input, lightning-textarea');
         let isValid = true;
        console.log('requiredFields :',requiredFields);
        
         // Iterate through each field to check validity
         requiredFields.forEach(field => {
            console.log('field :',field);
             console.log('field.reportValidity()  : ',field.reportValidity());
             if (!field.reportValidity()) {
                 isValid = false;
             }
         });
 
         // If resume field is required and file is not selected, mark form as invalid
         const resumeField = this.template.querySelector('lightning-input[type="file"]');
         if (resumeField && !resumeField.files.length) {
             isValid = false;
         }
    
        this.isFormValid = !isValid; // Disable submit button if form is invalid
    }
    get filteredJobs() {
        return this.jobList.length > 0 ? this.jobList.filter(
            job => job.title.value.toLowerCase().includes(this.searchQuery.toLowerCase()) ||
                job.location.value.toLowerCase().includes(this.searchQuery.toLowerCase())
        ) : null;
    }

    // Handle user input for search
    handleSearch(event) {
        this.searchQuery = event.target.value;
    }

    // Handle job details display
    handleShowDetails(event) {
        this.handleReset();
        this.selectedJob = event.detail;
    }

    // Close job details view
    closeSidebar() {
        this.selectedJob = null;
    }

    // Handle application form toggling
    handleApply() {
        this.isApplying = true;
    }

    // Handle cancel application
    handleCancel() {
        this.isApplying = false;
    }

    // Handle form input changes
    handleNameChange(event) {
        this.applicantName = event.target.value;
        this.checkFormValidity();
    }

    handleEmailChange(event) {
        this.applicantEmail = event.target.value;
        this.checkFormValidity();
    }

    handlePhoneChange(event) {
        this.applicantPhone = event.target.value;
        this.checkFormValidity();
    }

    handleLinkedInChange(event) {
        this.applicantLinkedIn = event.target.value;
        this.checkFormValidity();
    }

    handleSalaryChange(event) {
        this.expectedSalary = event.target.value;
        this.checkFormValidity();
    }

    handleMessageChange(event) {
        this.applicantMessage = event.target.value;
        this.checkFormValidity();
    }

    // Submit application
    handleSubmit() {
        // const fields = {
        //     Name: this.applicantName,
        //     Email__c: this.applicantEmail,
        //     Phone__c: this.applicantPhone,
        //     LinkedIn_Profile__c: this.applicantLinkedIn,
        //     Expected_Salary__c: this.expectedSalary,
        //     Cover_Letter__c: this.applicantMessage,
        //     Position_Applied__c: this.selectedJob.title
        // };

        // const recordInput = { apiName: 'Job_Application__c', fields };

        // createRecord(recordInput)
        //     .then(result => {
        //         this.jobApplicantId = result.id;
        //         this.showToast('Success', 'Application submitted successfully!', 'success');
        //         this.uploadFile(this.fileObj);
        //     })
        //     .catch(error => {
        //         this.showToast('Error', 'Failed to submit application.', 'error');
        //         console.error(error);
        //     });
        createJobApplication({ 
            applicantName: this.applicantName,
            applicantEmail: this.applicantEmail,
            applicantPhone: this.applicantPhone,
            applicantEmailLinkedIn: this.applicantLinkedIn,
            applicantExpectedSalary: this.expectedSalary,
            applicantCoverLetter: this.applicantMessage,
            applicantPositionApplied: this.selectedJob.title
        })
        .then(result => {
            this.jobApplicantId = result;
            this.uploadFile(this.fileObj);
            this.showToast('Success', 'Application submitted successfully!', 'success');
        })
        .catch(error => {
            this.showToast('Error', 'Failed to submit application.', 'error');
            console.error(error);
        });
        this.handleReset();
    }

    // Reset form
    handleReset() {
        this.isApplying = false;
        this.applicantName = '';
        this.applicantEmail = '';
        this.applicantPhone = '';
        this.applicantLinkedIn = '';
        this.expectedSalary = '';
        this.applicantMessage = '';
        this.resumeFileName = '';
        this.isFormValid = true;
    }

    // Fetch job list on component load
    connectedCallback() {
        getContent({})
            .then(result => {
                this.jobList = result;
            })
            .catch(error => {
                console.error('Error fetching job content:', error);
            });
    }

    // Decode HTML content for rich text
    get formattedDetail() {
        return this.decodeHTML(this.selectedJob?.detail || '');
    }

    decodeHTML(html) {
        let textArea = document.createElement('textarea');
        textArea.innerHTML = html;
        return textArea.value;
    }

    // Link uploaded file to job application
    linkFileToRecord(contentDocumentId) {
        const fields = {
            LinkedEntityId: this.jobApplicantId,
            ContentDocumentId: contentDocumentId
        };

        createRecord({ apiName: 'ContentDocumentLink', fields })
            .then(() => this.showToast('Success', 'Resume linked successfully!', 'success'))
            .catch(error => {
                this.showToast('Error', 'Failed to link resume.', 'error');
                console.error(error);
            });
    }

    // Show toast notification
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    // Handle file selection
    handleFileChange(event) {
        const file = event.target.files[0];
        
        if (file) {
            this.resumeFileName = file.name;
            this.fileObj = file;
            this.checkFormValidity();
        }
        
    }

    // Upload file and link to job application
    uploadFile(file) {
        const reader = new FileReader();
        
        reader.onloadend = () => {
            const base64File = reader.result.split(',')[1]; // Get base64 string

            uploadFileToSalesforce({ fileName: file.name, base64Data: base64File })
                .then(contentDocumentId => {
                    if (this.jobApplicantId && contentDocumentId) {
                        this.linkFileToRecord(contentDocumentId);
                    }
                })
                .catch(error => {
                    this.showToast('Error', 'Failed to upload the file.', 'error');
                    console.error(error);
                });
        };

        reader.readAsDataURL(file); // Convert to base64
    }
}