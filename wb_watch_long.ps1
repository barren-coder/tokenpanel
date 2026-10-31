# wb_watch_long.ps1 — 启动后每 3 秒探测，共 90 秒；记录窗口从有到无的时刻
$ErrorActionPreference = 'Continue'
foreach ($n in @('HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy')) {
    if ($null -ne [Environment]::GetEnvironmentVariable($n)) { Remove-Item ("Env:" + $n) -ErrorAction SilentlyContinue }
}
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Watch2 {
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    public static string Find(uint pid) {
        var sb = new StringBuilder();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            var t = new StringBuilder(256); GetWindowText(h, t, 256);
            var s = t.ToString();
            if (s.IndexOf("Token", StringComparison.OrdinalIgnoreCase) >= 0) {
                sb.Append("[TOKEN vis=" + IsWindowVisible(h) + " ex=0x" + GetWindowLong(h, -20).ToString("X8") + "]");
            }
            return true;
        }, IntPtr.Zero);
        return sb.ToString();
    }
}
"@
$ps = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*-File*TokenPanel.ps1*' }
foreach ($p in $ps) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
$proc = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'D:\AppData\TokenPanel\TokenPanel.ps1') `
    -WorkingDirectory 'D:\AppData\TokenPanel' -WindowStyle Hidden -PassThru
Write-Host ("panel pid=" + $proc.Id)
$logPath = "$env:APPDATA\TokenPanel\app.log"
$lastLen = (Get-Item $logPath).Length
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 3
    $alive = -not $proc.HasExited
    $w = [Watch2]::Find([uint32]$proc.Id)
    $tag = if ($w) { $w } else { '(no window)' }
    Write-Host ("t+" + (($i + 1) * 3) + "s alive=" + $alive + " " + $tag)
    # 增量日志
    $nowLen = (Get-Item $logPath).Length
    if ($nowLen -gt $lastLen) {
        $fs = [System.IO.File]::Open($logPath, 'Open', 'Read', 'ReadWrite')
        $fs.Position = $lastLen
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $newText = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        $lastLen = $nowLen
        foreach ($line in ($newText -split "`r?`n")) { if ($line.Trim()) { Write-Host ("    LOG " + $line) } }
    }
}
