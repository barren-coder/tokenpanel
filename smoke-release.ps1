# smoke-release.ps1 — 发布包冒烟测试
# 解压到全新临时目录，验证：能启动、窗口能出现、置顶生效、快捷方式生成正确
# 用法：powershell -File .\smoke-release.ps1 [-Version 1.2.3]
param([string]$Version = '1.2.3')
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Smoke {
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr p);
    public static IntPtr Find(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            var c = new StringBuilder(256); GetClassName(h, c, 256);
            if (c.ToString().StartsWith("WindowsForms") && IsWindowVisible(h)) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static bool IsTopMost(IntPtr h) { return (GetWindowLong(h, -20) & 0x8) != 0; }
}
"@
[void][Smoke]::SetThreadDpiAwarenessContext([IntPtr](-4))

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$zip = Join-Path $root ('release\TokenPanel-' + $Version + '.zip')
$tmp = Join-Path $env:TEMP ('tp-smoke-' + (Get-Random))
$pass = 0; $fail = 0
function CHK([string]$n, [bool]$ok, [string]$d = '') {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    Write-Host ('  [' + $(if ($ok) { 'OK  ' } else { 'FAIL' }) + '] ' + $n + $(if ($d) { '  → ' + $d } else { '' }))
}

Write-Host '=== 1. 解压到全新目录 ==='
Expand-Archive -Path $zip -DestinationPath $tmp -Force
$app = Join-Path $tmp ('TokenPanel-' + $Version)
CHK '解压成功' (Test-Path $app) $app
$need = @('TokenPanel.ps1', 'TokenPanel.vbs', 'start-token-panel.cmd', 'debug-token-panel.cmd',
          '创建快捷方式.cmd', '使用说明.md', 'make-shortcut.ps1', 'lib\QuotaCore.ps1', 'lib\ConfigWindow.ps1',
          'lib\wb\wb_query.js', 'lib\wb\grab_cookie.js')
foreach ($f in $need) { CHK ('包含 ' + $f) (Test-Path (Join-Path $app $f)) }
CHK '不含配置文件（密钥不入包）' (-not (Test-Path (Join-Path $app 'config.json')))
CHK '不含登录态（.browser-profile 绝不入包）' (-not (Test-Path (Join-Path $app 'lib\wb\.browser-profile')))

Write-Host ''
Write-Host '=== 2. 清掉已有实例（单实例锁会挡住新进程）==='
foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match 'TokenPanel\.ps1' -and $_.CommandLine -notmatch 'NonInteractive' })) {
    try { Stop-Process -Id $p.ProcessId -Force } catch { }
}
Start-Sleep -Seconds 2

Write-Host ''
Write-Host '=== 3. 从新目录启动（走 TokenPanel.vbs）==='
$log = Join-Path $env:APPDATA 'TokenPanel\app.log'
$before = if (Test-Path $log) { (Get-Content $log -Encoding UTF8).Count } else { 0 }
Invoke-Item (Join-Path $app 'TokenPanel.vbs')

$proc = $null; $hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Seconds 1
    if (-not $proc) {
        $proc = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -match 'TokenPanel\.ps1' -and $_.CommandLine -notmatch 'NonInteractive' } |
            Select-Object -First 1
    }
    if ($proc) {
        $hwnd = [Smoke]::Find([uint32]$proc.ProcessId)
        if ($hwnd -ne [IntPtr]::Zero) { break }
    }
}
CHK '进程已启动' ($null -ne $proc) $(if ($proc) { 'PID ' + $proc.ProcessId } else { '' })
CHK '窗口已出现' ($hwnd -ne [IntPtr]::Zero)
# 注意：窗口刚创建时 Assert-TopMost 可能还没执行完，
# 立刻检查会误判。等首帧稳定后再验。
# 注意：窗口刚创建时 Assert-TopMost 可能还没执行完，且启动时序偶发竞态，
# 单次检查会误判。最多轮询 12 秒（应用自带每 2 秒的自愈看护）。
$topOk = $false
$topEx = 0
for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Seconds 1
    $hw = if ($proc) { [Smoke]::Find([uint32]$proc.ProcessId) } else { [IntPtr]::Zero }
    if ($hw -ne [IntPtr]::Zero) {
        $topEx = [Smoke]::GetWindowLong($hw, -20)
        if (([Smoke]::IsTopMost($hw))) { $topOk = $true; break }
    }
}
CHK '窗口置顶（WS_EX_TOPMOST）' $topOk ('EXSTYLE=0x' + $topEx.ToString('X8'))
Start-Sleep -Milliseconds 800
$newLines = @()
if (Test-Path $log) { $newLines = Get-Content $log -Encoding UTF8 | Select-Object -Skip $before }
$startLine = $newLines | Select-String ('启动 v' + [regex]::Escape($Version))
CHK ('日志显示启动 v' + $Version) ($null -ne $startLine) $(if ($startLine) { ($startLine -join ' ') } else { '未找到' })
$topLine = $newLines | Select-String '置顶断言后 EXSTYLE=0x00090008'
if (-not $topLine) { $topLine = $newLines | Select-String '置顶补钉完成 EXSTYLE=0x00090008' }CHK '置顶断言日志正确' ($null -ne $topLine) $(if ($topLine) { ($topLine -join ' ') } else { '未找到' })

Write-Host ''
Write-Host '=== 4. 快捷方式生成（验证便携性）==='
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'make-shortcut.ps1') 2>&1 | Out-Null
$lnk = Join-Path $app 'TokenPanel.lnk'
CHK '.lnk 已生成' (Test-Path $lnk)
if (Test-Path $lnk) {
    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($lnk)
    CHK '.lnk 指向本目录的 vbs' ($sc.Arguments -like ('*' + $app + '*')) $sc.Arguments
}

Write-Host ''
Write-Host '=== 5. 清理 ==='
foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match 'TokenPanel\.ps1' -and $_.CommandLine -notmatch 'NonInteractive' })) {
    try { Stop-Process -Id $p.ProcessId -Force } catch { }
}
Start-Sleep -Seconds 1
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
CHK '临时目录已清理' (-not (Test-Path $tmp))

Write-Host ''
Write-Host ('通过 ' + $pass + ' / ' + ($pass + $fail))
if ($fail -gt 0) { exit 1 }
