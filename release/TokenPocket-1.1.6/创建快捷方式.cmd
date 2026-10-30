@echo off
rem ============================================================
rem  创建「Token Pocket」快捷方式
rem
rem  双击运行，会在当前目录生成 Token Pocket.lnk，
rem  之后双击它就能启动（全程无黑窗）。
rem  移动文件夹后需要重新运行一次本脚本。
rem ============================================================

cd /d "%~dp0"

if not exist "make-shortcut.ps1" (
    echo [ERROR] make-shortcut.ps1 not found in this folder.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "make-shortcut.ps1"

echo.
echo 完成。你可以把 Token Pocket.lnk 复制到桌面或开始菜单。
pause
