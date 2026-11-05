@echo off
rem ============================================================
rem  Create a "TokenPanel" shortcut
rem
rem  Double-click to generate TokenPanel.lnk in this folder,
rem  then double-click the .lnk to start the app (no console flash).
rem  Re-run this after moving the folder, the .lnk stores an
rem  absolute path.
rem
rem  NOTE (encoding): keep .cmd files pure ASCII or ANSI/GBK.
rem ============================================================

cd /d "%~dp0"

if not exist "make-shortcut.ps1" (
    echo [ERROR] make-shortcut.ps1 not found in this folder.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "make-shortcut.ps1"

echo.
echo Done. Copy TokenPanel.lnk to your Desktop or Start Menu if you like.
pause
