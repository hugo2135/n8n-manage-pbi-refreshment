@echo off
REM This tool is for the machine you edit workflow templates on. It just
REM shells out to export-templates.sh (needs bash from Git for Windows or WSL)
REM instead of re-implementing the sed/grep text processing in batch.
where bash >nul 2>nul
if errorlevel 1 (
    echo bash not found. This script needs bash from Git for Windows or WSL.
    echo Alternatively, run this in Git Bash directly: bash scripts/export-templates.sh
    pause
    exit /b 1
)
bash "%~dp0export-templates.sh"
pause
