import { api } from "lwc";
import LightningModal from "lightning/modal";

export default class NotificationModal extends LightningModal {
  @api message; // pass in content from parent

  handleOkay() {
    this.close("ok"); // resolves the promise in the parent
  }
}