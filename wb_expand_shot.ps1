# wb_expand_shot.ps1 — 点击 dock 展开面板，分别截折叠态与展开态
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WinCtl {
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, UIntPtr extra);
    public struct RECT { public int L, T, R, B; }
    public static string Find() {
        var sb = new StringBuilder();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            var t = new StringBuilder(256); GetWindowText(h, t, 256);
            if (t.ToString() == "Token Pocket") {
                RECT r; GetWindowRect(h, out r);
                sb.AppendLine(r.L + "|" + r.T + "|" + r.R + "|" + r.B);
            }
            return true;
        }, IntPtr.Zero);
        return sb.ToString();
    }
    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(120);
        mouse_event(2, 0, 0, 0, UIntPtr.Zero);
        mouse_event(4, 0, 0, 0, UIntPtr.Zero);
    }
}
"@
[void][WinCtl]::SetThreadDpiAwarenessContext([IntPtr](-4))

function Get-TpRect {
    $hits = [WinCtl]::Find()
    foreach ($line in ($hits -split "`n")) {
        $parts = $line.Split('|')
        if ($parts.Count -eq 4) {
            return @{ L = [int]$parts[0]; T = [int]$parts[1]; R = [int]$parts[2]; B = [int]$parts[3] }
        }
    }
    return $null
}

function Save-Shot([hashtable]$r, [string]$path) {
    $w = $r.R - $r.L; $h = $r.B - $r.T
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host ("截取 " + $w + "x" + $h + " -> " + $path)
}

$r = Get-TpRect
if (-not $r) { Write-Host '未找到窗口'; exit 1 }

# 折叠态
$collapsed = Join-Path $env:TEMP 'wb_dock_collapsed.png'
Save-Shot $r $collapsed

# 点击中心展开
$cx = [int](($r.L + $r.R) / 2); $cy = [int](($r.T + $r.B) / 2)
[WinCtl]::Click($cx, $cy)
Start-Sleep -Milliseconds 1800

$r2 = Get-TpRect
if ($r2) {
    $expanded = Join-Path $env:TEMP 'wb_panel_expanded.png'
    Save-Shot $r2 $expanded
    # 再点一次收起
    $cx2 = [int](($r2.L + $r2.R) / 2); $cy2 = [int](($r2.T + $r2.B) / 2)
    [WinCtl]::Click($cx2, $cy2)
    Start-Sleep -Milliseconds 1200
}
