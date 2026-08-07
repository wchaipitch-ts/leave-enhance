trigger ContentVersionLinkToCaseTrigger on ContentVersion (after insert) {
    ContentVersionLinkHandler.linkToCase(Trigger.new);
}