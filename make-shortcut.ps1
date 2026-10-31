# make-shortcut.ps1 — 生成「TokenPanel」快捷方式（零闪启动）
# 目标指向 wscript.exe + TokenPanel.vbs：wscript 是 GUI 子系统程序，
# 双击不会创建控制台，因此完全没有黑窗闪烁。
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs = Join-Path $root 'TokenPanel.vbs'
if (-not (Test-Path $vbs)) { Write-Host '找不到 TokenPanel.vbs'; exit 1 }

$lnkPath = Join-Path $root 'TokenPanel.lnk'
$wsh = New-Object -ComObject WScript.Shell
$sc = $wsh.CreateShortcut($lnkPath)
$sc.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$sc.Arguments = '//nologo "' + $vbs + '"'
$sc.WorkingDirectory = $root
$sc.WindowStyle = 7          # 7 = 最小化（wscript 本身无窗口，这里只是兜底）
$sc.Description = 'TokenPanel - 悬浮窗额度/余额监控'
$sc.Save()

if (Test-Path $lnkPath) {
    $chk = $wsh.CreateShortcut($lnkPath)
    Write-Host ('已生成 ' + $lnkPath)
    Write-Host ('  目标   = ' + $chk.TargetPath)
    Write-Host ('  参数   = ' + $chk.Arguments)
    Write-Host ('  工作目录 = ' + $chk.WorkingDirectory)
} else {
    Write-Host '生成失败'
    exit 1
}
