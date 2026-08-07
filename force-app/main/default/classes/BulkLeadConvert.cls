public with sharing class BulkLeadConvert {

    // ---- cache converted status ----
    private static String CONVERTED_STATUS;
    private static String getConvertedStatus() {
        if (CONVERTED_STATUS == null) {
            CONVERTED_STATUS = [
                SELECT MasterLabel FROM LeadStatus
                WHERE IsConverted = true
                ORDER BY SortOrder ASC
                LIMIT 1
            ].MasterLabel;
        }
        return CONVERTED_STATUS;
    }

    // ========= Public API (รักษา signature เดิม) =========
    public static Database.LeadConvertResult convertOne(Id leadId, Boolean createOpportunity) {
        return convertOne(leadId, createOpportunity, /*alwaysBypassDedupe*/ false, /*useDupPrecheck*/ false);
    }
    public static List<Database.LeadConvertResult> convertMany(List<Id> leadIds, Boolean createOpportunity) {
        return convertMany(leadIds, createOpportunity, /*alwaysBypassDedupe*/ false, /*useDupPrecheck*/ false);
    }

    // ========= Overloads (เพิ่มสวิตช์) =========
    public static Database.LeadConvertResult convertOne(
        Id leadId,
        Boolean createOpportunity,
        Boolean alwaysBypassDedupe,
        Boolean useDupPrecheck
    ) {
        try {
            Lead ld = [
                SELECT Id, OwnerId, IsConverted, Company, Email, Website,
                       Street, City, State, PostalCode, Country
                FROM Lead WHERE Id = :leadId LIMIT 1
            ];
            if (String.isBlank(ld.Email) || ld.IsConverted) return null;

            // (1) dup pre-check (optional)
            if (useDupPrecheck) {
                if (isLikelyDuplicate(new List<Lead>{ ld })) {
                    System.debug(LoggingLevel.WARN, 'Skip by dup-precheck: LeadId=' + ld.Id);
                    return null;
                }
            }

            // ===== Matching =====
            Contact matchedContact = [
                SELECT Id, AccountId
                FROM Contact
                WHERE Email = :ld.Email
                LIMIT 1
            ].isEmpty() ? null : [
                SELECT Id, AccountId
                FROM Contact
                WHERE Email = :ld.Email
                LIMIT 1
            ][0];

            Account matchedAcc =
                (matchedContact != null && matchedContact.AccountId != null)
                ? new Account(Id = matchedContact.AccountId)
                : null;

            // ---------- 2.1 Domain match (Email ⟷ Account.Website) ----------
            if (matchedAcc == null && !String.isBlank(ld.Email)) {
                String leadDomain = emailDomain(ld.Email); // e.g., zip1993.co.th
                if (!String.isBlank(leadDomain)) {
                    // ดึงบัญชีที่มี Website ใส่ไว้ เพื่อเทียบโดเมนแบบละเอียด
                    for (Account a : [SELECT Id, Website FROM Account WHERE Website != null LIMIT 50000]) {
                        String accDom = websiteDomain(a.Website);
                        if (accDom == null) continue;
                        // เทียบเท่ากัน หรือเป็น subdomain กัน
                        if (accDom.equalsIgnoreCase(leadDomain)
                            || accDom.endsWith('.' + leadDomain)
                            || leadDomain.endsWith('.' + accDom)) {
                            matchedAcc = a; break;
                        }
                    }
                }
            }

            // ---------- 2.2 Cleaned Company exact match ----------
            if (matchedAcc == null && !String.isBlank(ld.Company)) {
                String cleanLead = normalizeCompany(ld.Company);
                if (!String.isBlank(cleanLead)) {
                    // preload เฉพาะชื่อที่ “น่าจะ” เท่ากันหลัง normalize (ลด SOQL รอบ)
                    // เทคนิค: หา exact ก่อน ถ้าไม่เจอค่อยดึง batch แล้วเทียบ normalize ใน Apex
                    List<Account> byName = [SELECT Id, Name FROM Account WHERE Name = :ld.Company LIMIT 1];
                    if (!byName.isEmpty()) {
                        matchedAcc = byName[0];
                    } else {
                        // ดึง candidates จำนวนจำกัด (เริ่มจากตัวอักษรแรก ๆ เหมือนกัน ลด cardinality)
                        String prefix = ld.Company.left(Math.min(10, ld.Company.length()));
                        List<Account> cands = [
                            SELECT Id, Name
                            FROM Account
                            WHERE Name LIKE :('%' + String.escapeSingleQuotes(prefix) + '%')
                            LIMIT 50000
                        ];
                        for (Account a : cands) {
                            if (normalizeCompany(a.Name) == cleanLead) { matchedAcc = a; break; }
                        }
                    }
                }
            }

            // ---------- 2.3 Address match ----------
            if (matchedAcc == null && (!String.isBlank(ld.City) || !String.isBlank(ld.PostalCode) || !String.isBlank(ld.Country))) {
                for (Account a : [
                    SELECT Id, BillingCity, BillingPostalCode, BillingCountry
                    FROM Account
                    LIMIT 50000
                ]) {
                    Boolean cityMatch    = (String.isBlank(ld.City)       || (a.BillingCity != null       && a.BillingCity.equalsIgnoreCase(ld.City)));
                    Boolean postalMatch  = (String.isBlank(ld.PostalCode) || (a.BillingPostalCode != null && a.BillingPostalCode.equalsIgnoreCase(ld.PostalCode)));
                    Boolean countryMatch = (String.isBlank(ld.Country)    || (a.BillingCountry != null    && a.BillingCountry.equalsIgnoreCase(ld.Country)));
                    if (cityMatch && postalMatch && countryMatch) { matchedAcc = a; break; }
                }
            }
            // ---------- 2.4 otherwise → new account (ทำโดย convert เอง) ----------

            // Build LeadConvert
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(ld.Id);
            lc.setConvertedStatus(getConvertedStatus());
            lc.setDoNotCreateOpportunity(!createOpportunity);
            lc.setSendNotificationEmail(false);

            // Owner for new records
            Id fallbackOwner = UserInfo.getUserId();
            User ldOwner = [SELECT Id, IsActive FROM User WHERE Id = :ld.OwnerId LIMIT 1];
            lc.setOwnerId((ldOwner != null && ldOwner.IsActive) ? ldOwner.Id : fallbackOwner);

            // bypass flags (คู่กันเสมอ)
            Boolean reuseExisting = (matchedAcc != null) || (matchedContact != null);
            Boolean bypass = alwaysBypassDedupe ? true : reuseExisting;
            if (matchedAcc != null)      lc.setAccountId(matchedAcc.Id);
            if (matchedContact != null)  lc.setContactId(matchedContact.Id);
            lc.setBypassAccountDedupeCheck(bypass);
            lc.setBypassContactDedupeCheck(bypass);

            try {
                return Database.convertLead(lc, false); // allOrNone=false
            } catch (Exception ce) {
                System.debug(LoggingLevel.ERROR, 'convertOne failed: leadId=' + leadId + ' msg=' + ce.getMessage());
                return null;
            }

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'convertOne fatal: leadId=' + leadId + ' msg=' + e.getMessage());
            return null;
        }
    }

    public static List<Database.LeadConvertResult> convertMany(
        List<Id> leadIds,
        Boolean createOpportunity,
        Boolean alwaysBypassDedupe,
        Boolean useDupPrecheck
    ) {
        List<Database.LeadConvertResult> results = new List<Database.LeadConvertResult>();
        if (leadIds == null || leadIds.isEmpty()) return results;

        try {
            // load
            List<Lead> leads = [
                SELECT Id, OwnerId, IsConverted, Company, Email, Website,
                       Street, City, State, PostalCode, Country
                FROM Lead
                WHERE Id IN :leadIds
            ];
            if (leads.isEmpty()) return results;

            // filter has email, not converted, unique by email
            List<Lead> scope = new List<Lead>();
            Set<String> seenEmail = new Set<String>();
            for (Lead l : leads) {
                if (String.isBlank(l.Email) || l.IsConverted) continue;
                String k = l.Email.toLowerCase();
                if (seenEmail.add(k)) scope.add(l);
            }
            if (scope.isEmpty()) return results;

            // (1) dup pre-check (optional): ตัดตัวที่จะชน rule ออกไปเลย
            Set<Id> dupLeadIds = new Set<Id>();
            if (useDupPrecheck) {
                dupLeadIds = findDupLeadIds(scope);
                if (!dupLeadIds.isEmpty()) {
                    System.debug(LoggingLevel.WARN, 'Skip by dup-precheck size=' + dupLeadIds.size() + ' -> ' + dupLeadIds);
                }
            }

            // preload owners
            Set<Id> ownerIds = new Set<Id>();
            for (Lead l : scope) ownerIds.add(l.OwnerId);
            Map<Id, User> owners = new Map<Id, User>([
                SELECT Id, IsActive FROM User WHERE Id IN :ownerIds
            ]);
            Id fallbackOwner = UserInfo.getUserId();

            // preload contacts by email
            Set<String> emails = new Set<String>();
            for (Lead l : scope) emails.add(l.Email.toLowerCase());
            Map<String, Contact> contactByEmail = new Map<String, Contact>();
            if (!emails.isEmpty()) {
                for (Contact c : [
                    SELECT Id, AccountId, Email
                    FROM Contact WHERE Email IN :emails
                ]) if (c.Email != null) contactByEmail.put(c.Email.toLowerCase(), c);
            }

            // ---------- domain candidates (จาก email domains) ----------
            Set<String> domainKeywords = new Set<String>();
            for (Lead l : scope) {
                String dom = emailDomain(l.Email);
                String key = secondLevelKeyword(dom);
                if (!String.isBlank(key)) domainKeywords.add(key);
            }
            List<Account> websiteCandidates = new List<Account>();
            if (!domainKeywords.isEmpty()) {
                List<String> orParts = new List<String>();
                Integer cnt = 0, MAX_OR = 20;
                for (String k : domainKeywords) {
                    orParts.add('Website LIKE \'%' + String.escapeSingleQuotes(k) + '%\'');
                    if (++cnt == MAX_OR) {
                        websiteCandidates.addAll((List<Account>)Database.query(
                            'SELECT Id, Name, Website, BillingCity, BillingPostalCode, BillingCountry ' +
                            'FROM Account WHERE Website != null AND (' + String.join(orParts, ' OR ') + ')'
                        ));
                        orParts.clear(); cnt = 0;
                    }
                }
                if (!orParts.isEmpty()) {
                    websiteCandidates.addAll((List<Account>)Database.query(
                        'SELECT Id, Name, Website, BillingCity, BillingPostalCode, BillingCountry ' +
                        'FROM Account WHERE Website != null AND (' + String.join(orParts, ' OR ') + ')'
                    ));
                }
            }
            Map<String, Account> accountByWebsiteDomain = new Map<String, Account>();
            for (Account a : websiteCandidates) {
                String dom = websiteDomain(a.Website);
                if (!String.isBlank(dom)) {
                    String key = dom.toLowerCase();
                    if (!accountByWebsiteDomain.containsKey(key)) accountByWebsiteDomain.put(key, a);
                }
            }

            // ---------- cleaned-name preload ----------
            Set<String> companyNames = new Set<String>();
            for (Lead l : scope) if (!String.isBlank(l.Company)) companyNames.add(l.Company);
            Map<String, Account> accountByExactName = new Map<String, Account>();
            if (!companyNames.isEmpty()) {
                for (Account a : [
                    SELECT Id, Name, Website, BillingCity, BillingPostalCode, BillingCountry
                    FROM Account WHERE Name IN :companyNames
                ]) accountByExactName.put(a.Name, a);
            }
            // ทำ index จากชื่อที่ normalize แล้ว (ใช้จาก accounts ข้างบนและ websiteCandidates เพื่อประหยัด SOQL)
            Map<String, Account> accountByCleanName = new Map<String, Account>();
            for (Account a : accountByExactName.values()) {
                String k = normalizeCompany(a.Name);
                if (!String.isBlank(k) && !accountByCleanName.containsKey(k)) accountByCleanName.put(k, a);
            }
            for (Account a : websiteCandidates) {
                String k = normalizeCompany(a.Name);
                if (!String.isBlank(k) && !accountByCleanName.containsKey(k)) accountByCleanName.put(k, a);
            }

            // preload accounts by address (เลือกตามประเทศเพื่อลดปริมาณ)
            Set<String> countries = new Set<String>();
            for (Lead l : scope) if (!String.isBlank(l.Country)) countries.add(l.Country);
            List<Account> accountsByAddress =
                (countries.isEmpty())
                ? [SELECT Id, Name, Website, BillingCity, BillingPostalCode, BillingCountry
                   FROM Account WHERE BillingCountry != null LIMIT 2000]
                : [SELECT Id, Name, Website, BillingCity, BillingPostalCode, BillingCountry
                   FROM Account WHERE BillingCountry IN :countries LIMIT 5000];

            String convertedStatus = getConvertedStatus();

            // build jobs
            List<Database.LeadConvert> jobs = new List<Database.LeadConvert>();
            for (Lead l : scope) {
                if (dupLeadIds.contains(l.Id)) continue; // skip ที่ชน rule

                Database.LeadConvert lc = new Database.LeadConvert();
                lc.setLeadId(l.Id);
                lc.setConvertedStatus(convertedStatus);
                lc.setDoNotCreateOpportunity(!createOpportunity);
                lc.setSendNotificationEmail(false);

                User o = owners.get(l.OwnerId);
                lc.setOwnerId((o != null && o.IsActive) ? o.Id : fallbackOwner);

                // ===== Matching Order (2.1 → 2.2 → 2.3) =====
                Contact mc = contactByEmail.get(l.Email.toLowerCase());
                Account  ma = (mc != null && mc.AccountId != null) ? new Account(Id = mc.AccountId) : null;

                // 2.1 Domain
                if (ma == null) {
                    String dom = emailDomain(l.Email);
                    if (!String.isBlank(dom)) {
                        dom = dom.toLowerCase();
                        Account byDom = accountByWebsiteDomain.get(dom);
                        if (byDom == null) {
                            for (String accDom : accountByWebsiteDomain.keySet()) {
                                if (accDom.endsWith('.' + dom) || dom.endsWith('.' + accDom)) {
                                    byDom = accountByWebsiteDomain.get(accDom); break;
                                }
                            }
                        }
                        if (byDom != null) ma = byDom;
                    }
                }

                // 2.2 Cleaned Company exact
                if (ma == null && !String.isBlank(l.Company)) {
                    String cleanLead = normalizeCompany(l.Company);
                    if (!String.isBlank(cleanLead)) {
                        Account byExact = accountByExactName.get(l.Company);
                        if (byExact != null) {
                            ma = byExact;
                        } else {
                            Account byClean = accountByCleanName.get(cleanLead);
                            if (byClean != null) ma = byClean;
                        }
                    }
                }

                // 2.3 Address
                if (ma == null && (!String.isBlank(l.City) || !String.isBlank(l.PostalCode) || !String.isBlank(l.Country))) {
                    for (Account a : accountsByAddress) {
                        Boolean cityMatch    = (String.isBlank(l.City)       || (a.BillingCity != null       && a.BillingCity.equalsIgnoreCase(l.City)));
                        Boolean postalMatch  = (String.isBlank(l.PostalCode) || (a.BillingPostalCode != null && a.BillingPostalCode.equalsIgnoreCase(l.PostalCode)));
                        Boolean countryMatch = (String.isBlank(l.Country)    || (a.BillingCountry != null    && a.BillingCountry.equalsIgnoreCase(l.Country)));
                        if (countryMatch && cityMatch && postalMatch) { ma = a; break; }
                    }
                }

                Boolean reuseExisting = (ma != null) || (mc != null);
                Boolean bypass = alwaysBypassDedupe ? true : reuseExisting;
                if (ma != null) lc.setAccountId(ma.Id);
                if (mc != null) lc.setContactId(mc.Id);
                lc.setBypassAccountDedupeCheck(bypass);
                lc.setBypassContactDedupeCheck(bypass);

                jobs.add(lc);
            }

            if (jobs.isEmpty()) return results;

            // convert (allOrNone=false)
            try {
                results = Database.convertLead(jobs, false);
            } catch (Exception bulkEx) {
                System.debug(LoggingLevel.WARN, 'Bulk convert failed → fallback per lead: ' + bulkEx.getMessage());
                results = new List<Database.LeadConvertResult>();
                for (Database.LeadConvert lc : jobs) {
                    try {
                        results.add(Database.convertLead(lc, false));
                    } catch (Exception oneEx) {
                        System.debug(LoggingLevel.ERROR, 'Per-lead failed: leadId=' + lc.getLeadId() + ' msg=' + oneEx.getMessage());
                        results.add(null);
                    }
                }
            }

            // summary
            Integer ok = 0, fail = 0;
            for (Database.LeadConvertResult r : results) {
                if (r != null && r.isSuccess()) ok++; else fail++;
            }
            System.debug(LoggingLevel.INFO, 'BulkLeadConvert.convertMany: OK=' + ok + ' FAIL=' + fail + ' / total=' + results.size());
            return results;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'convertMany fatal: size=' + (leadIds==null?0:leadIds.size()) + ' msg=' + e.getMessage());
            return results;
        }
    }

   // คืน true ถ้า list ที่ส่งมา "มีอย่างน้อยหนึ่งตัว" ที่ match duplicate rule
    private static Boolean isLikelyDuplicate(List<Lead> leads) {
        if (leads == null || leads.isEmpty()) return false;
        try {
            List<SObject> sobjs = new List<SObject>(); sobjs.addAll(leads);
            List<Datacloud.FindDuplicatesResult> res = Datacloud.FindDuplicates.findDuplicates(sobjs);
            for (Datacloud.FindDuplicatesResult fr : res) {
                if (!fr.isSuccess()) continue;
                if (!fr.getDuplicateResults().isEmpty()) return true;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'findDuplicates failed (ignored): ' + e.getMessage());
        }
        return false;
    }

    // คืน Set ของ Lead.Id ที่ match duplicate rule (จะเอาไว้ skip)
    private static Set<Id> findDupLeadIds(List<Lead> leads) {
        Set<Id> out = new Set<Id>();
        if (leads == null || leads.isEmpty()) return out;
        try {
            List<SObject> sobjs = new List<SObject>(); sobjs.addAll(leads);
            List<Datacloud.FindDuplicatesResult> res = Datacloud.FindDuplicates.findDuplicates(sobjs);
            for (Integer i = 0; i < res.size(); i++) {
                Datacloud.FindDuplicatesResult fr = res[i];
                Lead src = leads[i];
                if (!fr.isSuccess()) continue;
                if (!fr.getDuplicateResults().isEmpty()) out.add(src.Id);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'findDuplicates failed (ignored): ' + e.getMessage());
        }
        return out;
    }

    // ========= Helpers =========
    private static String emailDomain(String email){
        if (String.isBlank(email) || !email.contains('@')) return null;
        return email.substringAfter('@').toLowerCase().trim();
    }

    // NEW: แข็งแรงขึ้น รองรับ scheme/credentials/port/path/query/fragment และตัด www./จุดท้าย
    private static String websiteDomain(String url) {
        if (String.isBlank(url)) return null;
        String d = url.trim().toLowerCase();
        // ตัด scheme
        d = d.replaceAll('^[a-z]+://', '');
        // ตัด credentials user:pass@
        Integer at = d.indexOf('@');
        Integer firstSlash = d.indexOf('/');
        if (at > -1 && (firstSlash == -1 || at < firstSlash)) d = d.substring(at + 1);
        // ตัด path/query/fragment
        Integer slash = d.indexOf('/'); if (slash > -1) d = d.substring(0, slash);
        Integer q = d.indexOf('?');     if (q     > -1) d = d.substring(0, q);
        Integer hash = d.indexOf('#');  if (hash  > -1) d = d.substring(0, hash);
        // ตัด port
        Integer colon = d.indexOf(':'); if (colon > -1) d = d.substring(0, colon);
        // ตัด www. และจุดท้าย
        if (d.startsWith('www.')) d = d.substring(4);
        if (d.endsWith('.')) d = d.substring(0, d.length()-1);
        d = d.trim();
        return String.isBlank(d) ? null : d;
    }

    // ใช้เป็น keyword ค้น Accounts โดย LIKE (ลด SOQL) เช่น zip1993 จาก zip1993.co.th
    private static String secondLevelKeyword(String domain){
        if (String.isBlank(domain)) return null;
        Integer dot = domain.indexOf('.');
        return (dot > 0) ? domain.substring(0, dot) : domain;
    }

    // Clean company: lower + ตัดคำลงท้ายยอดฮิต + ลบอักขระไม่ใช่ตัวอักษร/ตัวเลข
    private static String normalizeCompany(String name) {
        if (String.isBlank(name)) return null;
        String s = name.toLowerCase().trim();

        // ตัดคำลงท้าย/คำนำหน้าที่พบบ่อย (ENG/TH)
        // หมายเหตุ: ใช้ regex แบบหยาบเพื่อหลีกเลี่ยง dependency กับ custom formula field
        s = s.replaceAll('\\b(public company limited|company limited|co\\.,?\\s*ltd\\.?|co\\s*ltd|limited|ltd|inc\\.?|corp\\.?|corporation)\\b', '');
        s = s.replaceAll('\\b(บริษัท|จำกัด|บจก\\.?|หจก\\.?|ห้างหุ้นส่วนจำกัด)\\b', '');

        // ลบอักขระที่ไม่ใช่ a-z0-9 หรืออักษรไทย (ให้เหลือตัวเปรียบเทียบ)
        s = s.replaceAll('[^a-z0-9ก-ฮ]+', '');

        return s;
    }
}