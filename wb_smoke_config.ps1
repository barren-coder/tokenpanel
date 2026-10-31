# wb_smoke_config.ps1 — WorkBuddy 接入的配置页冒烟验证（布局自检 + 截图）
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$root = 'D:\AppData\TokenPanel'
Set-Location $root
. (Join-Path $root 'lib\QuotaCore.ps1')
. (Join-Path $root 'lib\ConfigWindow.ps1')

$cfg = Get-DefaultConfig
$wb = New-ProviderObject -Preset (Get-PresetById 'workbuddy' 'official') -Tpl 'official'
$cfg.providers = @($wb)

Write-Host '===== DumpLayout ====='
$r = Show-ConfigWindow -Cfg $cfg -DumpLayout 2>&1 | Where-Object { $_ -is [string] }
$r | ForEach-Object { "$_" }

Write-Host '===== 截图 ====='
$shot = Join-Path $env:TEMP 'wb_cfg_official.png'
$null = Show-ConfigWindow -Cfg $cfg -CapturePath $shot -OnlyTpl 'official' 2>&1
Write-Host ("official: 存在=" + (Test-Path $shot))

$shot2 = Join-Path $env:TEMP 'wb_cfg_tokenplan.png'
$null = Show-ConfigWindow -Cfg $cfg -CapturePath $shot2 -OnlyTpl 'tokenplan' 2>&1
Write-Host ("tokenplan: 存在=" + (Test-Path $shot2))
