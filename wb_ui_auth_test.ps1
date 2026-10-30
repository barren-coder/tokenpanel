# wb_ui_auth_test.ps1 — UI Automation 验证：取消授权后「授权登录」按钮恢复可点
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

$root = 'D:\AppData\token消耗面板'
$wbDir = Join-Path $root 'lib\wb'

function Find-Window([string]$name) {
    $cond = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), $name
    return [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
}

function Find-Button($win, [string]$name) {
    $c1 = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), ([System.Windows.Automation.ControlType]::Button)
    $c2 = New-Object System.Windows.Automation.PropertyCondition ([System.Windows.Automation.AutomationElement]::NameProperty), $name
    $and = New-Object System.Windows.Automation.AndCondition $c1, $c2
    return $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $and)
}

function Kill-AuthChrome {
    foreach ($exeName in @('chrome.exe', 'msedge.exe')) {
        $ps = @(Get-CimInstance Win32_Process -Filter "Name='$exeName'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like ('*' + $wbDir + '*') })
        if ($ps.Count -gt 0) {
            $main = ($ps | Sort-Object ParentProcessId | Select-Object -First 1).ProcessId
            Start-Process -FilePath 'taskkill' -ArgumentList @('/PID', [string]$main, '/T', '/F') -WindowStyle Hidden -Wait
            return $ps.Count
        }
    }
    return 0
}

# 1) 打开配置页（后台进程）
$p = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'wb_open_cfg.ps1')) `
    -PassThru -WindowStyle Hidden

$win = $null
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    $win = Find-Window 'Token Pocket · 设置'
    if ($win) { break }
}
if (-not $win) { Write-Host '[FAIL] 配置页窗口没起来'; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; exit 1 }
Write-Host '[OK] 配置页已打开'

# 2) 找到授权按钮
$btn = Find-Button $win '授权登录'
if (-not $btn) { Write-Host '[FAIL] 找不到「授权登录」按钮'; Stop-Process -Id $p.Id -Force; exit 1 }
Write-Host ("[OK] 初始状态: Enabled=" + $btn.Current.IsEnabled + "  Name=" + $btn.Current.Name)

# 3) 点击
$inv = $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$inv.Invoke()
Start-Sleep -Seconds 4
$btn2 = Find-Button $win '授权中…'
if ($btn2) { Write-Host ("[OK] 点击后: Enabled=" + $btn2.Current.IsEnabled + "  Name=" + $btn2.Current.Name) }
else { Write-Host '[!!] 没看到「授权中…」状态（可能已经秒退）' }

# 4) 等浏览器出现后杀掉（模拟用户关窗口）
$found = 0
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    $found = Kill-AuthChrome
    if ($found -gt 0) { break }
}
Write-Host ("[i] 关闭授权浏览器（进程数 " + $found + "）")

# 5) 等按钮恢复
$ok = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 700
    $b = Find-Button $win '授权登录'
    if ($b -and $b.Current.IsEnabled) { $ok = $true; break }
}
Write-Host ("判定: " + $(if ($ok) { '[PASS] 取消后按钮已恢复可点' } else { '[FAIL] 按钮仍是禁用态' }))

# 6) 收尾
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
Kill-AuthChrome | Out-Null
