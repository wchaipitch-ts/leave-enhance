/**
 * @description Batch Apex for advanced, automated Lead processing.
 * This version uses custom metadata-driven configuration and aligns to the revised
 * duplicate-handling requirements.
 */
public class BulkLeadConvertBatch implements Database.Batchable<sObject>, Database.Stateful {

    private static final String DUMMY_EMAIL = 'dummy@terraskythailandnoemailcheck.com';

    // Accessor for default dummy email to allow other classes to read fallback value safely
    public static String getDefaultDummyEmail() {
        return DUMMY_EMAIL;
    }

    // --- State variables for the summary report ---
    public Integer recordsProcessed = 0;
    private Integer successfulConversions = 0;
    private Integer failedConversions = 0;
    private Integer leadsDeletedAsDuplicates = 0;
    private Integer leadsMergedAsDuplicates = 0;
    private Integer contactsFlaggedAsDuplicates = 0;
    private Integer accountsFlaggedAsDuplicates = 0;

    @TestVisible private List<String> errorMessages = new List<String>();
    private final Integer BUFFER_MINUTES = 0;

    @TestVisible private List<Integer> mergeChunkSizes = new List<Integer>();

    private static LeadProcessConfig.Config getConfig() {
        return LeadProcessConfig.get();
    }

    private static Boolean isDummyNoEmail(Lead lead, LeadProcessConfig.Config config) {
        return lead != null
            && lead.Email != null
            && config.dummyEmailLower != null
            && lead.Email.toLowerCase() == config.dummyEmailLower
            && lead.leadHasNoEmail__c == true;
    }

    private void addError(LeadProcessConfig.Config config, String message) {
        if (errorMessages.size() < config.maxErrorLogs) {
            errorMessages.add(message);
        }
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        Datetime cutOffTime = System.now().addMinutes(-BUFFER_MINUTES);
        String query = 'SELECT Id, OwnerId, Email, Company, FirstName, LastName, '
                       + 'LastModifiedDate, leadHasNoEmail__c '
                       + 'FROM Lead '
                       + 'WHERE IsConverted = false AND Email != null '
                       + 'AND LastModifiedDate <= :cutOffTime';
        return Database.getQueryLocator(query);
    }

    public void execute(Database.BatchableContext bc, List<Lead> scope) {
        LeadProcessConfig.Config config = getConfig();
        if (scope.isEmpty()) { return; }

        List<Lead> dummyLeads = new List<Lead>();
        List<Lead> leadsWithRealEmail = new List<Lead>();
        for (Lead lead : scope) {
            if (isDummyNoEmail(lead, config)) {
                dummyLeads.add(lead);
            } else if (String.isNotBlank(lead.Email)) {
                leadsWithRealEmail.add(lead);
            }
        }

        List<Lead> leadsToProcess = new List<Lead>();

        if (!leadsWithRealEmail.isEmpty()) {
            Map<String, List<Lead>> leadsByEmail = new Map<String, List<Lead>>();
            for (Lead lead : leadsWithRealEmail) {
                String lowerEmail = lead.Email.toLowerCase();
                if (!leadsByEmail.containsKey(lowerEmail)) {
                    leadsByEmail.put(lowerEmail, new List<Lead>());
                }
                leadsByEmail.get(lowerEmail).add(lead);
            }

            for (String email : leadsByEmail.keySet()) {
                List<Lead> leadGroup = leadsByEmail.get(email);
                Lead masterLead = leadGroup[0];
                List<Lead> duplicatesToMerge = new List<Lead>();
                if (leadGroup.size() > 1) {
                    for (Integer i = 1; i < leadGroup.size(); i++) {
                        Lead candidate = leadGroup[i];
                        if (candidate.LastModifiedDate > masterLead.LastModifiedDate) {
                            duplicatesToMerge.add(masterLead);
                            masterLead = candidate;
                        } else {
                            duplicatesToMerge.add(candidate);
                        }
                    }
                }

                if (!duplicatesToMerge.isEmpty()) {
                    List<Lead> chunk = new List<Lead>();
                    for (Lead duplicateLead : duplicatesToMerge) {
                        chunk.add(duplicateLead);
                        if (chunk.size() == 2) {
                            mergeLeadChunk(masterLead, chunk, config);
                            chunk.clear();
                        }
                    }
                    if (!chunk.isEmpty()) {
                        mergeLeadChunk(masterLead, chunk, config);
                    }
                }
                leadsToProcess.add(masterLead);
            }
        }

        leadsToProcess.addAll(dummyLeads);

        if (leadsToProcess.isEmpty()) { return; }

        recordsProcessed += leadsToProcess.size();

        Map<Id, Lead> leadById = new Map<Id, Lead>();
        for (Lead lead : leadsToProcess) {
            leadById.put(lead.Id, lead);
        }

        Set<String> leadEmailsForQuery = new Set<String>();
        Set<String> normalizedCompanyNames = new Set<String>();
        Set<String> leadFirstNames = new Set<String>();
        Set<String> leadLastNames = new Set<String>();

        for (Lead lead : leadsToProcess) {
            if (!isDummyNoEmail(lead, config) && lead.Email != null) {
                leadEmailsForQuery.add(lead.Email.toLowerCase());
            }
            if (!isDummyNoEmail(lead, config) && String.isNotBlank(lead.Company)) {
                normalizedCompanyNames.add(StringUtils.normalizeCompanyName(lead.Company));
            }
            if (!isDummyNoEmail(lead, config) && String.isNotBlank(lead.FirstName)) {
                leadFirstNames.add(lead.FirstName);
            }
            if (!isDummyNoEmail(lead, config) && String.isNotBlank(lead.LastName)) {
                leadLastNames.add(lead.LastName);
            }
        }

        String convertedStatus = [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel;

        Map<String, List<Contact>> contactsByEmail = new Map<String, List<Contact>>();
        Map<Id, Id> contactAccountById = new Map<Id, Id>();
        if (!leadEmailsForQuery.isEmpty()) {
            for (Contact contact : [SELECT Id, AccountId, Email FROM Contact WHERE Email IN :leadEmailsForQuery]) {
                String lowerEmail = contact.Email.toLowerCase();
                if (!contactsByEmail.containsKey(lowerEmail)) {
                    contactsByEmail.put(lowerEmail, new List<Contact>());
                }
                contactsByEmail.get(lowerEmail).add(contact);
                contactAccountById.put(contact.Id, contact.AccountId);
            }
        }

        Map<String, List<Account>> accountsByNormalizedName = new Map<String, List<Account>>();
        if (!normalizedCompanyNames.isEmpty()) {
            for (Account accountRecord : [SELECT Id, Name, Normalized_Company_Name__c FROM Account WHERE Normalized_Company_Name__c IN :normalizedCompanyNames ORDER BY CreatedDate ASC]) {
                String normName = accountRecord.Normalized_Company_Name__c;
                if (!accountsByNormalizedName.containsKey(normName)) {
                    accountsByNormalizedName.put(normName, new List<Account>());
                }
                accountsByNormalizedName.get(normName).add(accountRecord);
            }
        }

        Map<String, Contact> contactsByNameAndAccount = new Map<String, Contact>();
        if (!leadFirstNames.isEmpty() && !leadLastNames.isEmpty()) {
            for (Contact contactRecord : [SELECT Id, AccountId, FirstName, LastName FROM Contact WHERE FirstName IN :leadFirstNames AND LastName IN :leadLastNames]) {
                String key = (contactRecord.AccountId + '-' + contactRecord.FirstName + '-' + contactRecord.LastName).toLowerCase();
                contactsByNameAndAccount.put(key, contactRecord);
                contactAccountById.put(contactRecord.Id, contactRecord.AccountId);
            }
        }

        List<Database.LeadConvert> leadConverts = new List<Database.LeadConvert>();
        List<Lead> leadsToDelete = new List<Lead>();
        Map<Id, Contact> contactsToUpdate = new Map<Id, Contact>();
        Map<Id, Account> accountsToUpdate = new Map<Id, Account>();
        List<String> normalizedCompanyKeysForConverts = new List<String>();
        List<Id> leadIdsForConverts = new List<Id>();
        @TestVisible List<Id> plannedContactIds = new List<Id>();
        @TestVisible List<Id> plannedAccountIds = new List<Id>();
        Set<Id> contactsFlaggedSet = new Set<Id>();
        Set<Id> accountsFlaggedSet = new Set<Id>();
        // Track new Accounts to create for orphan Contacts (no AccountId)
        List<Account> accountsToCreate = new List<Account>();
        List<Integer> pendingAccountIndexes = new List<Integer>();
        // De-dup staging: one staged account per normalized company per execute
        Map<String, Integer> stagedIndexByNormName = new Map<String, Integer>();
        Map<Integer, List<Integer>> stagedIndexToLcIndexes = new Map<Integer, List<Integer>>();

        for (Lead lead : leadsToProcess) {
            Boolean dummyPath = isDummyNoEmail(lead, config);
            List<Contact> matchingContacts = dummyPath || lead.Email == null ? null : contactsByEmail.get(lead.Email.toLowerCase());
            Boolean shouldConvert = true;

            if (!dummyPath && matchingContacts != null && !matchingContacts.isEmpty()) {
                if (matchingContacts.size() == 1) {
                    // handled later when building LeadConvert
                } else {
                    List<String> duplicateContactIds = new List<String>();
                    for (Contact contactMatch : matchingContacts) {
                        duplicateContactIds.add((String)contactMatch.Id);
                    }
                    String duplicateIdValue = String.join(duplicateContactIds, ',');
                    for (Contact contactMatch : matchingContacts) {
                        Contact contactUpdate = contactsToUpdate.containsKey(contactMatch.Id) ? contactsToUpdate.get(contactMatch.Id) : new Contact(Id = contactMatch.Id);
                        contactUpdate.Duplicate_Contact_Id__c = duplicateIdValue;
                        contactsToUpdate.put(contactMatch.Id, contactUpdate);
                        contactsFlaggedSet.add(contactMatch.Id);
                    }
                    leadsToDelete.add(lead);
                    shouldConvert = false;
                }
            }

            if (!shouldConvert) {
                continue;
            }

            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(lead.Id);
            lc.setOwnerId(lead.OwnerId);
            lc.setConvertedStatus(convertedStatus);
            lc.setDoNotCreateOpportunity(true);

            Id targetAccountId;
            String normalizedLeadCompany;
            // Track if we must create an Account for an orphan contact merge
            Boolean needsNewAccountForOrphanContact = false;
            String newAccountName;

            if (dummyPath) {
                if (config.dummyAccountId != null) {
                    lc.setAccountId(config.dummyAccountId);
                } else {
                    addError(config, 'Missing Dummy Account configuration. Lead Id: ' + lead.Id);
                }
            } else {
                if (matchingContacts != null && matchingContacts.size() == 1) {
                    // Ensure AccountId is set when merging into an existing Contact
                    if (matchingContacts[0].AccountId != null) {
                        lc.setAccountId(matchingContacts[0].AccountId);
                        targetAccountId = matchingContacts[0].AccountId;
                    } else {
                        // Existing Contact has no Account. Try company-based candidates; otherwise create an Account.
                        if (String.isNotBlank(lead.Company)) {
                            normalizedLeadCompany = StringUtils.normalizeCompanyName(lead.Company);
                            if (accountsByNormalizedName.containsKey(normalizedLeadCompany)) {
                                List<Account> candidateAccounts = accountsByNormalizedName.get(normalizedLeadCompany);
                                if (!candidateAccounts.isEmpty()) {
                                    targetAccountId = candidateAccounts[0].Id;
                                    lc.setAccountId(targetAccountId);
                                    if (candidateAccounts.size() > 1) {
                                        List<String> accountIds = new List<String>();
                                        for (Account candidate : candidateAccounts) {
                                            accountIds.add((String)candidate.Id);
                                        }
                                        String duplicateList = String.join(accountIds, ',');
                                        for (Account candidate : candidateAccounts) {
                                            Account accountUpdate = accountsToUpdate.containsKey(candidate.Id) ? accountsToUpdate.get(candidate.Id) : new Account(Id = candidate.Id);
                                            accountUpdate.Duplicate_Account_Id__c = duplicateList;
                                            accountsToUpdate.put(candidate.Id, accountUpdate);
                                            accountsFlaggedSet.add(candidate.Id);
                                        }
                                    }
                                } else {
                                    needsNewAccountForOrphanContact = true;
                                    newAccountName = lead.Company;
                                }
                            } else {
                                needsNewAccountForOrphanContact = true;
                                newAccountName = lead.Company;
                            }
                        } else {
                            needsNewAccountForOrphanContact = true;
                            newAccountName = (lead.LastName != null ? lead.LastName : 'Converted Lead');
                        }
                    }
                    lc.setContactId(matchingContacts[0].Id);
                }

                if (lc.getContactId() == null && String.isNotBlank(lead.Company)) {
                    normalizedLeadCompany = StringUtils.normalizeCompanyName(lead.Company);
                    if (accountsByNormalizedName.containsKey(normalizedLeadCompany)) {
                        List<Account> candidateAccounts = accountsByNormalizedName.get(normalizedLeadCompany);
                        if (!candidateAccounts.isEmpty()) {
                            targetAccountId = candidateAccounts[0].Id;
                            lc.setAccountId(targetAccountId);
                            if (candidateAccounts.size() > 1) {
                                List<String> accountIds = new List<String>();
                                for (Account candidate : candidateAccounts) {
                                    accountIds.add((String)candidate.Id);
                                }
                                String duplicateList = String.join(accountIds, ',');
                                for (Account candidate : candidateAccounts) {
                                    Account accountUpdate = accountsToUpdate.containsKey(candidate.Id) ? accountsToUpdate.get(candidate.Id) : new Account(Id = candidate.Id);
                                    accountUpdate.Duplicate_Account_Id__c = duplicateList;
                                    accountsToUpdate.put(candidate.Id, accountUpdate);
                                    accountsFlaggedSet.add(candidate.Id);
                                }
                            }
                        }
                    }
                }

                if (lc.getContactId() == null && targetAccountId != null && String.isNotBlank(lead.FirstName) && String.isNotBlank(lead.LastName)) {
                    String contactKey = (targetAccountId + '-' + lead.FirstName + '-' + lead.LastName).toLowerCase();
                    if (contactsByNameAndAccount.containsKey(contactKey)) {
                        lc.setContactId(contactsByNameAndAccount.get(contactKey).Id);
                    }
                }
            }

            Integer lcIndex = leadConverts.size();
            leadConverts.add(lc);
            normalizedCompanyKeysForConverts.add(dummyPath ? null : normalizedLeadCompany);
            leadIdsForConverts.add(lead.Id);
            plannedContactIds.add(lc.getContactId());
            plannedAccountIds.add(lc.getAccountId());
            // If we need to create an Account for an orphan Contact, stage it now and associate to this LC index
            if (!dummyPath && lc.getContactId() != null && lc.getAccountId() == null) {
                if (needsNewAccountForOrphanContact == true) {
                    // Determine a staging key to dedupe by normalized company
                    String stageKey;
                    if (String.isNotBlank(normalizedLeadCompany)) {
                        stageKey = normalizedLeadCompany;
                    } else if (String.isNotBlank(newAccountName)) {
                        stageKey = StringUtils.normalizeCompanyName(newAccountName);
                    } else {
                        stageKey = null;
                    }

                    if (stageKey != null && stagedIndexByNormName.containsKey(stageKey)) {
                        Integer stagedIdx = stagedIndexByNormName.get(stageKey);
                        if (!stagedIndexToLcIndexes.containsKey(stagedIdx)) {
                            stagedIndexToLcIndexes.put(stagedIdx, new List<Integer>());
                        }
                        stagedIndexToLcIndexes.get(stagedIdx).add(lcIndex);
                    } else {
                        accountsToCreate.add(new Account(Name = newAccountName));
                        Integer stagedIdx = accountsToCreate.size() - 1;
                        if (stageKey != null) {
                            stagedIndexByNormName.put(stageKey, stagedIdx);
                        }
                        stagedIndexToLcIndexes.put(stagedIdx, new List<Integer>{ lcIndex });
                        // Keep legacy index list for alignment; not used in mapping anymore
                        pendingAccountIndexes.add(lcIndex);
                    }
                }
            }
        }

        // Create any required Accounts for orphan Contacts and attach to corresponding LeadConverts
        if (!accountsToCreate.isEmpty()) {
            Database.SaveResult[] cr = Database.insert(accountsToCreate, false);
            for (Integer i = 0; i < cr.size(); i++) {
                if (cr[i].isSuccess()) {
                    Id accId = cr[i].getId();
                    List<Integer> lcIdxs = stagedIndexToLcIndexes.get(i);
                    if (lcIdxs != null) {
                        for (Integer li : lcIdxs) {
                            leadConverts[li].setAccountId(accId);
                            plannedAccountIds[li] = accId;
                        }
                    }
                } else if (cr[i].getErrors() != null && cr[i].getErrors().size() > 0) {
                    addError(getConfig(), 'Failed to create Account for orphan Contact merge: ' + cr[i].getErrors()[0].getMessage());
                }
            }
        }

        if (!leadConverts.isEmpty()) {
            // Defensive: ensure AccountId accompanies ContactId regardless of getter behavior
            Set<Id> contactIdsToBackfill = new Set<Id>();
            for (Integer i = 0; i < leadConverts.size(); i++) {
                Id pc = plannedContactIds[i];
                Id pa = plannedAccountIds[i];
                if (pc != null) {
                    if (pa == null) {
                        Id accId = contactAccountById.get(pc);
                        if (accId != null) {
                            plannedAccountIds[i] = accId;
                        } else {
                            contactIdsToBackfill.add(pc);
                        }
                    }
                }
            }
            if (!contactIdsToBackfill.isEmpty()) {
                Map<Id, Contact> fetched = new Map<Id, Contact>([
                    SELECT Id, AccountId FROM Contact WHERE Id IN :contactIdsToBackfill
                ]);
                for (Integer i = 0; i < leadConverts.size(); i++) {
                    Id pc = plannedContactIds[i];
                    if (pc != null && plannedAccountIds[i] == null) {
                        Contact c = fetched.get(pc);
                        if (c != null && c.AccountId != null) {
                            plannedAccountIds[i] = c.AccountId;
                        }
                    }
                }
            }
            // Re-apply the planned values to the LeadConvert objects explicitly
            for (Integer i = 0; i < leadConverts.size(); i++) {
                Database.LeadConvert lcSet = leadConverts[i];
                if (plannedContactIds[i] != null) {
                    lcSet.setContactId(plannedContactIds[i]);
                }
                if (plannedAccountIds[i] != null) {
                    lcSet.setAccountId(plannedAccountIds[i]);
                }
            }
            Database.LeadConvertResult[] lcrList = Database.convertLead(leadConverts, false);
            for (Integer idx = 0; idx < lcrList.size(); idx++) {
                Database.LeadConvertResult lcr = lcrList[idx];
                Id sourceLeadId = leadIdsForConverts[idx];
                Lead sourceLead = leadById.get(sourceLeadId);
                if (lcr.isSuccess()) {
                    successfulConversions++;
                    String normalizedKey = normalizedCompanyKeysForConverts[idx];
                    Id convertedAccountId = lcr.getAccountId();
                    if (normalizedKey != null && convertedAccountId != null) {
                        if (!accountsByNormalizedName.containsKey(normalizedKey)) {
                            accountsByNormalizedName.put(normalizedKey, new List<Account>());
                        }
                        Boolean alreadyTracked = false;
                        for (Account trackedAccount : accountsByNormalizedName.get(normalizedKey)) {
                            if (trackedAccount.Id == convertedAccountId) {
                                alreadyTracked = true;
                                break;
                            }
                        }
                        if (!alreadyTracked) {
                            accountsByNormalizedName.get(normalizedKey).add(new Account(Id = convertedAccountId));
                        }
                    }

                    Id contactId = lcr.getContactId();
                    if (contactId != null && sourceLead != null && String.isNotBlank(sourceLead.Company)) {
                        Contact contactUpdate = contactsToUpdate.containsKey(contactId) ? contactsToUpdate.get(contactId) : new Contact(Id = contactId);
                        contactUpdate.Original_Lead_Company__c = sourceLead.Company;
                        contactsToUpdate.put(contactId, contactUpdate);
                    }
                } else {
                    failedConversions++;
                    String errors = '';
                    for (Database.Error err : lcr.getErrors()) {
                        errors += err.getMessage() + '. ';
                    }
                    addError(config, 'Conversion failed for Lead ID: ' + sourceLeadId + '. Reason: ' + errors);
                }
            }
        }

        try {
            if (!leadsToDelete.isEmpty()) {
                Database.delete(leadsToDelete, false);
                leadsDeletedAsDuplicates += leadsToDelete.size();
            }
            List<Contact> contactUpdates = new List<Contact>(contactsToUpdate.values());
            if (!contactUpdates.isEmpty()) {
                Database.update(contactUpdates, false);
                contactsFlaggedAsDuplicates += contactsFlaggedSet.size();
            }
            List<Account> accountUpdates = new List<Account>(accountsToUpdate.values());
            if (!accountUpdates.isEmpty()) {
                Database.update(accountUpdates, false);
                accountsFlaggedAsDuplicates += accountsFlaggedSet.size();
            }
        } catch (DmlException e) {
            addError(config, 'DML failed during final execution. Error: ' + e.getMessage());
        }
    }

    private void mergeLeadChunk(Lead masterLead, List<Lead> chunk, LeadProcessConfig.Config config) {
        if (chunk == null || chunk.isEmpty()) {
            return;
        }
        mergeChunkSizes.add(chunk.size());
        try {
            Database.merge(new Lead(Id = masterLead.Id), chunk);
            leadsMergedAsDuplicates += chunk.size();
        } catch (DmlException e) {
            failedConversions += chunk.size();
            addError(config, 'Failed to merge lead chunk for Master Lead ID: ' + masterLead.Id + '. Error: ' + e.getMessage());
        }
    }

    public void finish(Database.BatchableContext bc) {
        String summaryMessage = 'Hourly Lead Auto-Process Result:\n'
                                + 'Total Leads Processed: ' + recordsProcessed + '\n'
                                + 'Successful Conversions: ' + successfulConversions + '\n'
                                + 'Failed Operations: ' + failedConversions + '\n'
                                + 'Leads Merged as Duplicates: ' + leadsMergedAsDuplicates + '\n'
                                + 'Leads Deleted as Duplicates: ' + leadsDeletedAsDuplicates + '\n'
                                + 'Contacts Flagged: ' + contactsFlaggedAsDuplicates + '\n'
                                + 'Accounts Flagged: ' + accountsFlaggedAsDuplicates;
        if (!errorMessages.isEmpty()) {
            summaryMessage += '\n\nError Details:\n' + String.join(errorMessages, '\n');
        }
        System.debug(summaryMessage);
    }
}