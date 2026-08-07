// OpportunityLineItemEditorController.cls
public with sharing class OpportunityLineItemEditorController {

    /**
     * @description Retrieves Opportunity Line Items for a given Opportunity.
     * @description 指定された商談の商談商品を取得します。
     * @param opportunityId The ID of the Opportunity. / 商談のID
     * @return List<OpportunityLineItem> A list of Opportunity Line Items. / 商談商品のリスト
     */
    @AuraEnabled
    public static List<OpportunityLineItem> getOpportunityLineItems(Id opportunityId) {
        try {
            // Ensure FLS and CRUD permissions are respected
            // FLS (Field Level Security) および CRUD 権限が尊重されることを確認
            return [
                SELECT
                    Id,
                    OpportunityId,
                    PricebookEntryId,
                    PricebookEntry.Name, // Product Name from Pricebook Entry
                    Quantity,
                    UnitPrice,
                    Name,
                    Product2Id,
                    ProductCode,
                    ServiceDate,
                    Description,
                    ListPrice,
                    Total_Amount__c
                FROM OpportunityLineItem
                WHERE OpportunityId = :opportunityId
                WITH SECURITY_ENFORCED
                ORDER BY ServiceDate, PricebookEntry.Name, CreatedDate ASC
            ];
        } catch (Exception e) {
            System.debug('Error in getOpportunityLineItems: ' + e.getMessage());
            System.debug('Error Type: ' + e.getTypeName());
            System.debug('Stack Trace: ' + e.getStackTraceString());
            
            String errorMessage = '商談商品の取得中にエラーが発生しました。 / Error retrieving Opportunity Products: ';
            errorMessage += e.getTypeName() + ' - ' + e.getMessage() + ' - ' + e.getStackTraceString(); 
            
            
            throw new AuraHandledException(errorMessage);
        }
    }

    /**
     * @description Saves (inserts/updates) a list of Opportunity Line Items.
     * @description 商談商品のリストを保存（挿入/更新）します。
     * @param opportunityLineItems List of OpportunityLineItem objects to save. / 保存するOpportunityLineItemオブジェクトのリスト
     * @param opportunityId The ID of the Opportunity to relate new items to. / 新しい項目を関連付ける商談のID
     */
    @AuraEnabled
    public static void saveOpportunityLineItems(List<OpportunityLineItem> opportunityLineItems, Id opportunityId, List<Id> deletedIds) {
        List<OpportunityLineItem> itemsToInsert = new List<OpportunityLineItem>();
        List<OpportunityLineItem> itemsToUpdate = new List<OpportunityLineItem>();

        // PricebookEntryIdがnullの新規レコード用のデフォルト値を取得
        Id defaultPricebookEntryId = getDefaultPricebookEntryId(opportunityLineItems);

        for (OpportunityLineItem oli : opportunityLineItems) {
            if (oli.OpportunityId == null) {
                oli.OpportunityId = opportunityId;
            }
            
            // すべてのレコードでPricebookEntryIdの自動設定（新規・既存問わず）
            if (oli.PricebookEntryId == null) {
                oli.PricebookEntryId = defaultPricebookEntryId;
            }
            
            if (oli.Id == null) {
                itemsToInsert.add(oli);
            } else {
                itemsToUpdate.add(oli);
            }
        }
        if (!itemsToInsert.isEmpty()) {
            insert itemsToInsert;
        }
        if (!itemsToUpdate.isEmpty()) {
            update itemsToUpdate;
        }
        // 削除処理
        if (deletedIds != null && !deletedIds.isEmpty()) {
            delete [SELECT Id FROM OpportunityLineItem WHERE Id IN :deletedIds];
        }
        
        // 商談のAmountを再計算
        // 権限問題が発生する場合、以下の行をコメントアウトしてください
        recalculateOpportunityAmount(opportunityId);
    }

    /**
     * @description Gets a default PricebookEntryId for new OpportunityLineItems
     * @description 新規商談商品のためのデフォルトPricebookEntryIdを取得します
     * @param opportunityLineItems List of OpportunityLineItems being processed
     * @return Id of a valid PricebookEntry
     */
    private static Id getDefaultPricebookEntryId(List<OpportunityLineItem> opportunityLineItems) {
        Id defaultPricebookEntryId = null;
        
        try {
            // 1. まずパラメータ内の既存OpportunityLineItemからPricebookEntryIdを取得
            for (OpportunityLineItem oli : opportunityLineItems) {
                if (oli.Id != null && oli.PricebookEntryId != null) {
                    defaultPricebookEntryId = oli.PricebookEntryId;
                    System.debug('Using PricebookEntryId from parameter LineItem: ' + defaultPricebookEntryId);
                    return defaultPricebookEntryId;
                }
            }
            
            // 2. パラメータ内に既存LineItemがない場合、標準価格表から最初のアクティブなPricebookEntryを取得
            Id standardPricebookId = getStandardPricebookId();
            if (standardPricebookId != null) {
                List<PricebookEntry> standardEntries = [
                    SELECT Id 
                    FROM PricebookEntry 
                    WHERE Pricebook2Id = :standardPricebookId 
                    AND IsActive = true
                    WITH SECURITY_ENFORCED
                    LIMIT 1
                ];
                
                if (!standardEntries.isEmpty()) {
                    defaultPricebookEntryId = standardEntries[0].Id;
                    System.debug('Using PricebookEntryId from standard pricebook: ' + defaultPricebookEntryId);
                    return defaultPricebookEntryId;
                }
            }
            
            // 3. 標準価格表にもアクティブなエントリがない場合はエラー
            throw new AuraHandledException('利用可能な商品が見つかりません。管理者にお問い合わせください。 / No available products found. Please contact your administrator.');
            
        } catch (Exception e) {
            System.debug('Error in getDefaultPricebookEntryId: ' + e.getMessage());
            throw new AuraHandledException('デフォルト商品の取得中にエラーが発生しました。 / Error occurred while getting default product: ' + e.getMessage());
        }
    }

    /**
     * @description Gets the standard pricebook ID
     * @description 標準価格表のIDを取得します
     * @return Id of the standard pricebook
     */
    private static Id getStandardPricebookId() {
        if (Test.isRunningTest()) {
            return Test.getStandardPricebookId();
        } else {
            List<Pricebook2> standardPricebooks = [
                SELECT Id 
                FROM Pricebook2 
                WHERE IsStandard = true 
                LIMIT 1
            ];
            return !standardPricebooks.isEmpty() ? standardPricebooks[0].Id : null;
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<PricebookEntry> getActivePricebookEntries() {
        Id stdPbId;
        if(Test.isRunningTest()){
            stdPbId = Test.getStandardPricebookId();
        }else{
            List<Pricebook2> stdPb2 = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
            stdPbId = stdPb2[0].Id;
        }
        return getActivePricebookEntries(stdPbId);
    }

    @testvisible
    private static List<PricebookEntry> getActivePricebookEntries(Id pbId) {
        return [
            SELECT Id, Name, Product2.Name
            FROM PricebookEntry
            WHERE Pricebook2Id = :pbId AND IsActive = true
        ];
    }

    /**
     * @description Triggers Salesforce's automatic recalculation of Opportunity Amount by performing an empty update.
     * @description 空更新を行うことでSalesforceの自動再計算機能をトリガーします。
     * @param opportunityId The ID of the Opportunity to recalculate. / 再計算する商談のID
     */
    private static void recalculateOpportunityAmount(Id opportunityId) {
        try {
            // まず商談が存在し、アクセス可能かを確認
            List<Opportunity> oppList = [
                SELECT Id, Amount 
                FROM Opportunity 
                WHERE Id = :opportunityId 
                WITH SECURITY_ENFORCED 
                LIMIT 1
            ];
            
            if (oppList.isEmpty()) {
                System.debug('OpportunityLineItemEditor: Opportunity not found or no access: ' + opportunityId);
                return; // 商談が見つからない場合は何もしない
            }
            
            // 商談の空更新を行い、Salesforceの標準機能でAmountを再計算させる
            Opportunity opp = new Opportunity(Id = opportunityId);
            update opp;
            
            System.debug('OpportunityLineItemEditor: Successfully updated Opportunity: ' + opportunityId);
            
        } catch (Exception e) {
            System.debug('OpportunityLineItemEditor Error: ' + e.getMessage());
            System.debug('OpportunityLineItemEditor Error Type: ' + e.getTypeName());
            System.debug('OpportunityLineItemEditor Stack Trace: ' + e.getStackTraceString());
            
            // より詳細なエラーメッセージを提供
            String errorMessage = '商談金額の再計算中にエラーが発生しました。 / Error occurred while recalculating Opportunity Amount: ';
            
            if (e instanceof System.DmlException) {
                DmlException dmlEx = (DmlException) e;
                errorMessage += 'DML Error: ' + dmlEx.getDmlMessage(0);
            } else {
                errorMessage += e.getMessage();
            }
            
            // エラーをスローして上位に伝える
            throw new AuraHandledException(errorMessage);
        }
    }
}