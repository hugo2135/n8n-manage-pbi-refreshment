#!/usr/bin/env bash
# macOS / Ubuntu 一鍵啟動腳本：拉起 n8n + postgres，若偵測到是全新環境（沒有任何 workflow、
# 沒有Data Table），會自動把 n8n_templates/ 底下凍結好的模板匯入進去。
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "[提示] 找不到 .env 檔案，正在從 .env.example 複製..."
  cp .env.example .env
  echo "[注意] 請記得編輯 .env 填寫您的 Azure AD 與連線設定！"
else
  echo "[提示] 偵測到現有 .env 檔案。"
fi

set -a
source .env
set +a

N8N_CONTAINER="n8n-manage-pbi-refreshment_n8n"
PG_CONTAINER="n8n-manage-pbi-refreshment_postgres"

echo "------------------------------------------"
echo "準備啟動 Docker 容器 (背景執行)..."
echo "------------------------------------------"
docker compose up -d --build

echo "等待 n8n 完成啟動（healthcheck）..."
for i in $(seq 1 60); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$N8N_CONTAINER" 2>/dev/null || echo "unknown")
  if [ "$status" = "healthy" ]; then
    break
  fi
  sleep 2
done
if [ "$status" != "healthy" ]; then
  echo "[警告] n8n 等待逾時，仍嘗試繼續執行（可能還沒完全就緒）。"
fi

echo "檢查是否為全新環境..."
WF_COUNT=$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM workflow_entity;" | tr -d '[:space:]')

if [ "$WF_COUNT" = "0" ]; then
  echo "沒有偵測到任何workflow，自動匯入 n8n_templates/workflows..."
  docker compose exec -T n8n n8n import:workflow --separate --input=/templates/workflows
else
  echo "偵測到已有 $WF_COUNT 個workflow，略過匯入。"
fi

DT_COUNT=$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "SELECT count(*) FROM data_table;" | tr -d '[:space:]')

if [ "$DT_COUNT" = "0" ]; then
  echo ""
  echo "[提示] 尚未偵測到Data Table（Today BI update status / Power BI workspaces），這部分需要手動建立一次："
  echo "  1. 開啟瀏覽器進入 http://localhost:6001"
  echo "  2. 到左側 Data Tables 分頁，用「Import CSV」分別匯入以下兩個範本檔（匯入後記得刪掉範例列）："
  echo "     - n8n_templates/data_tables/today_bi_update_status.csv"
  echo "     - n8n_templates/data_tables/power_bi_workspaces.csv"
  echo "     （或直接在UI手動新增欄位，欄位清單見README『狀態資料表』章節）"
  echo ""
else
  echo "偵測到Data Table已存在，略過建立。"
fi

echo ""
echo "容器已順利啟動！"
echo "後端自動化引擎 (n8n): http://localhost:6001"
echo ""
echo "如果要停止伺服器，請輸入指令: docker compose down (或 docker-compose down)"
