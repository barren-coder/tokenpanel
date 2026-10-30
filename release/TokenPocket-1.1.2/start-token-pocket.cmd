@echo off
rem ============================================================
rem  Token Pocket launcher
rem  Double-click to start. The floating window docks to the
rem  bottom-right corner of your screen.
rem    Left-click  : expand / collapse
rem    Drag        : move anywhere (auto-snaps near screen edges)
rem    Right-click : menu (settings / refresh / autostart / quit)
rem ============================================================

cd /d "%~dp0"

if not exist "TokenPanel.ps1" (
    echo [ERROR] TokenPanel.ps1 not found in this folder.
    pause
    exit /b 1
)

rem -WindowStyle Hidden keeps the console out of sight.
rem Use debug-token-pocket.cmd if you need to see errors.
start "Token Pocket" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "TokenPanel.ps1"

exit /b 0
