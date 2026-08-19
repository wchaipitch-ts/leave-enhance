/*
 * LEAVE-42. The Files related list deletes the ContentDocument rather than the link, and
 * a cascade does not fire the ContentDocumentLink trigger, so this is the path that has
 * to catch somebody removing the certificate from a request already with an approver.
 *
 * Fires on every file deletion in the org. LeaveDocumentPolicy gives up in its first few
 * lines when nothing being deleted is attached to a leave request.
 */
trigger ContentDocumentTrigger on ContentDocument (before delete) {
    LeaveDocumentPolicy.blockDocumentRemoval(Trigger.old);
}
