@echo off
rem ============================================================
rem  Cleanup script for the abandoned Tauri attempt
rem  MUST be run as Administrator (right-click -> Run as administrator)
rem
rem  Removes:
rem    - Visual Studio 2022 Build Tools  (~1.6 GB)
rem    - VS package cache                (~0.4 GB)
rem  Keeps:
rem    - Nothing else is touched. Your TokenPanel project is safe.
rem ============================================================

net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Please right-click this file and choose "Run as administrator".
    pause
    exit /b 1
)

echo ============================================================
echo  Step 1/2  Uninstalling Visual Studio Build Tools
echo  This can take several minutes. Please wait...
echo ============================================================
set "VSINST=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\setup.exe"
set "VSPATH=%ProgramFiles(x86)%\Microsoft Visual Studio\2022\BuildTools"

if exist "%VSINST%" (
    if exist "%VSPATH%" (
        "%VSINST%" uninstall --installPath "%VSPATH%" --quiet --norestart
        echo [OK] Uninstall command finished.
    ) else (
        echo [SKIP] Build Tools folder not found.
    )
) else (
    echo [SKIP] VS Installer not found.
)

echo.
echo ============================================================
echo  Step 2/2  Removing VS package cache
echo ============================================================
set "PKG=%ProgramData%\Microsoft\VisualStudio\Packages"
if exist "%PKG%" (
    rd /s /q "%PKG%"
    echo [OK] Package cache removed.
) else (
    echo [SKIP] Package cache not found.
)

echo.
echo ============================================================
echo  Done.
echo ============================================================
powershell -NoProfile -Command "$c=Get-PSDrive C; Write-Host ('C drive free: ' + [math]::Round($c.Free/1GB,2) + ' GB')"
pause
