# TokenPanel.ps1 — Token 消耗面板（WinForms 全自绘版）
#
# 为什么不用 WebView2：本机 32 位运行时虽已注册，但 CoreWebView2Environment
# 的四种初始化方式（系统注册 / 显式路径 / 控件模式 / 消息泵）全部失败，
# 报 "Couldn't find a compatible Webview2 Runtime"。改用 GDI+ 全自绘。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\TokenPanel.ps1
#   powershell -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -SelfTest
#   powershell -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -Shot      # 截图后退出

param(
    [switch]$SelfTest,
    [switch]$Shot,
    [switch]$Demo,
    [switch]$DumpMenu,
    [switch]$ConfigShot,
    [switch]$LayoutCheck,
    [switch]$TestAutostart,      # 验证开机自启真实写入注册表
    [switch]$TestUI,             # 程序化点击配置页控件，验证点击真的生效
    [string]$ConfigTpl = '',     # 配合 -ConfigShot：截图前切到指定模板
    [string]$ConfigPage = '',    # 配合 -ConfigShot：account / system
    [string]$ForceOrient = '',   # 验证用：h / v，强制折叠态排布方向（只影响本次运行）
    [string]$ForceTheme = '',    # 验证用：dark / light，强制配色（只影响本次运行）
    [switch]$Anim,               # 验证用：停在动效的某一帧截图
    [switch]$GeomTest,           # 验证用：贴边吸附 / 横纵排 / DPI 重算的断言测试
    [switch]$TestScale,          # 验证用：界面缩放是否真的改变配置页尺寸
    [switch]$TestRescaleLive     # 验证用：真点一次缩放 chip，看窗口是否重建
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LibDir = Join-Path $script:Root 'lib'


Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

$nativeSrc = @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Imaging;

public class NativeWin {
    [DllImport("user32.dll")]
    public static extern bool ReleaseCapture();
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

    // DPI 相关：PowerShell 宿主 manifest 锁定了 DPI 感知，
    // 必须在创建窗口前用线程级 API 覆盖，否则窗口会被系统位图拉伸导致模糊
    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    public struct RECT { public int Left, Top, Right, Bottom; }

    // 置顶修复用：直接读写扩展样式。
    // 踩过的坑：Form.TopMost = $true 在本项目里最终没有落到 WS_EX_TOPMOST 位上
    // （实测 EXSTYLE=0x00090000，只有 LAYERED|CONTROLPARENT），
    // 所以点别的窗口就被盖住。改为显式读-改-写样式位 + SetWindowPos 抬到 topmost 带。
    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    // ============================================================
    // 分层窗口：圆角抗锯齿
    //
    // 原来的做法是 Form.Region = Region(圆角路径)，走 SetWindowRgn。
    // 那是 1 位掩码 —— 像素只有「在窗口内 / 不在」两种状态，没有半透明过渡，
    // 曲线二值化之后必然出现台阶（就是用户看到的毛刺）。
    //
    // 改成 UpdateLayeredWindow：整窗内容是一张 32bpp ARGB 位图，
    // 圆角边缘按覆盖率输出 alpha，由 DWM 合成，任意半径都是平滑的。
    // ============================================================
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("user32.dll")]
    public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, IntPtr pptDst,
        ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx; public int cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }

    const int GWL_EXSTYLE = -20;
    const int WS_EX_LAYERED = 0x00080000;

    public static void EnableLayered(IntPtr hwnd) {
        int ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        if ((ex & WS_EX_LAYERED) == 0) SetWindowLong(hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED);
    }

    // 推一帧到窗口表面。alpha = 整体不透明度（0-255），等价于原来的 Form.Opacity，
    // 但不会像 Form.Opacity 那样把整块画面压成灰。
    public static bool PushLayered(IntPtr hwnd, Bitmap bmp, byte alpha) {
        int w = bmp.Width, h = bmp.Height;
        BitmapData bd = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        try {
            int len = bd.Stride * h;
            byte[] buf = new byte[len];
            Marshal.Copy(bd.Scan0, buf, 0, len);
            // UpdateLayeredWindow 要的是预乘 alpha，GDI+ 给的是直通 alpha，这里逐像素乘一次
            for (int i = 0; i < len; i += 4) {
                byte a = buf[i + 3];
                if (a == 0) { buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0; }
                else if (a != 255) {
                    buf[i]     = (byte)(buf[i]     * a / 255);
                    buf[i + 1] = (byte)(buf[i + 1] * a / 255);
                    buf[i + 2] = (byte)(buf[i + 2] * a / 255);
                }
            }
            Marshal.Copy(buf, 0, bd.Scan0, len);
        } finally { bmp.UnlockBits(bd); }

        IntPtr screenDc = GetDC(IntPtr.Zero);
        IntPtr memDc = CreateCompatibleDC(screenDc);
        IntPtr hBmp = bmp.GetHbitmap(Color.FromArgb(0));
        IntPtr old = SelectObject(memDc, hBmp);
        SIZE size; size.cx = w; size.cy = h;
        POINT src; src.X = 0; src.Y = 0;
        BLENDFUNCTION blend;
        blend.BlendOp = 0; blend.BlendFlags = 0;
        blend.SourceConstantAlpha = alpha; blend.AlphaFormat = 1;   // AC_SRC_ALPHA
        bool ok = UpdateLayeredWindow(hwnd, screenDc, IntPtr.Zero, ref size, memDc, ref src, 0, ref blend, 2);
        SelectObject(memDc, old);
        DeleteObject(hBmp);
        DeleteDC(memDc);
        ReleaseDC(IntPtr.Zero, screenDc);
        return ok;
    }

    // Win11 圆角兜底（分层窗口不可用时才走）：DWMWA_WINDOW_CORNER_PREFERENCE = 33
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);

    public static bool EnableDwmRound(IntPtr hwnd) {
        try {
            int v = 2;   // DWMWCP_ROUND
            return DwmSetWindowAttribute(hwnd, 33, ref v, 4) == 0;
        } catch { return false; }
    }

    public static int OsBuild() { return Environment.OSVersion.Version.Build; }
}

// 右键菜单配色（深/浅两套，由 Light 字段切换）
public class TokenColorTable : System.Windows.Forms.ProfessionalColorTable {
    public bool Light = false;
    static Color BgDark    = Color.FromArgb(28, 31, 39);
    static Color HoverDark = Color.FromArgb(45, 52, 64);
    static Color BordDark  = Color.FromArgb(52, 58, 72);
    static Color SepDark   = Color.FromArgb(46, 51, 63);
    static Color BgLight   = Color.FromArgb(252, 252, 252);
    static Color HoverLight= Color.FromArgb(238, 240, 244);
    static Color BordLight = Color.FromArgb(214, 216, 220);
    static Color SepLight  = Color.FromArgb(228, 230, 234);

    Color Bg    { get { return Light ? BgLight : BgDark; } }
    Color Hover { get { return Light ? HoverLight : HoverDark; } }
    Color Bord  { get { return Light ? BordLight : BordDark; } }
    Color Sep   { get { return Light ? SepLight : SepDark; } }

    public override Color ToolStripDropDownBackground { get { return Bg; } }
    public override Color MenuItemSelected            { get { return Hover; } }
    public override Color MenuItemSelectedGradientBegin { get { return Hover; } }
    public override Color MenuItemSelectedGradientEnd   { get { return Hover; } }
    public override Color MenuItemBorder              { get { return Hover; } }
    public override Color MenuBorder                  { get { return Bord; } }
    public override Color ImageMarginGradientBegin    { get { return Bg; } }
    public override Color ImageMarginGradientMiddle   { get { return Bg; } }
    public override Color ImageMarginGradientEnd      { get { return Bg; } }
    public override Color SeparatorDark               { get { return Sep; } }
    public override Color SeparatorLight              { get { return Sep; } }
    public override Color CheckBackground             { get { return Hover; } }
    public override Color CheckSelectedBackground     { get { return Hover; } }
}
'@
try {
    Add-Type -TypeDefinition $nativeSrc -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -ErrorAction Stop
} catch {
    Write-Host ("[WARN] 原生类型编译失败: " + $_.Exception.Message)
}

# 开启 Per-Monitor V2 DPI 感知：必须在创建任何窗口之前调用。
# 不设置的话，Windows 会把整个窗口当位图按 150% 拉伸，字体必然模糊。
$script:DpiAware = $false
try {
    [void][NativeWin]::SetThreadDpiAwarenessContext([IntPtr](-4))
    $script:DpiAware = $true
} catch {
    Write-Host ("[WARN] DPI 感知设置失败: " + $_.Exception.Message)
}

. (Join-Path $script:LibDir 'QuotaCore.ps1')
. (Join-Path $script:LibDir 'ConfigWindow.ps1')

# ============================================================
# 主题（深色 / 浅色，调色板定义在 QuotaCore.Get-MainTheme）
# ============================================================
function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }

# ============================================================
# 金额账户（余额类）—— 用圆环显示，不画进度弧
#   负数（欠费/透支）红；低于 moneyWarn 黄；其余青
# ============================================================
function Get-AccountMoney {
    param($Account)
    if (-not $Account) { return $null }
    foreach ($t in @($Account.tiers)) {
        if ($null -ne $t.money) { return [double]$t.money }
    }
    return $null
}

function Get-MoneyHex {
    param($Money)
    if ($null -eq $Money) { return $Theme.Tx3 }
    $warn = 20.0
    if ($script:Cfg.moneyWarn) {
        $tmp = 0.0
        if ([double]::TryParse([string]$script:Cfg.moneyWarn, [ref]$tmp)) { $warn = $tmp }
    }
    # 红色档（2026-10-30 定案）：≤ moneyCrit(默认5) 红，负数（欠费）也红
    $crit = 5.0
    if ($script:Cfg.moneyCrit) {
        $tmp2 = 0.0
        if ([double]::TryParse([string]$script:Cfg.moneyCrit, [ref]$tmp2)) { $crit = $tmp2 }
    }
    if ($Money -lt 0 -or $Money -le $crit) { return $Theme.Rd }
    if ($Money -lt $warn) { return $Theme.Am }
    return $Theme.Cy
}

# 账户的计量单位：'credits' = WorkBuddy 积分类（阈值独立于 ¥ 金额档）
function Get-AccountUnit {
    param($Account)
    if (-not $Account) { return '' }
    foreach ($t in @($Account.tiers)) {
        if ($t.unit) { return [string]$t.unit }
    }
    return ''
}

# 余额上色统一入口（2026-10-30 定案阈值）：
#   ¥ 金额档  ：≤5 红（负数也红）/ < moneyWarn(默认20) 黄 / 其余青
#   credits 档：≤20 红 / ≤50 黄 / 其余青
function Get-BalanceHex {
    param($Money, [string]$Unit = '')
    if ($null -eq $Money) { return $Theme.Tx3 }
    if ($Unit -eq 'credits') {
        $c = [double]$Money
        if ($c -le 20) { return $Theme.Rd }
        if ($c -le 50) { return $Theme.Am }
        return $Theme.Cy
    }
    return (Get-MoneyHex $Money)
}

function Get-AccountMoneyText {
    param($Account)
    $t = @($Account.tiers) | Select-Object -First 1
    if (-not $t) { return '--' }
    if ($t.display) { return [string]$t.display }
    if ($null -ne $t.money) { return ('{0:N2}' -f [double]$t.money) }
    return '--'
}

# 金额越长字号越小，保证不撑破单元
function Get-MoneyFontPx {
    param([string]$Text)
    $n = $Text.Length
    if ($n -le 5) { return 14 }
    if ($n -le 8) { return 11 }
    return 9
}

# 圆环里只放「当前金额」，不要 "$1.00 / $1.50" 这种长串
function Get-AccountMoneyShort {
    param($Account)
    # 积分类（credits）：小圆圈里只放数字，"credits" 后缀会挤爆（展开态仍显示完整 display）
    # 千位以上用 k 缩写：51px 圆环内径只有约 27px，"2052" 会顶到描边，"2.1k" 才留白
    if ((Get-AccountUnit $Account) -eq 'credits') {
        $m = Get-AccountMoney $Account
        if ($null -ne $m) {
            if ($m -ge 10000) { return ('{0:0}k' -f ($m / 1000)) }
            if ($m -ge 1000) { return ('{0:0.0}k' -f ($m / 1000)) }
            return ('{0:0}' -f $m)
        }
    }
    $s = Get-AccountMoneyText $Account
    if ($s -and $s.Contains('/')) {
        $s = ($s -split '/')[0].Trim()
    }
    return $s
}

$script:Cfg = Load-Config
$Theme = Get-MainTheme ([string]$script:Cfg.theme)
$script:ThemeName = if ($script:Cfg.theme -eq 'light') { 'light' } else { 'dark' }
# 超时时间从配置读取，供 QuotaCore 的 HTTP 请求使用
if ($script:Cfg.timeout) { $script:HttpTimeout = [int]$script:Cfg.timeout }
$script:Data = $null
$script:Mode = 'dock'
$script:Dragging = $false
# 只有「用户真的拖动过」才允许触发贴边/落盘。
# 否则程序自己调整尺寸（展开/收起/截图）也会被当成拖动，把位置写花。
$script:UserMoving = $false

# ---------- 双击刷新动效 ----------
$script:AnimActive = $false     # 是否正在播放动效
$script:AnimFrame = 0           # 已播放帧数（33ms/帧，30 帧 ≈ 1 秒）
$script:AnimAngle = 0           # 光弧当前角度
$script:AnimSeed = 0            # 随机数种子，保证同一帧内各环不各自乱闪

# 动效期间环内数字「快速读数」：位数/货币符号保持不变，数值乱跳，结束后回落到真实值
function Get-FlickerText {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $rnd = New-Object System.Random ($script:AnimSeed + [int][Math]::Floor($script:AnimFrame / 3))
    if ($Text -match '^\d+$') {
        $digits = $Text.Length
        $max = [int][Math]::Pow(10, $digits) - 1
        $v = $rnd.Next(0, $max + 1)
        return ([string]$v).PadLeft($digits, '0')
    }
    if ($Text -match '^([^\d\-\.]*)(-?\d+(?:\.\d+)?)$') {
        $prefix = $matches[1]
        $base = [double]$matches[2]
        $mag = [Math]::Max(5.0, [Math]::Abs($base) * 2.5)
        $v = ($rnd.NextDouble() * 2 - 0.5) * $mag
        return $prefix + $v.ToString('0.00')
    }
    return $Text
}

# ============================================================
# 告警等级（按「使用量」判断，不是剩余量）
#   5h 窗口：使用量 >= 80% → 黄，>= 90% → 红
#   周窗口 ：使用量 >= 95% → 黄，>= 100% → 红（满了才红）
#   悬浮窗环色取两个窗口里最严重的一级 —— 周额度快没了就必须报警，
#   哪怕 5 小时还很宽裕，也不能因为显示的是 5 小时就装没事。
# 返回 0=正常 1=偏紧 2=告急
# ============================================================
function Get-TierLevel {
    param($Tier)
    if ($null -eq $Tier) { return 0 }
    $remain = [int]$Tier.remain
    if ($remain -lt 0) { return 0 }
    $used = 100 - $remain

    $isWeek = ($Tier.name -match '周|天|week|weekly|month|月')
    if ($isWeek) {
        # 周额度：95% 起黄（提醒快没了），100%（满了）才红。
        # 红线原来是 95%，会让「周 97%」直接变红，与用户要求（97% 黄）冲突，故上调到 100。
        if ($used -ge 100) { return 2 }
        if ($used -ge 95) { return 1 }
    } else {
        if ($used -ge 90) { return 2 }
        if ($used -ge 80) { return 1 }
    }
    return 0
}

function Get-AccountLevel {
    param($Account)
    if (-not $Account -or -not $Account.ok) { return 0 }
    $max = 0
    foreach ($t in @($Account.tiers)) {
        $lv = Get-TierLevel $t
        if ($lv -gt $max) { $max = $lv }
    }
    return $max
}

function Get-LevelHex {
    param([int]$Level)
    if ($Level -ge 2) { return $Theme.Rd }
    if ($Level -ge 1) { return $Theme.Am }
    return $Theme.Cy
}

# 兼容旧调用：按剩余百分比直接给色（仅用于无 tier 结构的场合）
function Get-LevelColor {
    param([int]$Pct)
    if ($Pct -lt 0) { return $Theme.Tx3 }
    if ($Pct -le [int]$script:Cfg.critThreshold) { return $Theme.Rd }
    if ($Pct -le [int]$script:Cfg.warnThreshold) { return $Theme.Am }
    return $Theme.Cy
}

# ============================================================
# 尺寸（以下都是「逻辑像素」，绘制时统一经 S() 换算成物理像素）
# ============================================================
# 折叠态单元 68×68（用户指定），内部纵向分配：
#   上边距 7 + 圆环 40 + 环下间距 3 + 标签 11 + 下边距 7 = 68
# 不是把 89 等比缩 —— 89 时代的 12/52/4/12 塞不进 68，必须重新配平
$DOCK_W = 68          # 单账户单元宽度，多账户按此横向累加
$DOCK_H = 68
$PANEL_W = 340
$RING_R = 20          # 圆圈半径（直径 40，比 89 时代的 52 小 23%）
$DOCK_PAD_TOP = 7     # 环上边距
$DOCK_RING_GAP = 3    # 环与标签的间距
$DOCK_LBL_H = 11      # 标签行高
# 小于这个系数就不画账户名：51px 单元里标签只剩约 6px，糊成一团不如不画（用户确认方案 B）
$DOCK_LBL_MIN_SCALE = 0.9

# ---- 折叠态排版（v1.1.4，方案 B）----
# 这些以前散落在 Draw-Ring / Draw-MoneyRing 里写死，抽成常量便于统一调整
$DOCK_PEN      = 2.0    # 圆环笔宽：用量环与余额环共用（用户要求两者一致）
$NUM_SIZE      = 15     # 中心数字字号（逻辑像素，绘制时再乘 DS）
$NUM_SIZE_3    = 11     # 三位数（100%）字号
$PCT_RATIO     = 0.75   # 百分号字号 = 数字字号 × 该比例
$PCT_DROP      = 2      # 百分号相对数字的下沉量（视觉上落在右下角）
$PCT_GAP       = 0.0    # 数字与百分号的间距；0 = 贴齐，负值会挤压（旧版 -2 太挤）
$DOCK_LBL_SIZE = 8      # 账户名字号
# 垂直居中修正系数：TextRenderer 的 VerticalCenter 对齐的是「行框」，而数字没有下伸部，
# 行框下半截的空白把墨迹顶低约 0.075×字号。该系数由 measure-center.ps1 用亮度加权质心标定。
$CENTER_FIX    = 0.075

# DPI 缩放因子：在窗口句柄创建后赋值（150% 屏 → 1.5）
$script:Scale = 1.0

# 悬浮窗大小系数：小 0.75 / 默认 1.0 / 大 1.25（系统配置页可调）
$script:DockScale = 1.0
if ($script:Cfg.dockScale) {
    $dv = 0.0
    if ([double]::TryParse([string]$script:Cfg.dockScale, [ref]$dv) -and $dv -gt 0) { $script:DockScale = $dv }
}

# 悬浮窗排布方向：h = 横排（贴上下边/自由漂浮），v = 纵排（贴左右边）
$script:DockOrient = 'h'
# 当前吸附到的边：左右决定横坐标锚点，上下决定纵坐标锚点
$script:SnapEdgeH = 'none'    # none | left | right
$script:SnapEdgeV = 'none'    # none | top  | bottom

# 逻辑像素 → 物理像素
function S {
    param([double]$v)
    return [int][Math]::Round($v * $script:Scale)
}

# 悬浮窗专用：再乘上「悬浮大小」系数（面板展开态不受影响）
function DS {
    param([double]$v)
    return [int][Math]::Round($v * $script:Scale * $script:DockScale)
}

function Get-PanelHeight {
    param($Data)
    $n = 0
    if ($Data -and $Data.accounts) { $n = $Data.accounts.Count }
    if ($n -eq 0) { $n = 1 }
    # 44 标题 + 10 上边距 + n*76（名称 26 + 两条进度 44 + 间距 6）+ 6 + 20 底栏
    return (S (80 + ($n * 76)))
}

# 折叠态宽度：横排 = 账户数 × 89；纵排 = 单列 89 宽
function Get-DockCount {
    $all = @(Get-SortedAccounts).Count
    if ($all -le 0) { return 1 }
    # 折叠态显示几个由系统配置页的「显示数量」决定（1–5，默认 3）
    $max = 3
    if ($script:Cfg.maxDockItems) {
        $tmp = 0
        if ([int]::TryParse([string]$script:Cfg.maxDockItems, [ref]$tmp) -and $tmp -ge 1) { $max = $tmp }
    }
    if ($max -gt $all) { return $all }
    return $max
}

function Get-DockWidth {
    $n = Get-DockCount
    if ($script:DockOrient -eq 'v') { return (DS $DOCK_W) }
    return (DS ($n * $DOCK_W))
}

function Get-DockHeight {
    $n = Get-DockCount
    if ($script:DockOrient -eq 'v') { return (DS ($n * $DOCK_H)) }
    return (DS $DOCK_H)
}

# ============================================================
# 绘图工具
# ============================================================
function New-RoundedPath {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($R -le 0) { $p.AddRectangle((New-Object System.Drawing.RectangleF $X, $Y, $W, $H)); return $p }
    $d = $R * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# 圆角路径，四角半径可分别指定（贴屏幕边的那侧削平，视觉上才像「长在边上的」
function New-RoundedPathEx {
    param([single]$X, [single]$Y, [single]$W, [single]$H,
          [single]$RTL = 0, [single]$RTR = 0, [single]$RBR = 0, [single]$RBL = 0)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddLine(($X + $RTL), $Y, ($X + $W - $RTR), $Y)
    if ($RTR -gt 0) { $p.AddArc(($X + $W - 2 * $RTR), $Y, (2 * $RTR), (2 * $RTR), 270, 90) }
    $p.AddLine(($X + $W), ($Y + $RTR), ($X + $W), ($Y + $H - $RBR))
    if ($RBR -gt 0) { $p.AddArc(($X + $W - 2 * $RBR), ($Y + $H - 2 * $RBR), (2 * $RBR), (2 * $RBR), 0, 90) }
    $p.AddLine(($X + $W - $RBR), ($Y + $H), ($X + $RBL), ($Y + $H))
    if ($RBL -gt 0) { $p.AddArc($X, ($Y + $H - 2 * $RBL), (2 * $RBL), (2 * $RBL), 90, 90) }
    $p.AddLine($X, ($Y + $H - $RBL), $X, ($Y + $RTL))
    if ($RTL -gt 0) { $p.AddArc($X, $Y, (2 * $RTL), (2 * $RTL), 180, 90) }
    $p.CloseFigure()
    return $p
}

function Draw-Text {
    param($G, [string]$Text, $Font, [string]$Color, [single]$X, [single]$Y, [single]$W, [single]$H,
          [string]$Align = 'Near', [switch]$Ellipsis)
    # 用 TextRenderer（GDI）而不是 Graphics.DrawString（GDI+）：
    # GDI 走 ClearType + 整数像素对齐，小字号下明显更锐利
    $flags = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor `
             [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
             [System.Windows.Forms.TextFormatFlags]::NoPrefix
    if ($Align -eq 'Center') { $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::HorizontalCenter }
    elseif ($Align -eq 'Far') { $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::Right }
    if ($Ellipsis) { $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis }

    $rect = New-Object System.Drawing.Rectangle ([int]$X), ([int]$Y), ([int]$W), ([int]$H)
    [System.Windows.Forms.TextRenderer]::DrawText($G, $Text, $Font, $rect, (C $Color), $flags)
}

function Measure-TextWidth {
    param([string]$Text, $Font)
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $Font)
    return $sz.Width
}

function Draw-Ring {
    param($G, [single]$Cx, [single]$Cy, [int]$Pct, [string]$ColorHex, [string]$Text)

    $r = DS $RING_R
    $penW = DS $DOCK_PEN
    $box = [single](($r - $penW / 2) * 2)
    $bx = $Cx - $box / 2
    $by = $Cy - $box / 2

    # 底环（用主题色，浅色主题下白色半透明环会看不见）
    $penBg = New-Object System.Drawing.Pen (C $Theme.TrackRing), ([single]$penW)
    $G.DrawEllipse($penBg, $bx, $by, $box, $box)
    $penBg.Dispose()

    # 进度弧
    if ($Pct -gt 0) {
        $pen = New-Object System.Drawing.Pen (C $ColorHex), ([single]$penW)
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $sweep = [single](360.0 * [Math]::Min(100, $Pct) / 100.0)
        if ($sweep -ge 359.5) { $sweep = 359.5 }
        $G.DrawArc($pen, $bx, $by, $box, $box, -90, $sweep)
        $pen.Dispose()
    }

    # 双击刷新动效：一段 64° 的高亮光弧绕圈转，视觉上像「正在读数」
    if ($script:AnimActive) {
        $gl = New-Object System.Drawing.Pen (C $Theme.Glow), ([single]$penW)
        $gl.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $gl.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $G.DrawArc($gl, $bx, $by, $box, $box, [single]($script:AnimAngle - 90), 64)
        $gl.Dispose()
    }

    # 中心数字 + 百分号（方案 B：数字 15 SemiBold，% 放大到 0.75 且间距归零）
    $fs = DS $NUM_SIZE
    if ($Text.Length -ge 3) { $fs = DS $NUM_SIZE_3 }
    $fontNum = New-Object System.Drawing.Font 'Segoe UI Semibold', ([single]$fs), ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
    # 垂直居中修正：VerticalCenter 对齐行框，数字无下伸部 → 墨迹比圆心低 CENTER_FIX×字号
    $dyNum = [int][Math]::Round($fs * $CENTER_FIX)

    $flagsM = [System.Windows.Forms.TextFormatFlags]::NoPadding
    $flagsC = $flagsM -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter

    if ($Pct -lt 0) {
        $rN = New-Object System.Drawing.Rectangle ([int]($Cx - $r)), ([int]($Cy - $r - $dyNum)), ([int]($r * 2)), ([int]($r * 2))
        [System.Windows.Forms.TextRenderer]::DrawText($G, $Text, $fontNum, $rN,
            (C $Theme.RingText), ($flagsC -bor [System.Windows.Forms.TextFormatFlags]::HorizontalCenter))
        $fontNum.Dispose()
        return
    }

    $fsPct = [int][Math]::Round($fs * $PCT_RATIO)
    $fontPct = New-Object System.Drawing.Font 'Segoe UI Semibold', ([single]$fsPct), ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
    $dyPct = [int][Math]::Round($fsPct * $CENTER_FIX)
    # 用 GenericTypographic 测量：不含额外 padding，宽度最接近实际渲染
    $sfM = [System.Drawing.StringFormat]::GenericTypographic
    $numW = [int][Math]::Ceiling($G.MeasureString($Text, $fontNum, 1000, $sfM).Width)
    $pctW = [int][Math]::Ceiling($G.MeasureString('%', $fontPct, 1000, $sfM).Width)

    # 间距由 $PCT_GAP 控制：0 = 贴齐。旧版写死 -(DS 2) 是给 Bold 补 overhang，
    # 换 SemiBold 后字形右侧留白变小，那个补偿反而变成挤压，用户明确要求归零。
    $gap = [int][Math]::Round((DS $PCT_GAP))
    $totalW = $numW + $gap + $pctW
    $sx = [int]($Cx - $totalW / 2)

    $rNum = New-Object System.Drawing.Rectangle $sx, ([int]($Cy - $r - $dyNum)), $numW, ([int]($r * 2))
    [System.Windows.Forms.TextRenderer]::DrawText($G, $Text, $fontNum, $rNum, (C $Theme.RingText), $flagsC)

    # % 下沉 PCT_DROP，视觉上落在数字右下角
    $rPct = New-Object System.Drawing.Rectangle ($sx + $numW + $gap), ([int]($Cy - $r + (DS $PCT_DROP) - $dyPct)), ($pctW + (DS 2)), ([int]($r * 2))
    [System.Windows.Forms.TextRenderer]::DrawText($G, '%', $fontPct, $rPct, (C $Theme.RingText), $flagsC)

    $fontNum.Dispose(); $fontPct.Dispose()
}

# 余额圆环：细描边整圈 + 居中金额（不画进度弧，避免被误读成「用满了」）
function Draw-MoneyRing {
    param($G, [single]$Cx, [single]$Cy, [string]$Text, [string]$ColorHex)

    $r = DS $RING_R
    # 笔宽与用量环统一（用户明确要求）。原来这里故意用 2 让余额环更细以便区分，
    # 但两个环并排时粗细不一致会显得「没对齐」，改成共用 $DOCK_PEN。
    # 区分手段改为：余额环不画进度弧（整圈实线）+ 内容是金额。
    $penW = DS $DOCK_PEN
    $box = [single](($r - $penW / 2) * 2)
    $bx = [single]($Cx - $box / 2)
    $by = [single]($Cy - $box / 2)

    # 底环先铺一层，和百分比圆环保持同样的骨架
    $penBg = New-Object System.Drawing.Pen (C $Theme.TrackRing), ([single]$penW)
    $G.DrawEllipse($penBg, $bx, $by, $box, $box)
    $penBg.Dispose()

    $pen = New-Object System.Drawing.Pen (C $ColorHex), ([single]$penW)
    $G.DrawEllipse($pen, $bx, $by, $box, $box)
    $pen.Dispose()

    # 双击刷新动效：和百分比圆环同款光弧
    if ($script:AnimActive) {
        $gl = New-Object System.Drawing.Pen (C $Theme.Glow), ([single]($penW * 1.6))
        $gl.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $gl.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $G.DrawArc($gl, $bx, $by, $box, $box, [single]($script:AnimAngle - 90), 64)
        $gl.Dispose()
    }

    # 金额字号按长度自适应，保证不撑破圆环
    $fs = DS (Get-MoneyFontPx $Text)
    $font = New-Object System.Drawing.Font 'Segoe UI', ([single]$fs), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    # 和用量环同样的垂直居中修正
    $dyM = [int][Math]::Round($fs * $CENTER_FIX)
    $flags = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor
             [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
             [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor
             [System.Windows.Forms.TextFormatFlags]::NoPrefix
    # 文本框比圆环略宽一点（负号/¥ 容易贴边），靠 Ellipsis 兜底
    $pad = [int](DS 3)
    $rect = New-Object System.Drawing.Rectangle ([int]($Cx - $r - $pad)), ([int]($Cy - $r - $dyM)), ([int](($r + $pad) * 2)), ([int]($r * 2))
    [System.Windows.Forms.TextRenderer]::DrawText($G, $Text, $font, $rect, (C $ColorHex), $flags)
    $font.Dispose()
}

function Draw-Bar {
    param($G, [single]$X, [single]$Y, [single]$W, [single]$H, [int]$Pct, [string]$ColorHex)
    $p = [Math]::Max(0, [Math]::Min(100, $Pct))
    $pathBg = New-RoundedPath -X $X -Y $Y -W $W -H $H -R ($H / 2)
    $bg = New-Object System.Drawing.SolidBrush (C $Theme.Track)
    $G.FillPath($bg, $pathBg)
    $bg.Dispose(); $pathBg.Dispose()

    if ($p -gt 0) {
        $fw = [single]($W * $p / 100.0)
        if ($fw -lt $H) { $fw = $H }
        $pathFg = New-RoundedPath -X $X -Y $Y -W $fw -H $H -R ($H / 2)
        $fg = New-Object System.Drawing.SolidBrush (C $ColorHex)
        $G.FillPath($fg, $pathFg)
        $fg.Dispose(); $pathFg.Dispose()
    }
}

function Format-Reset {
    param($Iso)
    if (-not $Iso) { return '' }
    try {
        $span = ([DateTimeOffset]::Parse($Iso)).LocalDateTime - (Get-Date)
        if ($span.TotalSeconds -le 0) { return '已重置' }
        # 紧凑格式，对齐 CC Switch：49m / 4h42m / 3d9h
        $totalMin = [int][Math]::Floor($span.TotalMinutes)
        if ($totalMin -lt 60) { return ($totalMin.ToString() + 'm') }
        $d = [int][Math]::Floor($totalMin / 1440)
        $h = [int][Math]::Floor(($totalMin % 1440) / 60)
        $m = $totalMin % 60
        if ($d -gt 0) { return ($d.ToString() + 'd' + $h.ToString() + 'h') }
        return ($h.ToString() + 'h' + $m.ToString() + 'm')
    } catch { return '' }
}

function Get-MaxUsed {
    param($Account)
    if (-not $Account -or -not $Account.ok) { return -1 }
    $max = -1
    foreach ($t in @($Account.tiers)) {
        if ([int]$t.remain -ge 0) {
            $u = 100 - [int]$t.remain
            if ($u -gt $max) { $max = $u }
        }
    }
    return $max
}

# 折叠态圆环只看「主窗口」= 解析器输出的第一个窗口。
# 各家解析器都按「5 小时 → 7 天」的顺序建 tier，所以第一个就是 5 小时。
# 之前取两个窗口里的最大值，结果 MX2421（5h 用 1%、7d 用 34%）显示成 34%，
# 用户看到的其实是周额度 —— 这是用户明确指出的 bug。
function Get-PrimaryTier {
    param($Account)
    if (-not $Account -or -not $Account.ok) { return $null }
    foreach ($t in @($Account.tiers)) {
        if ($null -ne $t.remain -and [int]$t.remain -ge 0) { return $t }
    }
    return $null
}

# 折叠态圆环要显示的窗口：
#   默认取第一个有效窗口（即 5 小时窗口，见 Get-PrimaryTier 注释）。
#   新要求：当「周」窗口使用量达到 100%（已用满，remain <= 0）时，哪怕 5 小时
#   消耗为 0，也改显示周窗口 —— 因为周额度已经满了，用户要看的是周这一档。
#   周窗口按名称识别：7天 / 本周 / weekly 等（不含月，月是另一档，不在此规则内）。
function Get-DisplayTier {
    param($Account)
    if (-not $Account -or -not $Account.ok) { return $null }
    $primary = Get-PrimaryTier $Account
    $weekly = $null
    foreach ($t in @($Account.tiers)) {
        if ($null -ne $t.remain -and ($t.name -match '周|天|week|weekly')) {
            $weekly = $t
            break
        }
    }
    if ($weekly -and [int]$weekly.remain -le 0) {
        return $weekly
    }
    return $primary
}

function Get-SortedAccounts {
    if (-not $script:Data -or -not $script:Data.accounts) { return @() }
    # 顺序完全由配置里的 providers 数组决定（配置页可以 ↑↓ 手动移动）。
    # v1.1.1 起取消「按告警程度自动排序」——用户要的是自己说了算，自动排序会让列表在他眼前乱跳。
    return @($script:Data.accounts)
}

# ============================================================
# 折叠态绘制
# ============================================================
function Draw-Dock {
    param($G, [single]$W, [single]$H)

    $top = @(Get-SortedAccounts | Select-Object -First (Get-DockCount))
    $vert = ($script:DockOrient -eq 'v')

    if ($top.Count -eq 0) {
        $f = New-Object System.Drawing.Font 'Microsoft YaHei UI', ([single](DS 9)), ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
        Draw-Text -G $G -Text '无账户' -Font $f -Color $Theme.Tx3 -X 0 -Y (DS 34) -W $W -H (DS 20) -Align Center
        $f.Dispose()
        return
    }

    $fontLbl = New-Object System.Drawing.Font 'Microsoft YaHei UI', ([single](DS $DOCK_LBL_SIZE)), ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
    $ringR = DS $RING_R
    $unitW = DS $DOCK_W
    $unitH = DS $DOCK_H
    # 小档不画账户名：51px 单元里标签只有约 6px 高，笔画糊在一起反而更乱
    $showLabel = ($script:DockScale -ge $DOCK_LBL_MIN_SCALE)

    for ($i = 0; $i -lt $top.Count; $i++) {
        $a = $top[$i]

        # 纵排：单元向下堆叠，圆心始终在列中线上；横排：单元向右排列
        if ($vert) {
            $ox = 0
            $oy = $unitH * $i
            $cx = $W / 2
        } else {
            $ox = $unitW * $i
            $oy = 0
            $cx = $ox + $unitW / 2
        }
        # 有标签：圆环靠上，下面留出标签行；无标签：圆环在单元里垂直居中
        $cy = if ($showLabel) { $oy + (DS $DOCK_PAD_TOP) + $ringR } else { $oy + $unitH / 2 }

        if ($a.kind -eq 'money') {
            # 余额账户也用圆环（用户明确要求），只是不画进度弧，改成细描边 + 居中金额
            # credits 账户（WorkBuddy）走积分阈值档（≤20 红 / ≤50 黄）
            $money = Get-AccountMoney $a
            $mcol = if ($a.ok) { Get-BalanceHex $money (Get-AccountUnit $a) } else { $Theme.Tx3 }
            $txt = if ($a.ok) { Get-AccountMoneyShort $a } else { '--' }
            if ($script:AnimActive) { $txt = Get-FlickerText $txt }
            Draw-MoneyRing -G $G -Cx $cx -Cy $cy -Text $txt -ColorHex $mcol
        } else {
            # 数字默认显示 **5 小时** 窗口（用户明确指定），不再取两个窗口的最大值。
            # 例外：当「周」窗口已用满（使用量 >= 100%，remain <= 0）时，改显示周窗口，
            # 哪怕 5 小时消耗为 0 —— 因为周额度已经满了，用户要看的是周这一档。
            # 颜色不跟「显示的那个窗口」走，而是取两个窗口里最严重的一级：
            # 周额度快没了（>=95% 黄 / 满 100% 红）时，哪怕 5h 很宽裕也要报警。
            $pt = Get-DisplayTier $a
            $used = if ($pt) { 100 - [int]$pt.remain } else { -1 }
            $ringCol = if ($pt) { Get-LevelHex (Get-AccountLevel $a) } else { $Theme.Tx3 }
            $txt = if ($used -ge 0) { [string]$used } else { '--' }
            if ($script:AnimActive) { $txt = Get-FlickerText $txt }
            Draw-Ring -G $G -Cx $cx -Cy $cy -Pct $used -ColorHex $ringCol -Text $txt
        }

        # 标签占满整个单元宽度（左右各留 6），比圆圈宽，能放更多字
        if ($showLabel) {
            $lblColor = if ($a.ok) { $Theme.Tx2 } else { $Theme.Tx3 }
            $lx = if ($vert) { (DS 6) } else { $ox + (DS 6) }
            $lw = if ($vert) { $W - (DS 12) } else { $unitW - (DS 12) }
            Draw-Text -G $G -Text $a.short -Font $fontLbl -Color $lblColor `
                -X $lx -Y ($cy + $ringR + (DS $DOCK_RING_GAP)) -W $lw -H (DS $DOCK_LBL_H) -Align Center -Ellipsis
        }
    }
    $fontLbl.Dispose()
}

# ============================================================
# 展开态绘制
# ============================================================
function Draw-Panel {
    param($G, [single]$W, [single]$H)

    $fontTitle = New-Object System.Drawing.Font 'Microsoft YaHei UI', ([single](S 13)), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $fontName  = New-Object System.Drawing.Font 'Microsoft YaHei UI', ([single](S 12)), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $fontBig   = New-Object System.Drawing.Font 'Segoe UI', ([single](S 13)), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $fontMoney = New-Object System.Drawing.Font 'Segoe UI', ([single](S 11)), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $fontTiny  = New-Object System.Drawing.Font 'Microsoft YaHei UI', ([single](S 9)), ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
    $fontIcon  = New-Object System.Drawing.Font 'Segoe UI', ([single](S 11)), ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)

    # 标题栏
    Draw-Text -G $G -Text $script:AppName -Font $fontTitle -Color $Theme.Tx -X (S 16) -Y 0 -W (S 200) -H (S 44)
    Draw-Text -G $G -Text '✕' -Font $fontIcon -Color $Theme.Tx3 -X ($W - (S 38)) -Y 0 -W (S 24) -H (S 44) -Align Center

    # 分隔线
    $penLine = New-Object System.Drawing.Pen (C $Theme.Line), ([single](S 1))
    $G.DrawLine($penLine, 0, (S 44), $W, (S 44))
    $penLine.Dispose()

    $list = @(Get-SortedAccounts)
    if ($list.Count -eq 0) {
        Draw-Text -G $G -Text '还没有配置账户' -Font $fontTiny -Color $Theme.Tx3 -X 0 -Y (S 60) -W $W -H (S 30) -Align Center
        $fontTitle.Dispose(); $fontName.Dispose(); $fontBig.Dispose(); $fontMoney.Dispose(); $fontTiny.Dispose(); $fontIcon.Dispose()
        return
    }

    $y = (S 44) + (S 10)
    foreach ($a in $list) {
        # 大号百分比与圆圈保持一致：取「最严重的窗口」
        $usedAcc = Get-MaxUsed $a
        $lvAcc = Get-AccountLevel $a
        $isMoneyAcc = ($a.kind -eq 'money')
        # 色点跟着账户状态走：余额账户看金额（credits 走积分档阈值），额度账户看最严重窗口的等级
        $color = if (-not $a.ok) { $Theme.Tx3 }
                 elseif ($isMoneyAcc) { Get-BalanceHex (Get-AccountMoney $a) (Get-AccountUnit $a) }
                 else { Get-LevelHex $lvAcc }

        # 色点
        $dot = New-Object System.Drawing.SolidBrush (C $color)
        $G.FillEllipse($dot, (S 16), ($y + (S 6)), (S 8), (S 8))
        $dot.Dispose()

        # 名称 + 大号百分比（余额账户显示金额）
        $isMoney = ($a.kind -eq 'money')
        $bigW = if ($isMoney) { S 104 } else { S 46 }
        Draw-Text -G $G -Text $a.name -Font $fontName -Color $Theme.Tx -X (S 30) -Y $y -W ($W - (S 30) - $bigW - (S 10)) -H (S 20) -Ellipsis

        if ($isMoney) {
            $bigTxt = if ($a.ok) { Get-AccountMoneyText $a } else { '—' }
            $bigColor = if ($a.ok) { Get-BalanceHex (Get-AccountMoney $a) (Get-AccountUnit $a) } else { $Theme.Tx3 }
        } else {
            $bigTxt = if ($usedAcc -ge 0) { "$usedAcc%" } else { '—' }
            $bigColor = if ($lvAcc -ge 2) { $Theme.Rd } elseif ($lvAcc -ge 1) { $Theme.Am } else { $Theme.RingText }
        }
        Draw-Text -G $G -Text $bigTxt -Font $fontBig -Color $bigColor -X ($W - $bigW - (S 16)) -Y $y -W $bigW -H (S 20) -Align Far -Ellipsis

        $by = $y + (S 26)

        # 各窗口进度条
        $tiers = @($a.tiers)
        if ($tiers.Count -eq 0) {
            $errTxt = if ($a.error) { $a.error } else { '无数据' }
            Draw-Text -G $G -Text $errTxt -Font $fontTiny -Color $Theme.Rd -X (S 30) -Y $by -W ($W - (S 46)) -H (S 16) -Ellipsis
            $by += (S 18)
        } elseif ($isMoney) {
            # 余额账户只有一个「窗口」，金额已经显示在右上角，这里只留语义标签
            foreach ($t in $tiers) {
                $mhex = if ($null -ne $t.money) { Get-BalanceHex ([double]$t.money) ([string]$t.unit) } else { $Theme.Tx3 }
                Draw-Text -G $G -Text $t.name -Font $fontTiny -Color $Theme.Tx3 -X (S 30) -Y $by -W (S 60) -H (S 14)
                if ($null -ne $t.money -and [double]$t.money -lt 0) {
                    Draw-Text -G $G -Text '已欠费' -Font $fontMoney -Color $mhex -X (S 96) -Y $by -W (S 80) -H (S 14)
                } elseif ($t.display) {
                    # 积分/签到等无进度条的 tier：右侧显示状态文本（如「今日未签到」）
                    Draw-Text -G $G -Text ([string]$t.display) -Font $fontTiny -Color $mhex -X (S 96) -Y $by -W ($W - (S 96) - (S 16)) -H (S 14)
                }
                $by += (S 22)
            }
        } else {
            foreach ($t in $tiers) {
                # 进度条也按使用量画（用得越多条越长）
                $usedT = if ([int]$t.remain -ge 0) { 100 - [int]$t.remain } else { -1 }
                $c2 = Get-LevelHex (Get-TierLevel $t)
                Draw-Text -G $G -Text $t.name -Font $fontTiny -Color $Theme.Tx3 -X (S 30) -Y $by -W (S 36) -H (S 14)
                $barW = $W - (S 68) - (S 34) - (S 58) - (S 12)
                if ($usedT -ge 0) {
                    Draw-Bar -G $G -X (S 68) -Y ($by + (S 4)) -W $barW -H (S 6) -Pct $usedT -ColorHex $c2
                    Draw-Text -G $G -Text "$usedT%" -Font $fontTiny -Color $Theme.Tx2 -X ($W - (S 34) - (S 58) - (S 10)) -Y $by -W (S 34) -H (S 14) -Align Far
                } else {
                    Draw-Text -G $G -Text $t.display -Font $fontTiny -Color $Theme.Tx2 -X ($W - (S 34) - (S 58) - (S 10)) -Y $by -W (S 34) -H (S 14) -Align Far
                }
                $rst = Format-Reset $t.reset_at
                Draw-Text -G $G -Text $rst -Font $fontTiny -Color $Theme.Tx3 -X ($W - (S 58)) -Y $by -W (S 42) -H (S 14) -Align Far
                $by += (S 22)
            }
        }

        $y = $by + (S 6)
    }

    # 底部状态
    $footY = $H - (S 18)
    $t2 = ''
    if ($script:Data -and $script:Data.fetched_at) {
        try { $t2 = '更新于 ' + ([DateTimeOffset]::Parse($script:Data.fetched_at)).LocalDateTime.ToString('HH:mm') } catch { }
    }
    $okN = @($list | Where-Object { $_.ok }).Count
    Draw-Text -G $G -Text $t2 -Font $fontTiny -Color $Theme.Foot -X (S 16) -Y $footY -W (S 120) -H (S 14)
    Draw-Text -G $G -Text ("$okN/$($list.Count) 正常") -Font $fontTiny -Color $Theme.Foot -X ($W - (S 100)) -Y $footY -W (S 84) -H (S 14) -Align Far

    $fontTitle.Dispose(); $fontName.Dispose(); $fontBig.Dispose(); $fontMoney.Dispose(); $fontTiny.Dispose(); $fontIcon.Dispose()
}

# ============================================================
# 自检 / 截图模式
# ============================================================
if ($SelfTest) {
    Write-Host "=== 数据 ==="
    $script:Data = Get-AllQuota -Cfg $script:Cfg
    foreach ($a in $script:Data.accounts) {
        if ($a.ok) {
            $ts = ($a.tiers | ForEach-Object {
                if ($_.name -and $null -ne $_.money) { $_.name + '=' + $_.display + '(' + $_.money + ')' }
                else { $_.name + '=' + $_.remain + '%' }
            }) -join ', '
            Write-Host ("  ✓ " + $a.short + "  [" + $a.kind + "] " + $ts)
        } else {
            Write-Host ("  ✗ " + $a.short + "  " + $a.error)
        }
    }
    Write-Host "=== 尺寸 ==="
    Write-Host ("  折叠态（当前 " + $script:DockScale + "×，" + $(if ($script:DockOrient -eq 'v') { '纵排' } else { '横排' }) + "）: " + $DOCK_W + " x " + $DOCK_H + " 逻辑/单元")
    Write-Host ("  展开态: " + $PANEL_W + " x " + (Get-PanelHeight -Data $script:Data))
    Write-Host "  悬浮窗三档（单账户，逻辑像素）:"
    foreach ($ds in @(@{ N = '小'; V = 0.75 }, @{ N = '默认'; V = 1.0 }, @{ N = '大'; V = 1.25 })) {
        $u = [int][Math]::Round($DOCK_W * $ds.V)
        Write-Host ("    " + $ds.N.PadRight(4) + " " + $u + " x " + $u + "   (系数 " + $ds.V + ")")
    }
    Write-Host ("  界面缩放 = " + $script:Cfg.uiScale)

    # 折叠态文字是否塞得进圆环（量化，不靠肉眼）
    # 圆环内径 = (R - 笔宽) * 2；文字宽 = 数字宽 + %宽 + 间距
    # 判定用「填充率」：<50% 显得飘，>85% 显得挤，理想区间 60~80%
    Write-Host "=== 折叠态文字填充率（逻辑像素）==="
    Write-Host ("  笔宽 " + $DOCK_PEN + " / 数字 " + $NUM_SIZE + " SemiBold / %比例 " + $PCT_RATIO + " / 间距 " + $PCT_GAP)
    $bmpM = New-Object System.Drawing.Bitmap 1, 1
    $gM = [System.Drawing.Graphics]::FromImage($bmpM)
    $sfM = [System.Drawing.StringFormat]::GenericTypographic
    $innerD = ($RING_R - $DOCK_PEN) * 2
    $pass = 0; $total = 0
    foreach ($ds in @(@{ N = '小'; V = 0.75 }, @{ N = '默认'; V = 1.0 }, @{ N = '大'; V = 1.25 })) {
        $inner = $innerD * $ds.V
        $cases = @(
            @{ T = '58';  F = $NUM_SIZE },
            @{ T = '100'; F = $NUM_SIZE_3 },
            @{ T = '5';   F = $NUM_SIZE }
        )
        foreach ($c in $cases) {
            $fsN = [single]($c.F * $ds.V)
            $fsP = [single]($fsN * $PCT_RATIO)
            $fN = New-Object System.Drawing.Font 'Segoe UI Semibold', $fsN, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
            $fP = New-Object System.Drawing.Font 'Segoe UI Semibold', $fsP, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
            $wN = $gM.MeasureString($c.T, $fN, 1000, $sfM).Width
            $wP = $gM.MeasureString('%', $fP, 1000, $sfM).Width
            $tot = $wN + $wP + ($PCT_GAP * $ds.V)
            $fill = $tot / $inner * 100
            $ok = ($fill -le 85)
            $total++; if ($ok) { $pass++ }
            Write-Host ("  [" + $(if ($ok) { 'OK  ' } else { 'FAIL' }) + "] " + $ds.N.PadRight(4) +
                " 「" + $c.T + "%」宽 " + [Math]::Round($tot, 1) + " / 内径 " + [Math]::Round($inner, 1) +
                "  填充 " + [Math]::Round($fill, 0) + "%" + $(if ($fill -lt 50 -and $c.T.Length -ge 2) { '  (偏飘)' } else { '' }))
            $fN.Dispose(); $fP.Dispose()
        }
    }
    $gM.Dispose(); $bmpM.Dispose()
    Write-Host ("  通过 " + $pass + "/" + $total)

    Write-Host "=== 颜色逻辑边界测试 ==="
    Write-Host "  (0=青 1=黄 2=红；按使用量判断)"
    $cases = @(
        @{ N = '5h 使用 70%'; R5 = 30; RW = 50; E = 0 },
        @{ N = '5h 使用 79%'; R5 = 21; RW = 50; E = 0 },
        @{ N = '5h 使用 80%'; R5 = 20; RW = 50; E = 1 },
        @{ N = '5h 使用 89%'; R5 = 11; RW = 50; E = 1 },
        @{ N = '5h 使用 90%'; R5 = 10; RW = 50; E = 2 },
        @{ N = '周 使用 89%'; R5 = 80; RW = 11; E = 0 },
        @{ N = '周 使用 90%'; R5 = 80; RW = 10; E = 0 },   # 90–94% 回到青
        @{ N = '周 使用 94%'; R5 = 80; RW = 6;  E = 0 },   # 95% 以下仍是青
        @{ N = '周 使用 95%'; R5 = 80; RW = 5;  E = 1 },   # 95% 起黄（周红线已上调到 100）
        @{ N = '周 使用 97%'; R5 = 80; RW = 3;  E = 1 },   # 核心：周 97% → 黄，就算 5h 很宽裕
        @{ N = '周 使用 100%'; R5 = 80; RW = 0; E = 2 },    # 满了才红
        @{ N = '周告警 5h 很低'; R5 = 90; RW = 3; E = 1 },   # 5h 只用了 10%，仍按周 97% 报黄
        @{ N = '5h 红压过周黄'; R5 = 95; RW = 3; E = 2 }     # 5h 95% 红，取更严重的一级
    )
    $pass = 0
    foreach ($c in $cases) {
        $tiers = @(
            [pscustomobject]@{ name = '5小时';   remain = $c.R5; reset_at = $null; display = '' },
            [pscustomobject]@{ name = '7天'; remain = $c.RW; reset_at = $null; display = '' }
        )
        $acc = [pscustomobject]@{ ok = $true; tiers = $tiers; primary = $c.R5 }
        $lv = Get-AccountLevel $acc
        $mark = if ($lv -eq $c.E) { 'OK  '; $pass++ } else { 'FAIL' }
        Write-Host ("  [" + $mark + "] " + $c.N.PadRight(16) + " 期望 " + $c.E + "  实际 " + $lv)
    }
    Write-Host ("  通过 " + $pass + "/" + $cases.Count)

    exit 0
}

# ============================================================
# 单实例保护
# ============================================================
# 双击两次不该出现两个悬浮窗（那也会让启动时的黑窗闪两轮）。
# 所有 -Xxx 验证开关都跳过此检查，否则测试会被正在运行的实例挡住。
$script:IsTestMode = [bool]($SelfTest -or $Shot -or $Demo -or $DumpMenu -or $ConfigShot -or
    $LayoutCheck -or $TestAutostart -or $TestUI -or $GeomTest -or
    $TestScale -or $TestRescaleLive -or $Anim -or $ForceOrient -or $ForceTheme)

if (-not $script:IsTestMode) {
    try {
        $createdNew = $false
        $script:InstanceMutex = [System.Threading.Mutex]::new($true, 'TokenPanel_SingleInstance', [ref]$createdNew)
        if (-not $createdNew) {
            Write-CoreLog '已有实例在运行，本次启动直接退出（单实例保护）'
            exit 0
        }
        Write-CoreLog '单实例锁已获取'
    } catch {
        # 拿不到锁不阻塞启动，只是可能多开
        Write-CoreLog ('单实例检测失败（不阻塞启动）: ' + $_.Exception.Message)
    }
}

# ============================================================
# 窗口
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None   # 关键：禁掉 WinForms 自动缩放，尺寸自己算
$form.StartPosition = 'Manual'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.BackColor = C $Theme.Bg
$form.Text = $script:AppName
# PowerShell 是动态作用域：函数里写裸 $form 会解析到「调用方」的同名局部变量。
# 配置窗口内部也叫 $form，从那里调 Apply-Mode 就会去改设置窗口本身（已踩过：设置页被缩成 89×89）。
# 所以凡是被跨窗口调用的函数，一律用 $script:MainForm 显式指名。
$script:MainForm = $form

# 应用图标：窗口 / 任务栏 / Alt-Tab 统一用 TokenPanel.ico（内含 16~256 七档，
# 小尺寸是单独绘制的加粗版，不是从大图缩下来的）。文件缺失时退回系统默认图标。
$script:AppIconPath = Join-Path $script:Root 'TokenPanel.ico'
if (Test-Path $script:AppIconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($script:AppIconPath) } catch { }
}


# 悬浮窗透明度：四档 100 / 70 / 50 / 30（用户指定）。
# 用 Form.Opacity（分层窗口）实现 —— Region 圆角与鼠标命中都不受影响，
# 只作用于主悬浮窗，设置窗口始终不透明（否则调 30% 时自己都看不清）。
function Preview-Opacity {
    param([double]$V)
    if ($V -lt 0.3) { $V = 0.3 }
    if ($V -gt 1.0) { $V = 1.0 }
    $script:Opacity = $V
    if ($script:Layered) {
        # 分层模式：不透明度直接乘进 alpha，圆角依旧锐利，不会像 Form.Opacity 那样整块发灰
        Refresh-UI
    } else {
        try { $script:MainForm.Opacity = $V } catch { }
    }
    # 改不透明度/重画都可能顺手清掉置顶位，重新断言一次
    Assert-TopMost
}

# 强制把主窗钉在最上层。
# 为什么不能只靠 $form.TopMost = $true：实测该属性最终没落到 WS_EX_TOPMOST
# （EXSTYLE=0x00090000，只有 LAYERED|CONTROLPARENT），点别的窗口就被覆盖。
# 这里做两件事：
#   1) 读-改-写 GWL_EXSTYLE，确保 WS_EX_TOPMOST(0x8) 位被置上（保留其他位）
#   2) SetWindowPos(HWND_TOPMOST) 真正抬进 topmost 带 —— 只设样式位不会立刻重排 z 序
function Assert-TopMost {
    try {
        if (-not $script:MainForm) { return }
        if (-not $script:MainForm.IsHandleCreated) { return }
        $h = $script:MainForm.Handle
        $GWL_EXSTYLE = -20
        $WS_EX_TOPMOST = 0x8
        $ex = [NativeWin]::GetWindowLong($h, $GWL_EXSTYLE)
        if (($ex -band $WS_EX_TOPMOST) -eq 0) {
            [void][NativeWin]::SetWindowLong($h, $GWL_EXSTYLE, ($ex -bor $WS_EX_TOPMOST))
        }
        # HWND_TOPMOST = -1；SWP_NOSIZE(1)|SWP_NOMOVE(2)|SWP_NOACTIVATE(0x10)
        [void][NativeWin]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x13)
    } catch { }
}

# 启动时按配置恢复透明度
$op0 = 1.0
if ($script:Cfg.opacity) { [void][double]::TryParse([string]$script:Cfg.opacity, [ref]$op0) }
Preview-Opacity -V $op0
Write-CoreLog ('启动透明度 = ' + $script:MainForm.Opacity)

# 取窗口实际 DPI（强制创建句柄），据此确定缩放因子
try {
    $null = $form.Handle
    $dpiVal = [NativeWin]::GetDpiForWindow($form.Handle)
    if ($dpiVal -gt 0) { $script:Scale = $dpiVal / 96.0 }
} catch { }
Write-CoreLog ('DPI scale = ' + $script:Scale)

$canvas = New-Object System.Windows.Forms.Panel
$canvas.Dock = 'Fill'
$canvas.BackColor = C $Theme.Bg
# 双缓冲，避免闪烁
try {
    $pi = $canvas.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $pi.SetValue($canvas, $true, $null)
} catch { }
$form.Controls.Add($canvas)

# ---------- 开启分层合成（失败自动降级到 DWM / Region） ----------
if ($env:TOKENPANEL_NO_LAYERED -ne '1') {
    try {
        # 顺序很关键：先让 WinForms 把 Opacity 归 1，
        # 否则后面再设 Opacity=1.0 会走 Form.Opacity 的清理逻辑，把 WS_EX_LAYERED 位一起抹掉
        $script:MainForm.Opacity = 1.0
        [NativeWin]::EnableLayered($script:MainForm.Handle)
        $script:Layered = $true
        Write-CoreLog '合成方式 = 分层窗口（UpdateLayeredWindow，圆角抗锯齿）'
    } catch {
        $script:Layered = $false
        Write-CoreLog ('分层窗口不可用: ' + $_.Exception.Message)
    }
}
if (-not $script:Layered) {
    try {
        if ([NativeWin]::OsBuild() -ge 22000) {
            $script:DwmRound = [NativeWin]::EnableDwmRound($script:MainForm.Handle)
        }
    } catch { $script:DwmRound = $false }
    if ($script:DwmRound) { Write-CoreLog '合成方式 = Win11 DWM 圆角（半径由系统决定）' }
    else { Write-CoreLog '合成方式 = Region 硬裁剪（圆角会有台阶）' }
} else {
    # 句柄被重建（改 DPI / 主题 / ShowInTaskbar 等）会丢掉 WS_EX_LAYERED，重建后补回来
    $form.add_HandleCreated({
        try {
            if ($script:Layered) {
                [NativeWin]::EnableLayered($script:MainForm.Handle)
                Refresh-UI
            }
        } catch { }
    })
}

# ---------- 取窗口当前所在屏的可用区域 ----------
function Get-WorkArea {
    $r = New-Object NativeWin+RECT
    [void][NativeWin]::GetWindowRect($script:MainForm.Handle, [ref]$r)
    $rect = New-Object System.Drawing.Rectangle $r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top)
    $scr = $null
    try { $scr = [System.Windows.Forms.Screen]::FromRectangle($rect) } catch { }
    # 窗口跨屏时 FromRectangle 取交集最大的那块；退化时用主屏
    if (-not $scr) { $scr = [System.Windows.Forms.Screen]::PrimaryScreen }
    return $scr.WorkingArea
}

# ============================================================
# 圆角与画面合成（三级降级）
#   1) 分层窗口 UpdateLayeredWindow —— 任意半径、真抗锯齿（首选）
#   2) Win11 DWM 系统圆角        —— 分层不可用时兜底，半径由系统定（约 8px）
#   3) SetWindowRgn 硬裁剪       —— 最后兜底，会有台阶（老行为）
# 用环境变量 TOKENPANEL_NO_LAYERED=1 可强制走 2/3，便于对比排查。
# ============================================================
$script:Opacity  = if ($null -eq $script:Opacity) { 1.0 } else { $script:Opacity }
# 注意：这里不能再把 $script:Layered 置回 $false —— 初始化在画布创建之后（见「开启分层合成」），
# 本段代码在其后执行，重置会把刚打开的开关又关掉，窗口就变成一块全透明的空窗。
if ($null -eq $script:Layered)  { $script:Layered  = $false }
if ($null -eq $script:DwmRound) { $script:DwmRound = $false }
$script:Surface  = $null
$script:SurfaceG = $null

function Get-CornerRadius {
    if ($script:Mode -eq 'dock') { return [single](DS 18) }
    return [single](S 18)
}

function Update-WindowRegion {
    param([int]$W, [int]$H)
    # 分层模式下形状由 alpha 决定，不能再设 Region（Region 会盖掉抗锯齿）
    if ($script:Layered) {
        if ($script:MainForm.Region) { $script:MainForm.Region = $null }
        return
    }
    # Win11 走 DWM 圆角：必须不设 Region，否则系统圆角不生效
    if ($script:DwmRound) {
        if ($script:MainForm.Region) { $script:MainForm.Region = $null }
        return
    }
    $base = Get-CornerRadius
    # 贴边时也保持四角圆角（用户明确要求）。
    # 之前这里会把贴边那侧的圆角置 0 做成「直角贴齐」，但视觉上反而像被切掉一块；
    # 圆角贴边只会露出 1~2px 桌面，比直角更自然。
    $path = New-RoundedPathEx -X 0 -Y 0 -W $W -H $H -RTL $base -RTR $base -RBR $base -RBL $base
    $script:MainForm.Region = New-Object System.Drawing.Region $path
    $path.Dispose()
}

# 画一帧。AlphaEdge=$true 时整张画布从全透明开始，用抗锯齿路径填底色，
# 圆角外的像素 alpha=0（平滑 + 鼠标穿透）；=$false 时按老方式整块填底色。
function Draw-Scene {
    param($G, [single]$W, [single]$H, [bool]$AlphaEdge)
    $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $G.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $G.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

    if ($AlphaEdge) {
        $G.Clear([System.Drawing.Color]::Transparent)
        $rad = Get-CornerRadius
        $bgPath = New-RoundedPathEx -X 0 -Y 0 -W $W -H $H -RTL $rad -RTR $rad -RBR $rad -RBL $rad
        $bgBrush = New-Object System.Drawing.SolidBrush (C $Theme.Bg)
        $G.FillPath($bgBrush, $bgPath)
        $bgBrush.Dispose(); $bgPath.Dispose()
    } else {
        $G.Clear((C $Theme.Bg))
    }

    # 深色下方块与背景的色差已经足够，不画描边（曾经 1px #2E333F 会显成白边）；
    # 浅色下白窗贴白墙看不见，必须补一条极淡的描边
    if ($script:Mode -eq 'dock') {
        Draw-Dock -G $G -W $W -H $H
    } else {
        Draw-Panel -G $G -W $W -H $H
    }

    if ($Theme.Border) {
        $rad = Get-CornerRadius
        $bp = New-RoundedPathEx -X 0.5 -Y 0.5 -W ($W - 1) -H ($H - 1) -RTL $rad -RTR $rad -RBR $rad -RBL $rad
        $bpen = New-Object System.Drawing.Pen (C $Theme.Border), ([single]1)
        $G.DrawPath($bpen, $bp)
        $bpen.Dispose(); $bp.Dispose()
    }
}

function Ensure-Surface {
    param([int]$W, [int]$H)
    if ($script:Surface -and $script:Surface.Width -eq $W -and $script:Surface.Height -eq $H) { return }
    if ($script:SurfaceG) { $script:SurfaceG.Dispose(); $script:SurfaceG = $null }
    if ($script:Surface)  { $script:Surface.Dispose();  $script:Surface  = $null }
    $script:Surface  = New-Object System.Drawing.Bitmap $W, $H, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $script:SurfaceG = [System.Drawing.Graphics]::FromImage($script:Surface)
}

# 统一的重绘入口：分层模式下重画整帧再推给 DWM；否则退回 Invalidate 走 WM_PAINT
function Refresh-UI {
    if (-not $script:Layered) { $canvas.Invalidate(); return }
    try {
        $w = $script:MainForm.Width; $h = $script:MainForm.Height
        if ($w -le 0 -or $h -le 0) { return }
        Ensure-Surface -W $w -H $h
        Draw-Scene -G $script:SurfaceG -W $w -H $h -AlphaEdge $true
        $a = [byte][Math]::Round([Math]::Min(1.0, [Math]::Max(0.0, $script:Opacity)) * 255)
        if (-not [NativeWin]::PushLayered($script:MainForm.Handle, $script:Surface, $a)) {
            throw 'UpdateLayeredWindow 返回 false'
        }
    } catch {
        Write-CoreLog ('分层绘制失败，退回 Region 硬裁剪: ' + $_.Exception.Message)
        $script:Layered = $false
        $script:MainForm.Opacity = $script:Opacity
        Update-WindowRegion -W $script:MainForm.Width -H $script:MainForm.Height
        $canvas.Invalidate()
    }
}

function Apply-Mode {
    param([string]$M)
    $script:Mode = $M
    if ($M -eq 'dock') {
        $w = Get-DockWidth
        $h = Get-DockHeight
    } else {
        $w = S $PANEL_W
        $h = Get-PanelHeight -Data $script:Data
    }
    # 锚点跟着吸附的边走：贴左边就固定左边缘并**贴齐**，贴右边就贴齐右边缘；
    # 否则维持原来的右下角锚点（尺寸变化时向左上扩展，不跳动）。
    # 用 GetWindowRect/SetWindowPos 直接操作物理像素，绕开 WinForms 的 DPI 二次换算
    $r = New-Object NativeWin+RECT
    [void][NativeWin]::GetWindowRect($script:MainForm.Handle, [ref]$r)
    $wa = Get-WorkArea

    switch ($script:SnapEdgeH) {
        'left'  { $x = $wa.Left }
        'right' { $x = $wa.Right - $w }
        default { $x = $r.Right - $w }
    }
    switch ($script:SnapEdgeV) {
        'top'    { $y = $wa.Top }
        'bottom' { $y = $wa.Bottom - $h }
        default  { $y = $r.Bottom - $h }
    }

    # 尺寸变化后必须留在工作区内，否则换屏/换缩放会跑出可视区域
    if ($x + $w -gt $wa.Right) { $x = $wa.Right - $w }
    if ($y + $h -gt $wa.Bottom) { $y = $wa.Bottom - $h }
    if ($x -lt $wa.Left) { $x = $wa.Left }
    if ($y -lt $wa.Top) { $y = $wa.Top }

    [void][NativeWin]::SetWindowPos($script:MainForm.Handle, [IntPtr]::Zero, $x, $y, $w, $h, 0x14)
    Update-WindowRegion -W $w -H $h
    Refresh-UI
}

$canvas.add_Paint({
    param($s, $e)
    # 分层模式下画面由 UpdateLayeredWindow 直接提供，WM_PAINT 不参与
    if ($script:Layered) { return }
    try {
        Draw-Scene -G $e.Graphics -W $s.Width -H $s.Height -AlphaEdge $false
    } catch {
        Write-CoreLog ('绘制失败: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber)
    }
})

# ---------- 拖动 / 点击 ----------
$script:downPt = $null
$script:downScreen = $null

# ============================================================
# 双击 = 播放刷新动效 + 拉最新数据
#   单击是「展开/收起」，双击要区分开，所以单击动作挂 240ms 防抖
# ============================================================
$script:clickTimer = New-Object System.Windows.Forms.Timer
$script:clickTimer.Interval = 240
$script:clickTimer.add_Tick({
    $script:clickTimer.Stop()
    if ($script:Mode -eq 'dock') { Apply-Mode 'panel' } else { Apply-Mode 'dock' }
})

$script:animTimer = New-Object System.Windows.Forms.Timer
$script:animTimer.Interval = 33
$script:animTimer.add_Tick({
    $script:AnimFrame++
    $script:AnimAngle = ($script:AnimAngle + 24) % 360
    if ($script:AnimFrame -ge 30) {
        # 1 秒到：停动效，先画一帧静止，然后同步拉最新数据
        $script:animTimer.Stop()
        $script:AnimActive = $false
        try { Refresh-UI } catch { }
        Refresh-Data
        return
    }
    try { Refresh-UI } catch { }
})

function Start-DockAnim {
    # 展开态没有圆环，双击直接刷新即可
    if ($script:Mode -ne 'dock') { Refresh-Data; return }
    if ($script:AnimActive) { return }
    $script:AnimActive = $true
    $script:AnimFrame = 0
    $script:AnimAngle = 0
    $script:AnimSeed = Get-Random -Minimum 1 -Maximum 999999
    $script:animTimer.Start()
}

$canvas.add_MouseDown({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    # 展开态点右上角关闭（热区与绘制出的 ✕ 对齐）
    if ($script:Mode -eq 'panel' -and $e.X -ge ($s.Width - (S 40)) -and $e.Y -le (S 44)) {
        $script:MainForm.Hide()
        return
    }
    $script:downPt = $e.Location
    $script:downScreen = [System.Windows.Forms.Cursor]::Position
})

$canvas.add_MouseMove({
    param($s, $e)
    if (-not $script:downScreen) { return }
    $cur = [System.Windows.Forms.Cursor]::Position
    $dx = [Math]::Abs($cur.X - $script:downScreen.X)
    $dy = [Math]::Abs($cur.Y - $script:downScreen.Y)
    if ($dx -gt 4 -or $dy -gt 4) {
        $script:Dragging = $true
        $script:UserMoving = $true
        $script:downScreen = $null
        try {
            [void][NativeWin]::ReleaseCapture()
            [void][NativeWin]::SendMessage($form.Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero)
        } catch { }
    }
})

$canvas.add_MouseUp({
    param($s, $e)
    # 右键：弹出菜单（与托盘菜单同一套内容）
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        if ($script:formMenu) { $script:formMenu.Show($form, $e.Location) }
        return
    }
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($script:downScreen -ne $null -and -not $script:Dragging) {
        # 单击 / 双击用 240ms 防抖区分：
        #   定时器还在跑又来一次 → 双击，播放刷新动效
        #   240ms 内没有第二下 → 单击，展开 / 收起
        if ($script:clickTimer.Enabled) {
            $script:clickTimer.Stop()
            Start-DockAnim
        } else {
            $script:clickTimer.Start()
        }
    }
    $script:Dragging = $false
    $script:downScreen = $null
    $script:downPt = $null
})

# ---------- 几何更新：DPI 变化 / 贴边吸附 / 横纵排 ----------
# 返回 { Resize; Moved; X; Y; W; H }
#   Resize = 尺寸变了（DPI 或方向变化），必须走 Apply-Mode 重建
#   Moved  = 只是位置要贴到边上
function Update-DockGeometry {
    param([switch]$Commit)

    $resize = $false

    # 1) 跨不同缩放的显示器时重读 DPI。
    #    之前只在启动时取一次，从 150% 屏拖到 100% 屏仍按 1.5 倍绘制 → 内容溢出被裁掉。
    try {
        $dv = [NativeWin]::GetDpiForWindow($script:MainForm.Handle)
        if ($dv -gt 0) {
            $ns = $dv / 96.0
            if ([Math]::Abs($ns - $script:Scale) -gt 0.01) {
                $script:Scale = $ns
                $resize = $true
                Write-CoreLog ('DPI 变化 → ' + $script:Scale)
            }
        }
    } catch { }

    $wa = Get-WorkArea
    $r = New-Object NativeWin+RECT
    [void][NativeWin]::GetWindowRect($script:MainForm.Handle, [ref]$r)
    $cw = $r.Right - $r.Left
    $ch = $r.Bottom - $r.Top

    $snap = S 24
    $dL = [Math]::Abs($r.Left - $wa.Left)
    $dR = [Math]::Abs($r.Right - $wa.Right)
    $dT = [Math]::Abs($r.Top - $wa.Top)
    $dB = [Math]::Abs($r.Bottom - $wa.Bottom)

    $eH = 'none'; $eV = 'none'
    $nx = $r.Left; $ny = $r.Top
    if ($dL -lt $snap)      { $eH = 'left';  $nx = $wa.Left }
    elseif ($dR -lt $snap)  { $eH = 'right'; $nx = $wa.Right - $cw }
    if ($dT -lt $snap)      { $eV = 'top';   $ny = $wa.Top }
    elseif ($dB -lt $snap)  { $eV = 'bottom'; $ny = $wa.Bottom - $ch }

    $script:SnapEdgeH = $eH
    $script:SnapEdgeV = $eV

    # 2) 方向：贴左右边 **且** 窗口底边距工作区底部 ≥150 物理像素 → 纵排；否则横排。
    #    150 是物理像素（用户明确指定），不做 S() 换算 —— 150% 屏上视觉约 100 逻辑像素。
    #    贴住底部时距离为 0，自然横排：右下角是最常见的位置，不该被竖起来挡视线。
    $distToBottom = $wa.Bottom - ($ny + $ch)
    $orient = 'h'
    if ($eH -ne 'none' -and $distToBottom -ge 150) { $orient = 'v' }
    if ($orient -ne $script:DockOrient) {
        $script:DockOrient = $orient
        if ($script:Mode -eq 'dock') { $resize = $true }
    }

    if ($Commit) {
        # 存「相对屏幕右下角的偏移」，除以 scale 换回逻辑值，换分辨率不会跑出屏幕
        $script:Cfg.dockRight = [int][Math]::Round(($wa.Right - ($nx + $cw)) / $script:Scale)
        $script:Cfg.dockBottom = [int][Math]::Round(($wa.Bottom - ($ny + $ch)) / $script:Scale)
    }

    return [pscustomobject]@{
        Resize = $resize
        Moved  = ($nx -ne $r.Left -or $ny -ne $r.Top)
        X      = $nx
        Y      = $ny
        W      = $cw
        H      = $ch
    }
}

# ---------- 拖动结束后吸附 + 保存位置 ----------
$script:moveTimer = New-Object System.Windows.Forms.Timer
$script:moveTimer.Interval = 500
$script:moveTimer.add_Tick({
    $script:moveTimer.Stop()
    try {
        $g = Update-DockGeometry -Commit
        if ($g.Resize) {
            Apply-Mode $script:Mode
        } elseif ($g.Moved) {
            # 只挪位置：SWP_NOSIZE(1) | SWP_NOZORDER(4) | SWP_NOACTIVATE(16)
            [void][NativeWin]::SetWindowPos($form.Handle, [IntPtr]::Zero, $g.X, $g.Y, 0, 0, 0x15)
            Update-WindowRegion -W $g.W -H $g.H
        }
        Save-Config -Cfg $script:Cfg
    } catch {
        Write-CoreLog ('吸附失败: ' + $_.Exception.Message)
    }
    $script:UserMoving = $false
})

$form.add_LocationChanged({
    # 不是用户拖出来的位移（程序自己展开/收起/换屏）不触发吸附，也不落盘
    if (-not $script:UserMoving) { return }
    $script:moveTimer.Stop()
    $script:moveTimer.Start()
})

# ============================================================
# 菜单动作
# ============================================================
function Show-Panel {
    $script:MainForm.Show()
    # Hide/Show 之后置顶位会丢，重新断言（关闭按钮走的是 Hide）
    Assert-TopMost
    $script:MainForm.Activate()
    if ($script:Mode -ne 'panel') { Apply-Mode 'panel' }
}

function Refresh-Data {
    try {
        $script:Data = Get-AllQuota -Cfg $script:Cfg
        if ($script:Mode -eq 'panel') { Apply-Mode 'panel' } else { Refresh-UI }
    } catch {
        Write-CoreLog ('手动刷新失败: ' + $_.Exception.Message)
    }
}

# 配置页点「悬浮窗大小」时实时预览：改完立刻作用到主悬浮窗，
# 用户能直接看到大小变化，不用先保存再关窗口（这是原来「点了没反应」的根因）
# 配置页点「深色/浅色」时实时换色：主悬浮窗立刻重画，右键菜单也按新配色重建
function Preview-Theme {
    param([string]$Name)
    if ($Name -notin @('dark', 'light')) { return }
    $script:ThemeName = $Name
    $script:Theme = Get-MainTheme $Name
    try {
        $script:MainForm.BackColor = (C $Theme.Bg)
        $canvas.BackColor = (C $Theme.Bg)
    } catch { }
    try {
        $tray.ContextMenuStrip = New-PanelMenu
        $script:formMenu = New-PanelMenu
    } catch { }
    # 配置页是模态的，主窗被禁用，单纯 Invalidate 可能迟迟不重绘（看起来像没换肤）。
    # 用 Refresh 强制同步重绘，用户在设置页里点一下就能立刻看到新配色。
    try {
        Refresh-UI
        $script:MainForm.Refresh()
    } catch {
        try { $canvas.Invalidate() } catch { }
    }
}

function Preview-DockScale {
    param([double]$V)
    if ($V -le 0) { return }
    $script:DockScale = $V
    if ($script:Mode -eq 'dock') { Apply-Mode 'dock' }
}

function Open-ConfigFile {
    try {
        if (Show-ConfigWindow -Cfg $script:Cfg) {
            $script:Cfg = Load-Config
            if ($script:Cfg.timeout) { $script:HttpTimeout = [int]$script:Cfg.timeout }
            # 配色可能变了：重读调色板（同时会重建右键菜单）
            Preview-Theme -Name ([string]$script:Cfg.theme)
            # 悬浮大小可能变了，重新读系数再重算尺寸
            $dv = 0.0
            if ($script:Cfg.dockScale -and [double]::TryParse([string]$script:Cfg.dockScale, [ref]$dv) -and $dv -gt 0) {
                $script:DockScale = $dv
            }
            # 刷新间隔可能变了，重启定时器
            $timer.Interval = [Math]::Max(1, [int]$script:Cfg.refreshMinutes) * 60 * 1000
            $timer.Stop(); $timer.Start()
            # 透明度
            $opv = 1.0
            if ($script:Cfg.opacity) { [void][double]::TryParse([string]$script:Cfg.opacity, [ref]$opv) }
            Preview-Opacity -V $opv
            Apply-Mode $script:Mode
            Refresh-Data
            Write-CoreLog ('配置已保存并生效（浮窗 ' + $script:DockScale + '×，透明度 ' + $opv + '）')
        }
    } catch {
        Write-CoreLog ('打开配置页失败: ' + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show("打开配置页失败：`n" + $_.Exception.Message, $script:AppName)
    }
}

# ============================================================
# 开机自启（HKCU\...\Run，不需要管理员权限）
# 读写都做回验，确保真的落盘 —— 之前踩过「界面勾了但注册表没写」的坑
# ============================================================
$script:RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Get-AutostartCommand {
    # 用 VBS 启动器，而不是直接调 powershell：
    # 直接调 powershell 即使带 -WindowStyle Hidden，开机时仍会闪一下控制台
    # （窗口先创建、再隐藏）。VBS 的窗口模式 0 是从创建起就隐藏，全程无窗。
    $vbsPath = Join-Path $script:Root 'TokenPanel.vbs'
    return 'wscript.exe //nologo "' + $vbsPath + '"'
}

function Get-AutostartEnabled {
    try {
        $v = (Get-ItemProperty -Path $script:RunKey -Name $script:AppId -ErrorAction SilentlyContinue).$($script:AppId)
        return [bool]$v
    } catch { return $false }
}

function Set-AutostartEnabled {
    param([bool]$Enable)
    $ok = $false
    # 清掉改名前的旧键，避免开机启动两次。
    # 注意 AppId 现在就叫 TokenPanel，必须排除自身，否则会把刚写的值删掉。
    $legacyNames = @('TokenPocket', 'TokenPano', 'TokenPanel') | Where-Object { $_ -ne $script:AppId }
    try {
        if ($Enable) {
            Set-ItemProperty -Path $script:RunKey -Name $script:AppId -Value (Get-AutostartCommand) -Force
            foreach ($ln in $legacyNames) { Remove-ItemProperty -Path $script:RunKey -Name $ln -ErrorAction SilentlyContinue }
        } else {
            Remove-ItemProperty -Path $script:RunKey -Name $script:AppId -ErrorAction SilentlyContinue
            foreach ($ln in $legacyNames) { Remove-ItemProperty -Path $script:RunKey -Name $ln -ErrorAction SilentlyContinue }
        }
        $ok = ((Get-AutostartEnabled) -eq $Enable)
        Write-CoreLog ('开机自启 = ' + $Enable + '（回验 ' + $(if ($ok) { '成功' } else { '失败' }) + '）')
    } catch {
        Write-CoreLog ('设置开机自启失败: ' + $_.Exception.Message)
    }
    return $ok
}

# 配置里的 startWithBoot 与注册表保持一致：以注册表为准回写配置
function Sync-AutostartFromRegistry {
    $real = Get-AutostartEnabled
    if ($real) {
        # 已开启：顺手把命令刷新成当前路径（换目录后不会失效）
        try { Set-ItemProperty -Path $script:RunKey -Name $script:AppId -Value (Get-AutostartCommand) -Force } catch { }
    }
    if ([bool]$script:Cfg.startWithBoot -ne $real) {
        $script:Cfg.startWithBoot = $real
        Save-Config -Cfg $script:Cfg
    }
    return $real
}

# ============================================================
# 开机自启验证模式（-TestAutostart）
# ============================================================
if ($TestAutostart) {
    Write-Host '=== 开机自启测试 ==='
    $before = Get-AutostartEnabled
    Write-Host ('  初始状态: ' + $before)
    Write-Host ('  注册表键: ' + $script:RunKey + ' \ ' + $script:AppId)

    $ok1 = Set-AutostartEnabled -Enable $true
    $v1 = (Get-ItemProperty -Path $script:RunKey -Name $script:AppId -ErrorAction SilentlyContinue).$($script:AppId)
    Write-Host ('  [开启] 返回=' + $ok1 + '  回读=' + (Get-AutostartEnabled))
    Write-Host ('         注册表值: ' + $(if ($v1) { $v1 } else { '(空)' }))

    $ok2 = Set-AutostartEnabled -Enable $false
    $v2 = (Get-ItemProperty -Path $script:RunKey -Name $script:AppId -ErrorAction SilentlyContinue).$($script:AppId)
    Write-Host ('  [关闭] 返回=' + $ok2 + '  回读=' + (Get-AutostartEnabled))
    Write-Host ('         注册表值: ' + $(if ($null -eq $v2) { '(已删除)' } else { $v2 }))

    Set-AutostartEnabled -Enable $before | Out-Null
    Write-Host ('  已恢复初始状态: ' + (Get-AutostartEnabled))
    Write-Host ('  结论: ' + $(if ($ok1 -and $ok2) { '通过（读写双向一致）' } else { '失败' }))
    exit 0
}

function Show-About {
    $n = @($script:Data.accounts).Count
    $okN = @($script:Data.accounts | Where-Object { $_.ok }).Count
    $msg = "$($script:AppName)  v$($script:AppVersion)  $($script:AppChannel)`n`n账户：$okN/$n 正常`n刷新间隔：$($script:Cfg.refreshMinutes) 分钟`n配置文件：`n$($script:ConfigPath)"
    [System.Windows.Forms.MessageBox]::Show($msg, '关于', 'OK', 'Information') | Out-Null
}

function Quit-App {
    $tray.Visible = $false
    $tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
}

# ============================================================
# 右键菜单（悬浮窗与托盘共用同一套构建逻辑，保证一致）
# ============================================================
function New-PanelMenu {
    $m = New-Object System.Windows.Forms.ContextMenuStrip
    $m.BackColor = C $Theme.Bg
    $m.ForeColor = C $Theme.Tx
    $m.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9
    $m.ShowImageMargin = $false
    try {
        $ct = New-Object TokenColorTable
        $ct.Light = ($script:ThemeName -eq 'light')
        $m.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer $ct
    } catch { }

    $i1 = $m.Items.Add('显示面板')
    $i1.add_Click({ Show-Panel })

    $i2 = $m.Items.Add('立即刷新')
    $i2.add_Click({ Refresh-Data })

    $m.Items.Add('-') | Out-Null

    $i3 = $m.Items.Add('设置…')
    $i3.add_Click({ Open-ConfigFile })

    $i4 = $m.Items.Add('开机自启')
    $i4.Checked = Get-AutostartEnabled
    $i4.add_Click({
        param($sender, $e)
        $newVal = -not $sender.Checked
        $ok = Set-AutostartEnabled -Enable $newVal
        # 以真实写入结果回显，写失败就不打勾
        $sender.Checked = (Get-AutostartEnabled)
        $script:Cfg.startWithBoot = [bool]$sender.Checked
        Save-Config -Cfg $script:Cfg
        if (-not $ok) {
            [System.Windows.Forms.MessageBox]::Show(
                "写入开机自启失败，请检查注册表权限：`nHKCU\Software\Microsoft\Windows\CurrentVersion\Run",
                $script:AppName) | Out-Null
        }
    })

    $m.Items.Add('-') | Out-Null

    $i5 = $m.Items.Add('关于')
    $i5.add_Click({ Show-About })

    $i6 = $m.Items.Add('退出')
    $i6.add_Click({ Quit-App })

    return $m
}

# ---------- 托盘 ----------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = $script:AppName
$tray.Visible = $true
try {
    if (Test-Path $script:AppIconPath) {
        # 按系统小图标尺寸取对应的帧（100% DPI = 16×16，150% = 24×24）。
        # 直接给 32×32 会让系统再缩一次，托盘里就糊了。
        $si = [System.Windows.Forms.SystemInformation]::SmallIconSize
        $tray.Icon = New-Object System.Drawing.Icon($script:AppIconPath, $si.Width, $si.Height)
    } else {
        # 兜底：没有 .ico 时现画一个（旧逻辑，保底能用）
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $disk = New-Object System.Drawing.SolidBrush (C $Theme.Cy)
        $g.FillEllipse($disk, 1, 1, 29, 29)
        $disk.Dispose()
        $f2 = New-Object System.Drawing.Font 'Segoe UI', 15, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        $sf2 = New-Object System.Drawing.StringFormat
        $sf2.Alignment = 'Center'; $sf2.LineAlignment = 'Center'
        $w2 = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $g.DrawString('T', $f2, $w2, (New-Object System.Drawing.RectangleF 0, 0, 32, 32), $sf2)
        $g.Dispose()
        $tray.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    }
} catch { }

$tray.ContextMenuStrip = New-PanelMenu
$script:formMenu = New-PanelMenu

$tray.add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Show-Panel
    }
})

# ---------- 定时刷新 ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(1, [int]$script:Cfg.refreshMinutes) * 60 * 1000
$timer.add_Tick({
    try {
        $script:Data = Get-AllQuota -Cfg $script:Cfg
        Refresh-UI
    } catch { Write-CoreLog ('刷新失败: ' + $_.Exception.Message) }
})
$timer.Start()

# ---------- 首次拉数据（先拉数据，才能算出正确的折叠宽度）----------
try {
    $script:Data = Get-AllQuota -Cfg $script:Cfg
    Write-CoreLog ('启动 v' + $script:AppVersion + ' ' + $script:AppChannel + '，账户数 ' + $script:Data.accounts.Count)
} catch {
    Write-CoreLog ('首次拉取失败: ' + $_.Exception.Message)
}

# 演示数据：用于验证多账户布局（不影响真实配置）
if ($Demo) {
    $now = Get-Date
    # 刻意构造三种告警状态：青(正常) / 黄(5h使用82%) / 红(5h使用92%)
    $script:Data = [pscustomobject]@{
        fetched_at = $now.ToString('o')
        accounts = @(
            [pscustomobject]@{ id='minimax'; name='MiniMax Coding Plan'; short='MiniMax'; ok=$true; error=$null; primary=75
                tiers=@(
                    [pscustomobject]@{ name='5小时'; remain=75; reset_at=$now.AddHours(3.2).ToString('o'); display='75%' },
                    [pscustomobject]@{ name='7天'; remain=70; reset_at=$now.AddDays(4).ToString('o'); display='70%' }
                ) },
            [pscustomobject]@{ id='kimi'; name='Kimi For Coding'; short='Kimi'; ok=$true; error=$null; primary=18
                tiers=@(
                    [pscustomobject]@{ name='5小时'; remain=18; reset_at=$now.AddHours(1.8).ToString('o'); display='18%' },
                    [pscustomobject]@{ name='7天'; remain=55; reset_at=$now.AddDays(5).ToString('o'); display='55%' }
                ) },
            [pscustomobject]@{ id='zhipu'; name='智谱 GLM Coding'; short='智谱'; ok=$true; error=$null; primary=8
                tiers=@(
                    [pscustomobject]@{ name='5小时'; remain=8; reset_at=$now.AddMinutes(24).ToString('o'); display='8%' },
                    [pscustomobject]@{ name='7天'; remain=42; reset_at=$now.AddDays(3).ToString('o'); display='42%' }
                ) }
        )
    }
}

# 验证用：强制配色（只影响本次运行，不写配置）
if ($ForceTheme -in @('dark', 'light')) { Preview-Theme -Name $ForceTheme }

# ---------- 初始位置 ----------
$dw = Get-DockWidth
$dh = Get-DockHeight
$wa0 = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$x0 = $wa0.Right - (S $script:Cfg.dockRight) - $dw
$y0 = $wa0.Bottom - (S $script:Cfg.dockBottom) - $dh
if ($x0 -lt $wa0.Left) { $x0 = $wa0.Right - $dw - (S 40) }
if ($y0 -lt $wa0.Top) { $y0 = $wa0.Bottom - $dh - (S 60) }
[void][NativeWin]::SetWindowPos($form.Handle, [IntPtr]::Zero, $x0, $y0, $dw, $dh, 0x14)
# 摆好位置后立刻识别吸附边与横纵排：上次是贴着右边退出的，这次就要竖着起来
$gi = Update-DockGeometry
if ($gi.Resize) {
    Apply-Mode $script:Mode
} else {
    Update-WindowRegion -W $gi.W -H $gi.H
    if ($gi.Moved) { [void][NativeWin]::SetWindowPos($form.Handle, [IntPtr]::Zero, $gi.X, $gi.Y, 0, 0, 0x15) }
    # 尺寸没变时不会走 Apply-Mode，但首帧必须自己推一次：
    # 分层模式下 WM_PAINT 不参与绘制，不推就是一块全透明的空窗口
    Refresh-UI
}
$dw = $gi.W; $dh = $gi.H
Write-CoreLog ("初始窗口 " + $dw + "x" + $dh + " @ " + $gi.X + "," + $gi.Y + " 方向 " + $script:DockOrient + " 吸附 " + $script:SnapEdgeH + "/" + $script:SnapEdgeV)

# 验证用：强制方向后截图（-Shot -ForceOrient v），不影响配置
if ($ForceOrient -in @('h', 'v')) {
    $script:DockOrient = $ForceOrient
    Apply-Mode $script:Mode
}

# 验证用：停在动效的某一帧截图（-Shot -Anim），不启动定时器、不写配置
if ($Anim) {
    $script:AnimActive = $true
    $script:AnimFrame = 9
    $script:AnimAngle = 210
    $script:AnimSeed = 42
}

# ============================================================
# 几何自检（-GeomTest）：贴边吸附、横纵排切换、DPI 重算
# ============================================================
if ($GeomTest) {
    Write-Host '=== 几何自检 ==='
    $script:tp = 0; $script:tf = 0
    function GT([string]$Name, [bool]$Ok, [string]$Detail = '') {
        if ($Ok) { $script:tp++ } else { $script:tf++ }
        Write-Host ('  [' + $(if ($Ok) { 'OK  ' } else { 'FAIL' }) + '] ' + $Name + $(if ($Detail) { '  → ' + $Detail } else { '' }))
    }
    function GT-Place([int]$X, [int]$Y) {
        $r = New-Object NativeWin+RECT
        [void][NativeWin]::GetWindowRect($form.Handle, [ref]$r)
        [void][NativeWin]::SetWindowPos($form.Handle, [IntPtr]::Zero, $X, $Y, ($r.Right - $r.Left), ($r.Bottom - $r.Top), 0x15)
    }
    function GT-Size {
        $r = New-Object NativeWin+RECT
        [void][NativeWin]::GetWindowRect($form.Handle, [ref]$r)
        return @{ X = $r.Left; Y = $r.Top; W = ($r.Right - $r.Left); H = ($r.Bottom - $r.Top); R = $r.Right; B = $r.Bottom }
    }

    # 四个角是否真的被切圆：
    # 圆角时角落像素不在 Region 内（IsVisible=false）；直角时在区域内。
    # 比肉眼看截图可靠 —— 之前贴边被强制直角就是肉眼没发现。
    function GT-Corners([string]$Name) {
        $s = GT-Size
        Update-WindowRegion -W $s.W -H $s.H
        $reg = $script:MainForm.Region
        if (-not $reg) { GT $Name $false 'Region 为空'; return }
        $pts = @(
            (New-Object System.Drawing.Point 2, 2),
            (New-Object System.Drawing.Point ($s.W - 3), 2),
            (New-Object System.Drawing.Point 2, ($s.H - 3)),
            (New-Object System.Drawing.Point ($s.W - 3), ($s.H - 3))
        )
        $cut = 0
        foreach ($p in $pts) { if (-not $reg.IsVisible($p)) { $cut++ } }
        GT $Name ($cut -eq 4) ($cut.ToString() + '/4 角为圆角，吸附 ' + $script:SnapEdgeH + '/' + $script:SnapEdgeV)
    }

    $wa = Get-WorkArea
    $midY = [int][Math]::Floor($wa.Top + ($wa.Bottom - $wa.Top) / 2)
    $midX = [int][Math]::Floor($wa.Left + ($wa.Right - $wa.Left) / 2)
    $gap = 12     # 离边 12px 落手，应当被吸过去

    # 1) 贴近右边（垂直居中）→ 吸附 right + 纵排
    $s0 = GT-Size
    GT-Place ($wa.Right - $s0.W - $gap) $midY
    $g = Update-DockGeometry
    GT '贴右边 → 吸附 right' ($script:SnapEdgeH -eq 'right') $script:SnapEdgeH
    GT '贴右边 → 自动纵排' ($script:DockOrient -eq 'v') $script:DockOrient
    if ($g.Resize) { Apply-Mode 'dock' } elseif ($g.Moved) { [void][NativeWin]::SetWindowPos($form.Handle, [IntPtr]::Zero, $g.X, $g.Y, 0, 0, 0x15) }
    $r1 = GT-Size
    $n = Get-DockCount
    GT ('纵排尺寸 = 1 列 × ' + $n + ' 行') (($r1.W -eq (DS $DOCK_W)) -and ($r1.H -eq (DS ($n * $DOCK_H)))) ($r1.W.ToString() + 'x' + $r1.H)
    GT '纵排贴齐右边缘' ($r1.R -eq $wa.Right) (($r1.R - $wa.Right).ToString() + 'px')
    GT-Corners '贴右边后四角仍是圆角'

    # 1b) 纵排门槛：贴右边但离任务栏不足 150 物理像素 → 必须保持横排（用户第 4 条）
    $script:DockOrient = 'h'
    $sB = GT-Size
    GT-Place ($wa.Right - $sB.W - $gap) ($wa.Bottom - $sB.H - 149)
    [void](Update-DockGeometry)
    GT '贴右边 + 离底 149px → 横排' ($script:DockOrient -eq 'h') ('方向 ' + $script:DockOrient)

    $script:DockOrient = 'h'
    $sB = GT-Size
    GT-Place ($wa.Right - $sB.W - $gap) ($wa.Bottom - $sB.H - 151)
    [void](Update-DockGeometry)
    GT '贴右边 + 离底 151px → 纵排' ($script:DockOrient -eq 'v') ('方向 ' + $script:DockOrient)
    # 换回纵排尺寸，后续用例按纵排尺寸继续
    Apply-Mode 'dock'

    # 2) 贴近底边（水平居中）→ 吸附 bottom + 横排
    $s1 = GT-Size
    GT-Place $midX ($wa.Bottom - $s1.H - $gap)
    $g2 = Update-DockGeometry
    GT '贴底边 → 吸附 bottom' ($script:SnapEdgeV -eq 'bottom') $script:SnapEdgeV
    GT '贴底边 → 自动横排' ($script:DockOrient -eq 'h') $script:DockOrient
    if ($g2.Resize) { Apply-Mode 'dock' } elseif ($g2.Moved) { [void][NativeWin]::SetWindowPos($form.Handle, [IntPtr]::Zero, $g2.X, $g2.Y, 0, 0, 0x15) }
    $r2 = GT-Size
    GT ('横排尺寸 = ' + $n + ' 列 × 1 行') (($r2.W -eq (DS ($n * $DOCK_W))) -and ($r2.H -eq (DS $DOCK_H))) ($r2.W.ToString() + 'x' + $r2.H)
    GT '横排贴齐下边缘' (($r2.B - $wa.Bottom) -eq 0) (($r2.B - $wa.Bottom).ToString() + 'px')
    GT-Corners '贴底边后四角仍是圆角'

    # 3) 屏幕中间 → 不吸附、保持横排
    $s2 = GT-Size
    GT-Place ($midX - [int]($s2.W / 2)) ($midY - [int]($s2.H / 2))
    $g3 = Update-DockGeometry
    GT '中间悬浮 → 不吸附' (($script:SnapEdgeH -eq 'none') -and ($script:SnapEdgeV -eq 'none')) ($script:SnapEdgeH + '/' + $script:SnapEdgeV)
    GT '中间悬浮 → 横排' ($script:DockOrient -eq 'h') $script:DockOrient

    # 4) DPI 重算：把 Scale 故意写错，看下次几何更新能否纠正并重建尺寸
    $real = 1.0
    try { $real = [NativeWin]::GetDpiForWindow($form.Handle) / 96.0 } catch { }
    $script:Scale = 1.0
    $g4 = Update-DockGeometry
    GT 'DPI 变化被识别' ($g4.Resize -and [Math]::Abs($script:Scale - $real) -lt 0.01) ('scale=' + $script:Scale + ' 真实=' + $real)
    if ($g4.Resize) { Apply-Mode 'dock' }
    $r4 = New-Object NativeWin+RECT
    [void][NativeWin]::GetWindowRect($form.Handle, [ref]$r4)
    GT '重建后宽度按真实 DPI' (($r4.Right - $r4.Left) -eq (DS ($n * $DOCK_W))) (($r4.Right - $r4.Left).ToString() + ' vs ' + (DS ($n * $DOCK_W)))

    # 5) 悬浮窗大小实时预览（配置页点「小/默认/大」应当立刻改主悬浮窗尺寸）
    $script:DockScale = 1.0
    Apply-Mode 'dock'
    $b0 = GT-Size
    Preview-DockScale -V 1.25
    $b1 = GT-Size
    GT '点「大」→ 主悬浮窗立刻变大' (($b1.W -gt $b0.W) -and ($b1.H -gt $b0.H)) ($b0.W.ToString() + 'x' + $b0.H + ' → ' + $b1.W.ToString() + 'x' + $b1.H)
    Preview-DockScale -V 1.0
    $b2 = GT-Size
    GT '恢复「默认」→ 尺寸回落' (($b2.W -eq $b0.W) -and ($b2.H -eq $b0.H)) ($b0.W.ToString() + 'x' + $b0.H + ' → ' + $b2.W.ToString() + 'x' + $b2.H)

    # 6) 折叠态显示数量（系统配置项）
    $origMax = $script:Cfg.maxDockItems
    $script:Cfg.maxDockItems = 2
    Apply-Mode 'dock'
    $m2 = GT-Size
    GT '显示数量=2 → 宽度 2 个单元' ($m2.W -eq (DS (2 * $DOCK_W))) ($m2.W.ToString() + ' vs ' + (DS (2 * $DOCK_W)))
    $script:Cfg.maxDockItems = 5
    Apply-Mode 'dock'
    $m5 = GT-Size
    $all = @($script:Data.accounts).Count
    $exp = if ($all -gt 5) { 5 } else { $all }
    GT ('显示数量=5 → 最多到账户数(' + $all + ')') ($m5.W -eq (DS ($exp * $DOCK_W))) ($m5.W.ToString() + ' vs ' + (DS ($exp * $DOCK_W)))
    $script:Cfg.maxDockItems = $origMax
    Apply-Mode 'dock'

    # 7) 配色切换（两套调色板都要完整，缺键会在绘制时静默失败）
    $needKeys = @('Bg', 'BgHover', 'Track', 'Line', 'Tx', 'Tx2', 'Tx3', 'Cy', 'Am', 'Rd', 'RingText', 'TrackRing', 'Foot', 'Border', 'Glow')
    foreach ($tn in @('dark', 'light')) {
        $pal = Get-MainTheme $tn
        $miss = @($needKeys | Where-Object { $null -eq $pal[$_] })
        GT ('主窗配色 ' + $tn + ' 键齐全') ($miss.Count -eq 0) ($miss -join ',')
    }
    Preview-Theme -Name 'light'
    GT '切浅色 → Bg 变白' ($script:Theme.Bg -eq '#F7F7F8') $script:Theme.Bg
    GT '切浅色 → 圆环文字转深色' ($script:Theme.RingText -eq '#1B1B1B') $script:Theme.RingText
    Preview-Theme -Name 'dark'
    GT '切回深色' ($script:Theme.Bg -eq '#1C1F27') $script:Theme.Bg

    # 8) 双击刷新动效：开 → 数字乱跳 → 1 秒自动停 → 数据被刷新
    $t0 = [string]$script:Data.fetched_at
    Start-DockAnim
    GT '双击 → 动效开启' $script:AnimActive
    $script:AnimFrame = 4
    $vals = @()
    for ($k = 0; $k -lt 6; $k++) {
        $script:AnimFrame = $k * 3
        $vals += (Get-FlickerText '34')
    }
    GT '动效文本保持两位' (@($vals | Where-Object { $_.Length -ne 2 }).Count -eq 0) ($vals -join ' ')
    GT '动效文本在跳' ((@($vals | Select-Object -Unique).Count) -ge 3) ($vals -join ' ')
    $script:AnimFrame = 4
    $mv = Get-FlickerText '¥-0.49'
    GT '金额文本保持货币符号与两位小数' ($mv -like '¥*' -and $mv -match '¥-?\d+\.\d\d') $mv
    $script:AnimFrame = 29
    $script:animTimer.Start()
    $deadline = (Get-Date).AddSeconds(4)
    while ((Get-Date) -lt $deadline -and $script:AnimActive) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 20
    }
    GT '1 秒后动效自动停止' (-not $script:AnimActive)
    GT '停止后数据已刷新' (([string]$script:Data.fetched_at) -ne $t0) ($t0 + ' → ' + [string]$script:Data.fetched_at)

    Write-Host ('  通过 ' + $script:tp + ' / ' + ($script:tp + $script:tf))
    $tray.Visible = $false
    $tray.Dispose()
    exit $(if ($script:tf -eq 0) { 0 } else { 1 })
}

# ---------- 菜单导出模式（验证菜单内容）----------
if ($DumpMenu) {
    $m = New-PanelMenu
    Write-Host "=== 悬浮窗 / 托盘 共用菜单 ==="
    foreach ($it in $m.Items) {
        if ($it.GetType().Name -eq 'ToolStripSeparator') {
            Write-Host '  ──────────────'
        } else {
            $chk = if ($it.Checked) { '  [已勾选]' } else { '' }
            Write-Host ("  " + $it.Text + $chk)
        }
    }
    Write-Host ("  开机自启当前状态: " + (Get-AutostartEnabled))
    $m.Dispose()
    $tray.Visible = $false
    $tray.Dispose()
    exit 0
}

# ---------- 配置页截图模式 ----------
if ($ConfigShot) {
    $cp = Join-Path $script:Root 'shot-config.png'
    $shotCfg = $script:Cfg
    if ($ForceTheme -in @('dark', 'light')) {
        $shotCfg = $script:Cfg | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $shotCfg.theme = $ForceTheme
    }
    Show-ConfigWindow -Cfg $shotCfg -CapturePath $cp -OnlyTpl $ConfigTpl -OnlyPage $ConfigPage | Out-Null
    Write-Host ('已保存 ' + $cp)
    $tray.Visible = $false
    $tray.Dispose()
    exit 0
}

# ---------- 配置页布局自检 ----------
if ($LayoutCheck) {
    Show-ConfigWindow -Cfg $script:Cfg -DumpLayout | Out-Null
    $tray.Visible = $false
    $tray.Dispose()
    exit 0
}

# ---------- 界面缩放实测：五档是否真的产生不同尺寸 ----------
if ($TestScale) {
    Write-Host '=== 界面缩放实测（配置页实际宽高）==='
    $script:tsP = 0; $script:tsF = 0
    function TSL([string]$n, [bool]$ok, [string]$d = '') {
        if ($ok) { $script:tsP++ } else { $script:tsF++ }
        Write-Host ('  [' + $(if ($ok) { 'OK  ' } else { 'FAIL' }) + '] ' + $n + $(if ($d) { '  → ' + $d } else { '' }))
    }
    function Parse-W([string]$s) {
        $p = $s -split 'x'
        if ($p.Count -lt 2) { return 0 }
        return [int]$p[0]
    }

    $sizes = @{}
    foreach ($sid in @('50', '75', '100', '150', 'auto')) {
        $c2 = $script:Cfg | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $c2.uiScale = $sid
        $raw = @(Show-ConfigWindow -Cfg $c2 -ProbeSize)
        $sizes[$sid] = [string]$raw[-1]
        Write-Host ('  ' + $sid.PadRight(5) + ' → ' + $sizes[$sid])
    }

    $w100 = Parse-W $sizes['100']
    $w150 = Parse-W $sizes['150']
    $w75 = Parse-W $sizes['75']
    $w50 = Parse-W $sizes['50']
    TSL '150% 宽度 ≈ 100% × 1.5' ([Math]::Abs($w150 - $w100 * 1.5) -le 6) ($w150.ToString() + ' vs ' + [int]($w100 * 1.5))
    TSL '75%  宽度 ≈ 100% × 0.75' ([Math]::Abs($w75 - $w100 * 0.75) -le 6) ($w75.ToString() + ' vs ' + [int]($w100 * 0.75))
    TSL '50%  宽度 ≈ 100% × 0.5' ([Math]::Abs($w50 - $w100 * 0.5) -le 6) ($w50.ToString() + ' vs ' + [int]($w100 * 0.5))
    TSL '四档宽度互不相同' ((@($w50, $w75, $w100, $w150) | Sort-Object -Unique).Count -eq 4) ($w50.ToString() + '/' + $w75.ToString() + '/' + $w100.ToString() + '/' + $w150.ToString())

    Write-Host ('  通过 ' + $script:tsP + ' / ' + ($script:tsP + $script:tsF))
    $tray.Visible = $false
    $tray.Dispose()
    exit $(if ($script:tsF -eq 0) { 0 } else { 1 })
}

# ---------- 缩放实时重建实测：真的点一次 chip ----------
if ($TestRescaleLive) {
    Write-Host '=== 缩放实时重建实测（真点击）==='
    $script:tsP = 0; $script:tsF = 0
    $cases = @(
        @{ Click = '150'; Expect = 1.5 },
        @{ Click = '75';  Expect = 0.75 }
    )
    foreach ($c in $cases) {
        $c2 = $script:Cfg | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $c2.uiScale = '100'
        $script:CWLastF = 0
        $script:CWLastSize = ''
        Show-ConfigWindow -Cfg $c2 -StartPage 'system' -AutoScaleClick $c.Click -AutoClose | Out-Null
        $ok = [Math]::Abs([double]$script:CWLastF - [double]$c.Expect) -lt 0.01
        if ($ok) { $script:tsP++ } else { $script:tsF++ }
        Write-Host ('  [' + $(if ($ok) { 'OK  ' } else { 'FAIL' }) + '] 100% → 点「' + $c.Click +
            '%」→ 重建为 ' + $script:CWLastF + ' 倍，窗口 ' + $script:CWLastSize)
    }
    Write-Host ('  通过 ' + $script:tsP + ' / ' + ($script:tsP + $script:tsF))
    $tray.Visible = $false
    $tray.Dispose()
    exit $(if ($script:tsF -eq 0) { 0 } else { 1 })
}

# ---------- 配置页交互自测（程序化点击）----------
if ($TestUI) {
    Write-Host '=== 配置页交互自测 ==='
    $ok = Show-ConfigWindow -Cfg $script:Cfg -TestInteractions
    $tray.Visible = $false
    $tray.Dispose()
    exit $(if ($ok) { 0 } else { 1 })
}

# ---------- 截图模式 ----------
if ($Shot) {
    $dockPng = if ($ForceOrient) { Join-Path $script:Root ("shot-dock-" + $ForceOrient + ".png") } else { Join-Path $script:Root 'shot-dock.png' }
    $panelPng = if ($ForceOrient) { Join-Path $script:Root ("shot-panel-" + $ForceOrient + ".png") } else { Join-Path $script:Root 'shot-panel.png' }
    $form.Show()
    $form.Activate()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 600
    [System.Windows.Forms.Application]::DoEvents()

    # 自绘控件用 DrawToBitmap 捕获，不受 DPI 缩放和窗口遮挡影响
    $pad = 16
    $bmp = New-Object System.Drawing.Bitmap ($form.Width + $pad * 2), ($form.Height + $pad * 2)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear((C '#0E1216'))
    $tmp = New-Object System.Drawing.Bitmap $form.Width, $form.Height
    $form.DrawToBitmap($tmp, (New-Object System.Drawing.Rectangle 0, 0, $form.Width, $form.Height))
    $g.DrawImage($tmp, $pad, $pad)
    $g.Dispose(); $tmp.Dispose()
    $bmp.Save($dockPng, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ('已保存 ' + $dockPng)

    Apply-Mode 'panel'
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 400
    [System.Windows.Forms.Application]::DoEvents()

    $bmp2 = New-Object System.Drawing.Bitmap ($form.Width + $pad * 2), ($form.Height + $pad * 2)
    $g2 = [System.Drawing.Graphics]::FromImage($bmp2)
    $g2.Clear((C '#0E1216'))
    $tmp2 = New-Object System.Drawing.Bitmap $form.Width, $form.Height
    $form.DrawToBitmap($tmp2, (New-Object System.Drawing.Rectangle 0, 0, $form.Width, $form.Height))
    $g2.DrawImage($tmp2, $pad, $pad)
    $g2.Dispose(); $tmp2.Dispose()
    $bmp2.Save($panelPng, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp2.Dispose()
    Write-Host ('已保存 ' + $panelPng)

    $form.Close()
    $tray.Visible = $false
    $tray.Dispose()
    exit 0
}

$form.Show()
# 句柄此时才真正创建完成，属性设置期间设的 TopMost 可能没落到位，这里显式钉一次
Assert-TopMost
# 自愈看护：实测同一份代码偶发 0x00090000（无置顶）与 0x00090008（正常），
# 属于启动时序竞态（外部进程对同一窗口设置则必定成功）。
# 所以每 2 秒检查一次，连续两次到位就停；最多看护 60 秒。
$script:topMostTimer = New-Object System.Windows.Forms.Timer
$script:topMostTimer.Interval = 2000
$script:topMostTicks = 0
$script:topMostOkStreak = 0
$script:topMostTimer.Add_Tick({
    $script:topMostTicks++
    Assert-TopMost
    $ex = [NativeWin]::GetWindowLong($form.Handle, -20)
    if (($ex -band 0x8) -ne 0) {
        $script:topMostOkStreak++
        if ($script:topMostOkStreak -ge 2) {
            $script:topMostTimer.Stop()
            $script:topMostTimer.Dispose()
            Write-CoreLog ('置顶补钉完成 EXSTYLE=0x' + $ex.ToString('X8') + '（第 ' + $script:topMostTicks + ' 次检查）')
        }
    } else {
        $script:topMostOkStreak = 0
        if ($script:topMostTicks -ge 30) {
            $script:topMostTimer.Stop()
            $script:topMostTimer.Dispose()
            Write-CoreLog ('置顶补钉失败 EXSTYLE=0x' + $ex.ToString('X8') + '（60 秒内始终未置顶）')
        }
    }
})
$script:topMostTimer.Start()
Write-CoreLog ('置顶断言后 EXSTYLE=0x' + ([NativeWin]::GetWindowLong($form.Handle, -20)).ToString('X8'))
[System.Windows.Forms.Application]::Run($form)
