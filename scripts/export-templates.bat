@echo off
REM 這個工具是給「編輯模板的開發機」用的，實作直接沿用export-templates.sh（用bash執行，
REM 避免在批次檔裡重寫一份sed/grep等文字處理邏輯，需要Git for Windows或WSL提供的bash）。
where bash >nul 2>nul
if errorlevel 1 (
    echo 找不到 bash。這個腳本需要 Git for Windows 或 WSL 提供的 bash，請安裝後再試，
    echo 或直接在 Git Bash 裡執行：bash scripts/export-templates.sh
    pause
    exit /b 1
)
bash "%~dp0export-templates.sh"
pause
