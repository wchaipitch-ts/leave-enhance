/*
 * TestDataFactory
 * Public class for create test data
 * 
 */
 @isTest
 public class TST_TestDataFactory {
    /**
	 * Create Managing Director user
	 */
	public static User createManagingDirectorUser(){        
		String mdUserName = 'md01@test.com.dev1';
		User mdUser = new User();
		List<User> userList = [SELECT Id FROM User where UserName = :mdUserName limit 1];
		if(userList.size() != 0){
			mdUser = userList[0];
		}else{
            Profile profile = [SELECT Id FROM Profile WHERE Name='Managing Director']; 
            mdUser.FirstName = 'Md01tst';
            mdUser.LastName = 'Tst';
            mdUser.Email = 'md01@test.com';
            mdUser.Alias = 'md01';
            mdUser.Username = mdUserName;
            mdUser.CommunityNickname = 'tstMd';
            mdUser.EmailEncodingKey = 'UTF-8';
            mdUser.LanguageLocaleKey = 'en_US';
            mdUser.LocaleSidKey = 'ja_JP';
            mdUser.TimeZoneSidKey = 'Asia/Bangkok';
            mdUser.ProfileId = profile.Id;
            insert mdUser;
        }

		return mdUser;
	}

    /**
	 * Create Engineer user
	 */
	public static User createEngineerUser(){      
		String engineerUserName = 'engineeruser1@test.com.dev1';
		User engineerUser = new User();
		List<User> userList = [SELECT Id FROM User where UserName = :engineerUserName limit 1];
		if(userList.size() != 0){
			engineerUser = userList[0];
		}else{
            Profile profile = [SELECT Id FROM Profile WHERE Name='EngineerGroupMember'];             
            engineerUser.FirstName = 'Test1';
            engineerUser.LastName = 'User1';
            engineerUser.Email = 'testuser1@test.com';
            engineerUser.Alias = 'test1';
            engineerUser.Username = engineerUserName;
            engineerUser.CommunityNickname = 'test1';
            engineerUser.EmailEncodingKey = 'UTF-8';
            engineerUser.LanguageLocaleKey = 'en_US';
            engineerUser.LocaleSidKey = 'ja_JP';
            engineerUser.TimeZoneSidKey = 'Asia/Bangkok';
            engineerUser.ProfileId = profile.Id;
            insert engineerUser;
        }

		return engineerUser;
	}

    // Method to assign a permission set to a user
    public static PermissionSetAssignment assignPermissionSetToUser(User user, String permissionSetName) {
        PermissionSet permSet = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName LIMIT 1];
        PermissionSetAssignment permSetAssignment = new PermissionSetAssignment(
            AssigneeId = user.Id,
            PermissionSetId = permSet.Id
        );
        insert permSetAssignment;
        return permSetAssignment;
    } 


}