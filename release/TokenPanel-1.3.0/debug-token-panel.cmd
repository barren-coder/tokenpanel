@echo off
rem ============================================================
rem  TokenPanel debug launcher
rem
rem  Normal use: start-token-panel.cmd (runs hidden in background).
rem  This version keeps the PowerShell window on screen so that
rem  errors stay visible. When someone reports a problem, ask them
rem  to run this and screenshot the window.
rem
rem  NOTE (encoding): keep .cmd files pure ASCII or ANSI/GBK.
rem ============================================================

cd /d "%~dp0"

if not exist "TokenPanel.ps1" (
    echo [ERROR] TokenPanel.ps1 not found in this folder.
    pause
    exit /b 1
)

echo ============================================================
echo   TokenPanel - debug mode
echo   - errors are printed below
echo   - log file: %APPDATA%\TokenPanel\app.log
echo   - closing this window terminates the app
echo ============================================================
echo.

"%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "TokenPanel.ps1"

echo.
echo [app exited] any red text above is the cause.
echo log file: %APPDATA%\TokenPanel\app.log
pause
