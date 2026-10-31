# diag-topmost.ps1 — 检查悬浮窗的 WS_EX_TOPMOST 样式是否真的生效
# 不靠肉眼：直接读 GWL_EXSTYLE，并检查 z 序里是否排在其他普通窗口之上
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class TopProbe {
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr p);

    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TOPMOST = 0x00000008;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_LAYERED = 0x00080000;
    public const int WS_EX_NOACTIVATE = 0x08000000;

    public static IntPtr FindByPid(uint pid) {
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

    public static string Styles(IntPtr h) {
        int ex = GetWindowLong(h, GWL_EXSTYLE);
        var sb = new StringBuilder();
        sb.Append("EXSTYLE=0x").Append(ex.ToString("X8")).Append("  ");
        sb.Append("TOPMOST=").Append((ex & WS_EX_TOPMOST) != 0 ? "是" : "否").Append("  ");
        sb.Append("TOOLWINDOW=").Append((ex & WS_EX_TOOLWINDOW) != 0 ? "是" : "否").Append("  ");
        sb.Append("LAYERED=").Append((ex & WS_EX_LAYERED) != 0 ? "是" : "否").Append("  ");
        sb.Append("NOACTIVATE=").Append((ex & WS_EX_NOACTIVATE) != 0 ? "是" : "否");
        return sb.ToString();
    }

    // 返回 z 序（从顶到底）里前 N 个可见顶层窗口的类名与是否置顶
    public static string ZOrder(IntPtr target, int limit) {
        var sb = new StringBuilder();
        int idx = 0;
        bool hit = false;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            var c = new StringBuilder(256); GetClassName(h, c, 256);
            string cls = c.ToString();
            if (cls.Length == 0) return true;
            int ex = GetWindowLong(h, GWL_EXSTYLE);
            bool isTop = (ex & WS_EX_TOPMOST) != 0;
            string mark = (h == target) ? "  <== 我们的窗口" : "";
            sb.Append("    #").Append(idx).Append(" ").Append(cls.Substring(0, Math.Min(34, cls.Length)).PadRight(34));
            sb.Append(isTop ? " [置顶]" : "       ").Append(mark).AppendLine();
            idx++;
            if (h == target) { hit = true; return false; }
            return idx < limit;
        }, IntPtr.Zero);
        if (!hit) sb.AppendLine("    （z 序前 " + limit + " 个里没找到我们的窗口）");
        return sb.ToString();
    }
}
"@

[void][TopProbe]::SetThreadDpiAwarenessContext([IntPtr](-4))
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-AppProc {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match 'TokenPanel\.ps1' -and $_.CommandLine -notmatch 'NonInteractive' } |
        Select-Object -First 1
}

Write-Host '=== 启动程序 ==='
Invoke-Item (Join-Path $root 'TokenPanel.lnk')

$proc = $null; $hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Seconds 1
    if (-not $proc) { $proc = Get-AppProc }
    if ($proc) {
        $hwnd = [TopProbe]::FindByPid([uint32]$proc.ProcessId)
        if ($hwnd -ne [IntPtr]::Zero) { break }
    }
}
if ($hwnd -eq [IntPtr]::Zero) { Write-Host '窗口未出现'; exit 1 }
Start-Sleep -Milliseconds 900

Write-Host ''
Write-Host '=== 启动后 ==='
Write-Host ('  ' + [TopProbe]::Styles($hwnd))
Write-Host '  z 序（从顶到底）：'
Write-Host ([TopProbe]::ZOrder($hwnd, 8))

Write-Host ''
Write-Host '=== 把记事本叫到前台，看是否被覆盖 ==='
$np = $null
foreach ($cand in @("$env:WINDIR\System32\notepad.exe")) {
    if (Test-Path $cand) {
        $np = Start-Process -FilePath $cand -PassThru
        break
    }
}
if ($np) {
    Start-Sleep -Seconds 2
    Write-Host ('  记事本 PID ' + $np.Id + ' 已启动（会抢焦点）')
    Write-Host ('  ' + [TopProbe]::Styles($hwnd))
    Write-Host '  z 序：'
    Write-Host ([TopProbe]::ZOrder($hwnd, 8))
    try { Stop-Process -Id $np.Id -Force } catch { }
} else {
    Write-Host '  找不到记事本，跳过'
}

foreach ($p in @(Get-AppProc)) { try { Stop-Process -Id $p.ProcessId -Force } catch { } }
Write-Host ''
Write-Host '已清理测试实例'
