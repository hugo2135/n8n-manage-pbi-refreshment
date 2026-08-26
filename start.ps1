Set-Location $PSScriptRoot

if (-not (Test-Path ".env")) {
    Write-Host "[提示] 找不到 .env 檔案，正在從 .env.example 複製..."
    Copy-Item ".env.example" ".env"
    Write-Host "[注意] 請記得編輯 .env 填寫您的 Azure AD 與連線設定！"
} else {
    Write-Host "[提示] 偵測到現有 .env 檔案。"
}

Write-Host "------------------------------------------"
Write-Host "準備啟動 Docker 容器 (背景執行)..."
Write-Host "------------------------------------------"
docker compose up -d --build
if ($LASTEXITCODE -ne 0) {
    Write-Host "[警告] docker compose 執行失敗，嘗試使用舊版指令 docker-compose..."
    docker-compose up -d --build
}

$envVars = @{}
Get-Content ".env" | ForEach-Object {
    if ($_ -match '^\s*([^#=\s][^=]*)\s*=\s*(.*)$') {
        $envVars[$matches[1].Trim()] = $matches[2].Trim()
    }
}
$PG_USER = $envVars['POSTGRES_USER']
$PG_DB = $envVars['POSTGRES_DB']

Write-Host "等待 n8n 完成啟動（healthcheck）..."
$healthy = $false
for ($i = 0; $i -lt 60; $i++) {
    $status = docker inspect -f '{{.State.Health.Status}}' n8n-manage-pbi-refreshment_n8n 2>$null
    if ($status -eq "healthy") { $healthy = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $healthy) {
    Write-Host "[警告] n8n 等待逾時，仍嘗試繼續執行。"
}

Write-Host "檢查是否為全新環境..."
$wfCount = (docker compose exec -T postgres psql -U $PG_USER -d $PG_DB -tAc "SELECT count(*) FROM workflow_entity;" | Out-String).Trim()
if ($wfCount -eq "0") {
    Write-Host "沒有偵測到任何workflow，自動匯入 n8n_templates/workflows..."
    docker compose exec -T n8n n8n import:workflow --separate --input=/templates/workflows
} else {
    Write-Host "偵測到已有 $wfCount 個workflow，略過匯入。"
}

$dtCount = (docker compose exec -T postgres psql -U $PG_USER -d $PG_DB -tAc "SELECT count(*) FROM data_table;" | Out-String).Trim()
if ($dtCount -eq "0") {
    Write-Host ""
    Write-Host "[提示] 尚未偵測到Data Table（Today BI update status / Power BI workspaces），這部分需要手動執行一次："
    Write-Host "  1. 開啟瀏覽器進入 http://localhost:6001"
    Write-Host "  2. 找到並執行『初始化環境』這個workflow（Manual Trigger，按 Execute workflow 即可）"
    Write-Host "     它會自動建立這兩個Data Table（已存在則清空重建），不用手動輸入欄位"
    Write-Host ""
} else {
    Write-Host "偵測到Data Table已存在，略過建立。"
}

Write-Host ""
Write-Host "容器已順利啟動！"
Write-Host "後端自動化引擎 (n8n): http://localhost:6001"
Write-Host ""
Write-Host "如果要停止伺服器，請輸入指令: docker compose down (或 docker-compose down)"
Write-Host ""
Read-Host "按 Enter 鍵繼續"
