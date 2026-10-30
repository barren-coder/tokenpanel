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
    if ($Money -lt 0) { return $Theme.Rd }
    if ($Money -lt $warn) { return $Theme.Am }
    return $Theme.Cy
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
#   周窗口 ：使用量 >= 90% → 黄，>= 95% → 红
#   账户圆圈取两个窗口里最严重的一级（周告警会联动到 5h 圆圈）
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
        if ($used -ge 95) { return 2 }
        if ($used -ge 90) { return 1 }
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
$DOCK_W = 89          # 单账户单元宽度，多账户按此横向累加
$DOCK_H = 89
$PANEL_W = 340
$RING_R = 26          # 圆圈半径（直径 52）
$RING_GAP = 12

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
    $penW = DS 4
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

    # 中心数字 + 小号 %（腾讯管家样式：数字大、百分号小且靠下）
    $fs = DS 14
    if ($Text.Length -ge 3) { $fs = DS 11 }
    $fontNum = New-Object System.Drawing.Font 'Segoe UI', ([single]$fs), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)

    $flagsM = [System.Windows.Forms.TextFormatFlags]::NoPadding
    $flagsC = $flagsM -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter

    if ($Pct -lt 0) {
        $rN = New-Object System.Drawing.Rectangle ([int]($Cx - $r)), ([int]($Cy - $r)), ([int]($r * 2)), ([int]($r * 2))
        [System.Windows.Forms.TextRenderer]::DrawText($G, $Text, $fontNum, $rN,
            (C $Theme.RingText), ($flagsC -bor [System.Windows.Forms.TextFormatFlags]::HorizontalCenter))
        $fontNum.Dispose()
        return
    }

    $fsPct = [int][Math]::Round($fs * 0.62)
    $fontPct = New-Object System.Drawing.Font 'Segoe UI', ([single]$fsPct), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    # 用 GenericTypographic 测量：不含额外 padding，宽度最接近实际渲染
    $sfM = [System.Drawing.StringFormat]::GenericTypographic
    $numW = [int][Math]::Ceiling($G.MeasureString($Text, $fontNum, 1000, $sfM).Width)
    $pctW = [int][Math]::Ceiling($G.MeasureString('%', $fontPct, 1000, $sfM).Width)

    # MeasureString 对 Bold 字体含约 2 逻辑像素的 overhang，这里扣掉，否则 % 会离数字太远
    $gap = -(DS 2)
    $totalW = $numW + $gap + $pctW
    $sx = [int]($Cx - $totalW / 2)

    $rNum = New-Object System.Drawing.Rectangle $sx, ([int]($Cy - $r)), $numW, ([int]($r * 2))
    [System.Windows.Forms.TextRenderer]::DrawText($G, $Text, $fontNum, $rNum, (C $Theme.RingText), $flagsC)

    # % 往下沉 3px，视觉上落在数字右下角
    $rPct = New-Object System.Drawing.Rectangle ($sx + $numW + $gap), ([int]($Cy - $r + (DS 3))), ($pctW + (DS 2)), ([int]($r * 2))
    [System.Windows.Forms.TextRenderer]::DrawText($G, '%', $fontPct, $rPct, (C $Theme.RingText), $flagsC)

    $fontNum.Dispose(); $fontPct.Dispose()
}

# 余额圆环：细描边整圈 + 居中金额（不画进度弧，避免被误读成「用满了」）
function Draw-MoneyRing {
    param($G, [single]$Cx, [single]$Cy, [string]$Text, [string]$ColorHex)

    $r = DS $RING_R
    # 比百分比圆环细一档（2 vs 4），一眼能区分「这是余额，不是用量」
    $penW = DS 2
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
    $flags = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor
             [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
             [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor
             [System.Windows.Forms.TextFormatFlags]::NoPrefix
    # 文本框比圆环略宽一点（负号/¥ 容易贴边），靠 Ellipsis 兜底
    $pad = [int](DS 3)
    $rect = New-Object System.Drawing.Rectangle ([int]($Cx - $r - $pad)), ([int]($Cy - $r)), ([int](($r + $pad) * 2)), ([int]($r * 2))
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

    $fontLbl = New-Object System.Drawing.Font 'Microsoft YaHei UI', ([single](DS 9)), ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
    $ringR = DS $RING_R
    $unitW = DS $DOCK_W
    $unitH = DS $DOCK_H

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
        $cy = $oy + (DS 12) + $ringR

        if ($a.kind -eq 'money') {
            # 余额账户也用圆环（用户明确要求），只是不画进度弧，改成细描边 + 居中金额
            $money = Get-AccountMoney $a
            $mcol = if ($a.ok) { Get-MoneyHex $money } else { $Theme.Tx3 }
            $txt = if ($a.ok) { Get-AccountMoneyShort $a } else { '--' }
            if ($script:AnimActive) { $txt = Get-FlickerText $txt }
            Draw-MoneyRing -G $G -Cx $cx -Cy $cy -Text $txt -ColorHex $mcol
        } else {
            # 圆圈固定显示 **5 小时** 窗口（用户明确指定），不再取两个窗口的最大值。
            # 颜色也跟着 5 小时的阈值走，保证「数字 = 34%」和「颜色」说的是同一件事
            $pt = Get-PrimaryTier $a
            $used = if ($pt) { 100 - [int]$pt.remain } else { -1 }
            $ringCol = if ($pt) { Get-LevelHex (Get-TierLevel $pt) } else { $Theme.Tx3 }
            $txt = if ($used -ge 0) { [string]$used } else { '--' }
            if ($script:AnimActive) { $txt = Get-FlickerText $txt }
            Draw-Ring -G $G -Cx $cx -Cy $cy -Pct $used -ColorHex $ringCol -Text $txt
        }

        # 标签占满整个单元宽度（左右各留 6），比圆圈宽，能放更多字
        $lblColor = if ($a.ok) { $Theme.Tx2 } else { $Theme.Tx3 }
        $lx = if ($vert) { (DS 6) } else { $ox + (DS 6) }
        $lw = if ($vert) { $W - (DS 12) } else { $unitW - (DS 12) }
        Draw-Text -G $G -Text $a.short -Font $fontLbl -Color $lblColor `
            -X $lx -Y ($cy + $ringR + (DS 4)) -W $lw -H (DS 12) -Align Center -Ellipsis
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
        # 色点跟着账户状态走：余额账户看金额（负数红），额度账户看最严重窗口的等级
        $color = if (-not $a.ok) { $Theme.Tx3 }
                 elseif ($isMoneyAcc) { Get-MoneyHex (Get-AccountMoney $a) }
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
            $bigColor = if ($a.ok) { Get-MoneyHex (Get-AccountMoney $a) } else { $Theme.Tx3 }
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
                $mhex = if ($null -ne $t.money) { Get-MoneyHex ([double]$t.money) } else { $Theme.Tx3 }
                Draw-Text -G $G -Text $t.name -Font $fontTiny -Color $Theme.Tx3 -X (S 30) -Y $by -W (S 60) -H (S 14)
                if ($null -ne $t.money -and [double]$t.money -lt 0) {
                    Draw-Text -G $G -Text '已欠费' -Font $fontMoney -Color $mhex -X (S 96) -Y $by -W (S 80) -H (S 14)
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

    Write-Host "=== 颜色逻辑边界测试 ==="
    Write-Host "  (0=青 1=黄 2=红；按使用量判断)"
    $cases = @(
        @{ N = '5h 使用 70%'; R5 = 30; RW = 50; E = 0 },
        @{ N = '5h 使用 79%'; R5 = 21; RW = 50; E = 0 },
        @{ N = '5h 使用 80%'; R5 = 20; RW = 50; E = 1 },
        @{ N = '5h 使用 89%'; R5 = 11; RW = 50; E = 1 },
        @{ N = '5h 使用 90%'; R5 = 10; RW = 50; E = 2 },
        @{ N = '周 使用 89%'; R5 = 80; RW = 11; E = 0 },
        @{ N = '周 使用 90%'; R5 = 80; RW = 10; E = 1 },
        @{ N = '周 使用 94%'; R5 = 80; RW = 6;  E = 1 },
        @{ N = '周 使用 95%'; R5 = 80; RW = 5;  E = 2 },
        @{ N = '周联动 5h 圆圈'; R5 = 95; RW = 3; E = 2 }
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

# ---------- 按吸附的边削平圆角 ----------
function Update-WindowRegion {
    param([int]$W, [int]$H)
    $base = if ($script:Mode -eq 'dock') { [single](DS 18) } else { [single](S 18) }
    $rtl = $base; $rtr = $base; $rbr = $base; $rbl = $base
    if ($script:SnapEdgeV -eq 'bottom') { $rbr = 0; $rbl = 0 }
    if ($script:SnapEdgeV -eq 'top')    { $rtl = 0; $rtr = 0 }
    if ($script:SnapEdgeH -eq 'left')   { $rtl = 0; $rbl = 0 }
    if ($script:SnapEdgeH -eq 'right')  { $rtr = 0; $rbr = 0 }
    $path = New-RoundedPathEx -X 0 -Y 0 -W $W -H $H -RTL $rtl -RTR $rtr -RBR $rbr -RBL $rbl
    $script:MainForm.Region = New-Object System.Drawing.Region $path
    $path.Dispose()
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
    $canvas.Invalidate()
}

$canvas.add_Paint({
    param($s, $e)
    try {
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear((C $Theme.Bg))

    # 深色下方块与背景的色差已经足够，不画描边（曾经 1px #2E333F 会显成白边）；
    # 浅色下白窗贴白墙看不见，必须补一条极淡的描边
    if ($script:Mode -eq 'dock') {
        Draw-Dock -G $g -W $s.Width -H $s.Height
    } else {
        Draw-Panel -G $g -W $s.Width -H $s.Height
    }

    if ($Theme.Border) {
        $bw = [single]$s.Width; $bh = [single]$s.Height
        $rad = if ($script:Mode -eq 'dock') { [single](DS 18) } else { [single](S 18) }
        $bp = New-RoundedPathEx -X 0.5 -Y 0.5 -W ($bw - 1) -H ($bh - 1) -RTL $rad -RTR $rad -RBR $rad -RBL $rad
        $bpen = New-Object System.Drawing.Pen (C $Theme.Border), ([single]1)
        $g.DrawPath($bpen, $bp)
        $bpen.Dispose(); $bp.Dispose()
    }
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
        try { $canvas.Refresh() } catch { }
        Refresh-Data
        return
    }
    try { $canvas.Invalidate() } catch { }
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

    # 2) 方向：贴左右边 → 纵排；贴上下边 / 自由漂浮 → 横排。
    #    只在「真的贴上竖边」时才换向，避免离边缘几十像素就自己竖起来（那样很惊悚）
    $orient = 'h'
    if ($eH -ne 'none') { $orient = 'v' }
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
    $script:MainForm.Activate()
    if ($script:Mode -ne 'panel') { Apply-Mode 'panel' }
}

function Refresh-Data {
    try {
        $script:Data = Get-AllQuota -Cfg $script:Cfg
        if ($script:Mode -eq 'panel') { Apply-Mode 'panel' } else { $canvas.Invalidate() }
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
        $script:MainForm.Refresh()
        $canvas.Refresh()
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
            Apply-Mode $script:Mode
            Refresh-Data
            Write-CoreLog ('配置已保存并生效（浮窗 ' + $script:DockScale + '×）')
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
    $script = Join-Path $script:Root 'TokenPanel.ps1'
    return 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script + '"'
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
    try {
        if ($Enable) {
            Set-ItemProperty -Path $script:RunKey -Name $script:AppId -Value (Get-AutostartCommand) -Force
            # 清掉改名前的旧值，避免开机启动两次
            Remove-ItemProperty -Path $script:RunKey -Name 'TokenPanel' -ErrorAction SilentlyContinue
        } else {
            Remove-ItemProperty -Path $script:RunKey -Name $script:AppId -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $script:RunKey -Name 'TokenPanel' -ErrorAction SilentlyContinue
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
        $canvas.Invalidate()
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
[System.Windows.Forms.Application]::Run($form)
