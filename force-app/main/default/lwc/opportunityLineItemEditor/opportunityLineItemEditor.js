// opportunityLineItemEditor.js
import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import getOpportunityLineItems from '@salesforce/apex/OpportunityLineItemEditorController.getOpportunityLineItems';
import saveOpportunityLineItems from '@salesforce/apex/OpportunityLineItemEditorController.saveOpportunityLineItems';
import getActivePricebookEntries from '@salesforce/apex/OpportunityLineItemEditorController.getActivePricebookEntries';

export default class OpportunityLineItemEditor extends LightningElement {
    // Public property to receive Opportunity Id from record page
    // 商談レコードページから商談IDを受け取るための公開プロパティ
    @api recordId;

    // Tracked property to hold the list of Opportunity Line Items
    // 商談商品のリストを保持するためのトラックプロパティ
    @track opportunityLineItems = [];

    // Tracked property for PricebookEntry options
    // PricebookEntryオプションを保持するためのトラックプロパティ
    @track pricebookOptions = [];

    // Flag to indicate if data is being processed (save/load)
    // データの処理中（保存/読み込み）を示すフラグ
    @track isProcessing = false;

    // Unique key counter for new rows
    // 新しい行のためのユニークキーカウンタ
    _nextKey = 0;

    // Tracked property to hold IDs of deleted Opportunity Line Items
    // 削除された商談商品のIDを保持するためのトラックプロパティ
    @track deletedIds = [];

    connectedCallback() {
        // Load existing Opportunity Line Items when the component initializes
        // コンポーネントが初期化されたときに既存の商談商品を読み込む
        this.loadOpportunityLineItems();
    }

    /**
     * @description Loads existing Opportunity Line Items from Apex.
     * @description Apexから既存の商談商品を読み込みます。
     */
    loadOpportunityLineItems() {
        this.isProcessing = true;
        getOpportunityLineItems({ opportunityId: this.recordId })
            .then(result => {
                // Map results to add a unique key and `isNew` flag
                // 結果をマッピングして、ユニークキーと`isNew`フラグを追加
                this.opportunityLineItems = result.map(item => ({
                    ...item,
                    key: item.Id || this._generateUniqueKey(), // Use Id if exists, otherwise generate a new key
                    isNew: false // Existing items are not new
                }));
            })
            .catch(error => {
                this.showToast('エラー / Error', '商談商品の取得中にエラーが発生しました。 / Failed to load Opportunity Products. ' + error.body.message, 'error');
                console.error('Error loading Opportunity Line Items:', error);
            })
            .finally(() => {
                this.isProcessing = false;
            });
    }

    /**
     * @description Handles input changes for Quantity, UnitPrice, and ServiceDate.
     * @description 数量、単価、提供日の入力変更を処理します。
     * @param {Event} event - The change event. / 変更イベント
     */
    handleInputChange(event) {
        const { field, index } = event.target.dataset;
        const value = event.target.value;

        // Create a deep copy to ensure reactivity
        // リアクティビティを確保するためにディープコピーを作成
        let updatedItems = JSON.parse(JSON.stringify(this.opportunityLineItems));
        let itemToUpdate = updatedItems[index];

        // Update the specific field
        // 特定のフィールドを更新
        if (field === 'Quantity') {
            itemToUpdate.Quantity = parseFloat(value);
        } else if (field === 'UnitPrice') {
            itemToUpdate.UnitPrice = parseFloat(value);
        } else if (field === 'ServiceDate') {
            itemToUpdate.ServiceDate = value; // 日付はそのまま文字列として保存
        }

        this.opportunityLineItems = updatedItems;
    }

    /**
     * @description Handles the change event for the PricebookEntryId lookup field.
     * @description PricebookEntryIdルックアップフィールドの変更イベントを処理します。
     * @param {Event} event - The change event. / 変更イベント
     */
    handleProductLookupChange(event) {
        const index = event.target.dataset.index;
        const selectedId = event.detail.value[0]; // lightning-input-field for lookup returns an array

        let updatedItems = JSON.parse(JSON.stringify(this.opportunityLineItems));
        let itemToUpdate = updatedItems[index];

        itemToUpdate.PricebookEntryId = selectedId;
        // Optionally, if you need the PricebookEntry.Name immediately, you'd need to query it.
        // For simplicity, we assume Apex will handle the relationship correctly on save.
        // オプションで、PricebookEntry.Nameをすぐに必要とする場合、クエリが必要です。
        // シンプルさのため、保存時にApexが関係を正しく処理すると仮定します。

        this.opportunityLineItems = updatedItems;
    }

    /**
     * @description Adds a new empty row to the list.
     * @description リストに新しい空の行を追加します。
     */
    handleAddNewRow() {
        // Generate a unique key for the new row
        // 新しい行のためにユニークキーを生成
        const newKey = this._generateUniqueKey();
        this.opportunityLineItems = [
            ...this.opportunityLineItems,
            {
                key: newKey,
                Id: null, // New item has no Id yet
                OpportunityId: this.recordId,
                PricebookEntryId: null, // This will be set by the lookup
                PricebookEntry: null, // Placeholder for product name
                Quantity: 1,
                UnitPrice: 0,
                isNew: true // Flag to identify new rows
            }
        ];
    }

    /**
     * @description Copies an existing row and adds it as a new row.
     * @description 既存の行をコピーして新しい行として追加します。
     * @param {Event} event - The click event. / クリックイベント
     */
    handleCopyRow(event) {
        const indexToCopy = parseInt(event.target.dataset.index, 10);
        const itemToCopy = this.opportunityLineItems[indexToCopy];

        if (itemToCopy) {
            // ディープコピー
            const copiedItem = JSON.parse(JSON.stringify(itemToCopy));

            // Id, key, isNewをリセット
            copiedItem.Id = null;
            copiedItem.key = this._generateUniqueKey();
            copiedItem.isNew = true;

            // ServiceDateがあれば翌月の応当日に（応当日がない場合は月末日）
            if (copiedItem.ServiceDate) {
                try {
                    const date = new Date(copiedItem.ServiceDate);
                    if (!isNaN(date.getTime())) {
                        const originalDay = date.getDate();
                        date.setMonth(date.getMonth() + 1);
                        date.setDate(originalDay);

                        // 日付が巻き戻った場合（月末を超えた場合）、前月の最終日を設定
                        if (date.getDate() !== originalDay) {
                            date.setDate(0); // 前月の最終日
                        }

                        copiedItem.ServiceDate = date.toISOString().slice(0, 10);
                    } else {
                        // 無効な日付の場合はデフォルト処理
                        copiedItem.ServiceDate = this._getDefaultServiceDate();
                    }
                } catch (error) {
                    console.error('Error processing ServiceDate during copy:', error);
                    copiedItem.ServiceDate = this._getDefaultServiceDate();
                }
            } else {
                // ServiceDateが未設定の場合はデフォルト処理
                copiedItem.ServiceDate = this._getDefaultServiceDate();
            }

            // コピー行を追加
            let updatedItems = [...this.opportunityLineItems];
            updatedItems.splice(indexToCopy + 1, 0, copiedItem);
            this.opportunityLineItems = updatedItems;
        }
    }

    /**
     * @description Deletes a row from the list.
     * @description リストから行を削除します。
     * @param {Event} event - The click event. / クリックイベント
     */
    handleDeleteRow(event) {
        const indexToDelete = parseInt(event.target.dataset.index, 10);
        let updatedItems = [...this.opportunityLineItems];
        const item = updatedItems[indexToDelete];
        // 既存レコードならdeletedIdsに追加
        if (item.Id) {
            this.deletedIds = [...this.deletedIds, item.Id];
        }
        updatedItems.splice(indexToDelete, 1); // Remove the item at the specified index
        this.opportunityLineItems = updatedItems;
    }

    /**
     * @description Saves the modified Opportunity Line Items to Apex.
     * @description 変更された商談商品をApexに保存します。
     */
    handleSave() {
        this.isProcessing = true;
        const itemsToSave = this.opportunityLineItems.filter(item =>
            (item.Quantity > 0 && item.UnitPrice >= 0 && item.PricebookEntryId) || (!item.isNew && item.Id)
        );
        const invalidNewItems = itemsToSave.filter(item => item.isNew && !item.PricebookEntryId);
        if (invalidNewItems.length > 0) {
            this.showToast('入力エラー / Input Error', '新規商品は商品を選択してください。 / Please select a product for new items.', 'error');
            this.isProcessing = false;
            return;
        }
        saveOpportunityLineItems({
            opportunityLineItems: itemsToSave,
            opportunityId: this.recordId,
            deletedIds: this.deletedIds
        })
            .then(() => {
                this.showToast('Success', 'Opportunity Products saved successfully.', 'success');
                this.loadOpportunityLineItems();
                this.deletedIds = [];
                
                // レコードページの他のコンポーネントに変更を通知
                this.notifyRecordUpdate();
            })
            .catch(error => {
                let message = 'Failed to save Opportunity Products.';
                if (error && error.body) {
                    if (error.body.message) {
                        message += '\n' + error.body.message;
                    }
                    if (error.body.stackTrace) {
                        message += '\nStacktrace:\n' + error.body.stackTrace;
                    }
                } else if (error && error.message) {
                    message += '\n' + error.message;
                }
                this.showToast('Error', message, 'error');
                // 主要な情報を個別に出力
                console.error('Error saving Opportunity Line Items:', error);
                if (error && error.body) {
                    if (error.body.message) {
                        console.error('Error message:', error.body.message);
                    }
                    if (error.body.stackTrace) {
                        console.error('Stacktrace:', error.body.stackTrace);
                    }
                }
                if (error && error.message) {
                    console.error('Error message:', error.message);
                }
                // オブジェクト全体も整形して出力
                console.error('Error (stringified):', JSON.stringify(error, null, 2));
            })
            .finally(() => {
                this.isProcessing = false;
            });
    }

    /**
     * @description Cancels the changes and reloads the original data.
     * @description 変更をキャンセルし、元のデータを再読み込みします。
     */
    handleCancel() {
        // Revert to the original state by reloading data
        // データを再読み込みして元の状態に戻す
        this.loadOpportunityLineItems();
        this.showToast('Cancelled', 'Changes have been cancelled.', 'info');
    }

    /**
     * @description Displays a toast message.
     * @description トーストメッセージを表示します。
     * @param {string} title - The title of the toast. / トーストのタイトル
     * @param {string} message - The message of the toast. / トーストのメッセージ
     * @param {string} variant - The variant (e.g., 'success', 'error', 'warning', 'info'). / バリアント（例：'success', 'error', 'warning', 'info'）
     */
    showToast(title, message, variant) {
        const event = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant,
            duration: variant === 'success' ? 1000 : undefined
        });
        this.dispatchEvent(event);
    }

    /**
     * @description Generates a unique key for new rows.
     * @description 新しい行のためのユニークキーを生成します。
     * @returns {string} - A unique key. / ユニークキー
     */
    _generateUniqueKey() {
        this._nextKey++;
        return `new_item_${this._nextKey}`;
    }

    /**
     * @description Gets a default ServiceDate (next month from today).
     * @description デフォルトのServiceDate（今日から翌月の応当日）を取得します。
     * @returns {string} - ISO date string (YYYY-MM-DD format). / ISO日付文字列（YYYY-MM-DD形式）
     */
    _getDefaultServiceDate() {
        try {
            const today = new Date();
            const originalDay = today.getDate();
            const nextMonth = new Date(today);
            nextMonth.setMonth(nextMonth.getMonth() + 1);
            nextMonth.setDate(originalDay);

            // 日付が巻き戻った場合（月末を超えた場合）、前月の最終日を設定
            if (nextMonth.getDate() !== originalDay) {
                nextMonth.setDate(0); // 前月の最終日
            }

            return nextMonth.toISOString().slice(0, 10);
        } catch (error) {
            console.error('Error generating default ServiceDate:', error);
            // エラーの場合は今日の日付を返す
            return new Date().toISOString().slice(0, 10);
        }
    }

    @wire(getActivePricebookEntries)
    wiredEntries({ error, data }) {
        if (data) {
            this.pricebookOptions = data.map(entry => ({
                label: entry.Product2.Name,
                value: entry.Id
            }));
        } else if (error) {
            // エラーハンドリング
        }
    }

    handleProductChange(event) {
        const index = event.target.dataset.index;
        const value = event.detail.value;
        this.opportunityLineItems[index].PricebookEntryId = value;
        // 必要に応じて再描画
    }

    /**
     * @description Notifies Lightning Data Service that the record has been updated.
     * @description Lightning Data Service にレコードが更新されたことを通知します。
     */
    notifyRecordUpdate() {
        // Lightning Data Service に商談レコードの変更を通知
        // これにより、レコードページ上の他のコンポーネントも自動的に更新される
        getRecordNotifyChange([{recordId: this.recordId}]);
    }
}