@echo off
rem QuotaTray launcher - starts the tray app as an independent background process.
rem Double-click to run. No console window stays open.

set "SCRIPT=%~dp0QuotaTray.ps1"

if not exist "%SCRIPT%" (
    echo QuotaTray.ps1 not found next to this launcher.
    pause
    exit /b 1
)

start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%SCRIPT%"
exit /b 0
