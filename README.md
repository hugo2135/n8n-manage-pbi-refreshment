# n8n-manage-pbi-refreshment

以 [n8n](https://n8n.io/) 打造的 Power BI（Microsoft Fabric）批次更新自動化平台。透過 n8n 工作流程排程觸發「資料流程（Dataflow）」與「語意模型（Semantic Model）」的更新，並依照設定的相依關係（前置任務）依序執行、輪詢更新狀態，直到全部完成。

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
   - **依相依關係啟動新任務**：讀取所有 `NotStarted` 任務，`整理所有前置` 這個 Code 節點會比對每筆任務的 `PRE_WORKFLOW_LIST` 是否全數 `Success`（或沒有前置任務），只有符合的任務才會依類型呼叫 `行動:BI 資料流程啟動更新` 或 `行動:BI 語意模型啟動更新`（實際呼叫 Power BI REST API 觸發 `refreshes` / `transactions`），觸發成功後狀態更新為 `InProgress`。
   - **判斷是否結束**：若狀態表中仍有 `NotStarted` 或 `InProgress` 的任務，呼叫 `行動:整理非完成排程` 產生目前卡住/進行中任務的樹狀文字報告，透過 `行動:發送釘釘訊息` 送出進度通知，再回到 `迴圈起點` 繼續下一輪；若已經沒有未完成任務，則送出完成通知後結束流程。

### 相依關係機制

每筆任務可透過 `PRE_WORKFLOW_LIST`（JSON 陣列）宣告前置任務，例如語意模型通常需要等待其所依賴的多個資料流程都更新成功後才能開始重新整理，範例格式：

```json
[
  { "PRE_WORKSPACE_ID": "<workspace-id>", "PRE_DATAFLOW_ID": "<dataflow-id>" }
]
```

`整理所有前置`（主流程內）與 `行動:整理非完成排程` 這兩個 Code 節點都各自實作了對這個欄位的嚴格解析與容錯：常見的資料問題是用拖曳表達式手動拼接 JSON 字串時，GUID 值忘記加雙引號（例如 `"PRE_WORKSPACE_ID":5af7925b-...` 而非 `"5af7925b-..."`），兩個節點都會先嘗試自動修補這種格式再解析；修補後仍解析失敗的任務會被擋下、不予觸發（`整理所有前置`）或在報告中標示格式錯誤（`行動:整理非完成排程`），避免髒資料造成誤動作。

### 進度通知的文字地圖

`行動:整理非完成排程` 會把「Today BI update status」裡尚未完成（`NotStarted`／`InProgress`／`Failed`）的任務，依 `PRE_WORKFLOW_LIST` 的相依關係畫成樹狀縮排文字（根節點是沒有被任何任務依賴的任務，通常是語意模型；已完成的 `Success` 分支不顯示也不往下展開；同一個前置任務被多個任務共用時，只在第一次出現完整展開，之後只標註「共用依賴，詳見上方」避免報告爆版），再交給 `行動:發送釘釘訊息` 透過 DingTalk 機器人 Webhook 送出。

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
│   ├── workflows/              # n8n export:workflow --separate 產出，每個workflow一個json（用workflow id命名）
│   └── data_tables/            # Data Table的CSV範本，供n8n介面「Import CSV」手動匯入用（見〈狀態資料表〉章節）
│       ├── today_bi_update_status.csv
│       └── power_bi_workspaces.csv
├── n8n_backups_workflows/
│   └── workflows.json         # 全站 n8n 工作流程備份（完整匯出，含開發草稿，用途是原始備份而非啟動模板）
└── docs/
    └── nodes/                 # n8n_templates/workflows/ 的鏡射，依「分類:名稱」慣例整理成好認的檔名/資料夾
        ├── 總行動/PBI更新.json
        ├── 獲取/Fabric Authrozation.json
        ├── 行動/整理非完成排程.json
        └── ...（其餘workflow同理，共14個）
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

**Data Table 不會自動建立**（n8n 沒有官方 CLI/API 支援匯出匯入 Data Table 結構），全新環境第一次啟動時，腳本偵測到沒有 Data Table 會印出提示，需要手動建立一次，最快的方式是用 `n8n_templates/data_tables/` 底下的 CSV 範本匯入（見下方〈狀態資料表〉章節），之後就不用再重建。

啟動後於瀏覽器開啟 `http://localhost:6001` 進入 n8n 編輯介面。

停止服務：

```bash
docker compose down
```

## n8n_templates/ 與自動匯入

`n8n_templates/` 是給 `start.bat` / `start.sh` 在全新環境自動套用的凍結模板，跟 `n8n_backups_workflows/`（原始全量備份，含開發草稿）用途不同。目前只有 workflow（`n8n_templates/workflows/`）會這樣自動化：用 n8n 官方 CLI `export:workflow` / `import:workflow` 匯出匯入，完全自動化、官方支援。Data Table 的結構因為 n8n 沒有官方 CLI/API 支援匯出匯入，沒有做自動化，改成手動建立一次（見〈狀態資料表〉章節）。

在 n8n 介面編輯完 workflow 後，若要把最新內容重新凍結進 `n8n_templates/`：

```bash
# macOS / Ubuntu，或 Windows 上有 Git Bash / WSL：
bash scripts/export-templates.sh

# Windows（實質是呼叫上面那份 bash 腳本，需要 Git for Windows 或 WSL）：
scripts\export-templates.bat
```

這個腳本會自動檢查匯出的 workflow json 有沒有意外把 `.env` 裡的機密值（`CLIENT_SECRET`、`TENANT_ID`、`CLIENT_ID`、`DINGTALK_BOT`）或非空的 `pinData`（過去發生過 pinData 裡殘留真實 Power BI access token 與工作區 GUID 的情況）夾帶進去，若有會印出警告，但不會自動修改，commit 前務必人工複查。

## 主要工作流程一覽

`n8n_templates/workflows/` 目前共 14 個 workflow，均已在文字報告與DingTalk通知的表達式裡把機密改成透過`$env.*`讀取（見〈環境變數設定〉），可以安全凍結進版本控制：

| 分類 | 工作流程 | 啟用 | 用途 |
| --- | --- | --- | --- |
| 總行動 | `總行動:PBI更新` | ✅ | 主排程入口，`Schedule Trigger`每日01:00啟動，統籌整個批次更新流程 |
| 總行動 | `總行動:PBI更新 測試` | ❌ | 上面主流程的開發測試副本，內含幾個寫死名稱的Data Table測試節點，非正式流程 |
| 獲取 | `獲取:Fabric Authrozation` | ✅ | 以 Client Credentials 流程向 Azure AD 取得 Power BI API Access Token |
| 獲取 | `獲取:虛擬帳號可存取工作區的資料流程與語意模型` | ✅ | 讀取工作區快取表，逐一工作區掃描服務帳號可存取的資料流程與語意模型並登錄為待處理任務 |
| 獲取 | `獲取:所有資料流程` / `獲取:所有語意模型` | ✅ | 列出指定工作區下的資料流程／語意模型 |
| 獲取 | `獲取:資料流程狀態` / `獲取:語意模型狀態` | ✅ | 查詢更新歷史，判斷本次觸發是否已完成，並回寫狀態表 |
| 獲取 | `獲取:全Workspace` | ✅ | **維護性workflow**：掃描服務帳號可存取的全部工作區，更新/新增/刪除「Power BI workspaces」快取表裡的紀錄。目前沒有排程也沒被主流程呼叫，需要手動執行或自行加上排程來保持快取更新（見〈已知狀態與限制〉） |
| 行動 | `行動:查詢已知工作區` | ✅ | 讀取「Power BI workspaces」快取表，供掃描流程取得要遍歷的工作區清單 |
| 行動 | `行動:BI 資料流程啟動更新` / `行動:BI 語意模型啟動更新` | ✅ | 呼叫 Power BI REST API 實際觸發更新（`refreshes` / `transactions`） |
| 行動 | `行動:整理非完成排程` | ✅ | 把尚未完成的任務依前置關係整理成樹狀文字報告，供DingTalk通知使用 |
| 行動 | `行動:發送釘釘訊息` | ✅ | 透過 DingTalk 機器人 Webhook 發送文字通知 |

## 狀態資料表（Data Table，需手動建立一次）

n8n 沒有官方 CLI/API 可以匯出匯入 Data Table 結構，所以 `start.bat` / `start.sh` 不會自動建立它們；全新環境第一次啟動時，腳本偵測到缺少會印出提示，需要手動建立一次，之後就不用再重建。

**最快的方式**：到 n8n 介面左側「Data Tables」分頁，用「Import CSV」功能分別匯入 `n8n_templates/data_tables/today_bi_update_status.csv` 與 `n8n_templates/data_tables/power_bi_workspaces.csv`，n8n 會依照 CSV 的欄位自動建表。這兩份 CSV 各帶一筆範例列（讓 `RETRY_COUNT` 能被正確判斷成 number 型別），**匯入後記得刪掉這筆範例列**。也可以不用 CSV，直接在 UI 裡手動新增欄位，欄位與型別如下：

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
- `n8n_backups_workflows/workflows.json` 為完整工作流程匯出檔，其中可能包含測試用的存取權杖（pinned execution data）；匯入或分享前請先確認並清除其中的敏感資訊。
- `n8n_templates/workflows/` 每次用 `scripts/export-templates` 更新時會自動掃描機密與pinData，但無法保證涵蓋所有情況（例如新增了會把機密塞進其他非pinData欄位的node），commit前仍建議人工複查。

## 安全性提醒

`.env` 內含 Azure AD 密鑰、資料庫密碼與 n8n 加密金鑰，切勿提交至版本控制，目前 `.gitignore` 已排除 `.env`。`n8n_backups_workflows/`（內含可能過期但仍應視為機密的存取權杖）目前仍會被提交，commit 前建議人工複查其中有無殘留 pinData／token；`n8n_templates/` 因為是特意整理過的凍結模板，每次用 `scripts/export-templates` 更新時腳本都會自動做一次機密與 pinData 掃描，相對風險較低，但仍建議養成commit前複查的習慣。
