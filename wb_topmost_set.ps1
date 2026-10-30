# wb_topmost_set.ps1 — 按标题子串找窗口，尝试设 TOPMOST 并打印错误码
$ErrorActionPreference = 'Continue'
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class TopSet {
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll", SetLastError=true)] public static extern int SetWindowLong(IntPtr h, int idx, int val);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public static string Run() {
        IntPtr found = IntPtr.Zero;
        string title = "";
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            var t = new StringBuilder(256); GetWindowText(h, t, 256);
            var s = t.ToString();
            if (s.IndexOf("Token Pocket", StringComparison.OrdinalIgnoreCase) >= 0) { found = h; title = s; return false; }
            return true;
        }, IntPtr.Zero);
        if (found == IntPtr.Zero) return "window-not-found";
        var sb = new StringBuilder();
        sb.AppendLine("hwnd=" + found.ToInt64() + " title=[" + title + "] len=" + title.Length);
        int before = GetWindowLong(found, -20);
        sb.AppendLine("before=0x" + before.ToString("X8"));
        int r1 = SetWindowLong(found, -20, before | 0x8);
        sb.AppendLine("SetWindowLong ret=" + r1 + " err=" + Marshal.GetLastWin32Error());
        sb.AppendLine("after SetWindowLong=0x" + GetWindowLong(found, -20).ToString("X8"));
        bool ok = SetWindowPos(found, new IntPtr(-1), 0, 0, 0, 0, 0x13);
        sb.AppendLine("SetWindowPos ret=" + ok + " err=" + Marshal.GetLastWin32Error());
        sb.AppendLine("final=0x" + GetWindowLong(found, -20).ToString("X8"));
        return sb.ToString();
    }
}
"@
Write-Host ([TopSet]::Run())
