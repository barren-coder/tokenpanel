@echo off
rem ============================================================
rem  Token Pocket 调试启动器
rem  正常用 start-token-pocket.cmd（无窗口后台运行）。
rem  这个版本会把 PowerShell 窗口留在屏幕上，出错时能看到报错，
rem  别人反馈问题时，让他们把这个窗口的文字截图给你。
rem ============================================================

cd /d "%~dp0"

if not exist "TokenPanel.ps1" (
    echo [ERROR] TokenPanel.ps1 not found in this folder.
    pause
    exit /b 1
)

echo ============================================================
echo   Token Pocket 调试模式
echo   - 出错信息会显示在下面
echo   - 日志位置：%APPDATA%\TokenPocket\app.log
echo   - 关闭这个窗口就等于退出程序
echo ============================================================
echo.

"%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "TokenPanel.ps1"

echo.
echo [程序已退出] 上面如果有红色文字，那就是原因。
echo 日志文件：%APPDATA%\TokenPocket\app.log
pause
