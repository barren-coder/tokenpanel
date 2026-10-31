param([string]$Target = 'start-token-panel.cmd')
# verify-launch.ps1 — 启动 TokenPanel 并检查是否出现「可见的控制台窗口」
# 用法：powershell -File .\verify-launch.ps1                     （测 .cmd）
#       powershell -File .\verify-launch.ps1 -Target "TokenPanel.lnk"  （测快捷方式）
# 判定依据：枚举该进程的所有顶层窗口，统计 class = ConsoleWindowClass 且 IsWindowVisible 的个数。
# 期望 0 个。旧启动方式（start + -WindowStyle Hidden）会有 1 个可见控制台窗口闪过。
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WinProbe {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
    public static string Probe(uint targetPid) {
        var sb = new StringBuilder();
        int visibleConsole = 0;
        int totalWindows = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (pid != targetPid) return true;
            totalWindows++;
            var cls = new StringBuilder(256);
            GetClassName(h, cls, 256);
            string name = cls.ToString();
            bool vis = IsWindowVisible(h);
            if (name == "ConsoleWindowClass" && vis) visibleConsole++;
            sb.AppendLine("    hwnd=" + h.ToInt64() + " class=" + name + " visible=" + vis);
            return true;
        }, IntPtr.Zero);
        return "total=" + totalWindows + " visibleConsole=" + visibleConsole + "\n" + sb.ToString();
    }
}
"@

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$cmd = Join-Path $root $Target
if (-not (Test-Path $cmd)) { Write-Host ('找不到 ' + $Target); exit 1 }

Write-Host ('=== 通过 ' + $Target + ' 启动 ===')
# ShellExecute 打开，等同于用户在资源管理器里双击
Invoke-Item $cmd

Start-Sleep -Seconds 6

$targets = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'TokenPanel\.ps1' -and $_.CommandLine -notmatch 'NonInteractive' })

Write-Host ("  找到 TokenPanel 进程 " + $targets.Count + " 个")
if ($targets.Count -eq 0) { Write-Host '  [FAIL] 没有进程启动'; exit 1 }

$bad = 0
foreach ($t in $targets) {
    Write-Host ('  进程 PID ' + $t.ProcessId + ' 的顶层窗口：')
    $r = [WinProbe]::Probe([uint32]$t.ProcessId)
    $firstLine = ($r -split "`n")[0]
    Write-Host ('    ' + $firstLine)
    $rest = ($r -split "`n") | Select-Object -Skip 1 | Where-Object { $_.Trim() -ne '' }
    if ($rest) { $rest | ForEach-Object { Write-Host $_ } } else { Write-Host '    (无顶层窗口)' }
    if ($firstLine -notmatch 'visibleConsole=0') { $bad++ }
}

Write-Host ''
if ($bad -eq 0) {
    Write-Host '  [OK] 所有实例都没有可见的控制台窗口 —— 启动不闪黑窗'
} else {
    Write-Host ('  [FAIL] ' + $bad + ' 个实例存在可见控制台窗口')
}

# 清理
Write-Host ''
Write-Host '=== 清理测试实例 ==='
foreach ($t in $targets) {
    try { Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop; Write-Host ('  已停止 ' + $t.ProcessId) } catch { }
}
