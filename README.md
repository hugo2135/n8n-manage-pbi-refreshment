# n8n-manage-pbi-refreshment

A batch refresh-orchestration platform for Power BI (Microsoft Fabric), built on [n8n](https://n8n.io/). A scheduled master workflow triggers **dataflow** and **semantic model** refreshes, executes them in declared dependency order, polls refresh status, and pushes dependency-tree progress reports to DingTalk until everything completes — replacing the one-workflow-per-dependency sprawl of Power Automate with a single dependency-aware pipeline.

## Usage flow

Rough order for a from-scratch setup:

1. **Configure `.env`** — copy `.env.example`, fill in the Azure AD Service Principal (`TENANT_ID`/`CLIENT_ID`/`CLIENT_SECRET`), Postgres credentials, `N8N_ENCRYPTION_KEY`, timezone, and (optional) `DINGTALK_BOT`
2. **Bring up the containers** — `start.bat` (Windows) or `./start.sh` (macOS/Ubuntu); auto-imports the frozen workflow templates on a fresh instance. This does **not** include `總行動:PBI更新` itself (see "Reproducible deployment" below) — it's built manually from `總行動:PBI更新_模版` in the next step
3. **Initialize the Data Tables** — on a fresh instance, run the `初始化環境` workflow once from the n8n UI (Manual Trigger → Execute workflow) to create *Today BI update status* and *Power BI workspaces*
4. **Build the master workflow and register the dataflows/models to track** — duplicate `總行動:PBI更新_模版` and save it as the real `總行動:PBI更新`. The workspace scan (`獲取:虛擬帳號可存取工作區的資料流程與語意模型`) discovers everything the service account can see, but can't infer dependencies between items. Declare dependent items by hand, following the pattern of the generic example nodes in `_模版` (`Model1`, `Dataflow - ETL1`, ...):
   1. Duplicate an existing registration node as a starting point
   2. Point `WORKSPACE_ID`/`DATASET_ID` at the target workspace/dataset, e.g. `={{ $('Call \'獲取:虛擬帳號可存取工作區的資料流程與語意模型\'').item.json.workspaces['<workspace>']['語意模型'][0]['<dataset name>'] }}` (use `['資料流程']` instead of `['語意模型']` for dataflows)
   3. Set `DATASET_NAME` to match
   4. Fill in `PRE_WORKFLOW_LIST` — one object per prerequisite, using the same expression pattern for `PRE_WORKSPACE_ID`/`PRE_DATAFLOW_ID`
   5. Rename the node itself so it doesn't collide with other registrations

## System architecture

Two services via Docker Compose:

- **postgres** (`postgres:15-alpine`) — n8n's database, also backing the n8n Data Tables that store the daily refresh-status table and the workspace cache
- **n8n** (`n8nio/n8n:latest`) — the automation engine, exposed at `http://localhost:6001`

Azure AD Service Principal credentials are read inside workflows via `$env.*` expressions from `.env` — **secrets never live in the workflow definitions**, so the frozen templates are safe to version-control.

## How the master pipeline works

The master workflow (enabled, `Schedule Trigger` daily at 01:00):

1. **Rebuild the daily status table** — records the run start time, clears the *Today BI update status* Data Table, reads the *Power BI workspaces* cache table, scans each workspace for the service account's dataflows and semantic models, and registers every item as a `NotStarted` task with its prerequisite list (`PRE_WORKFLOW_LIST`)
2. **Main loop** (anchored on a `Wait` node):
   - **Acquire token** — Azure AD Client Credentials flow → Power BI API Bearer token
   - **Poll in-progress tasks** — queries refresh history, matches start times to confirm this run's triggers, writes `Success` / failure states back
   - **Dispatch by dependency** — a Code node checks each `NotStarted` task's `PRE_WORKFLOW_LIST`; only tasks whose prerequisites are all `Success` (or that have none) get triggered via the Power BI REST API (`refreshes` / `transactions`) and move to `InProgress`. Both trigger workflows guard against duplicate triggers: Power BI returns a 400 when a refresh is already running (`CdsaModelIsAlreadyRefreshing` for dataflows, `RefreshInProgressException` for models), and a Switch node matching that error text treats it as a no-op instead of a failure
   - **Retry on failure** — a parallel branch filters `Failed` tasks under their retry limit into `行動:處理更新失敗`, which parks `STATUS=Waiting` for a configurable latency, then flips back to `NotStarted` with `RETRY_COUNT+1` so the existing dispatch step above picks it back up; tasks that exhaust the limit stay `Failed`
   - **Progress notification** — while unfinished tasks (`NotStarted`/`InProgress`/`Waiting`) remain, a report workflow renders them as a dependency-tree text map (roots first, completed branches pruned, shared dependencies expanded once) and sends it through the DingTalk bot webhook, then the loop repeats; a completion notice is sent when nothing is left

### Dependency mechanism with fault tolerance

Each task declares prerequisites as a JSON array:

```json
[
  { "PRE_WORKSPACE_ID": "<workspace-id>", "PRE_DATAFLOW_ID": "<dataflow-id>" }
]
```

Both parsing Code nodes implement strict validation **with auto-repair**: the most common data issue — GUID values missing their quotes when JSON strings are hand-assembled from drag-and-drop expressions — is patched automatically before parsing. Tasks that still fail to parse are blocked from dispatch (or flagged in the report), so malformed data can never cause unintended refreshes.

## Reproducible deployment: frozen templates

- `n8n_templates/workflows/` holds 15 frozen workflow templates (exported with the official n8n CLI). `start.bat` / `start.sh` detect a fresh environment and **auto-import** them (skipped if workflows already exist — no overwrites)
- `總行動:PBI更新`'s own frozen file is deliberately excluded (`.gitignore`) — the live master workflow accumulates real, business-identifying dataset registrations over time (see "Usage flow" step 4) that shouldn't land in a shared repo. Browse `總行動:PBI更新_模版` instead for the sanitized structural reference; a fresh environment imports the other 15 and needs the master workflow rebuilt or restored from a private backup
- Data Tables can't be exported/imported via official CLI, so table creation is itself a workflow: `初始化環境` (imported along with everything else) creates both tables if missing and clears them if not, using the Data Table node's native `create` operation (`createIfNotExists`); the start scripts detect missing tables and prompt you to run it once from the n8n UI
- `scripts/export-templates` re-freezes edited workflows and **automatically scans for leaked secrets** (`CLIENT_SECRET`, `TENANT_ID`, `CLIENT_ID`, `DINGTALK_BOT`) **and non-empty pinData** (a past incident left real access tokens in pinned execution data) — warnings are printed for manual review before commit

## Data Tables

**Today BI update status** — rebuilt daily: `WORKSPACE_ID` / `DATASET_ID` / `DATASET_NAME` / `TYPE` (`Dataflow`|`Model`) / `STATUS` (`NotStarted` → `InProgress` → `Success`/failure) / `PRE_WORKFLOW_LIST` (JSON) / `RETRY_COUNT` / `ERROR_MESSAGE`

**Power BI workspaces** — cache of workspaces accessible to the service account: `WORKSPACE_ID` / `WORKSPACE_NAME`

## Requirements & setup

- Docker / Docker Compose; an Azure AD Service Principal with Power BI API access, added to the target workspaces; (optional) DingTalk bot webhook token

```bash
cp .env.example .env   # TENANT_ID / CLIENT_ID / CLIENT_SECRET, Postgres credentials, N8N_ENCRYPTION_KEY, timezone, DINGTALK_BOT
./start.sh             # macOS / Ubuntu (Windows: start.bat)
```

The start script creates `.env` from the example if missing, brings up the containers, waits for n8n, and auto-imports templates on a fresh instance (imported workflows arrive disabled — enable them in the UI). Open `http://localhost:6001`.

## Known status & limitations

- The workspace-cache maintenance workflow has no schedule and isn't called by the master flow — run it manually (or add a trigger) after workspace changes
- The trigger workflows only detect the "already refreshing" duplicate-trigger case. Genuine other trigger errors (permission revoked, quota exhausted) have a `啟動失敗` node ready to mark `STATUS=Failed`, but it isn't wired up yet — those tasks currently just stall instead of entering the retry/escalation path

## Security notes

`.env` (Azure AD secret, database credentials, n8n encryption key) is git-ignored — never commit it. Workflow templates read all secrets via `$env.*` expressions, keeping the versioned files clean; the export script additionally scans every freeze for leaked secrets and pinData before commit.
