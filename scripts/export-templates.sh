#!/usr/bin/env bash
# 把目前這台開發機上 n8n 裡建好的 workflow 重新「凍結」進 n8n_templates/workflows。
# 不是給全新環境用的，是給你在n8n介面編輯完、要更新版本控制裡的模板時執行。
# Data Table的結構n8n沒有官方CLI/API可以匯出匯入，需另外在n8n介面手動建立（見README）。
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."

set -a
source ./.env
set +a

N8N_CONTAINER="n8n-manage-pbi-refreshment_n8n"

echo "== 匯出 workflow 模板 =="
docker exec "$N8N_CONTAINER" n8n export:workflow --all --separate --output=/templates/workflows

echo "== 依workflow名稱重新產生 docs/nodes/（給人看好認的檔名，內容跟上面匯出的一致） =="
node scripts/regenerate-docs.js

echo "== 安全檢查：比對 .env 機密值是否被意外硬編碼進匯出的 workflow json =="
LEAK_FOUND=0
for VAR in CLIENT_SECRET DINGTALK_BOT TENANT_ID CLIENT_ID; do
  VALUE="${!VAR:-}"
  if [ -n "$VALUE" ] && grep -rl -- "$VALUE" n8n_templates/workflows/ >/dev/null 2>&1; then
    echo "警告：偵測到 $VAR 的值被硬編碼進以下檔案，請檢查並清除："
    grep -rl -- "$VALUE" n8n_templates/workflows/
    LEAK_FOUND=1
  fi
done
if [ "$LEAK_FOUND" -eq 0 ]; then
  echo "OK：未偵測到已知機密值。"
fi

echo "== 檢查 pinData 是否為空 =="
for f in n8n_templates/workflows/*.json; do
  if grep -q '"pinData":{"' "$f"; then
    echo "警告：$(basename "$f") 有非空pinData，裡面可能殘留真實token/GUID，commit前請人工複查、清空（在n8n介面裡對該node取消pin，或直接把json裡的pinData改成{}）"
  fi
done

echo "== 完成，請檢查 n8n_templates/ 的變動後再 commit =="
