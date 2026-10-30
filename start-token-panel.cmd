@echo off
rem 旧文件名保留为转发入口（避免已有快捷方式失效）
cd /d "%~dp0"
call "%~dp0start-token-pocket.cmd"
