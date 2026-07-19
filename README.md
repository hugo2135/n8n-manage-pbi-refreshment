# n8n-manage-pbi-refreshment

以 [n8n](https://n8n.io/) 打造的 Power BI（Microsoft Fabric）批次更新自動化平台。透過 n8n 工作流程排程觸發「資料流程（Dataflow）」與「語意模型（Semantic Model）」的更新，並依照設定的相依關係（前置任務）依序執行、輪詢更新狀態，直到全部完成。

## 系統架構

專案以 Docker Compose 啟動兩個服務：

- **postgres**（`postgres:15-alpine`）：n8n 的資料庫，同時也作為 n8n Data Table 功能的儲存後端，用來記錄「當日 Power BI 更新狀態表」。
- **n8n**（`n8nio/n8n:latest`）：實際執行自動化流程的引擎，對外開放 `http://localhost:5678`。

n8n 容器內建了呼叫 Power BI REST API 所需的 Azure AD 應用程式（Service Principal）認證資訊，並可選擇性整合 DingTalk（釘釘）機器人推播通知。

## 核心運作流程

主要邏輯集中在工作流程 **`總行動:Power BI更新`**（目前為停用狀態，見〈已知狀態與限制〉），大致步驟如下：

1. **排程觸發**：`Schedule Trigger` 每日固定時間啟動（目前設定為每天 01:00）。
2. **讀取全域參數**：呼叫 `參數: 全域變數` 取得 `TENANT_ID`、`WORKSPACE_ID_ONE` 等共用設定。
3. **清空並重建當日狀態表**：清空 n8n Data Table「Today BI update status V2」，再呼叫 `獲取：虛擬帳號可存取工作區的資料流程與語意模型`，掃描服務帳號可存取的所有工作區，將每一個資料流程／語意模型登錄為一筆待處理任務（狀態 `NotStarted`），並依需求填入相依的前置任務清單（`PRE_WORKFLOW_LIST`）。
4. **取得存取權杖**：呼叫 `獲取:Fabric Authrozation`，以 Azure AD Client Credentials 流程向 `login.microsoftonline.com` 換取 Power BI API 的 Bearer Token。
5. **依相依關係啟動更新（迴圈）**：
   - 讀取所有 `NotStarted` 任務，比對其 `PRE_WORKFLOW_LIST` 中列出的前置資料流程／語意模型是否皆已成功（`Success`）。
   - 只有前置任務全部完成的任務才會被送出，依類型呼叫 `行動:BI "資料流程"啟動更新V2` 或 `行動:BI "語意模型"啟動更新V2`（實際呼叫 Power BI REST API 觸發 `refreshes` / `transactions`）。
   - 觸發成功後狀態表更新為 `InProgress`。
6. **輪詢更新狀態**：透過 `獲取:BI "資料流程"狀態` / `獲取:BI "語意模型"狀態` 查詢 Power BI 更新歷史，比對更新開始時間判斷是否為本次觸發，並將結果（成功／失敗）寫回狀態表。
7. **重複迴圈**：以 `Wait`（30 秒）搭配迴圈持續執行步驟 5–6，直到狀態表中不再有 `NotStarted` 或 `InProgress` 的任務為止。
8. **完成通知（規劃中）**：流程結束後預留了發送 DingTalk 通知的節點，實際的訊息推播邏輯已獨立成 `行動：發送釘釘訊息` 工作流程（透過 DingTalk 機器人 Webhook 發送文字訊息），但尚未串接進主流程。

### 相依關係機制

每筆任務可透過 `PRE_WORKFLOW_LIST`（JSON 陣列）宣告前置任務，例如語意模型通常需要等待其所依賴的多個資料流程都更新成功後才能開始重新整理，範例格式：

```json
[
  { "PRE_WORKSPACE_ID": "<workspace-id>", "PRE_DATAFLOW_ID": "<dataflow-id>" }
]
```

流程中的 Code 節點會嚴格驗證此欄位格式，格式錯誤或解析失敗的任務會被擋下、不予觸發，避免髒資料造成誤動作。

## 目錄結構

```
.
├── docker-compose.yml         # postgres + n8n 容器定義
├── start.bat                  # Windows 一鍵啟動腳本
├── .env.example                # 環境變數範本
├── n8n_backups_workflows/
│   └── workflows.json         # 全站 n8n 工作流程備份（完整匯出，共 27 個工作流程）
└── docs/
    └── nodes/                 # 部分關鍵工作流程的節點匯出，作為文件參考
        ├── 參數/全域變數.json
        ├── 獲取/Fabric Authrozation.json
        ├── 獲取/BI 資料流程狀態.json
        ├── 獲取/BI 語意模型狀態.json
        ├── 獲取/虛擬帳號可存取工作區的資料流程與語意模型.json
        ├── 行動/BI 資料流程啟動更新V2.json
        ├── 行動/BI 語意模型啟動更新V2.json
        └── 總行動/PBI更新.json
```

## 環境需求

- Docker / Docker Compose
- 一組具備 Power BI API 存取權限的 Azure AD 應用程式（Service Principal），並已被加入目標 Power BI 工作區
- （選用）DingTalk 群組機器人 Webhook Token，供更新結果通知使用

## 環境變數設定

複製 `.env.example` 為 `.env` 後填入實際值：

| 變數 | 說明 |
| --- | --- |
| `CLIENT_ID` / `CLIENT_SECRET` | Azure AD Service Principal 的應用程式 ID 與密鑰，n8n 容器內用於向 Power BI API 換取 Access Token |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | n8n 所使用的 Postgres 資料庫帳密與資料庫名稱 |
| `N8N_ENCRYPTION_KEY` | n8n 憑證加密金鑰，用於加密儲存在資料庫中的認證資訊 |
| `GENERIC_TIMEZONE` | n8n 排程執行時區（例如 `Asia/Taipei`） |
| `DINGTALK_BOT` | DingTalk 機器人 Webhook 的 access_token，供 `行動：發送釘釘訊息` 工作流程使用 |

> 另外，`Config: 全域變數` 工作流程內仍需手動設定 `TENANT_ID`（Azure AD 租戶 ID）與 `WORKSPACE_ID_ONE` 等參數，此為 n8n 平台內設定，不在 `.env` 檔案中。

## 快速開始

Windows 環境可直接執行：

```bat
start.bat
```

此腳本會在 `.env` 不存在時自動從 `.env.example` 複製一份，接著以 `docker compose up -d --build` 啟動容器。也可手動執行：

```bash
docker compose up -d --build
```

啟動後於瀏覽器開啟 `http://localhost:5678` 進入 n8n 編輯介面。工作流程本身（`n8n_backups_workflows/workflows.json`）需另行匯入至 n8n 實例中才能執行；`docs/nodes/` 內容僅供閱讀參考，非可直接匯入的完整工作流程。

停止服務：

```bash
docker compose down
```

## 主要工作流程一覽

| 分類 | 工作流程 | 用途 |
| --- | --- | --- |
| 總行動 | `總行動:Power BI更新` | 主排程入口，統籌整個批次更新流程（目前為停用狀態） |
| 參數 | `參數: 全域變數` | 提供 `TENANT_ID` 等共用設定值 |
| 獲取 | `獲取:Fabric Authrozation` | 以 Client Credentials 流程取得 Power BI API Access Token |
| 獲取 | `獲取：虛擬帳號可存取工作區的資料流程與語意模型` | 掃描服務帳號可存取的工作區，彙整其下所有資料流程與語意模型 |
| 獲取 | `獲取：全Workspace` / `行動：查詢全工作區` | 列出所有可存取的工作區 |
| 獲取 | `獲取:所有資料流程` / `獲取:所有語意模型` | 列出指定工作區下的資料流程／語意模型 |
| 獲取 | `獲取:BI "資料流程"狀態` / `獲取:BI "語意模型"狀態` | 查詢更新歷史，判斷本次觸發是否已完成，並回寫狀態表 |
| 行動 | `行動:BI "資料流程"啟動更新V2` / `行動:BI "語意模型"啟動更新V2` | 呼叫 Power BI REST API 實際觸發更新 |
| 行動 | `行動：發送釘釘訊息` | 透過 DingTalk 機器人 Webhook 發送文字通知 |

其餘標示為 `My workflow`、`copy` 等命名的工作流程為開發過程中的草稿／舊版本，目前多為停用（inactive）狀態。

## 狀態資料表：Today BI update status V2

流程執行狀態儲存於 n8n Data Table「Today BI update status V2」，每日流程開始時會清空重建，主要欄位：

| 欄位 | 說明 |
| --- | --- |
| `WORKSPACE_ID` / `DATASET_ID` | Power BI 工作區 ID 與資料流程／語意模型 ID |
| `DATASET_NAME` | 顯示名稱 |
| `TYPE` | `Dataflow` 或 `Model` |
| `STATUS` | `NotStarted` → `InProgress` → `Success` / 失敗狀態 |
| `PRE_WORKFLOW_LIST` | 前置任務清單（JSON），需全數 `Success` 才會觸發本任務 |
| `RETRY_COUNT` / `ERROR_MESSAGE` | 重試次數與錯誤訊息欄位（供後續擴充） |

## 已知狀態與限制

- 主排程工作流程 `總行動:Power BI更新` 目前為**停用**狀態，需在 n8n 中手動啟用後排程才會生效。
- 更新完成後的 DingTalk 通知節點在主流程中仍為暫時的 NoOp 佔位節點，尚未正式串接 `行動：發送釘釘訊息`。
- `Config: 全域變數` 工作流程內的 `TENANT_ID`、`WORKSPACE_ID_ONE` 在備份中為空值，需依實際 Azure 租戶與工作區手動填入。
- `n8n_backups_workflows/workflows.json` 為完整工作流程匯出檔，其中可能包含測試用的存取權杖（pinned execution data）；匯入或分享前請先確認並清除其中的敏感資訊。

## 安全性提醒

`.env` 內含 Azure AD 密鑰、資料庫密碼與 n8n 加密金鑰，切勿提交至版本控制。目前專案根目錄的 `.gitignore` 為空，建議至少排除 `.env` 與 `n8n_backups_workflows/`（內含可能過期但仍應視為機密的存取權杖）。
