# n8n-manage-pbi-refreshment

以 [n8n](https://n8n.io/) 打造的 Power BI（Microsoft Fabric）批次更新自動化平台。透過 n8n 工作流程排程觸發「資料流程（Dataflow）」與「語意模型（Semantic Model）」的更新，並依照設定的相依關係（前置任務）依序執行、輪詢更新狀態，直到全部完成。

## 使用流程

從零開始建置到能正常運作，大致依序如下：

1. **設定環境變數**：複製 `.env.example` 為 `.env`，填入 Azure AD Service Principal 的 `TENANT_ID`/`CLIENT_ID`/`CLIENT_SECRET`、Postgres帳密、`N8N_ENCRYPTION_KEY`、時區、（選用）`DINGTALK_BOT`（詳見〈環境變數設定〉）。
2. **啟動容器**：執行 `start.bat`（Windows）或 `./start.sh`（macOS/Ubuntu）。腳本會自動拉起n8n+postgres、偵測是否為全新環境，若沒有任何workflow會自動匯入`n8n_templates/workflows/`底下凍結的模板（詳見〈快速開始〉）。**這裡不含`總行動:PBI更新`本身**（見下方主要工作流程一覽的說明），需要在下一步依`總行動:PBI更新_模版`手動建立。
3. **初始化Data Table**：全新環境第一次啟動，`start.bat`/`start.sh`偵測到沒有Data Table會印出提示，需要到n8n介面手動執行一次`初始化環境`這個workflow（Manual Trigger，按「Execute workflow」），會自動建立「Today BI update status」與「Power BI workspaces」兩個表（詳見〈狀態資料表〉）。
4. **建立主流程並登錄要追蹤的資料流程／語意模型**：複製`總行動:PBI更新_模版`另存為正式的`總行動:PBI更新`。`獲取:虛擬帳號可存取工作區的資料流程與語意模型`會自動掃描服務帳號可存取的所有工作區、資料流程、語意模型，但**無法自動判斷相依關係**（哪個語意模型依賴哪個資料流程），需要手動登錄有相依關係的項目。做法是參考`_模版`裡`Model1`、`Dataflow - ETL1`等通用命名的節點範例，依樣畫葫蘆：
   1. 複製一個現有的登錄節點（例如`Model1`或`Dataflow - ETL1`）當起點
   2. 把`WORKSPACE_ID`／`DATASET_ID`欄位的表達式，改成引用`Call '獲取:虛擬帳號可存取工作區的資料流程與語意模型'`輸出裡對應的工作區名稱與資料集名稱，例如：
      ```
      ={{ $('Call \'獲取:虛擬帳號可存取工作區的資料流程與語意模型\'').item.json.workspaces['<工作區名稱>']['語意模型'][0]['<資料集名稱>'] }}
      ```
      （資料流程對應的路徑是`['資料流程']`而非`['語意模型']`）
   3. 把`DATASET_NAME`改成該資料集的名稱
   4. 確認並新增`PRE_WORKFLOW_LIST`（前置工作流佇列）——每個前置依賴一個物件，`PRE_WORKSPACE_ID`/`PRE_DATAFLOW_ID`一樣用上面的表達式指到該前置資料流程的位置
   5. 把這個n8n節點本身重新命名，避免跟其他登錄節點混淆

## 系統架構

專案以 Docker Compose 啟動兩個服務：

- **postgres**（`postgres:15-alpine`）：n8n 的資料庫，同時也作為 n8n Data Table 功能的儲存後端，用來記錄「當日 Power BI 更新狀態表」。
- **n8n**（`n8nio/n8n:latest`）：實際執行自動化流程的引擎，對外開放 `http://localhost:6001`。

n8n 容器內建了呼叫 Power BI REST API 所需的 Azure AD 應用程式（Service Principal）認證資訊，並可選擇性整合 DingTalk（釘釘）機器人推播通知。

## 核心運作流程

主要邏輯集中在工作流程 **`總行動:PBI更新`**（目前為**啟用**狀態），大致步驟如下：

1. **排程觸發**：`Schedule Trigger` 每日固定時間啟動（目前設定為每天 01:00）。
2. **清空並重建當日狀態表**：記錄本次流程啟動時間後，清空 n8n Data Table「Today BI update status」，再呼叫 `獲取:虛擬帳號可存取工作區的資料流程與語意模型`——這個子流程會先呼叫 `行動:查詢已知工作區` 讀取「Power BI workspaces」快取表取得工作區清單，逐一工作區呼叫 `獲取:所有資料流程` / `獲取:所有語意模型` 掃描該服務帳號可存取的資料流程與語意模型，將每一筆登錄為一筆待處理任務（狀態 `NotStarted`），並帶入相依的前置任務清單（`PRE_WORKFLOW_LIST`）。
3. **進入主迴圈**（`迴圈起點` 為 Wait 節點）：
   - **取得存取權杖**：呼叫 `獲取:Fabric Authrozation`，以 Azure AD Client Credentials 流程向 `login.microsoftonline.com` 換取 Power BI API 的 Bearer Token（`TENANT_ID`/`CLIENT_ID`/`CLIENT_SECRET` 皆透過 `$env.*` 表達式讀取 `.env`，不會寫進 workflow 本身）。
   - **輪詢進行中的任務**：若目前有 `InProgress` 任務，依類型呼叫 `獲取:資料流程狀態` / `獲取:語意模型狀態` 查詢 Power BI 更新歷史，比對更新開始時間判斷是否為本次觸發，並將結果（`Success` / 失敗狀態）寫回狀態表。
   - **依相依關係啟動新任務**：讀取所有 `NotStarted` 任務，`整理所有前置` 這個 Code 節點會比對每筆任務的 `PRE_WORKFLOW_LIST` 是否全數 `Success`（或沒有前置任務），只有符合的任務才會依類型呼叫 `行動:BI 資料流程啟動更新` 或 `行動:BI 語意模型啟動更新`（實際呼叫 Power BI REST API 觸發 `refreshes` / `transactions`），觸發成功後狀態更新為 `InProgress`。這兩個觸發workflow內建**重複觸發防護**：Power BI對「已經在刷新中」的資料集會回400錯誤（資料流程是`CdsaModelIsAlreadyRefreshing`，語意模型是`RefreshInProgressException`），Switch節點偵測到這個錯誤字樣就視為正常、直接結束，不會誤判成失敗。
   - **失敗重試**：另一條平行分支會篩選出`STATUS=Failed`且`RETRY_COUNT`未達上限的任務，交給 `行動:處理更新失敗` 處理——先把STATUS掛成`Waiting`、等待設定的重試間隔，時間到再掛回`NotStarted`並將`RETRY_COUNT`加一，讓它在下一輪迴圈被`整理所有前置`重新撿去派工，不需要自己重新呼叫觸發API。超過重試上限的任務會停在`Failed`，不再被這條分支撿到。
   - **判斷是否結束**：若狀態表中仍有 `NotStarted`、`InProgress` 或 `Waiting` 的任務，呼叫 `行動:整理非完成排程` 產生目前卡住/進行中任務的樹狀文字報告，透過 `行動:發送釘釘訊息` 送出進度通知，再回到 `迴圈起點` 繼續下一輪；若已經沒有未完成任務，則送出完成通知後結束流程。

### 相依關係機制

每筆任務可透過 `PRE_WORKFLOW_LIST`（JSON 陣列）宣告前置任務，例如語意模型通常需要等待其所依賴的多個資料流程都更新成功後才能開始重新整理，範例格式：

```json
[
  { "PRE_WORKSPACE_ID": "<workspace-id>", "PRE_DATAFLOW_ID": "<dataflow-id>" }
]
```

`整理所有前置`（主流程內）與 `行動:整理非完成排程` 這兩個 Code 節點都各自實作了對這個欄位的嚴格解析與容錯：常見的資料問題是用拖曳表達式手動拼接 JSON 字串時，GUID 值忘記加雙引號（例如 `"PRE_WORKSPACE_ID":5af7925b-...` 而非 `"5af7925b-..."`），兩個節點都會先嘗試自動修補這種格式再解析；修補後仍解析失敗的任務會被擋下、不予觸發（`整理所有前置`）或在報告中標示格式錯誤（`行動:整理非完成排程`），避免髒資料造成誤動作。

### 進度通知的文字地圖

`行動:整理非完成排程` 會把「Today BI update status」裡尚未完成（`NotStarted`／`InProgress`／`Waiting`／`Failed`）的任務，依 `PRE_WORKFLOW_LIST` 的相依關係畫成樹狀縮排文字（根節點是沒有被任何任務依賴的任務，通常是語意模型；已完成的 `Success` 分支不顯示也不往下展開；同一個前置任務被多個任務共用時，只在第一次出現完整展開，之後只標註「共用依賴，詳見上方」避免報告爆版），再交給 `行動:發送釘釘訊息` 透過 DingTalk 機器人 Webhook 送出。

## 目錄結構

```
.
├── docker-compose.yml         # postgres + n8n 容器定義
├── start.bat                  # Windows 一鍵啟動腳本
├── start.sh                   # macOS / Ubuntu 一鍵啟動腳本
├── .env.example                # 環境變數範本
├── scripts/
│   ├── export-templates.sh    # 把目前n8n裡編輯好的內容重新凍結進 n8n_templates/（開發機用）
│   └── export-templates.bat   # 同上，Windows版（需要Git Bash或WSL提供bash）
├── n8n_templates/              # 全新環境自動匯入用的凍結模板，會被 start.sh / start.bat 自動套用
│   └── workflows/              # n8n export:workflow --separate 產出，每個workflow一個json（用workflow id命名）
├── n8n_backups_workflows/
│   └── workflows.json         # 全站 n8n 工作流程備份（完整匯出，含開發草稿，用途是原始備份而非啟動模板）
└── docs/
    └── nodes/                 # n8n_templates/workflows/ 的鏡射，依「分類:名稱」慣例整理成好認的檔名/資料夾
        ├── 總行動/PBI更新.json
        ├── 獲取/Fabric Authrozation.json
        ├── 行動/整理非完成排程.json
        ├── 其他/初始化環境(注意會覆蓋同名表格).json   # 名稱沒用「分類:名稱」格式的會落在這個資料夾
        └── ...（其餘workflow同理，共15個）
```

> `docs/nodes/` 內容跟 `n8n_templates/workflows/` **完全一樣**，只是用workflow名稱當檔名/資料夾比較好瀏覽，是由 `scripts/regenerate-docs.js` 從 `n8n_templates/workflows/` 自動產生（`scripts/export-templates` 執行時會自動呼叫），**不要手動編輯這裡的檔案**，改動會在下次匯出時被覆蓋掉。

## 環境需求

- Docker / Docker Compose
- 一組具備 Power BI API 存取權限的 Azure AD 應用程式（Service Principal），並已被加入目標 Power BI 工作區
- （選用）DingTalk 群組機器人 Webhook Token，供更新結果通知使用

## 環境變數設定

複製 `.env.example` 為 `.env` 後填入實際值：

| 變數 | 說明 |
| --- | --- |
| `TENANT_ID` / `CLIENT_ID` / `CLIENT_SECRET` | Azure AD Service Principal 的租戶 ID、應用程式 ID 與密鑰，n8n 容器內用於向 Power BI API 換取 Access Token（工作流程內透過 `$env.TENANT_ID` 等表達式讀取，不會寫進 workflow 本身，所以凍結進 `n8n_templates/` 的模板不含機密） |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | n8n 所使用的 Postgres 資料庫帳密與資料庫名稱 |
| `N8N_ENCRYPTION_KEY` | n8n 憑證加密金鑰，用於加密儲存在資料庫中的認證資訊 |
| `GENERIC_TIMEZONE` | n8n 排程執行時區（例如 `Asia/Taipei`） |
| `DINGTALK_BOT` | DingTalk 機器人 Webhook 的 access_token，供 `行動：發送釘釘訊息` 工作流程使用 |

## 快速開始

Windows：

```bat
start.bat
```

macOS / Ubuntu：

```bash
./start.sh
```

兩份腳本邏輯一致：在 `.env` 不存在時自動從 `.env.example` 複製一份、以 `docker compose up -d --build` 啟動容器、等待 n8n 完成啟動後，**自動偵測是否為全新環境**——如果偵測到沒有任何 workflow，會自動把 `n8n_templates/workflows/` 底下凍結好的模板匯入進去（匯入後預設為停用狀態，需自行到 n8n 介面手動啟用）；如果偵測到環境已有 workflow，則略過匯入，不會重複套用或覆蓋既有內容。

**Data Table 不會自動建立**（n8n 沒有官方 CLI/API 支援匯出匯入 Data Table 結構），全新環境第一次啟動時，腳本偵測到沒有 Data Table 會印出提示，需要手動執行一次 `初始化環境` 這個workflow（Manual Trigger，在n8n介面按「Execute workflow」即可，見下方〈狀態資料表〉章節），之後就不用再重建。

啟動後於瀏覽器開啟 `http://localhost:6001` 進入 n8n 編輯介面。

停止服務：

```bash
docker compose down
```

## n8n_templates/ 與自動匯入

`n8n_templates/` 是給 `start.bat` / `start.sh` 在全新環境自動套用的凍結模板，跟 `n8n_backups_workflows/`（原始全量備份，含開發草稿）用途不同。Workflow（`n8n_templates/workflows/`）用 n8n 官方 CLI `export:workflow` / `import:workflow` 匯出匯入，完全自動化、官方支援。Data Table 的結構因為 n8n 沒有官方 CLI/API 支援匯出匯入，改成靠 `初始化環境` 這個workflow用 Data Table 節點原生的 `create` 操作（`createIfNotExists`）自己建表、有資料則清空重建，這個workflow本身也隨其他15個一起被凍結進 `n8n_templates/workflows/`，只是需要在全新環境手動執行一次（見〈狀態資料表〉章節）。

在 n8n 介面編輯完 workflow 後，若要把最新內容重新凍結進 `n8n_templates/`：

```bash
# macOS / Ubuntu，或 Windows 上有 Git Bash / WSL：
bash scripts/export-templates.sh

# Windows（實質是呼叫上面那份 bash 腳本，需要 Git for Windows 或 WSL）：
scripts\export-templates.bat
```

這個腳本會自動檢查匯出的 workflow json 有沒有意外把 `.env` 裡的機密值（`CLIENT_SECRET`、`TENANT_ID`、`CLIENT_ID`、`DINGTALK_BOT`）或非空的 `pinData`（過去發生過 pinData 裡殘留真實 Power BI access token 與工作區 GUID 的情況）夾帶進去，若有會印出警告，但不會自動修改，commit 前務必人工複查。

## 主要工作流程一覽

`n8n_templates/workflows/` 目前共 15 個 workflow 有被追蹤進版本控制，均已在文字報告與DingTalk通知的表達式裡把機密改成透過`$env.*`讀取（見〈環境變數設定〉），可以安全凍結進版本控制。**`總行動:PBI更新`本身的凍結檔案刻意被`.gitignore`排除**——這個正式在跑的主流程，隨著時間會累積真實、可識別業務內容的資料集登錄（見〈使用流程〉第4步），不適合放進共用的repo；要看結構參考，改看不含真實資料的`總行動:PBI更新_模版`。也因此全新環境自動匯入的15個workflow裡不含`總行動:PBI更新`，需要照〈使用流程〉自行從`_模版`建立：

| 分類 | 工作流程 | 啟用 | 用途 |
| --- | --- | --- | --- |
| 總行動 | `總行動:PBI更新` | ✅ | 主排程入口，`Schedule Trigger`每日01:00啟動，統籌整個批次更新流程。**本身未被追蹤進版本控制**（見上方說明），此列僅供了解其角色 |
| 獲取 | `獲取:Fabric Authrozation` | ✅ | 以 Client Credentials 流程向 Azure AD 取得 Power BI API Access Token |
| 獲取 | `獲取:虛擬帳號可存取工作區的資料流程與語意模型` | ✅ | 讀取工作區快取表，逐一工作區掃描服務帳號可存取的資料流程與語意模型並登錄為待處理任務 |
| 獲取 | `獲取:所有資料流程` / `獲取:所有語意模型` | ✅ | 列出指定工作區下的資料流程／語意模型 |
| 獲取 | `獲取:資料流程狀態` / `獲取:語意模型狀態` | ✅ | 查詢更新歷史，判斷本次觸發是否已完成，並回寫狀態表 |
| 獲取 | `獲取:全Workspace` | ✅ | **維護性workflow**：掃描服務帳號可存取的全部工作區，更新/新增/刪除「Power BI workspaces」快取表裡的紀錄。目前沒有排程也沒被主流程呼叫，需要手動執行或自行加上排程來保持快取更新（見〈已知狀態與限制〉） |
| 行動 | `行動:查詢已知工作區` | ✅ | 讀取「Power BI workspaces」快取表，供掃描流程取得要遍歷的工作區清單 |
| 行動 | `行動:BI 資料流程啟動更新` / `行動:BI 語意模型啟動更新` | ✅ | 呼叫 Power BI REST API 實際觸發更新（`refreshes` / `transactions`），內建重複觸發防護（見下方說明） |
| 行動 | `行動:處理更新失敗` | ✅ | 對失敗且未達重試上限的任務，掛`Waiting`等待重試間隔，時間到再掛回`NotStarted`並累加`RETRY_COUNT`，交由主迴圈既有派工機制重新觸發 |
| 行動 | `行動:整理非完成排程` | ✅ | 把尚未完成的任務依前置關係整理成樹狀文字報告，供DingTalk通知使用 |
| 行動 | `行動:發送釘釘訊息` | ✅ | 透過 DingTalk 機器人 Webhook 發送文字通知 |
| 其他 | `初始化環境(注意會覆蓋同名表格)` | ❌ | Manual Trigger，一次性建立/清空兩個Data Table，全新環境需手動執行一次（見〈狀態資料表〉章節） |
| 其他 | `總行動:PBI更新_模版` | ❌ | `總行動:PBI更新`的獨立參考副本，內含`Model1`、`Dataflow - ETL1`等通用命名的登錄節點範例，不含真實工作區資訊，供學習如何手動登錄有相依關係的資料流程/語意模型（見〈使用流程〉），本身不會被執行 |

### 重複觸發防護與失敗重試

`行動:BI 資料流程啟動更新` / `行動:BI 語意模型啟動更新` 呼叫Power BI API時，若目標資料集已經在刷新中，API會回400錯誤（資料流程是`error.message`包含`CdsaModelIsAlreadyRefreshing`，語意模型是包含`RefreshInProgressException`）。這兩個workflow的httpRequest節點設定成錯誤時也把回應內容往下傳（而不是直接中斷workflow），後面接一個Switch節點比對這個錯誤字樣，符合就視為正常、直接結束，不會誤判成觸發失敗。

> 目前這個Switch只處理了「已在進行中」這一種情況；真正的其他錯誤（例如權限被拿掉）預留了一個`啟動失敗`節點（會把STATUS寫成`Failed`），但**目前還沒接線**，屬於刻意保留的擴充點，還不會被自動偵測（見〈已知狀態與限制〉）。

失敗後的重試由 `行動:處理更新失敗` 負責：`總行動:PBI更新` 會篩選出`STATUS=Failed`且`RETRY_COUNT`小於重試上限的任務交給它處理，掛`Waiting`等待一段設定的間隔後，改回`NotStarted`並將`RETRY_COUNT`加一，之後就交還給主迴圈既有的`整理所有前置`派工機制，不需要重新呼叫觸發API。超過重試上限的任務會維持在`Failed`，不會再被這條分支撿到，並持續出現在`行動:整理非完成排程`的進度報告裡。

## 狀態資料表（Data Table，需手動執行一次`初始化環境`）

n8n 沒有官方 CLI/API 可以匯出匯入 Data Table 結構，所以 `start.bat` / `start.sh` 不會自動建立它們；全新環境第一次啟動時，腳本偵測到缺少會印出提示，需要到 n8n 介面手動執行一次 `初始化環境` 這個workflow（左側找到它，按「Execute workflow」），之後就不用再重建。

它內部用 Data Table 節點原生的 `create` 操作（帶`createIfNotExists`選項）分別建立以下兩個表，已存在則會清空重建，欄位與型別如下：

### Today BI update status

流程執行狀態表，每日流程開始時會清空重建，主要欄位：

| 欄位 | 型別 | 說明 |
| --- | --- | --- |
| `WORKSPACE_ID` / `DATASET_ID` | string | Power BI 工作區 ID 與資料流程／語意模型 ID |
| `DATASET_NAME` | string | 顯示名稱 |
| `TYPE` | string | `Dataflow` 或 `Model` |
| `STATUS` | string | `NotStarted` → `InProgress` → `Success` / 失敗狀態 |
| `PRE_WORKFLOW_LIST` | string | 前置任務清單（JSON），需全數 `Success` 才會觸發本任務 |
| `RETRY_COUNT` | number | 重試次數 |
| `ERROR_MESSAGE` | string | 錯誤訊息（供後續擴充） |

### Power BI workspaces

服務帳號可存取工作區的快取表，欄位：

| 欄位 | 型別 | 說明 |
| --- | --- | --- |
| `WORKSPACE_ID` | string | Power BI 工作區 ID |
| `WORKSPACE_NAME` | string | 工作區顯示名稱 |

## 已知狀態與限制

- `獲取:全Workspace`（維護「Power BI workspaces」快取表的workflow）目前沒有自己的排程、也沒被主流程呼叫，工作區異動（新增/移除/改名）不會自動反映到快取表，需要手動執行一次，或自行幫它加上 Schedule Trigger。
- `行動:BI 資料流程啟動更新` / `行動:BI 語意模型啟動更新` 目前只偵測「已在進行中」這一種觸發錯誤；真正的其他錯誤（例如權限被拿掉、額度用完）預留了`啟動失敗`節點但還沒接線，不會被自動標記`Failed`、也就不會進入`行動:處理更新失敗`的重試流程，這類任務目前會卡住不動，需要人工到n8n執行紀錄裡查。

## 安全性提醒

`.env` 內含 Azure AD 密鑰、資料庫密碼與 n8n 加密金鑰，切勿提交至版本控制，目前 `.gitignore` 已排除 `.env`。
