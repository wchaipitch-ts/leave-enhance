({
    afterRender : function(cmp,helper){
        // cmp.find("selLanguage").set("v.language", 'en-US');
        // language selector element
        var elements = document.getElementsByClassName("slds-button slds-button_icon search-triggerButton js-search-triggerButton slds-button_icon-bare slds-button_icon-inverse");
        // set icon
        if(elements.length>0){
            elements[0].firstChild.iconName = 'utility:http';
        }
    },
    handleLanguageSelect: function (cmp, event, helper) {
        const selectedLanguageCode = event.getParam('value');
        const currentUrl = window.location.pathname;
        const url = window.location.origin + currentUrl + '?language='+selectedLanguageCode;
        window.location.href = url;
    }
})