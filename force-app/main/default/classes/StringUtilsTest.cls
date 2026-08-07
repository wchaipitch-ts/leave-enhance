@IsTest
private class StringUtilsTest {

    private static void assertBoth(String input, String expectedSpaces, String expectedNoSpaces) {
        System.assertEquals(expectedSpaces, StringUtils.normalizeCompanyName(input, false), 'spaces preserved: ' + input);
        System.assertEquals(expectedNoSpaces, StringUtils.normalizeCompanyName(input, true), 'no spaces: ' + input);
    }

    @IsTest
    static void testOptionalSuffixesRemoved() {
        assertBoth('acme corporation', 'acme', 'acme');
        assertBoth('ACME INC.', 'acme', 'acme');
        assertBoth('acme corp', 'acme', 'acme');
    }

    @IsTest
    static void testCoLtdPunctuationVariants() {
        List<String> variants = new List<String>{
            'acme co.,ltd',
            'acme co., ltd',
            'acme co. ltd.,',
            'acme co,. ltd.',
            'acme co. ltd.,',
            'acme co ltd'
        };
        for (String v : variants) {
            assertBoth(v, 'acme', 'acme');
        }
    }

    @IsTest
    static void testThailandPublicCompanyLimited() {
        // Thailand optional token and Co., Ltd. at the end
        assertBoth('Acme (Thailand) Co., Ltd.', 'acme', 'acme');
        // Public Company Limited suffix
        System.assertEquals('bangkok bank', StringUtils.normalizeCompanyName('Bangkok Bank Public Company Limited', false));
        System.assertEquals('bangkokbank', StringUtils.normalizeCompanyName('Bangkok Bank Public Company Limited', true));
    }

    @IsTest
    static void testGuardrailCoNotStrippedMidString() {
        System.assertEquals('acme co working', StringUtils.normalizeCompanyName('acme co working', false));
        System.assertEquals('acmecoworking', StringUtils.normalizeCompanyName('acme co working', true));
    }

    @IsTest
    static void testCocaColaCoLtd() {
        System.assertEquals('coca cola', StringUtils.normalizeCompanyName('coca cola co., ltd.', false));
        System.assertEquals('cocacola', StringUtils.normalizeCompanyName('coca cola co., ltd.', true));
    }

    @IsTest
    static void testNullBlankAndSuffixOnly() {
        System.assertEquals(null, StringUtils.normalizeCompanyName(null, true));
        System.assertEquals(null, StringUtils.normalizeCompanyName('   ', false));
        System.assertEquals(null, StringUtils.normalizeCompanyName('Inc.', true));
        System.assertEquals(null, StringUtils.normalizeCompanyName('  co., ltd  ', false));
    }
}