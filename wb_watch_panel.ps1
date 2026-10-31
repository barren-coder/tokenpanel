# wb_watch_panel.ps1 — 启动后每 2 秒探测一次：进程存活 / 窗口是否存在
$ErrorActionPreference = 'Continue'
foreach ($n in @('HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy')) {
    if ($null -ne [Environment]::GetEnvironmentVariable($n)) { Remove-Item ("Env:" + $n) -ErrorAction SilentlyContinue }
}
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WatchWin {
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static string Find(uint pid) {
        var sb = new StringBuilder();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            var t = new StringBuilder(256); GetWindowText(h, t, 256);
            sb.Append("[" + t.ToString() + " vis=" + IsWindowVisible(h) + "]");
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

for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 2
    $alive = -not $proc.HasExited
    $wins = [WatchWin]::Find([uint32]$proc.Id)
    Write-Host ("t+" + (($i + 1) * 2) + "s  alive=" + $alive + "  windows=" + $(if ($wins) { $wins } else { '(none)' }))
}
Write-Host '--- app.log 末尾 10 行 ---'
Get-Content "$env:APPDATA\TokenPanel\app.log" -Tail 10
