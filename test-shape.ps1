# test-shape.ps1 — 验证预设数组形态（PowerShell 解包坑回归测试）
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib\QuotaCore.ps1')

$expect = @{ custom = 1; general = 1; newapi = 1; tokenplan = 4; balance = 4; official = 2 }
$bad = 0
foreach ($id in @('custom', 'general', 'newapi', 'tokenplan', 'balance', 'official')) {
    $wrapped = @(Get-ProviderPresets -Tpl $id)
    $direct = @(Get-ProviderPresets -Tpl $id)
    $first = $wrapped[0]
    $firstId = if ($first -is [hashtable]) { $first.Id } else { 'NESTED-OR-NULL' }
    $ok = ($wrapped.Count -eq $expect[$id]) -and ($direct.Count -eq $expect[$id]) -and ($firstId -match '^[a-z]+$')
    if (-not $ok) { $bad++ }
    Write-Host ("  [" + $(if ($ok) { 'OK  ' } else { 'FAIL' }) + "] " + $id.PadRight(10) +
        " @()=" + $wrapped.Count + " 直接=" + $direct.Count + " [0].Id=" + $firstId)
}
if ($bad -gt 0) { Write-Host ("失败 " + $bad); exit 1 }
Write-Host "数组形态全部正确"
