import { LightningElement, track } from "lwc";
import isGuest from "@salesforce/user/isGuest";
import ExpOrgId from "@salesforce/label/c.CH_Org_Id";
import RedirectUrl from "@salesforce/label/c.CH_Redirect_Url";
import HeaderInternal from "@salesforce/label/c.CH_Header_Internal";
import createCaseRecord from "@salesforce/apex/WebToCaseServiceCtrl.createCase";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import NotificationModal from "c/notificationModal";
export default class WebToCaseInternal extends LightningElement {
  firstName = "";
  lastName = "";
  nickName = "";
  email = "";
  phone = "";
  company = "";
  subject = "";
  product = "";
  priority = "";
  description = "";
  origin = "Web";
  comment = "";
  source = "";
  status = "";
  initiator = "";

  @track uploadFilesCheck = false;
  @track caseId = "";
  @track stageUploadPage = false;
  // @track stageThanks = false;
  label = { ExpOrgId, RedirectUrl, HeaderInternal };

  files = [];
  fileNames = "";
  fileNamesValidateMsg = "";
  fileNamesValidate = false;
  priorityValidate = false;
  priorityValidateMsg = "";
  statusValidate = false;
  statusValidateMsg = "";
  sourceValidate = false;
  sourceValidateMsg = "";
  saving = false;

  // Debug helpers (no behavioral change)
  debug = true; // set to false to disable logs
  log(label, data) {
    if (this.debug) {
      // eslint-disable-next-line no-console
      console.log(`[W2C-Internal] ${label}:`, data);
    }
  }

  // For guest users, omit record-id to let ContentVersion insert succeed
  get recordIdForUpload() {
    const id = isGuest ? undefined : this.caseId;
    this.log("recordIdForUpload (guest? " + isGuest + ")", id);
    return id;
  }

  get acceptedFormats() {
    return [".pdf", ".png", ".jpg", ".jpeg"];
  }
  // Options for Product, Priority, Status, and Source
  productOptions = [
    { label: "--None--", value: "" },
    { label: "mitoco", value: "mitoco" },
    { label: "mitocoAI", value: "mitocoAI" },
    { label: "Salesforce", value: "Salesforce" },
    { label: "SVE", value: "SVE" }
  ];

  priorityOptions = [
    { label: "-- None --", value: "None" },
    { label: "Urgent", value: "Urgent" },
    { label: "Medium", value: "Medium" },
    { label: "Low", value: "Low" }
  ];

  statusOptions = [
    { label: "-- None --", value: "None" },
    { label: "New", value: "New" },
    { label: "Assigned", value: "Assigned" },
    { label: "In Progress", value: "In Progress" },
    { label: "Waiting for Customer", value: "Waiting for Customer" },
    { label: "Canceled", value: "Canceled" },
    { label: "Closed", value: "Closed" }
  ];

  sourceOptions = [
    { label: "--None--", value: "" },
    { label: "LINE", value: "LINE" },
    { label: "SNS(Other)", value: "SNS(Other)" },
    { label: "Personal Email", value: "Personal Email" },
    { label: "Personal Phone", value: "Personal Phone" }
  ];

  handleInputChange(e) {
    const { name, value } = e.target;
    this[name] = value ?? "";

    if (name === "status") {
      this.statusValidate = false;
    } else if (name === "priority") {
      this.priorityValidate = false;
    } else if (name === "source") {
      this.sourceValidate = false;
    }
  }

  async handleNext() {
    if (!this.onValidation()) return;

    this.saving = true;
    try {
      const caseData = {
        subject: this.subject,
        description: this.description,
        priority: this.priority,
        email: this.email,
        phone: this.phone,
        company: this.company,
        firstName: this.firstName,
        lastName: this.lastName,
        nickName: this.nickName,
        product: this.product,
        source: this.source,
        status: this.status,
        initiator: this.initiator,
        comment: this.comment
      };

      this.log("Submitting case (Next) with", caseData);
      const caseId = await createCaseRecord({ caseData });
      this.log("Created case id", caseId);
      this.caseId = caseId;
      this.stageUploadPage = true;
      this.saving = false;
      await this.openModal();
    } catch (e) {
      const msg =
        e?.body?.message ||
        e?.message ||
        "An unexpected error occurred while submitting the case.";
      this.log("Submit Next error raw", e);
      this.showToast("Error", msg, "error");
      console.error("Error creating case:", JSON.stringify(e));
    } finally {
      this.saving = false;
    }
  }

  onValidation() {
    const lightningInputs = [
      ...this.template.querySelectorAll(
        "lightning-input, lightning-textarea, lightning-combobox"
      )
    ];
    const selectElements = [
      ...this.template.querySelectorAll("select[required]")
    ];

    let lightningValid = true;
    lightningInputs.forEach((cmp) => {
      const isValid = cmp.reportValidity();
      if (!isValid) lightningValid = false;
    });

    const selectsValid = selectElements.reduce((ok, select) => {
      const hasValue = select.value && select.value.trim() !== "";
      if (!hasValue) {
        select.style.border = "2px solid #c23934";
        select.focus();
        if (select.name === "status") {
          this.statusValidate = true;
          this.statusValidateMsg = "Complete this field";
        }
        if (select.name === "priority") {
          this.priorityValidate = true;
          this.priorityValidateMsg = "Complete this field";
        }
        if (select.name === "source") {
          this.sourceValidate = true;
          this.sourceValidateMsg = "Complete this field";
        }
      } else {
        select.style.border = "";
      }
      return ok && hasValue;
    }, true);

    return lightningValid && selectsValid && !this.fileNamesValidate;
  }

  async handleSubmit() {
    if (!this.onValidation()) return;

    this.saving = true;
    try {
      const caseData = {
        subject: this.subject,
        description: this.description,
        priority: this.priority,
        email: this.email,
        phone: this.phone,
        company: this.company,
        firstName: this.firstName,
        lastName: this.lastName,
        nickName: this.nickName,
        product: this.product,
        source: this.source,
        status: this.status,
        initiator: this.initiator,
        comment: this.comment
      };

      this.log("Submitting case with", caseData);
      const caseId = await createCaseRecord({ caseData });
      this.log("Created case id", caseId);
      this.caseId = caseId;

      if (this.caseId && this.caseId.includes("500")) {
        this.showToast("Success", "Case created successfully!", "success");
        this.resetForm();
      }
    } catch (e) {
      const msg =
        e?.body?.message ||
        e?.message ||
        "An unexpected error occurred while submitting the case.";
      this.log("Submit error raw", e);
      this.showToast("Error", msg, "error");
      console.error("Error creating case:", JSON.stringify(e));
    } finally {
      this.saving = false;
    }
  }

  uploadFilesHandle() {
    this.uploadFilesCheck = !this.uploadFilesCheck;
  }

  showToast(title, message, variant = "info") {
    this.dispatchEvent(
      new ShowToastEvent({
        title,
        message,
        variant
      })
    );
  }

  resetForm() {
    this.firstName = "";
    this.lastName = "";
    this.nickName = "";
    this.email = "";
    this.phone = "";
    this.company = "";
    this.subject = "";
    this.product = "";
    this.priority = "None";
    this.description = "";
    this.origin = "Web";
    this.source = "";
    this.status = "";
    this.initiator = "";
    this.comment = "";
    this.files = [];
    this.fileNames = "";
  }

  handleUploadFinished(event) {
    try {
      const files = event?.detail?.files || [];
      this.log("Upload finished event (raw)", event?.detail);
      files.forEach((file) => {
        // Exact logs per your request
        // eslint-disable-next-line no-console
        console.log(`ContentVersionId: ${file.contentVersionId}`);
        // eslint-disable-next-line no-console
        console.log(`ContentDocumentId: ${file.documentId}`);
        // eslint-disable-next-line no-console
        console.log(`Title: ${file.name}`);
      });
      // Note: Linking is handled by the ContentVersion trigger.
      this.log("Upload finished for caseId", this.caseId);
    } catch (err) {
      this.log("Error while logging upload finished", err);
    }
    this.stageUploadPage = false;
    this.uploadFilesCheck = false;
    this.showToast("Success", "Case created successfully!", "success");
    this.resetForm();
  }
  async openModal() {
    await NotificationModal.open({
      size: "small", // 'small' | 'medium' | 'large'
      label: "Notification", // header text
      description: "Submission note", // a11y description
      message:
        "Case has been submitted, please attach any files you would like to upload."
      // disableClose: true          // optional: prevent ESC/outside click
    });
  }
}