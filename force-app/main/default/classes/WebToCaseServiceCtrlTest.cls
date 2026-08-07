@IsTest
private class WebToCaseServiceCtrlTest {
  @TestSetup
  static void setup() {
    // Insert some base data if needed in future (like Product records)
  }

  @IsTest
  static void testCreateCase_Success() {
    // Arrange
    Map<String, Object> caseData = new Map<String, Object>{
      'subject' => 'Test Subject',
      'description' => 'Test Description',
      'priority' => 'High',
      'email' => 'test@example.com',
      'phone' => '1234567890',
      'company' => 'Test Company',
      'firstName' => 'John',
      'lastName' => 'Doe',
      'nickName' => 'JD',
      'product' => 'mitoco',
      'source' => 'LINE',
      'status' => 'New',
      'initiator' => 'Tester',
      'comment' => 'Test Comment'
    };

    // Act
    Test.startTest();
    Id caseId = WebToCaseServiceCtrl.createCase(caseData);
    Test.stopTest();
  }

  
}