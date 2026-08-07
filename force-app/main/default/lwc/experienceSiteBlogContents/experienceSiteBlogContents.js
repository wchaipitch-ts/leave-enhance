import { LightningElement } from 'lwc';
import { NavigationMixin } from "lightning/navigation";

export default class ExperienceSiteBlogContents extends NavigationMixin(LightningElement) {
    connectedCallback() {
        this.handleNavigate();
      }
    handleNavigate() {
      const config = {
          type: 'standard__webPage',
          attributes: {
              url: 'https://medium.com/@terrasky_thailand'
          }
      };
      this[NavigationMixin.Navigate](config);
    }
  }