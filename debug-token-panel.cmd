@echo off
rem ============================================================
rem  Debug launcher - keeps the console open so you can read errors
rem  Use this one if start-token-panel.cmd exits silently.
rem ============================================================

cd /d "%~dp0"
echo Starting Token Panel with 32-bit PowerShell...
echo.

"%WINDIR%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "TokenPanel.ps1"

echo.
echo Process exited. If there was an error it is shown above.
echo Log file: %APPDATA%\TokenPanel\app.log
pause
