@echo off
rem ============================================================
rem  Token Pocket launcher
rem
rem  双击启动。真正的启动动作交给 TokenPocket.vbs，
rem  这样不会出现黑色控制台窗口一闪而过。
rem
rem  操作方式：
rem    左键点击  : 展开 / 收起
rem    拖动      : 移动位置（靠近屏幕边缘会自动吸附）
rem    右键点击  : 菜单（设置 / 刷新 / 开机启动 / 退出）
rem ============================================================

cd /d "%~dp0"

if not exist "TokenPanel.ps1" (
    echo [ERROR] TokenPanel.ps1 not found in this folder.
    pause
    exit /b 1
)

if not exist "TokenPocket.vbs" (
    echo [ERROR] TokenPocket.vbs not found in this folder.
    pause
    exit /b 1
)

rem 用 VBS 拉起，窗口模式 0 = 隐藏，避免控制台闪烁
wscript.exe //nologo "TokenPocket.vbs"

exit /b 0
