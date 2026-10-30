# wb_topmost_check.ps1 — 读 Token Pocket 窗口扩展样式，判断 WS_EX_TOPMOST 是否在位
$ErrorActionPreference = 'Continue'
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class TopChk {
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public struct RECT { public int L, T, R, B; }
    public static string Scan() {
        var sb = new StringBuilder();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            var t = new StringBuilder(256); GetWindowText(h, t, 256);
            if (t.ToString() == "Token Pocket") {
                RECT r; GetWindowRect(h, out r);
                int ex = GetWindowLong(h, -20);
                sb.AppendLine("hwnd=" + h.ToInt64() + " ex=0x" + ex.ToString("X8") + " topmost=" + ((ex & 0x8) != 0) +
                              " rect=" + r.L + "," + r.T + "," + r.R + "," + r.B);
            }
            return true;
        }, IntPtr.Zero);
        return sb.ToString();
    }
}
"@
$s = [TopChk]::Scan()
if ($s) { Write-Host $s.TrimEnd() } else { Write-Host '未找到 Token Pocket 窗口' }
