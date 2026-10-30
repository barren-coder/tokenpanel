# wb_open_cfg.ps1 — 打开配置页并停留（供 UI Automation 测试操作）
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$root = 'D:\AppData\token消耗面板'
. (Join-Path $root 'lib\QuotaCore.ps1')
. (Join-Path $root 'lib\ConfigWindow.ps1')
$cfg = Get-DefaultConfig
$wb = New-ProviderObject -Preset (Get-PresetById 'workbuddy' 'official') -Tpl 'official'
$cfg.providers = @($wb)
$null = Show-ConfigWindow -Cfg $cfg
