@echo off
rem ============================================================
rem  TokenPanel launcher
rem
rem  Double-click to start. The actual launch is delegated to
rem  TokenPanel.vbs so that no black console window flashes.
rem
rem  Controls:
rem    left click : expand / collapse
rem    drag       : move (snaps to screen edges)
rem    right click: menu (settings / refresh / start with Windows / exit)
rem
rem  NOTE (encoding): keep .cmd files pure ASCII, or save them as
rem  ANSI/GBK. cmd.exe reads them with the OEM/ANSI code page; a
rem  UTF-8 file shows mojibake in echo output on CP936 systems.
rem ============================================================

cd /d "%~dp0"

if not exist "TokenPanel.ps1" (
    echo [ERROR] TokenPanel.ps1 not found in this folder.
    pause
    exit /b 1
)

if not exist "TokenPanel.vbs" (
    echo [ERROR] TokenPanel.vbs not found in this folder.
    pause
    exit /b 1
)

rem Launch through VBS, window mode 0 = hidden, no console flash
wscript.exe //nologo "TokenPanel.vbs"

exit /b 0
