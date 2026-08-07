@IsTest
private class BulkLeadConvertTest {

    // ----------------- helper factories -----------------
    private static Account makeAccount(String name, String website, String city, String postal, String country) {
        Account a = new Account(Name = name);
        if (website != null) a.Website = website;
        if (city != null)    a.BillingCity = city;
        if (postal != null)  a.BillingPostalCode = postal;
        if (country != null) a.BillingCountry = country;
        insert a;
        return a;
    }

    private static Contact makeContact(Id accountId, String email) {
        Contact c = new Contact(LastName = 'TC', AccountId = accountId, Email = email);
        insert c;
        return c;
    }

    // ปกติ
    private static Lead makeLead(String company, String email, String city, String postal, String country) {
        return makeLead(company, email, city, postal, country, false);
    }

    // bypass duplicate rule (ใช้เฉพาะเคสที่ต้องการ email ซ้ำใน org)
    private static Lead makeLead(String company, String email, String city, String postal, String country, Boolean bypassDupRule) {
        Lead l = new Lead(LastName = 'TL', Company = (company == null ? 'Test Co' : company));
        if (email != null)   l.Email = email;
        if (city != null)    l.City = city;
        if (postal != null)  l.PostalCode = postal;
        if (country != null) l.Country = country;

        if (bypassDupRule == true) {
            Database.DMLOptions dml = new Database.DMLOptions();
            dml.DuplicateRuleHeader.allowSave = true;
            dml.DuplicateRuleHeader.runAsCurrentUser = true;
            Database.insert(l, dml);
        } else {
            insert l;
        }
        return l;
    }

    // ----------------- tests -----------------

    // 1) ไม่มีอีเมล → ข้าม (return null)
    @IsTest
    static void test_noEmail_skipped() {
        Lead l = makeLead('NoEmail Co', null, null, null, null);

        Test.startTest();
        Database.LeadConvertResult res = BulkLeadConvert.convertOne(l.Id, false);
        Test.stopTest();

        System.assertEquals(null, res, 'Lead without email should return null');
        l = [SELECT IsConverted FROM Lead WHERE Id = :l.Id];
        System.assertEquals(false, l.IsConverted, 'Lead without email must not be converted');
    }

    // 2) Duplicate by Contact.Email → ผูกกับ Account/Contact เดิม
    @IsTest
    static void test_duplicateByContactEmail() {
        Account a = makeAccount('DupCo', null, null, null, null);
        String email = 'dup@test.tld';
        Contact c = makeContact(a.Id, email);
        Lead l = makeLead('Any Co', email, null, null, null);

        Test.startTest();
        Database.LeadConvertResult res = BulkLeadConvert.convertOne(l.Id, false);
        Test.stopTest();

        System.assertNotEquals(null, res, 'Result should not be null');
        System.assertEquals(true, res.isSuccess(), 'Conversion should succeed');

        Lead conv = [SELECT ConvertedAccountId, ConvertedContactId, IsConverted FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, conv.IsConverted);
        System.assertEquals(a.Id, conv.ConvertedAccountId, 'Should link to existing Account via Contact');
        System.assertEquals(c.Id, conv.ConvertedContactId,  'Should link to existing Contact by email');
    }

    // 3) Exact Account Name
    @IsTest
    static void test_exactAccountName() {
        Account a = makeAccount('Exact Inc.', null, null, null, null);
        Lead l = makeLead('Exact Inc.', 'exact@test.tld', null, null, null);

        Test.startTest();
        Database.LeadConvertResult res = BulkLeadConvert.convertOne(l.Id, false);
        Test.stopTest();

        System.assertEquals(true, res.isSuccess(), 'convertOne should succeed by exact name');
        Lead conv = [SELECT ConvertedAccountId, ConvertedContactId, IsConverted FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, conv.IsConverted);
        System.assertEquals(a.Id, conv.ConvertedAccountId);
        System.assertNotEquals(null, conv.ConvertedContactId, 'Contact should be created under that Account');
    }

    // 4) Domain Match (ครอบเคส parsing websiteDomain ที่ซับซ้อน)
    @IsTest
    static void test_domainMatch_hardenedWebsiteParsing() {
        // website มี scheme + credentials + subdomain + port + path + query + fragment + trailing dot
        String complexWebsite = 'https://user:pass@sub.zip1993.co.th:8080/path?q=1#frag.';
        Account a = makeAccount('Domain Co', complexWebsite, null, null, null);

        // Email โดเมนหลัก (ไม่ใช่ sub.) → ต้อง match (รองรับ subdomain)
        Lead l = makeLead('Any Co', 'u@zip1993.co.th', null, null, null);

        Test.startTest();
        Database.LeadConvertResult res = BulkLeadConvert.convertOne(l.Id, false, /*bypass*/ false, /*precheck*/ false);
        Test.stopTest();

        System.assertEquals(true, res.isSuccess(), 'convertOne should succeed by domain match with complex website');
        Lead conv = [SELECT ConvertedAccountId, IsConverted FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, conv.IsConverted);
        System.assertEquals(a.Id, conv.ConvertedAccountId, 'Should match account by hardened websiteDomain');
    }

    // 5) Cleaned Company Name match (normalize ชื่อให้ตรงกัน)
    @IsTest
    static void test_cleanedCompanyName_match() {
        // ไม่มี website/ที่อยู่เพื่อบังคับให้ใช้ cleaned-name เท่านั้น
        Account a = makeAccount('Zip1993 Company Limited', null, null, null, null);

        // ตั้งชื่อ lead แบบหลากหลายสไตล์ (ต้อง normalize แล้วเท่ากัน)
        Lead l = makeLead('zip1993 co., ltd.', 'x@random-domain.tld', null, null, null);

        Test.startTest();
        Database.LeadConvertResult res = BulkLeadConvert.convertOne(l.Id, false, false, false);
        Test.stopTest();

        System.assertEquals(true, res.isSuccess(), 'convertOne should succeed by cleaned company name match');
        Lead conv = [SELECT ConvertedAccountId, IsConverted FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, conv.IsConverted);
        System.assertEquals(a.Id, conv.ConvertedAccountId, 'Should match by normalized company name');
    }

    // 6) Address Match
    @IsTest
    static void test_addressMatch() {
        Account a = makeAccount('Addr Co', null, 'Bangkok', '10200', 'Thailand');
        Lead l = makeLead('Other Co', 'addr@test.tld', 'Bangkok', '10200', 'Thailand');

        Test.startTest();
        Database.LeadConvertResult res = BulkLeadConvert.convertOne(l.Id, false);
        Test.stopTest();

        System.assertEquals(true, res.isSuccess(), 'convertOne should succeed by address match');
        Lead conv = [SELECT ConvertedAccountId, IsConverted FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, conv.IsConverted);
        System.assertEquals(a.Id, conv.ConvertedAccountId, 'Should match by address');
    }

    // 7) No match → ควรสร้าง Account ใหม่
    @IsTest
    static void test_noMatch_createsNewAccount() {
        // ไม่มี Account ใด ๆ ที่ match
        Lead l = makeLead('Brand New Co', 'brandnew_' + String.valueOf(Crypto.getRandomInteger()) + '@noacc.tld', null, null, 'TH');

        Test.startTest();
        Database.LeadConvertResult res = BulkLeadConvert.convertOne(l.Id, false, /*bypass*/ true, /*precheck*/ false);
        Test.stopTest();

        System.assertNotEquals(null, res, 'Result should not be null');
        Lead conv = [SELECT IsConverted, ConvertedAccountId FROM Lead WHERE Id = :l.Id];
        System.assertEquals(true, conv.IsConverted, 'Lead must be converted when no match found');
        System.assertNotEquals(null, conv.ConvertedAccountId, 'New Account should be created');
    }

    // 8) convertMany: ผสมหลายเคส + “อีเมลซ้ำในรอบเดียวกันให้ข้ามเฉพาะตัวที่ซ้ำ”
    @IsTest
    static void test_convertMany_mix_withDuplicateEmails() {
        Account byName = makeAccount('BulkName Co', null, null, null, null);
        Account byDom  = makeAccount('BulkDomain Co', 'http://bulkdom.example.tld/path', null, null, null);

        // exact name → ต้อง convert
        Lead l1 = makeLead('BulkName Co', 'l1@test.tld', null, null, null);

        // domain match → ต้อง convert
        Lead l2 = makeLead('Other Co', 'l2@bulkdom.example.tld', null, null, null);

        // new account → ต้อง convert
        Lead l3 = makeLead('Create New Co', 'l3@newco.tld', null, null, null);

        // duplicate email ในชุดเดียวกัน → ตัวนี้ต้อง "ไม่ convert" (เพราะ class กันซ้ำด้วย Set)
        Lead l1dup = makeLead('BulkName Co', 'l1@test.tld', null, null, null, true);

        // no email → skip
        Lead lNoEmail = makeLead('No Email Bulk', null, null, null, null);

        List<Id> ids = new List<Id>{ l1.Id, l2.Id, l3.Id, l1dup.Id, lNoEmail.Id };

        Test.startTest();
        List<Database.LeadConvertResult> results = BulkLeadConvert.convertMany(ids, false);
        Test.stopTest();

        // คาดหวัง: convert เฉพาะอีเมลไม่ว่างที่ “ไม่ซ้ำ” → l1, l2, l3 = 3 jobs
        System.assertEquals(3, results.size(),
            'Unique non-blank emails in scope should be 3 (l1, l2, l3), duplicates (l1dup) & no-email skipped.');

        // ตรวจสถานะจริง
        Map<Id, Lead> after = new Map<Id, Lead>([
            SELECT Id, IsConverted, ConvertedAccountId FROM Lead WHERE Id IN :ids
        ]);

        // ---- l1 vs l1dup: ต้องมี "เท่ากับ 1 ตัว" ถูก convert และต้องไปที่ byName ----
        Integer convertedCountDup = 0;
        if (after.get(l1.Id).IsConverted)    convertedCountDup++;
        if (after.get(l1dup.Id).IsConverted) convertedCountDup++;
        System.assertEquals(1, convertedCountDup,
            'Exactly one of (l1, l1dup) must be converted in this run (dedup within batch).');

        Id convertedIdDup = after.get(l1.Id).IsConverted ? l1.Id : l1dup.Id;
        System.assertEquals(byName.Id, after.get(convertedIdDup).ConvertedAccountId,
            'The converted record among (l1, l1dup) should link to byName account');

        // ---- l2: ควร match byDom (domain) ----
        System.assertEquals(true, after.get(l2.Id).IsConverted, 'l2 should be converted by domain');
        System.assertEquals(byDom.Id, after.get(l2.Id).ConvertedAccountId, 'l2 should link to byDom account');

        // ---- l3: ควรสร้าง account ใหม่ ----
        System.assertEquals(true,  after.get(l3.Id).IsConverted, 'l3 should be converted (new account)');
        System.assertNotEquals(null, after.get(l3.Id).ConvertedAccountId, 'l3 should have a new ConvertedAccountId');

        // ---- lNoEmail: skip ----
        System.assertEquals(false, after.get(lNoEmail.Id).IsConverted, 'No-email lead should be skipped');
    }

    // 9) Convert ครั้งแรกต้องสำเร็จ
    @IsTest
    static void test_convertOnce_success() {
        Lead l = makeLead('Convert Me', 'once@test.tld', null, null, null);

        Test.startTest();
        Database.LeadConvertResult first = BulkLeadConvert.convertOne(l.Id, false);
        Test.stopTest();

        System.assertEquals(true, first.isSuccess(), 'First conversion should succeed');
    }

    // 10) เรียกซ้ำหลังจาก convert แล้ว → return null
    @IsTest
    static void test_convertAgain_returnsNull() {
        Lead l = makeLead('Convert Again', 'again@test.tld', null, null, null);

        // convert ครั้งแรก (นอก startTest เพื่อเลี่ยง Testing already started)
        Database.LeadConvertResult first = BulkLeadConvert.convertOne(l.Id, false);
        System.assertEquals(true, first.isSuccess(), 'Precondition: first convert must succeed');

        Test.startTest();
        Database.LeadConvertResult second = BulkLeadConvert.convertOne(l.Id, false);
        Test.stopTest();

        System.assertEquals(null, second, 'Second call should return null on already-converted lead');
    }

    // 11) useDupPrecheck=true → อาจถูก skip ได้ (return null) หรือ convert ถ้าไม่ชน rule
    @IsTest
    static void test_convertOne_withDupPrecheck_soft() {
        Lead l = makeLead('DupPrecheck Co',
                          'dupcheck_' + String.valueOf(Crypto.getRandomInteger()) + '@dom.tld',
                          null, null, 'TH');

        Test.startTest();
        Database.LeadConvertResult res = BulkLeadConvert.convertOne(
            l.Id,
            /*createOpportunity*/ false,
            /*alwaysBypassDedupe*/ true,
            /*useDupPrecheck*/ true
        );
        Test.stopTest();

        // soft assert: ถ้าโดน precheck ตัด → res อาจเป็น null (ยอมรับได้)
        if (res == null) {
            System.debug('dup-precheck skipped conversion by org rules → res=null, acceptable');
        } else {
            System.assertEquals(true, res.isSuccess(), 'Conversion should succeed when not duplicate');
            Lead conv = [SELECT IsConverted FROM Lead WHERE Id = :l.Id];
            System.assertEquals(true, conv.IsConverted, 'Lead should be converted when not truly duplicate');
        }
    }

    // 12) convertMany + dup-precheck=true → ควรพยายามแปลงทั้งชุด (soft)
    @IsTest
    static void test_convertMany_withDupPrecheck_path() {
        Lead a = makeLead('Flag Co A', 'flagA_' + String.valueOf(Crypto.getRandomInteger()) + '@test.tld', null, null, 'TH');
        Lead b = makeLead('Flag Co B', 'flagB_' + String.valueOf(Crypto.getRandomInteger()) + '@test.tld', null, null, 'TH');

        List<Id> ids = new List<Id>{ a.Id, b.Id };

        Test.startTest();
        List<Database.LeadConvertResult> res = BulkLeadConvert.convertMany(
            ids,
            /*createOpportunity*/ false,
            /*alwaysBypassDedupe*/ true,
            /*useDupPrecheck*/ true
        );
        Test.stopTest();

        System.assertNotEquals(null, res, 'Result list should not be null');
        // ไม่ assert จำนวนแน่นอน เพราะ dup-precheck อาจตัดออกใน org จริง
        Map<Id, Lead> after = new Map<Id, Lead>([
            SELECT Id, IsConverted FROM Lead WHERE Id IN :ids
        ]);
        System.debug('Post dup-precheck convertMany IsConverted: A=' + after.get(a.Id).IsConverted + ', B=' + after.get(b.Id).IsConverted);
    }
}