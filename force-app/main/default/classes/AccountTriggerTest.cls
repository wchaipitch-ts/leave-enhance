@IsTest
private class AccountTriggerTest {

    @IsTest
    static void testAccountInsertNormalization() {
        // 1. Prepare test data
        List<Account> testAccounts = new List<Account>{
            new Account(Name = 'Test Company, Inc.'),
            new Account(Name = 'บริษัท ทดสอบ'), // Thai name that should lose the trailing legal token
            new Account(Name = 'Another Co. Ltd.')
        };

        // 2. Run the code to be tested
        Test.startTest();
        insert testAccounts;
        Test.stopTest();

        // 3. Verify the results
        List<Account> createdAccounts = [
            SELECT Id, Name, Normalized_Company_Name__c
            FROM Account
            WHERE Id IN :testAccounts
        ];

        for (Account acc : createdAccounts) {
            if (acc.Name == 'Test Company, Inc.') {
                  System.debug('Normalized Name: ' + acc.Normalized_Company_Name__c);
                System.assertEquals('testcompany', acc.Normalized_Company_Name__c,
                    'Normalization failed on insert for English name.');
            } else if (acc.Name == 'บริษัท ทดสอบ จำกัด') {
                // Expected: Thai text without the trailing legal token and without spaces
            System.debug('Normalized Name: ' + acc.Normalized_Company_Name__c);
                System.assertEquals('บริษัททดสอบ', acc.Normalized_Company_Name__c,
                    'Normalization failed on insert for Thai name.');
            } else if (acc.Name == 'Another Co. Ltd.') {
                System.assertEquals('another', acc.Normalized_Company_Name__c,
                    'Normalization failed on insert for mixed name.');
            }
        }
    }

    @IsTest
    static void testAccountUpdateNormalization() {
        // 1. Setup
        Account acc = new Account(Name = 'Initial Name');
        insert acc;

        // 2. Update
        acc.Name = 'Updated Name Corp.';

        // 3. Exercise
        Test.startTest();
        update acc;
        Test.stopTest();

        // 4. Verify
        Account updatedAccount = [
            SELECT Id, Normalized_Company_Name__c
            FROM Account WHERE Id = :acc.Id
        ];
        System.assertEquals('updatedname', updatedAccount.Normalized_Company_Name__c,
            'Normalization failed on update.');
    }
}