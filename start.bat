@echo off
chcp 65001 >nul
echo 初始化 PowerBI 批次更新自動化平台...

IF NOT EXIST ".env" (
    echo [提示] 找不到 .env 檔案，正在從 .env.example 複製...
    copy .env.example .env
    echo [注意] 請記得編輯 .env 填寫您的 Azure AD 與連線設定！
) ELSE (
    echo [提示] 偵測到現有 .env 檔案。
)

echo ------------------------------------------
echo 準備啟動 Docker 容器 (背景執行)...
echo ------------------------------------------
docker compose up -d --build
IF %ERRORLEVEL% NEQ 0 (
    echo [警告] docker compose 執行失敗，嘗試使用舊版指令 docker-compose...
    docker-compose up -d --build
)

echo.
echo 容器已順利啟動！
echo ⚙️ 後端自動化引擎 (n8n): http://localhost:5678
echo.
echo 如果要停止伺服器，請輸入指令: docker compose down (或 docker-compose down)
echo.
pause
