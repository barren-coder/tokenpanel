# diag-corner.ps1 — 抓取悬浮窗四角的真实屏幕像素并放大，判断圆角锯齿成因
# 关键点：
#   1) DrawToBitmap 不经过窗口 Region 裁剪，截图看不出锯齿，必须 CopyFromScreen
#   2) 本脚本必须自己做 DPI 感知，否则 CopyFromScreen 用虚拟化坐标、
#      GetWindowRect 返回物理像素，两者错位 → 抓到一片空白
#   3) 程序要先拉一次数据才建窗口（实测约 8 秒），必须轮询等待
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Diag {
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
    public static IntPtr FindWin(uint pid) {
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
}
"@

# 必须先做 DPI 感知，再做任何坐标运算
[void][Diag]::SetThreadDpiAwarenessContext([IntPtr](-4))

$root = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host '=== 启动程序 ==='
Invoke-Item (Join-Path $root 'Token Pocket.lnk')

function Get-AppProc {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match 'TokenPanel\.ps1' -and $_.CommandLine -notmatch 'NonInteractive' } |
        Select-Object -First 1
}

# 轮询：先等进程，再等窗口
$proc = $null; $hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Seconds 1
    if (-not $proc) { $proc = Get-AppProc }
    if ($proc) {
        $hwnd = [Diag]::FindWin([uint32]$proc.ProcessId)
        if ($hwnd -ne [IntPtr]::Zero) { break }
    }
}
if (-not $proc) { Write-Host '程序未启动'; exit 1 }
if ($hwnd -eq [IntPtr]::Zero) { Write-Host '窗口未出现'; exit 1 }

Start-Sleep -Milliseconds 900     # 等首帧画完

$r = New-Object Diag+RECT
[void][Diag]::GetWindowRect($hwnd, [ref]$r)
$w = $r.R - $r.L; $h = $r.B - $r.T
$scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
Write-Host ("窗口 " + $w + "x" + $h + " @ " + $r.L + "," + $r.T + "   屏幕 " + $scr.Width + "x" + $scr.Height)

$zoom = 12
$sz = 24
$corners = @(
    @{ X = $r.L; Y = $r.T },
    @{ X = $r.R - $sz; Y = $r.T },
    @{ X = $r.L; Y = $r.B - $sz },
    @{ X = $r.R - $sz; Y = $r.B - $sz }
)

$pad = 12
$cellW = $sz * $zoom
$outW = $cellW * 2 + $pad * 3
$outH = $cellW * 2 + $pad * 3 + 26
$sheet = New-Object System.Drawing.Bitmap $outW, $outH
$gs = [System.Drawing.Graphics]::FromImage($sheet)
$gs.Clear([System.Drawing.Color]::FromArgb(255, 30, 30, 34))
$gs.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$gs.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half

$pos = @(
    @{ X = $pad;              Y = $pad },
    @{ X = $pad * 2 + $cellW; Y = $pad },
    @{ X = $pad;              Y = $pad * 2 + $cellW },
    @{ X = $pad * 2 + $cellW; Y = $pad * 2 + $cellW }
)
for ($i = 0; $i -lt 4; $i++) {
    $c = $corners[$i]
    $bmp = New-Object System.Drawing.Bitmap $sz, $sz
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($c.X, $c.Y, 0, 0, (New-Object System.Drawing.Size $sz, $sz)) } catch { }
    $g.Dispose()
    $gs.DrawImage($bmp, $pos[$i].X, $pos[$i].Y, $cellW, $cellW)
    $bmp.Dispose()
}

$fT = New-Object System.Drawing.Font 'Microsoft YaHei UI', 12, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
[System.Windows.Forms.TextRenderer]::DrawText($gs, ('四角放大 ' + $zoom + ' 倍（左上 / 右上 / 左下 / 右下） 窗口 ' + $w + 'x' + $h), $fT,
    (New-Object System.Drawing.Rectangle $pad, ($outH - 22), ($outW - $pad * 2), 18),
    [System.Drawing.Color]::FromArgb(255, 140, 150, 165),
    ([System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::HorizontalCenter))
$fT.Dispose()
$gs.Dispose()

$out = Join-Path $root 'diag-corner.png'
$sheet.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$sheet.Dispose()
Write-Host ('已保存 ' + $out)

foreach ($p in @(Get-AppProc)) { try { Stop-Process -Id $p.ProcessId -Force } catch { } }
Write-Host '已清理测试实例'
