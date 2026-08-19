/*
 * Unlinking a file from a request without deleting the file - the API route,
 * rather than anything the Files related list offers. The companion to
 * ContentDocumentTrigger, which covers the deletion users actually perform.
 */
trigger ContentDocumentLinkTrigger on ContentDocumentLink (before delete) {
    LeaveDocumentPolicy.blockLinkRemoval(Trigger.old);
}