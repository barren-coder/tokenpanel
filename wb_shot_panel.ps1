# wb_shot_panel.ps1 — TokenPanel 悬浮窗截屏（模糊匹配 + 虚拟屏兜底）
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class DpiFix {
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
}
"@
[void][DpiFix]::SetThreadDpiAwarenessContext([IntPtr](-4))
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WinRect2 {
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public struct RECT { public int L, T, R, B; }
    public static string Scan() {
        var sb = new StringBuilder();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            var t = new StringBuilder(256); GetWindowText(h, t, 256);
            var title = t.ToString();
            if (title.Length > 0 && title.ToLower().Contains("token")) {
                RECT r; GetWindowRect(h, out r);
                sb.AppendLine(title.Replace("|"," ") + "|" + r.L + "|" + r.T + "|" + r.R + "|" + r.B);
            }
            return true;
        }, IntPtr.Zero);
        return sb.ToString();
    }
}
"@

$hits = [WinRect2]::Scan()
Write-Host '--- Token 窗口 ---'
Write-Host $hits

$shot = Join-Path $env:TEMP 'wb_panel_dock.png'
$captured = $false
foreach ($line in ($hits -split "`n")) {
    $parts = $line.Split('|')
    if ($parts.Count -ge 5 -and $parts[0] -like '*TokenPanel*') {
        $l = [int]$parts[1]; $t = [int]$parts[2]; $r = [int]$parts[3]; $b = [int]$parts[4]
        if ($r -gt $l -and $b -gt $t) {
            $w = $r - $l; $h = $b - $t
            $bmp = New-Object System.Drawing.Bitmap $w, $h
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($l, $t, 0, 0, (New-Object System.Drawing.Size $w, $h))
            $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
            $g.Dispose(); $bmp.Dispose()
            Write-Host ("截取窗口: " + $w + "x" + $h + " @ " + $l + "," + $t)
            $captured = $true
            break
        }
    }
}
if (-not $captured) {
    Write-Host '未匹配到窗口，截虚拟屏'
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)
    $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host ("虚拟屏截屏: " + $shot)
}
Write-Host ("输出: " + $shot + "  存在=" + (Test-Path $shot))
