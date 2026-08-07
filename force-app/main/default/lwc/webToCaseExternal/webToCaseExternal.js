import { LightningElement, track } from "lwc";
import isGuest from "@salesforce/user/isGuest";
import "./webToCaseExternal.css";
import ExpOrgId from "@salesforce/label/c.CH_Org_Id";
import RedirectUrl from "@salesforce/label/c.CH_Redirect_Url";
import HeaderExternal from "@salesforce/label/c.CH_Header_External";
import createCaseRecord from "@salesforce/apex/WebToCaseServiceCtrl.createCase";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import NotificationModal from "c/notificationModal";
export default class WebToCaseExternal extends LightningElement {
  firstName = "";
  lastName = "";
  nickName = "";
  email = "";
  phone = "";
  company = "";
  subject = "";
  product = "";
  priority = "None";
  description = "";
  @track uploadFilesCheck = false;
  @track caseId = "";
  @track stageUploadPage = false;
  @track stageThanks = false;
  files = [];
  fileNames = "";
  fileNamesValidateMsg = "";
  fileNamesValidate = false;
  saving = false;
  productValidate = false;
  productValidateMsg = "";
  priorityValidate = false;
  priorityValidateMsg = "";
  label = { ExpOrgId, RedirectUrl, HeaderExternal };

  // For guest users, omit record-id to let ContentVersion insert succeed
  get recordIdForUpload() {
    const id = isGuest ? undefined : this.caseId;
    return id;
  }

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

  handleInputChange(e) {
    const { name, value } = e.target;
    this[name] = value ?? "";

    if (name === "product") {
      this.productValidate = false;
    } else if (name === "priority") {
      this.priorityValidate = false;
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
        product: this.product
      };

      const caseId = await createCaseRecord({ caseData });
      this.caseId = caseId;
      this.stageUploadPage = true;
      this.saving = false;
      await this.openModal();
    } catch (e) {
      const msg =
        e?.body?.message ||
        e?.message ||
        "An unexpected error occurred while submitting the case.";
      this.showToast("Error", msg, "error");
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
        if (select.name === "product") {
          this.productValidate = true;
          this.productValidateMsg = "Complete this field";
        }
        if (select.name === "priority") {
          this.priorityValidate = true;
          this.priorityValidateMsg = "Complete this field";
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
        product: this.product
      };

      const caseId = await createCaseRecord({ caseData });
      this.caseId = caseId;
      if (this.caseId && this.caseId.includes("500")) {
        this.showToast("Success", "Case created successfully!", "success");
        this.resetForm();
      }
      this.saving = false;
    } catch (e) {
      const msg =
        e?.body?.message ||
        e?.message ||
        "An unexpected error occurred while submitting the case.";
      this.showToast("Error", msg, "error");
    } finally {
      this.saving = false;
    }
  }

  get acceptedFormats() {
    return [".pdf", ".png", ".jpg", ".jpeg", ".iso"];
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
    this.files = [];
    this.fileNames = "";
  }

  handleUploadFinished(event) {
    try {
      const files = event?.detail?.files || [];
      // Note: Linking is handled by the ContentVersion trigger.
    } catch (err) {
      // no-op
    }
    this.stageUploadPage = false;
    this.uploadFilesCheck = false;
    this.stageThanks = true;
    // this.showToast("Success", "Case created successfully!", "success");
    // this.resetForm();
  }

  uploadFilesHandle() {
    this.uploadFilesCheck = !this.uploadFilesCheck;
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