# ConfigWindow.ps1 — 图形化配置页（布局参考 CC Switch 的用量查询面板）
# 被 TokenPanel.ps1 dot-source 引入，调用 Show-ConfigWindow -Cfg $cfg
#
# 两个页面（左侧底部按钮切换）：
#   账户配置：模板决定「显示哪些字段 + 用什么认证 + 用什么解析器」
#             custom / general / newapi / tokenplan / balance / official
#   系统配置：界面缩放 / 悬浮窗大小 / 开机启动 / 超时与间隔 / 关于
#
# 缩放实现：先按 1.0 建完静态布局，再 Form.Scale(f) 统一放大，
# 之后所有动态布局（模板切换、账户列表）都用 X() 换算，避免二次缩放。

# 配色：调色板在 QuotaCore.Get-CwTheme（深色/浅色两套）。
# 这里先给一个默认值，Show-ConfigWindow 开头会按配置里的 theme 重新赋值。
$CW = Get-CwTheme 'dark'

# 当前界面缩放因子（1.0 = 基准）。CW-Font / X 都依赖它
$script:cwF = 1.0

function CC([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }

# 基准逻辑像素 -> 当前缩放后的像素
function X {
    param([double]$v)
    return [int][Math]::Round($v * $script:cwF)
}

function CW-Round {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    if ($d -gt $W) { $d = $W }
    if ($d -gt $H) { $d = $H }
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function CW-Font {
    param([int]$Size, [bool]$Bold = $false)
    $st = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    # 必须用像素单位：pt 会随 DPI 放大（9pt≈18px@150%），撑破按像素布局的控件
    $px = [single]($Size * 1.34 * $script:cwF)
    return New-Object System.Drawing.Font 'Microsoft YaHei UI', $px, $st, ([System.Drawing.GraphicsUnit]::Pixel)
}

function CW-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Color = '#9A9A9A', [int]$Size = 9,
          [switch]$Bold, [string]$Bg = '')
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point $X, $Y
    $l.Size = New-Object System.Drawing.Size $W, $H
    # 显式背景色比 Transparent 稳：透明 Label 在重绘时偶发丢字
    $l.BackColor = if ($Bg) { CC $Bg } else { CC $CW.Card }
    $l.ForeColor = CC $Color
    $l.Font = CW-Font -Size $Size -Bold $Bold.IsPresent
    return $l
}

function CW-Text {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Value = '', [switch]$Password)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point $X, $Y
    $t.Size = New-Object System.Drawing.Size $W, $H
    $t.Text = $Value
    $t.BorderStyle = 'FixedSingle'
    $t.BackColor = CC $CW.Field
    $t.ForeColor = CC $CW.Tx
    $t.Font = CW-Font -Size 9
    $t.TextAlign = 'Left'
    if ($Password) { $t.UseSystemPasswordChar = $true }
    return $t
}

function CW-Btn {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Kind = 'ghost')
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point $X, $Y
    $b.Size = New-Object System.Drawing.Size $W, $H
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.Font = CW-Font -Size 9
    $b.Cursor = 'Hand'
    switch ($Kind) {
        'primary' {
            $b.BackColor = CC $CW.Accent
            $b.ForeColor = [System.Drawing.Color]::White
            $b.Font = CW-Font -Size 9 -Bold $true
        }
        'chip' {
            $b.BackColor = CC $CW.Field
            $b.ForeColor = CC $CW.Tx2
            $b.FlatAppearance.BorderSize = 1
            $b.FlatAppearance.BorderColor = CC $CW.Line
        }
        'chipOn' {
            $b.BackColor = CC $CW.Accent
            $b.ForeColor = [System.Drawing.Color]::White
            $b.Font = CW-Font -Size 9 -Bold $true
        }
        default {
            $b.BackColor = CC $CW.Field
            $b.ForeColor = CC $CW.Tx
            $b.FlatAppearance.BorderSize = 1
            $b.FlatAppearance.BorderColor = CC $CW.Line
        }
    }
    return $b
}

# 胶囊按钮（W 传 0 时按文字实测宽度自动定宽）
function CW-Chip {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 0, [int]$H = 30, [bool]$On = $false, [string]$Tag2 = '')
    if ($W -le 0) {
        $f = CW-Font -Size 9
        $W = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $f).Width + (X 26)
        $f.Dispose()
    }
    $b = CW-Btn -Text $Text -X $X -Y $Y -W $W -H $H -Kind $(if ($On) { 'chipOn' } else { 'chip' })
    $b.Tag = $Tag2
    return $b
}

function Set-ChipState {
    param($Btn, [bool]$On)
    $Btn.BackColor = if ($On) { CC $CW.Accent } else { CC $CW.Field }
    $Btn.ForeColor = if ($On) { [System.Drawing.Color]::White } else { CC $CW.Tx2 }
    $Btn.Font = CW-Font -Size 9 -Bold $On
}

# 开关控件（自绘，尺寸相对自身大小算，缩放后不会变形）
function CW-Switch {
    param([int]$X, [int]$Y, [bool]$On = $true, [scriptblock]$OnChange)
    $sw = New-Object System.Windows.Forms.Panel
    $sw.Location = New-Object System.Drawing.Point $X, $Y
    $sw.Size = New-Object System.Drawing.Size (X 44), (X 24)
    $sw.BackColor = CC $CW.Card
    $sw.Tag = $On
    $sw.Cursor = 'Hand'
    $sw.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $on = [bool]$s.Tag
        $w = [single]$s.Width
        $h = [single]$s.Height
        $pad = [single]($h * 0.10)
        $trackH = $h - $pad * 2
        $bg = if ($on) { CC $CW.Accent } else { CC '#3A3A3A' }
        $path = CW-Round -X 0 -Y $pad -W $w -H $trackH -R ($trackH / 2)
        $br = New-Object System.Drawing.SolidBrush $bg
        $g.FillPath($br, $path)
        $br.Dispose(); $path.Dispose()
        $knob = [single]($trackH - $pad * 2)
        $kx = if ($on) { $w - $knob - $pad * 1.4 } else { $pad * 1.4 }
        $ky = [single](($h - $knob) / 2)
        $kb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $g.FillEllipse($kb, $kx, $ky, $knob, $knob)
        $kb.Dispose()
    })
    $sw.Add_Click({
        param($s, $e)
        $s.Tag = -not [bool]$s.Tag
        $s.Invalidate()
        if ($OnChange) { & $OnChange ([bool]$s.Tag) }
    })
    return $sw
}

# 递归缩放字体。
# 坑：Form.Scale(SizeF) 只缩放 Bounds，不会缩放显式设置的字体（实测 12px 缩放后仍是 12px），
# 结果就是「框变大了、字还是小的」。必须自己走一遍。
function Scale-CtrlFonts {
    param($Ctl, [single]$Factor)
    foreach ($c in @($Ctl.Controls)) {
        try {
            $ft = $c.Font
            if ($ft -and $ft.Size -gt 0.01) {
                $ns = [single]($ft.Size * $Factor)
                if ($ns -lt 1) { $ns = 1 }
                $c.Font = New-Object System.Drawing.Font $ft.FontFamily, $ns, $ft.Style, $ft.Unit
            }
        } catch { }
        Scale-CtrlFonts -Ctl $c -Factor $Factor
    }
}

# ============================================================
# 主窗口
# ============================================================
function Show-ConfigWindow {
    param($Cfg, [string]$CapturePath = '', [switch]$DumpLayout, [string]$OnlyTpl = '', [string]$OnlyPage = '',
          [switch]$TestInteractions,
          # 只量尺寸：建好窗口、读实际宽高、关掉。用于验证「界面缩放真的改变了窗口尺寸」
          [switch]$ProbeSize,
          # 无人值守验证用：N 毫秒后自动点某个缩放档 / 悬浮大小档，再由 -AutoClose 关窗
          [string]$AutoScaleClick = '', [switch]$AutoClose,
          # 改缩放后窗口会重建一次：下面三个参数用来把「当前页 / 当前模板 / 窗口位置」带回去
          [string]$StartPage = '', [string]$StartTpl = '', $StartPos = $null)

    # 自测模式下不能真的重建窗口（会把测试脚本正在操作的控件销毁）
    $script:NoRescale = [bool]$TestInteractions

    # 深拷贝，取消时不污染原配置
    $script:EditCfg = $Cfg | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    # 按配置选配色（可能是深色也可能是浅色）；点「浅色」会走重建流程重新读这里
    $CW = Get-CwTheme ([string]$script:EditCfg.theme)
    $script:CW = $CW
    if ($null -eq $script:EditCfg.providers) { $script:EditCfg.providers = @() }
    if ($script:EditCfg.providers -isnot [array]) { $script:EditCfg.providers = @($script:EditCfg.providers) }
    $script:EditIdx = 0
    if ($script:EditCfg.providers.Count -eq 0) {
        $script:EditCfg.providers = @((New-ProviderObject -Preset (Get-PresetById 'minimax' 'tokenplan') -Tpl 'tokenplan'))
    }
    foreach ($pv in $script:EditCfg.providers) {
        if (-not $pv.tpl) { $pv.tpl = 'tokenplan' }
    }

    $tpls = @(Get-TemplateDefs)
    $script:cwF = 1.0          # 先按基准尺寸建布局，最后再统一缩放

    # ---------------- 布局常量（基准逻辑像素）----------------
    $W = 880
    $RX = 240
    $RW = $W - $RX - 22          # 618
    $LIST_W = 200
    $CARD1_Y = 58
    $CARD1_H = 60
    $CARD2_Y = 132
    $ROW_H = 52
    $ROW_GAP = 6
    $SYS_H = 854                 # 系统配置页的基准高度（S5 底 772 + 底部按钮栏 82）

    # 模板标签（实测宽度，超宽自动换行）
    $tabFont = CW-Font -Size 9
    $tabX = 18; $tabY = 44; $tabRowH = 38
    $tabPos = @{}
    foreach ($t in $tpls) {
        $bw = [System.Windows.Forms.TextRenderer]::MeasureText($t.Label, $tabFont).Width + 26
        if ($tabX + $bw -gt ($RW - 18)) { $tabX = 18; $tabY += $tabRowH }
        $tabPos[$t.Id] = @{ X = $tabX; Y = $tabY; W = $bw }
        $tabX += $bw + 8
    }
    $tabFont.Dispose()
    $tabsBottom = $tabY + 30

    $ySep1 = $tabsBottom + 12
    $yHint = $ySep1 + 10
    $yDyn = $yHint + 28

    # 预演各模板的供应商胶囊行数，取最大值
    $maxPresetH = 0
    foreach ($t in $tpls) {
        $ps = @(Get-ProviderPresets -Tpl $t.Id)
        $fM = CW-Font -Size 9
        $px = 0; $py = 0
        foreach ($p in $ps) {
            $bw = [System.Windows.Forms.TextRenderer]::MeasureText($p.Label, $fM).Width + 26
            if ($px + $bw -gt ($RW - 36)) { $px = 0; $py += 36 }
            $px += $bw + 8
        }
        $fM.Dispose()
        $h = if ($ps.Count -eq 0) { 0 } else { 18 + $py + 36 }
        if ($h -gt $maxPresetH) { $maxPresetH = $h }
    }

    $layoutMap = @{
        custom    = @('name', 'url', 'key', 'paths', 'scaleunit')
        general   = @('name', 'url', 'key')
        newapi    = @('name', 'url', 'newapi')
        tokenplan = @('name', 'preset', 'url', 'key')
        balance   = @('name', 'preset', 'key')
        official  = @('name', 'preset', 'official')
    }
    $maxDynH = 0
    foreach ($k in $layoutMap.Keys) {
        $yy = 0
        foreach ($key in $layoutMap[$k]) {
            $hh = if ($key -eq 'preset') { $maxPresetH } else { $ROW_H }
            $yy += $hh + $ROW_GAP
        }
        $yy += 2 + 40
        if ($yy -gt $maxDynH) { $maxDynH = $yy }
    }
    # 底部「提取器 / 支持的变量」区块：固定高度，所有模板都显示，避免各模板窗口高矮不一
    # 38px 标题 + 150px 代码框（约 7~8 行，带滚动条）
    $EXTRACT_H = 192
    $CARD2_H = $yDyn + $maxDynH + 12 + $EXTRACT_H
    $H = $CARD2_Y + $CARD2_H + 78
    if ($SYS_H -gt $H) { $H = $SYS_H }

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    if ($StartPos) {
        $form.StartPosition = 'Manual'
        $form.Location = $StartPos
    } else {
        $form.StartPosition = 'CenterScreen'
    }
    $form.BackColor = CC $CW.Bg
    $form.Size = New-Object System.Drawing.Size $W, $H
    $form.ShowInTaskbar = $true
    $form.Text = $script:AppName + ' · 设置'

    # 拖动
    $script:cwDrag = $false
    $script:cwPt = New-Object System.Drawing.Point 0, 0
    $form.Add_MouseDown({ param($s, $e) $script:cwDrag = $true; $script:cwPt = $e.Location })
    $form.Add_MouseMove({
        param($s, $e)
        if ($script:cwDrag) {
            $s.Location = New-Object System.Drawing.Point (
                ($s.Location.X + $e.X - $script:cwPt.X),
                ($s.Location.Y + $e.Y - $script:cwPt.Y))
        }
    })
    $form.Add_MouseUp({ $script:cwDrag = $false })

    # ---------------- 标题栏：应用名 + 紧跟版本号 ----------------
    $title = CW-Label -Text $script:AppName -X 22 -Y 14 -W 260 -H 30 -Color $CW.Tx -Size 13 -Bold -Bg $CW.Bg
    $form.Controls.Add($title)
    $nameW = [System.Windows.Forms.TextRenderer]::MeasureText($script:AppName, $title.Font).Width
    $verText = 'v' + $script:AppVersion + '  ' + $script:AppChannel
    $form.Controls.Add((CW-Label -Text $verText -X (22 + $nameW + 6) -Y 20 -W 200 -H 22 -Color $CW.Tx3 -Size 8 -Bg $CW.Bg))

    $btnX = New-Object System.Windows.Forms.Label
    $btnX.Text = '✕'
    $btnX.Location = New-Object System.Drawing.Point ($W - 40), 14
    $btnX.Size = New-Object System.Drawing.Size 26, 26
    $btnX.TextAlign = 'MiddleCenter'
    $btnX.ForeColor = CC $CW.Tx3
    $btnX.BackColor = CC $CW.Bg
    $btnX.Font = New-Object System.Drawing.Font 'Segoe UI', 10
    $btnX.Cursor = 'Hand'
    $btnX.Add_Click({ $form.Close() })
    $form.Controls.Add($btnX)

    # ==================== 左侧 ====================
    $LIST_H = $H - 128
    $listPanel = New-Object System.Windows.Forms.Panel
    $listPanel.Location = New-Object System.Drawing.Point 22, 58
    $listPanel.Size = New-Object System.Drawing.Size $LIST_W, $LIST_H
    $listPanel.BackColor = CC $CW.Card
    $form.Controls.Add($listPanel)

    $listTitle = CW-Label -Text '账户' -X 14 -Y 12 -W 120 -H 20 -Color $CW.Tx2 -Size 9 -Bold
    $listPanel.Controls.Add($listTitle)

    $accountHost = New-Object System.Windows.Forms.Panel
    $accountHost.Location = New-Object System.Drawing.Point 0, 40
    $accountHost.Size = New-Object System.Drawing.Size $LIST_W, ($LIST_H - 50)
    $accountHost.BackColor = CC $CW.Card
    $accountHost.AutoScroll = $true
    $listPanel.Controls.Add($accountHost)

    # 页面切换按钮（底部）
    $btnPage = New-Object System.Windows.Forms.Button
    $btnPage.Text = '⚙  系统配置'
    $btnPage.Location = New-Object System.Drawing.Point 10, ($LIST_H - 42)
    $btnPage.Size = New-Object System.Drawing.Size 180, 32
    $btnPage.FlatStyle = 'Flat'
    $btnPage.FlatAppearance.BorderSize = 1
    $btnPage.FlatAppearance.BorderColor = CC $CW.Line
    $btnPage.BackColor = CC $CW.Card
    $btnPage.ForeColor = CC $CW.Tx2
    $btnPage.Font = CW-Font -Size 9
    $btnPage.Cursor = 'Hand'
    $listPanel.Controls.Add($btnPage)

    # ==================== 账户页：卡片1 ====================
    $card1 = New-Object System.Windows.Forms.Panel
    $card1.Location = New-Object System.Drawing.Point $RX, $CARD1_Y
    $card1.Size = New-Object System.Drawing.Size $RW, $CARD1_H
    $card1.BackColor = CC $CW.Card
    $form.Controls.Add($card1)

    $card1.Controls.Add((CW-Label -Text '启用用量查询' -X 18 -Y 20 -W 200 -H 22 -Color $CW.Tx -Size 10 -Bold))
    $swEnable = CW-Switch -X ($RW - 62) -Y 18 -On $true
    $card1.Controls.Add($swEnable)

    # ==================== 账户页：卡片2 ====================
    $card2 = New-Object System.Windows.Forms.Panel
    $card2.Location = New-Object System.Drawing.Point $RX, $CARD2_Y
    $card2.Size = New-Object System.Drawing.Size $RW, $CARD2_H
    $card2.BackColor = CC $CW.Card
    $form.Controls.Add($card2)

    $card2.Controls.Add((CW-Label -Text '账户配置' -X 18 -Y 14 -W 160 -H 22 -Color $CW.Tx -Size 10 -Bold))

    $tplButtons = @{}
    foreach ($t in $tpls) {
        $pos = $tabPos[$t.Id]
        $b = CW-Chip -Text $t.Label -X $pos.X -Y $pos.Y -W $pos.W -H 30 -On $false -Tag2 $t.Id
        $card2.Controls.Add($b)
        $tplButtons[$t.Id] = $b
    }

    $sep1 = New-Object System.Windows.Forms.Panel
    $sep1.Location = New-Object System.Drawing.Point 18, $ySep1
    $sep1.Size = New-Object System.Drawing.Size ($RW - 36), 1
    $sep1.BackColor = CC $CW.Line
    $card2.Controls.Add($sep1)

    $tplHint = CW-Label -Text '' -X 18 -Y $yHint -W ($RW - 36) -H 20 -Color $CW.Tx3 -Size 8
    $card2.Controls.Add($tplHint)

    # ---------------- 动态字段行 ----------------
    $rows = @{}

    $rowName = New-Object System.Windows.Forms.Panel
    $rowName.Size = New-Object System.Drawing.Size ($RW - 36), $ROW_H
    $rowName.Location = New-Object System.Drawing.Point 18, $yDyn
    $rowName.BackColor = CC $CW.Card
    $card2.Controls.Add($rowName)
    $rowName.Controls.Add((CW-Label -Text '显示名称' -X 0 -Y 0 -W 260 -H 16 -Color $CW.Tx3 -Size 8))
    $rowName.Controls.Add((CW-Label -Text '短名（圆圈下方显示）' -X 274 -Y 0 -W 240 -H 16 -Color $CW.Tx3 -Size 8))
    $tbName = CW-Text -X 0 -Y 18 -W 260 -H 28
    $rowName.Controls.Add($tbName)
    $tbShort = CW-Text -X 274 -Y 18 -W 160 -H 28
    $rowName.Controls.Add($tbShort)
    $rows['name'] = $rowName

    $rowPreset = New-Object System.Windows.Forms.Panel
    $rowPreset.Size = New-Object System.Drawing.Size ($RW - 36), $maxPresetH
    $rowPreset.Location = New-Object System.Drawing.Point 18, $yDyn
    $rowPreset.BackColor = CC $CW.Card
    $card2.Controls.Add($rowPreset)
    $rowPreset.Controls.Add((CW-Label -Text '供应商' -X 0 -Y 0 -W 200 -H 16 -Color $CW.Tx3 -Size 8))
    $presetHost = New-Object System.Windows.Forms.Panel
    $presetHost.Location = New-Object System.Drawing.Point 0, 18
    $presetHost.Size = New-Object System.Drawing.Size ($RW - 36), ($maxPresetH - 18)
    $presetHost.BackColor = CC $CW.Card
    $rowPreset.Controls.Add($presetHost)
    $rows['preset'] = $rowPreset

    $rowUrl = New-Object System.Windows.Forms.Panel
    $rowUrl.Size = New-Object System.Drawing.Size ($RW - 36), $ROW_H
    $rowUrl.Location = New-Object System.Drawing.Point 18, $yDyn
    $rowUrl.BackColor = CC $CW.Card
    $card2.Controls.Add($rowUrl)
    $lblUrl = CW-Label -Text 'API 地址' -X 0 -Y 0 -W 400 -H 16 -Color $CW.Tx3 -Size 8
    $rowUrl.Controls.Add($lblUrl)
    $tbUrl = CW-Text -X 0 -Y 18 -W ($RW - 36) -H 28
    $rowUrl.Controls.Add($tbUrl)
    $rows['url'] = $rowUrl

    $rowKey = New-Object System.Windows.Forms.Panel
    $rowKey.Size = New-Object System.Drawing.Size ($RW - 36), $ROW_H
    $rowKey.Location = New-Object System.Drawing.Point 18, $yDyn
    $rowKey.BackColor = CC $CW.Card
    $card2.Controls.Add($rowKey)
    $rowKey.Controls.Add((CW-Label -Text 'API Key' -X 0 -Y 0 -W 300 -H 16 -Color $CW.Tx3 -Size 8))
    $tbKey = CW-Text -X 0 -Y 18 -W ($RW - 36 - 106) -H 28 -Password
    $rowKey.Controls.Add($tbKey)
    $btnProbe = CW-Btn -Text '自动探测' -X ($RW - 36 - 100) -Y 18 -W 100 -H 28 -Kind 'ghost'
    $rowKey.Controls.Add($btnProbe)
    $rows['key'] = $rowKey

    $rowNewApi = New-Object System.Windows.Forms.Panel
    $rowNewApi.Size = New-Object System.Drawing.Size ($RW - 36), $ROW_H
    $rowNewApi.Location = New-Object System.Drawing.Point 18, $yDyn
    $rowNewApi.BackColor = CC $CW.Card
    $card2.Controls.Add($rowNewApi)
    $rowNewApi.Controls.Add((CW-Label -Text 'Access Token' -X 0 -Y 0 -W 260 -H 16 -Color $CW.Tx3 -Size 8))
    $rowNewApi.Controls.Add((CW-Label -Text 'User ID' -X 274 -Y 0 -W 160 -H 16 -Color $CW.Tx3 -Size 8))
    $tbAccess = CW-Text -X 0 -Y 18 -W 260 -H 28 -Password
    $rowNewApi.Controls.Add($tbAccess)
    $tbUserId = CW-Text -X 274 -Y 18 -W 160 -H 28
    $rowNewApi.Controls.Add($tbUserId)
    $rows['newapi'] = $rowNewApi

    $rowPaths = New-Object System.Windows.Forms.Panel
    $rowPaths.Size = New-Object System.Drawing.Size ($RW - 36), $ROW_H
    $rowPaths.Location = New-Object System.Drawing.Point 18, $yDyn
    $rowPaths.BackColor = CC $CW.Card
    $card2.Controls.Add($rowPaths)
    $rowPaths.Controls.Add((CW-Label -Text '剩余百分比 JSON 路径（如 data.balance）' -X 0 -Y 0 -W 300 -H 16 -Color $CW.Tx3 -Size 8))
    $rowPaths.Controls.Add((CW-Label -Text '重置时间 JSON 路径（可空）' -X 314 -Y 0 -W 260 -H 16 -Color $CW.Tx3 -Size 8))
    $tbValuePath = CW-Text -X 0 -Y 18 -W 300 -H 28
    $rowPaths.Controls.Add($tbValuePath)
    $tbResetPath = CW-Text -X 314 -Y 18 -W 240 -H 28
    $rowPaths.Controls.Add($tbResetPath)
    $rows['paths'] = $rowPaths

    # 自定义模板的换算：倍数 + 单位（决定了「百分比额度」还是「余额金额」）
    $rowScaleUnit = New-Object System.Windows.Forms.Panel
    $rowScaleUnit.Size = New-Object System.Drawing.Size ($RW - 36), $ROW_H
    $rowScaleUnit.Location = New-Object System.Drawing.Point 18, $yDyn
    $rowScaleUnit.BackColor = CC $CW.Card
    $card2.Controls.Add($rowScaleUnit)
    $rowScaleUnit.Controls.Add((CW-Label -Text '倍数（接口原始值 × 该倍数）' -X 0 -Y 0 -W 300 -H 16 -Color $CW.Tx3 -Size 8))
    $rowScaleUnit.Controls.Add((CW-Label -Text '单位：% 或 CNY / USD' -X 314 -Y 0 -W 240 -H 16 -Color $CW.Tx3 -Size 8))
    $tbScale = CW-Text -X 0 -Y 18 -W 140 -H 28 -Value '1'
    $rowScaleUnit.Controls.Add($tbScale)
    $tbUnit = CW-Text -X 314 -Y 18 -W 120 -H 28 -Value '%'
    $rowScaleUnit.Controls.Add($tbUnit)
    $rows['scaleunit'] = $rowScaleUnit

    $rowOfficial = New-Object System.Windows.Forms.Panel
    $rowOfficial.Size = New-Object System.Drawing.Size ($RW - 36), $ROW_H
    $rowOfficial.Location = New-Object System.Drawing.Point 18, $yDyn
    $rowOfficial.BackColor = CC $CW.Card
    $card2.Controls.Add($rowOfficial)
    $lblOfficial = CW-Label -Text '' -X 0 -Y 4 -W ($RW - 36) -H 40 -Color $CW.Tx3 -Size 8
    $rowOfficial.Controls.Add($lblOfficial)
    $rows['official'] = $rowOfficial

    $statusBar = New-Object System.Windows.Forms.Panel
    $statusBar.Location = New-Object System.Drawing.Point 18, ($yDyn + 100)
    $statusBar.Size = New-Object System.Drawing.Size ($RW - 36), 40
    $statusBar.BackColor = CC $CW.Sunken
    $card2.Controls.Add($statusBar)
    $statusText = CW-Label -Text '填好信息后点「测试脚本」' -X 12 -Y 11 -W ($RW - 36 - 24) -H 18 -Color $CW.Tx3 -Size 8 -Bg $CW.Sunken
    $statusBar.Controls.Add($statusText)

    # ---------------- 提取器 / 支持的变量（对照 CC Switch 的用量脚本）----------------
    # CC Switch 的模板本质是「request + extractor 函数」，变量用 {{apiKey}} 这类占位符替换。
    # 我们是 PowerShell、没有 JS 引擎，所以这里做两件事：
    #   1) 列出 CC Switch 支持的 4 个变量，让用户知道每个模板会用到什么
    #   2) 按当前模板 + 当前填写的值，生成「等价的 CC Switch 脚本」只读展示
    #      —— 文案是生成的不是写死的，改了字段这里立刻跟着变，可以直接复制去 CC Switch 用
    $extractBlock = New-Object System.Windows.Forms.Panel
    $extractBlock.Location = New-Object System.Drawing.Point 18, ($yDyn + 152)
    $extractBlock.Size = New-Object System.Drawing.Size ($RW - 36), $EXTRACT_H
    $extractBlock.BackColor = CC $CW.Card
    $card2.Controls.Add($extractBlock)

    $lblVars = CW-Label -Text '' -X 0 -Y 0 -W ($RW - 36) -H 16 -Color $CW.Tx3 -Size 8
    $extractBlock.Controls.Add($lblVars)
    $extractBlock.Controls.Add((CW-Label -Text '提取器代码（等价 CC Switch 用量脚本，只读）' -X 0 -Y 19 -W ($RW - 36) -H 16 -Color $CW.Tx3 -Size 8))

    $tbCode = New-Object System.Windows.Forms.TextBox
    $tbCode.Location = New-Object System.Drawing.Point 0, 38
    $tbCode.Size = New-Object System.Drawing.Size ($RW - 36), ($EXTRACT_H - 42)
    $tbCode.Multiline = $true
    $tbCode.ReadOnly = $true
    $tbCode.ScrollBars = 'Vertical'
    # 自动换行：只读参考文本，宁可折行也不要横向被裁掉（长行会看不全）
    $tbCode.WordWrap = $true
    $tbCode.AcceptsReturn = $true
    $tbCode.BackColor = CC $CW.CodeBg
    $tbCode.ForeColor = CC $CW.CodeFg
    $tbCode.BorderStyle = 'FixedSingle'
    # 等宽字体：缩放由 Scale-CtrlFonts 统一处理
    $tbCode.Font = New-Object System.Drawing.Font 'Consolas', ([single](9 * 1.34)), ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
    $extractBlock.Controls.Add($tbCode)

    # ==================== 系统配置页 ====================
    $sysCtrls = @()

    # --- 卡片 S1：界面缩放 ---
    $s1 = New-Object System.Windows.Forms.Panel
    $s1.Location = New-Object System.Drawing.Point $RX, 58
    $s1.Size = New-Object System.Drawing.Size $RW, 104
    $s1.BackColor = CC $CW.Card
    $form.Controls.Add($s1)
    $sysCtrls += $s1
    $s1.Controls.Add((CW-Label -Text '界面缩放' -X 18 -Y 14 -W 200 -H 22 -Color $CW.Tx -Size 10 -Bold))

    $scaleDefs = @(
        @{ Id = '50';   Text = '50%' },
        @{ Id = '75';   Text = '75%' },
        @{ Id = '100';  Text = '100%' },
        @{ Id = '150';  Text = '150%' },
        @{ Id = 'auto'; Text = '自适应' }
    )
    $scaleButtons = @{}
    $sx = 18
    foreach ($d in $scaleDefs) {
        $b = CW-Chip -Text $d.Text -X $sx -Y 42 -H 30 -On $false -Tag2 $d.Id
        $s1.Controls.Add($b)
        $scaleButtons[$d.Id] = $b
        $sx += $b.Width + 8
    }
    $scaleHint = CW-Label -Text '' -X 18 -Y 80 -W ($RW - 36) -H 18 -Color $CW.Tx3 -Size 8
    $s1.Controls.Add($scaleHint)

    # --- 卡片 S2：悬浮窗大小 ---
    $s2 = New-Object System.Windows.Forms.Panel
    $s2.Location = New-Object System.Drawing.Point $RX, 174
    $s2.Size = New-Object System.Drawing.Size $RW, 104
    $s2.BackColor = CC $CW.Card
    $form.Controls.Add($s2)
    $sysCtrls += $s2
    $s2.Controls.Add((CW-Label -Text '悬浮窗大小' -X 18 -Y 14 -W 200 -H 22 -Color $CW.Tx -Size 10 -Bold))

    $dockDefs = @(
        @{ Id = '0.75'; Text = '小' },
        @{ Id = '1';    Text = '默认' },
        @{ Id = '1.25'; Text = '大' }
    )
    $dockButtons = @{}
    $dx = 18
    foreach ($d in $dockDefs) {
        $b = CW-Chip -Text $d.Text -X $dx -Y 42 -H 30 -On $false -Tag2 $d.Id
        $s2.Controls.Add($b)
        $dockButtons[$d.Id] = $b
        $dx += $b.Width + 8
    }
    $dockHint = CW-Label -Text '' -X 18 -Y 80 -W ($RW - 36) -H 18 -Color $CW.Tx3 -Size 8
    $s2.Controls.Add($dockHint)

    # --- 卡片 S3：外观与显示（配色 | 透明度 | 折叠态显示数量）---
    # 配色与透明度并排一行：两者都是「一眼看到的效果」，放一起对比着调最直观
    $s3 = New-Object System.Windows.Forms.Panel
    $s3.Location = New-Object System.Drawing.Point $RX, 290
    $s3.Size = New-Object System.Drawing.Size $RW, 180
    $s3.BackColor = CC $CW.Card
    $form.Controls.Add($s3)
    $sysCtrls += $s3
    $s3.Controls.Add((CW-Label -Text '外观与显示' -X 18 -Y 14 -W 200 -H 22 -Color $CW.Tx -Size 10 -Bold))

    # 左：配色
    $s3.Controls.Add((CW-Label -Text '配色' -X 18 -Y 44 -W 100 -H 18 -Color $CW.Tx3 -Size 8))
    $themeDefs = @(
        @{ Id = 'dark';  Text = '深色' },
        @{ Id = 'light'; Text = '浅色' }
    )
    $themeButtons = @{}
    $tx = 18
    foreach ($d in $themeDefs) {
        $b = CW-Chip -Text $d.Text -X $tx -Y 64 -H 30 -On $false -Tag2 $d.Id
        $s3.Controls.Add($b)
        $themeButtons[$d.Id] = $b
        $tx += $b.Width + 8
    }

    # 右：透明度（100 / 70 / 50 / 30）
    $s3.Controls.Add((CW-Label -Text '透明度' -X 200 -Y 44 -W 120 -H 18 -Color $CW.Tx3 -Size 8))
    $opacityDefs = @(
        @{ Id = '1';   Text = '100%' },
        @{ Id = '0.7'; Text = '70%' },
        @{ Id = '0.5'; Text = '50%' },
        @{ Id = '0.3'; Text = '30%' }
    )
    $opacityButtons = @{}
    $ox = 200
    foreach ($d in $opacityDefs) {
        $b = CW-Chip -Text $d.Text -X $ox -Y 64 -H 30 -On $false -Tag2 $d.Id
        $s3.Controls.Add($b)
        $opacityButtons[$d.Id] = $b
        $ox += $b.Width + 8
    }

    # 配色与透明度的说明合并成一行，横跨整行（两句分开写会挤出卡片）
    $themeHint = CW-Label -Text '' -X 18 -Y 102 -W ($RW - 36) -H 18 -Color $CW.Tx3 -Size 8
    $s3.Controls.Add($themeHint)

    $s3.Controls.Add((CW-Label -Text '悬浮窗显示数量（1–5）' -X 18 -Y 124 -W 220 -H 18 -Color $CW.Tx3 -Size 8))
    $tbMaxItems = CW-Text -X 18 -Y 142 -W 90 -H 26 -Value ([string]$script:EditCfg.maxDockItems)
    $s3.Controls.Add($tbMaxItems)
    $maxItemsHint = CW-Label -Text '只影响折叠态，展开态始终显示全部账户' -X 120 -Y 146 -W ($RW - 138) -H 18 -Color $CW.Tx3 -Size 8
    $s3.Controls.Add($maxItemsHint)

    # --- 卡片 S4：启动与查询 ---
    $s4 = New-Object System.Windows.Forms.Panel
    $s4.Location = New-Object System.Drawing.Point $RX, 480
    $s4.Size = New-Object System.Drawing.Size $RW, 180
    $s4.BackColor = CC $CW.Card
    $form.Controls.Add($s4)
    $sysCtrls += $s4
    $s4.Controls.Add((CW-Label -Text '启动与查询' -X 18 -Y 14 -W 200 -H 22 -Color $CW.Tx -Size 10 -Bold))

    $s4.Controls.Add((CW-Label -Text '开机自动启动' -X 18 -Y 48 -W 200 -H 22 -Color $CW.Tx2 -Size 9))
    $autoOn = [bool]$script:EditCfg.startWithBoot
    if (Get-Command Get-AutostartEnabled -ErrorAction SilentlyContinue) {
        try { $autoOn = Get-AutostartEnabled } catch { }
    }
    $swAuto = CW-Switch -X ($RW - 62) -Y 46 -On $autoOn
    $s4.Controls.Add($swAuto)
    $autoHint = CW-Label -Text '' -X 18 -Y 74 -W ($RW - 36) -H 18 -Color $CW.Tx3 -Size 8
    $s4.Controls.Add($autoHint)

    $s4.Controls.Add((CW-Label -Text '超时时间（秒）' -X 18 -Y 104 -W 210 -H 18 -Color $CW.Tx3 -Size 8))
    $s4.Controls.Add((CW-Label -Text '自动查询间隔（分钟，0 表示不查询）' -X 250 -Y 104 -W 340 -H 18 -Color $CW.Tx3 -Size 8))
    $tbTimeout = CW-Text -X 18 -Y 124 -W 210 -H 28 -Value ([string]$script:EditCfg.timeout)
    $s4.Controls.Add($tbTimeout)
    $tbInterval = CW-Text -X 250 -Y 124 -W 210 -H 28 -Value ([string]$script:EditCfg.refreshMinutes)
    $s4.Controls.Add($tbInterval)

    # --- 卡片 S5：关于 ---
    $s5 = New-Object System.Windows.Forms.Panel
    $s5.Location = New-Object System.Drawing.Point $RX, 672
    $s5.Size = New-Object System.Drawing.Size $RW, 100
    $s5.BackColor = CC $CW.Card
    $form.Controls.Add($s5)
    $sysCtrls += $s5
    $s5.Controls.Add((CW-Label -Text '关于' -X 18 -Y 14 -W 200 -H 22 -Color $CW.Tx -Size 10 -Bold))
    $s5.Controls.Add((CW-Label -Text ($script:AppName + '  v' + $script:AppVersion + '  ' + $script:AppChannel) `
        -X 18 -Y 42 -W ($RW - 36) -H 20 -Color $CW.Tx -Size 9 -Bold))
    $cfgPathShow = $script:ConfigPath
    if ($cfgPathShow.Length -gt 72) { $cfgPathShow = $cfgPathShow.Substring(0, 69) + '...' }
    $s5.Controls.Add((CW-Label -Text ('配置文件：' + $cfgPathShow) -X 18 -Y 66 -W ($RW - 36) -H 18 -Color $CW.Tx3 -Size 8))

    # ==================== 底部操作栏 ====================
    $bottomY = $H - 58
    $sepBottom = New-Object System.Windows.Forms.Panel
    $sepBottom.Location = New-Object System.Drawing.Point 0, $bottomY
    $sepBottom.Size = New-Object System.Drawing.Size $W, 1
    $sepBottom.BackColor = CC $CW.Line
    $form.Controls.Add($sepBottom)

    $btnTest = CW-Btn -Text '▶  测试脚本' -X ($W - 420) -Y ($bottomY + 12) -W 110 -H 34 -Kind 'ghost'
    $btnCancel = CW-Btn -Text '取消' -X ($W - 190) -Y ($bottomY + 12) -W 76 -H 34 -Kind 'ghost'
    $btnSave = CW-Btn -Text '保存配置' -X ($W - 106) -Y ($bottomY + 12) -W 84 -H 34 -Kind 'primary'
    $form.Controls.Add($btnTest)
    $form.Controls.Add($btnCancel)
    $form.Controls.Add($btnSave)

    # ==================== 逻辑 ====================
    $script:CurTpl = $script:EditCfg.providers[0].tpl
    $script:CurType = $script:EditCfg.providers[0].type
    $script:CWPage = 'account'
    $script:presetButtons = @{}
    $script:presetBaseH = $maxPresetH

    # 界面缩放说明文案
    function Get-ScaleHint {
        param([string]$Id)
        switch ($Id) {
            '50'   { return '整体缩小到 50%，小屏笔记本上能一屏看全。点完立即生效。' }
            '75'   { return '整体缩小到 75%。点完立即生效。' }
            '100'  { return '基准大小（1:1）。点完立即生效。' }
            '150'  { return '整体放大到 150%，适合高分屏。超出屏幕时程序会自动降档。' }
            default { return '自适应：按屏幕可用空间自动缩放，最大 100%（不会放大）。点完立即生效。' }
        }
    }

    function Update-SystemHints {
        $sc = [string]$script:EditCfg.uiScale
        if (-not $sc) { $sc = 'auto' }
        foreach ($k in $scaleButtons.Keys) { Set-ChipState $scaleButtons[$k] ($k -eq $sc) }
        $scaleHint.Text = Get-ScaleHint $sc

        $ds = [double]$script:EditCfg.dockScale
        if ($ds -le 0) { $ds = 1.0 }
        $dsKey = if ($ds -lt 0.9) { '0.75' } elseif ($ds -gt 1.1) { '1.25' } else { '1' }
        foreach ($k in $dockButtons.Keys) { Set-ChipState $dockButtons[$k] ($k -eq $dsKey) }
        $u = [int][Math]::Round($DOCK_W * $ds)
        $dockHint.Text = ('单账户浮窗约 ' + $u + '×' + $u + ' 像素（基准 ' + $DOCK_W + '×' + $DOCK_W + '）。点完立即生效。')

        # 配色 + 透明度：两句说明合成一行，否则卡片放不下
        $th = [string]$script:EditCfg.theme
        if ($th -notin @('dark', 'light')) { $th = 'dark' }
        foreach ($k in $themeButtons.Keys) { Set-ChipState $themeButtons[$k] ($k -eq $th) }

        $opv = [double]$script:EditCfg.opacity
        if ($opv -le 0) { $opv = 1.0 }
        $opKey = if ($opv -ge 0.95) { '1' } elseif ($opv -ge 0.6) { '0.7' } elseif ($opv -ge 0.4) { '0.5' } else { '0.3' }
        foreach ($k in $opacityButtons.Keys) { Set-ChipState $opacityButtons[$k] ($k -eq $opKey) }

        $thTxt = if ($th -eq 'light') { '浅色：白底深字，接近 Windows 11 浅色主题。' } else { '深色：默认配色，长时间挂着不刺眼。' }
        $opTxt = switch ($opKey) {
            '1'     { '完全不透明，最清晰。' }
            '0.7'   { '略透，仍然清晰可读。' }
            '0.5'   { '半透明，文字开始变淡。' }
            default { '很淡，只留轮廓，适合不想被打扰时。' }
        }
        $themeHint.Text = $thTxt + ' ｜ 透明度 ' + [int][Math]::Round($opv * 100) + '%：' + $opTxt + ' 点完立即生效。'

        # 折叠态显示数量
        $mi = 0
        if (-not [int]::TryParse([string]$script:EditCfg.maxDockItems, [ref]$mi)) { $mi = 3 }
        if ($mi -lt 1) { $mi = 1 }
        if ($mi -gt 5) { $mi = 5 }
        $n = @($script:EditCfg.providers).Count
        $real = if ($mi -gt $n) { $n } else { $mi }
        $maxItemsHint.Text = ('当前填 ' + $mi + '，账户共 ' + $n + ' 个 → 折叠态显示 ' + $real + ' 个。保存后生效。')

        $on = [bool]$swAuto.Tag
        $autoHint.Text = if ($on) {
            '已开启：登录 Windows 后自动启动，注册表 HKCU\...\Run\TokenPocket'
        } else {
            '已关闭。开启后写入 HKCU\...\Run，不需要管理员权限。'
        }
        $autoHint.ForeColor = if ($on) { CC $CW.Cy } else { CC $CW.Tx3 }
    }

    # ---- 悬浮窗预览的回滚基准（取消/关闭时还原，避免"没保存却生效了"）----
    $script:DockOrigScale = 1.0
    try { $script:DockOrigScale = [double]$Cfg.dockScale } catch { }
    if ($script:DockOrigScale -le 0) { $script:DockOrigScale = 1.0 }
    $script:ThemeOrig = if ([string]$Cfg.theme -eq 'light') { 'light' } else { 'dark' }
    $script:OpacityOrig = 1.0
    try { $script:OpacityOrig = [double]$Cfg.opacity } catch { }
    if ($script:OpacityOrig -le 0) { $script:OpacityOrig = 1.0 }
    function Restore-DockPreview {
        if (Get-Command Preview-DockScale -ErrorAction SilentlyContinue) {
            try { Preview-DockScale -V $script:DockOrigScale } catch { }
        }
        # 配色也一起回滚，否则「点了浅色又取消」会留在浅色
        if (Get-Command Preview-Theme -ErrorAction SilentlyContinue) {
            try { Preview-Theme -Name $script:ThemeOrig } catch { }
        }
        # 透明度同理：点了 30% 又取消，不能留在 30%
        if (Get-Command Preview-Opacity -ErrorAction SilentlyContinue) {
            try { Preview-Opacity -V $script:OpacityOrig } catch { }
        }
    }

    # ---- 提取器展示：字段一改就重算，保证「看到的代码 == 实际会执行的逻辑」----
    function Update-Extractor {
        $tpl = $script:CurTpl
        try { $lblVars.Text = Get-TemplateVars $tpl } catch { }
        try {
            $tbCode.Text = Get-ExtractorPreview -Tpl $tpl -Type $script:CurType `
                -Url $tbUrl.Text.Trim() -ValuePath $tbValuePath.Text.Trim() `
                -Scale $tbScale.Text.Trim() -Unit $tbUnit.Text.Trim()
        } catch { $tbCode.Text = '// 生成失败：' + $_.Exception.Message }
    }

    # ---- 页面切换 ----
    function Show-Page {
        param([string]$Page)
        $script:CWPage = $Page
        $isAcc = ($Page -eq 'account')
        $card1.Visible = $isAcc
        $card2.Visible = $isAcc
        foreach ($c in $sysCtrls) { $c.Visible = -not $isAcc }
        $btnTest.Visible = $isAcc
        $accountHost.Visible = $isAcc
        $listTitle.Text = if ($isAcc) { '账户' } else { '系统' }
        $btnPage.Text = if ($isAcc) { '⚙  系统配置' } else { '←  返回账户' }
        Resize-ForPage
        if (-not $isAcc) { Update-SystemHints }
    }

    $btnPage.Add_Click({ Show-Page -Page $(if ($script:CWPage -eq 'account') { 'system' } else { 'account' }) })

    # ---- 当前模板所需高度 -> 窗口跟着伸缩 ----
    function Resize-ForPage {
        if ($script:CWPage -eq 'system') {
            $nh = $SYS_H
        } else {
            $yy = 0
            foreach ($key in $layoutMap[$script:CurTpl]) {
                $hh = if ($key -eq 'preset') { $script:presetBaseH } else { $ROW_H }
                $yy += $hh + $ROW_GAP
            }
            $c2h = $yDyn + $yy + 2 + 40 + 10 + $EXTRACT_H + 12
            $card2.Height = X $c2h
            $nh = $CARD2_Y + $c2h + 78
        }
        $by = $nh - 58
        $sepBottom.Top = X $by
        $btnTest.Top = X ($by + 12)
        $btnCancel.Top = X ($by + 12)
        $btnSave.Top = X ($by + 12)
        $listPanel.Height = X ($nh - 128)
        # 账户列表要给底部「系统配置」按钮让出 42+ 的空间，否则会盖住按钮
        $accountHost.Height = X ($nh - 214)
        $btnPage.Top = X ($nh - 170)
        $form.Height = X $nh
    }

    function Rebuild-Presets {
        param([string]$Tpl, [string]$CurId)
        foreach ($c in @($presetHost.Controls)) {
            $presetHost.Controls.Remove($c)
            $c.Dispose()
        }
        $script:presetButtons = @{}
        $presets = @(Get-ProviderPresets -Tpl $Tpl)
        $fM = CW-Font -Size 9
        $px = 0; $py = 0
        foreach ($p in $presets) {
            $bw = [System.Windows.Forms.TextRenderer]::MeasureText($p.Label, $fM).Width + (X 26)
            if ($px + $bw -gt $presetHost.Width) { $px = 0; $py += (X 36) }
            $b = CW-Chip -Text $p.Label -X $px -Y $py -W $bw -H (X 30) -On ($p.Id -eq $CurId) -Tag2 $p.Id
            $b.Add_Click({
                param($s, $e)
                $id = [string]$s.Tag
                $preset = Get-PresetById $id $script:CurTpl
                foreach ($k2 in $script:presetButtons.Keys) { Set-ChipState $script:presetButtons[$k2] ($k2 -eq $id) }
                $script:CurType = $id
                $i = $script:EditIdx
                if ($i -ge 0 -and $i -lt $script:EditCfg.providers.Count) {
                    $script:EditCfg.providers[$i].type = $id
                    $script:EditCfg.providers[$i].authMode = $preset.Auth
                }
                if ($script:CurTpl -in @('tokenplan', 'balance', 'official')) { $tbUrl.Text = $preset.Url }
                $tbShort.Text = $preset.Short
                if (-not $tbName.Text -or $tbName.Text -eq '新账户') { $tbName.Text = $preset.Label }
                $statusText.Text = $preset.Hint
                $statusText.ForeColor = CC $CW.Tx3
                if ($script:CurTpl -eq 'official') { Update-OfficialHint }
                Update-Extractor
            })
            $presetHost.Controls.Add($b)
            $script:presetButtons[$p.Id] = $b
            $px += $bw + (X 8)
        }
        $fM.Dispose()
        $needBase = if ($presets.Count -eq 0) { 0 } else { 18 + [int][Math]::Round($py / $script:cwF) + 36 }
        $script:presetBaseH = [Math]::Max(18, $needBase)
        $rowPreset.Height = X $script:presetBaseH
        $presetHost.Height = X ([Math]::Max(1, $script:presetBaseH - 18))
    }

    function Update-OfficialHint {
        $path = if ($script:CurType -eq 'claude') { '~/.claude/.credentials.json' } else { '~/.codex/auth.json' }
        $tok = if ($script:CurType -eq 'claude') { Get-ClaudeOAuthToken } else { Get-CodexOAuthToken }
        $lblOfficial.ForeColor = if ($tok) { CC $CW.Cy } else { CC $CW.Am }
        $lblOfficial.Text = if ($tok) {
            '✓ 已在本机找到 OAuth 凭据，无需填写 API Key。点「测试脚本」查询订阅额度。'
        } else {
            '✗ 未找到 OAuth 凭据（' + $path + '）。官方额度需先用对应 CLI 登录一次；' +
            '若用的是 API Key 方式，请改用 Token Plan 或自定义模板。'
        }
    }

    function Apply-TemplateLayout {
        param([string]$Tpl)
        $order = $layoutMap[$Tpl]
        if (-not $order) { $order = $layoutMap['custom'] }
        $y = $yDyn
        foreach ($k in $order) {
            $row = $rows[$k]
            if (-not $row) { continue }
            $row.Visible = $true
            $row.Top = X $y
            $hh = if ($k -eq 'preset') { $script:presetBaseH } else { $ROW_H }
            $y += $hh + $ROW_GAP
        }
        foreach ($k in $rows.Keys) {
            if ($order -notcontains $k) { $rows[$k].Visible = $false }
        }
        $statusBar.Top = X ($y + 2)
        $extractBlock.Top = X ($y + 2 + 40 + 10)
        switch ($Tpl) {
            'general' { $lblUrl.Text = 'Base URL（程序自动拼 /user/balance）' }
            'newapi'  { $lblUrl.Text = '站点地址（程序自动拼 /api/user/self）' }
            default   { $lblUrl.Text = 'API 地址' }
        }
        Update-Extractor
    }

    function Set-Template {
        param([string]$Id)
        $script:CurTpl = $Id
        foreach ($k in $tplButtons.Keys) { Set-ChipState $tplButtons[$k] ($k -eq $Id) }
        $tplHint.Text = (Get-TemplateById $Id).Hint
        $i = $script:EditIdx
        if ($i -ge 0 -and $i -lt $script:EditCfg.providers.Count) {
            $script:EditCfg.providers[$i].tpl = $Id
        }
        $ps = @(Get-ProviderPresets -Tpl $Id)
        $valid = @($ps | ForEach-Object { $_.Id })
        if ($valid -notcontains $script:CurType) {
            $script:CurType = $ps[0].Id
            if ($i -ge 0 -and $i -lt $script:EditCfg.providers.Count) {
                $script:EditCfg.providers[$i].type = $script:CurType
                $script:EditCfg.providers[$i].authMode = $ps[0].Auth
            }
            if ($Id -in @('tokenplan', 'balance', 'official')) { $tbUrl.Text = $ps[0].Url }
        }
        Rebuild-Presets -Tpl $Id -CurId $script:CurType
        Apply-TemplateLayout -Tpl $Id
        Resize-ForPage
        if ($Id -eq 'official') { Update-OfficialHint }
    }

    function Load-AccountToUI {
        $i = $script:EditIdx
        if ($i -lt 0 -or $i -ge $script:EditCfg.providers.Count) { return }
        $a = $script:EditCfg.providers[$i]
        $tbName.Text = $a.name
        $tbShort.Text = $a.short
        $tbUrl.Text = $a.apiUrl
        $tbKey.Text = Unprotect-String $a.apiKey
        $tbAccess.Text = Unprotect-String $a.accessToken
        $tbUserId.Text = [string]$a.userId
        $tbValuePath.Text = [string]$a.valuePath
        $tbResetPath.Text = [string]$a.resetPath
        $tbScale.Text = if ($a.scale) { [string]$a.scale } else { '1' }
        $tbUnit.Text = if ($a.unit) { [string]$a.unit } else { '%' }
        $swEnable.Tag = [bool]$a.enabled
        $swEnable.Invalidate()
        $script:CurType = $a.type
        Set-Template -Id $a.tpl
    }

    function Rebuild-AccountList {
        $accountHost.Controls.Clear()
        $y = 0
        for ($i = 0; $i -lt $script:EditCfg.providers.Count; $i++) {
            $a = $script:EditCfg.providers[$i]
            $btn = New-Object System.Windows.Forms.Button
            $btn.Text = $a.short
            $btn.Location = New-Object System.Drawing.Point (X 10), (X $y)
            $btn.Size = New-Object System.Drawing.Size (X 180), (X 32)
            $btn.FlatStyle = 'Flat'
            $btn.FlatAppearance.BorderSize = 0
            $btn.TextAlign = 'MiddleLeft'
            $btn.Padding = New-Object System.Windows.Forms.Padding (X 10), 0, 0, 0
            $btn.Cursor = 'Hand'
            $isOn = ($i -eq $script:EditIdx)
            $btn.BackColor = if ($isOn) { CC $CW.Sel } else { CC $CW.Card }
            $btn.ForeColor = if ($isOn) { CC $CW.Tx } else { CC $CW.Tx2 }
            $btn.Font = CW-Font -Size 9
            $btn.Tag = $i
            $btn.Add_Click({
                param($s, $e)
                Save-UIToAccount
                $script:EditIdx = [int]$s.Tag
                Rebuild-AccountList
                Load-AccountToUI
            })
            $accountHost.Controls.Add($btn)
            $y += 36
        }

        $btnAdd = New-Object System.Windows.Forms.Button
        $btnAdd.Text = '+ 添加账户'
        $btnAdd.Location = New-Object System.Drawing.Point (X 10), (X $y)
        $btnAdd.Size = New-Object System.Drawing.Size (X 180), (X 30)
        $btnAdd.FlatStyle = 'Flat'
        $btnAdd.FlatAppearance.BorderSize = 1
        $btnAdd.FlatAppearance.BorderColor = CC $CW.Line
        $btnAdd.BackColor = CC $CW.Card
        $btnAdd.ForeColor = CC $CW.Tx2
        $btnAdd.Font = CW-Font -Size 9
        $btnAdd.Cursor = 'Hand'
        $btnAdd.Add_Click({
            Save-UIToAccount
            $np = New-ProviderObject -Preset (Get-PresetById 'minimax' 'tokenplan') -Tpl 'tokenplan'
            $np.name = '新账户'
            $np.short = '新账户'
            $script:EditCfg.providers = @($script:EditCfg.providers) + @($np)
            $script:EditIdx = $script:EditCfg.providers.Count - 1
            Rebuild-AccountList
            Load-AccountToUI
        })
        $accountHost.Controls.Add($btnAdd)

        # ---- 上移 / 下移：手动决定悬浮窗里的显示顺序 ----
        $moveDefs = @(
            @{ Text = '↑  上移'; Dx = 10;  Dy = ($y + 38);  D = -1 },
            @{ Text = '↓  下移'; Dx = 100; Dy = ($y + 38);  D = 1 }
        )
        foreach ($mv in $moveDefs) {
            $b = New-Object System.Windows.Forms.Button
            $b.Text = $mv.Text
            $b.Location = New-Object System.Drawing.Point (X $mv.Dx), (X $mv.Dy)
            $b.Size = New-Object System.Drawing.Size (X 84), (X 30)
            $b.FlatStyle = 'Flat'
            $b.FlatAppearance.BorderSize = 1
            $b.FlatAppearance.BorderColor = CC $CW.Line
            $b.BackColor = CC $CW.Field
            $b.ForeColor = CC $CW.Tx2
            $b.Font = CW-Font -Size 9
            $b.Cursor = 'Hand'
            $b.Tag = [int]$mv.D
            $b.Add_Click({
                param($s, $e)
                $dir = [int]$s.Tag
                $i = $script:EditIdx
                $n = @($script:EditCfg.providers).Count
                $j = $i + $dir
                if ($i -lt 0 -or $j -lt 0 -or $j -ge $n) { return }
                Save-UIToAccount
                $list = @($script:EditCfg.providers)
                $tmp = $list[$i]
                $list[$i] = $list[$j]
                $list[$j] = $tmp
                $script:EditCfg.providers = $list
                $script:EditIdx = $j
                Rebuild-AccountList
                Load-AccountToUI
            })
            $accountHost.Controls.Add($b)
        }

        $btnDel = New-Object System.Windows.Forms.Button
        $btnDel.Text = '− 删除选中'
        $btnDel.Location = New-Object System.Drawing.Point (X 10), (X ($y + 74))
        $btnDel.Size = New-Object System.Drawing.Size (X 174), (X 30)
        $btnDel.FlatStyle = 'Flat'
        $btnDel.FlatAppearance.BorderSize = 1
        $btnDel.FlatAppearance.BorderColor = CC $CW.DelLine
        $btnDel.BackColor = CC $CW.Card
        $btnDel.ForeColor = CC $CW.DelFg
        $btnDel.Font = CW-Font -Size 9
        $btnDel.Cursor = 'Hand'
        $btnDel.Add_Click({
            if ($script:EditCfg.providers.Count -le 1) { return }
            $list = @($script:EditCfg.providers)
            $newList = @()
            for ($k = 0; $k -lt $list.Count; $k++) {
                if ($k -ne $script:EditIdx) { $newList += $list[$k] }
            }
            $script:EditCfg.providers = $newList
            $script:EditIdx = 0
            Rebuild-AccountList
            Load-AccountToUI
        })
        $accountHost.Controls.Add($btnDel)
    }

    function Save-UIToAccount {
        $i = $script:EditIdx
        if ($i -lt 0 -or $i -ge $script:EditCfg.providers.Count) { return }
        $a = $script:EditCfg.providers[$i]
        $a.name = $tbName.Text.Trim()
        $a.short = $tbShort.Text.Trim()
        $a.tpl = $script:CurTpl
        $a.type = $script:CurType
        $a.apiUrl = $tbUrl.Text.Trim()
        $a.valuePath = $tbValuePath.Text.Trim()
        $a.resetPath = $tbResetPath.Text.Trim()
        $scv = 0.0
        $a.scale = if ([double]::TryParse($tbScale.Text.Trim(), [ref]$scv) -and $scv -gt 0) { $scv } else { 1 }
        $a.unit = if ($tbUnit.Text.Trim()) { $tbUnit.Text.Trim() } else { '%' }
        # 只保存本模板用得到的凭据，避免切换模板时把别的字段覆盖成空
        switch ($script:CurTpl) {
            'newapi' {
                $a.accessToken = Protect-String $tbAccess.Text.Trim()
                $a.userId = $tbUserId.Text.Trim()
            }
            'official' { }
            default {
                $a.apiKey = Protect-String $tbKey.Text.Trim()
            }
        }
        if (-not $a.short) { $a.short = $a.name }
    }

    # ---- 模板标签点击 ----
    foreach ($k in $tplButtons.Keys) {
        $btn = $tplButtons[$k]
        $btn.Add_Click({
            param($s, $e)
            Save-UIToAccount
            Set-Template -Id ([string]$s.Tag)
        })
    }

    # ---- 字段改动 → 提取器代码跟着变 ----
    foreach ($tb in @($tbUrl, $tbValuePath, $tbScale, $tbUnit)) {
        $tb.Add_TextChanged({ Update-Extractor })
    }

    # ---- 界面缩放 chips ----
    # 原来只改配置不重建窗口，用户点完毫无反应，以为坏了。
    # 这里改成「点完立刻重建窗口」：Form.Scale 增量缩放会累积舍入误差，
    # 重建一次最干净，视觉上只是闪一下，未保存的编辑全都带着走。
    foreach ($k in $scaleButtons.Keys) {
        $b = $scaleButtons[$k]
        $b.Add_Click({
            param($s, $e)
            $newId = [string]$s.Tag
            if ([string]$script:EditCfg.uiScale -eq $newId) { Update-SystemHints; return }
            $script:EditCfg.uiScale = $newId
            if ($script:NoRescale) { Update-SystemHints; return }
            $script:ReopenPage = $script:CWPage
            $script:ReopenTpl = $script:CurTpl
            $script:ReopenPos = $form.Location
            $form.Tag = 'rescale'
            $form.Close()
        })
    }

    # ---- 悬浮大小 chips：立即预览主悬浮窗（不用先保存）----
    foreach ($k in $dockButtons.Keys) {
        $b = $dockButtons[$k]
        $b.Add_Click({
            param($s, $e)
            $v = [double]$s.Tag
            $script:EditCfg.dockScale = $v
            Update-SystemHints
            if (Get-Command Preview-DockScale -ErrorAction SilentlyContinue) {
                try { Preview-DockScale -V $v } catch { }
            }
        })
    }

    # ---- 配色 chips：立即换色，并重建配置页（配置页自己也要跟着换）----
    foreach ($k in $themeButtons.Keys) {
        $b = $themeButtons[$k]
        $b.Add_Click({
            param($s, $e)
            $newId = [string]$s.Tag
            if ([string]$script:EditCfg.theme -eq $newId) { Update-SystemHints; return }
            $script:EditCfg.theme = $newId
            if (Get-Command Preview-Theme -ErrorAction SilentlyContinue) {
                try { Preview-Theme -Name $newId } catch { }
            }
            if ($script:NoRescale) { Update-SystemHints; return }
            $script:ReopenPage = $script:CWPage
            $script:ReopenTpl = $script:CurTpl
            $script:ReopenPos = $form.Location
            $form.Tag = 'rescale'
            $form.Close()
        })
    }

    # ---- 透明度 chips：立即作用到主悬浮窗，取消时由 Restore-DockPreview 回滚 ----
    foreach ($k in $opacityButtons.Keys) {
        $b = $opacityButtons[$k]
        $b.Add_Click({
            param($s, $e)
            $v = 1.0
            [void][double]::TryParse([string]$s.Tag, [ref]$v)
            $script:EditCfg.opacity = $v
            if (Get-Command Preview-Opacity -ErrorAction SilentlyContinue) {
                try { Preview-Opacity -V $v } catch { }
            }
            Update-SystemHints
        })
    }

    # ---- 开机启动开关 ----
    $swAuto.Add_Click({
        param($s, $e)
        # 先走开关自身的翻转逻辑，再落到注册表
        $on = [bool]$s.Tag
        $ok = $true
        if (Get-Command Set-AutostartEnabled -ErrorAction SilentlyContinue) {
            $ok = Set-AutostartEnabled -Enable $on
        }
        if (-not $ok) {
            # 写失败就回滚显示，避免界面与真实状态不一致
            $s.Tag = -not $on
            $s.Invalidate()
            $script:EditCfg.startWithBoot = -not $on
        } else {
            $script:EditCfg.startWithBoot = $on
        }
        Update-SystemHints
    })

    # ---- 自动探测 ----
    $btnProbe.Add_Click({
        $btnProbe.Enabled = $false
        $btnProbe.Text = '探测中…'
        [System.Windows.Forms.Application]::DoEvents()
        $found = Find-WorkingKey -Type $script:CurType -Tpl $script:CurTpl
        if ($found) {
            $tbKey.Text = $found.Key
            $statusText.Text = '✓ 从 ' + $found.Src + ' 找到可用 Key'
            $statusText.ForeColor = CC $CW.Cy
        } else {
            $statusText.Text = '✗ 未找到可用 Key，请手动填写'
            $statusText.ForeColor = CC $CW.Am
        }
        $btnProbe.Enabled = $true
        $btnProbe.Text = '自动探测'
    })

    # ---- 测试脚本 ----
    $btnTest.Add_Click({
        $btnTest.Enabled = $false
        $statusText.Text = '正在测试…'
        $statusText.ForeColor = CC $CW.Tx3
        [System.Windows.Forms.Application]::DoEvents()

        $probe = [pscustomobject]@{
            name           = $tbName.Text
            tpl            = $script:CurTpl
            type           = $script:CurType
            apiUrl         = $tbUrl.Text.Trim()
            apiKey         = ''
            accessToken    = ''
            userId         = $tbUserId.Text.Trim()
            authMode       = (Get-PresetById $script:CurType $script:CurTpl).Auth
            refreshMinutes = 5
            enabled        = $true
            valuePath      = $tbValuePath.Text.Trim()
            resetPath      = $tbResetPath.Text.Trim()
            scale          = $(if ($tbScale.Text.Trim()) { $tbScale.Text.Trim() } else { '1' })
            unit           = $(if ($tbUnit.Text.Trim()) { $tbUnit.Text.Trim() } else { '%' })
        }
        $r = if ($script:CurTpl -eq 'newapi') {
            $probe.accessToken = Protect-String $tbAccess.Text.Trim()
            Invoke-Provider -Provider $probe
        } else {
            Invoke-Provider -Provider $probe -OverrideKey $tbKey.Text.Trim()
        }

        if ($r.Ok) {
            $parts = @()
            foreach ($t in $r.Tiers) { $parts += ('{0} {1}' -f $t.Name, $t.Display) }
            $statusText.Text = '✓ 连接成功 · ' + ($parts -join ' · ')
            $statusText.ForeColor = CC $CW.Cy
        } else {
            $statusText.Text = '✗ ' + $r.Error
            $statusText.ForeColor = CC $CW.Rd
        }
        $btnTest.Enabled = $true
    })

    # ---- 取消 ----
    $btnCancel.Add_Click({ $form.Tag = 'cancel'; $form.Close() })

    # ---- 保存 ----
    $btnSave.Add_Click({
        if ($script:CWPage -eq 'account') { Save-UIToAccount }
        $i = $script:EditIdx
        if ($i -ge 0 -and $i -lt $script:EditCfg.providers.Count) {
            $script:EditCfg.providers[$i].enabled = [bool]$swEnable.Tag
        }
        # 全局项（系统配置页）
        $script:EditCfg.timeout = [int]($(if ($tbTimeout.Text -match '^\d+$') { $tbTimeout.Text } else { '15' }))
        $script:EditCfg.refreshMinutes = [int]($(if ($tbInterval.Text -match '^\d+$') { $tbInterval.Text } else { '5' }))
        $script:EditCfg.startWithBoot = [bool]$swAuto.Tag
        # 折叠态显示数量：1–5，非法值回落 3
        $mi = 0
        if ([int]::TryParse($tbMaxItems.Text.Trim(), [ref]$mi)) {
            if ($mi -lt 1) { $mi = 1 }
            if ($mi -gt 5) { $mi = 5 }
        } else { $mi = 3 }
        $script:EditCfg.maxDockItems = $mi
        Save-Config -Cfg $script:EditCfg
        $script:HttpTimeout = [int]$script:EditCfg.timeout
        Write-CoreLog ('配置已保存：账户 ' + $script:EditCfg.providers.Count +
            '，超时 ' + $script:EditCfg.timeout + 's' +
            '，缩放 ' + $script:EditCfg.uiScale + '，浮窗 ' + $script:EditCfg.dockScale +
            '，配色 ' + $script:EditCfg.theme + '，显示 ' + $script:EditCfg.maxDockItems + ' 个' +
            '，自启 ' + $script:EditCfg.startWithBoot)
        $form.Tag = 'saved'
        $form.Close()
    })

    # ==================== 应用界面缩放（只做一次）====================
    $scaleCfg = [string]$script:EditCfg.uiScale
    if (-not $scaleCfg) { $scaleCfg = 'auto' }
    $f = 1.0
    switch ($scaleCfg) {
        '50'  { $f = 0.50 }
        '75'  { $f = 0.75 }
        '100' { $f = 1.00 }
        '150' { $f = 1.50 }
        default {
            # 自适应：按屏幕可用逻辑尺寸缩小，最大 100%（不放大，保证默认观感不变）
            $dpiF = 1.0
            try {
                $null = $form.Handle
                $dv = [NativeWin]::GetDpiForWindow($form.Handle)
                if ($dv -gt 0) { $dpiF = $dv / 96.0 }
            } catch { }
            $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $lw = $wa.Width / $dpiF
            $lh = $wa.Height / $dpiF
            $fit = [Math]::Min(($lw - 60) / $W, ($lh - 60) / $H)
            $f = [Math]::Min(1.0, $fit)
            if ($f -lt 0.5) { $f = 0.5 }
            $f = [Math]::Round($f * 20) / 20     # 取整到 5% 档
        }
    }
    # 兜底：缩放后不能超出屏幕工作区（新加了提取器区块，150% 在小屏上会把底部按钮顶出屏幕）
    try {
        $wa2 = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $maxF = [Math]::Min((($wa2.Height - 48) / [double]$form.Height), (($wa2.Width - 48) / [double]$form.Width))
        if ($maxF -gt 0 -and $f -gt $maxF) {
            $f = [Math]::Floor($maxF * 20) / 20
            if ($f -lt 0.5) { $f = 0.5 }
        }
    } catch { }

    $script:cwF = $f
    # 给自测用：记录本次构建实际采用的缩放系数与窗口尺寸
    $script:CWLastF = $f
    if ([Math]::Abs($f - 1.0) -gt 0.001) {
        $form.Scale((New-Object System.Drawing.SizeF ([single]$f), ([single]$f)))
        # Form.Scale 只缩 Bounds，字体要单独走一遍；之后新建的控件由 CW-Font 直接按 f 生成
        Scale-CtrlFonts -Ctl $form -Factor ([single]$f)
    }

    # ---- 初始化 ----
    Rebuild-AccountList
    Load-AccountToUI
    Update-SystemHints
    Show-Page -Page 'account'
    if ($StartTpl -and $StartTpl -ne $script:CurTpl) { Set-Template -Id $StartTpl }
    if ($OnlyPage) { Show-Page -Page $OnlyPage }
    elseif ($StartPage -in @('account', 'system')) { Show-Page -Page $StartPage }

    # ---- 只量尺寸（验证缩放是否真的生效）----
    if ($ProbeSize) {
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point 20, 20
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        $sz = ([string]$form.Width + 'x' + [string]$form.Height)
        $form.Close()
        $form.Dispose()
        return $sz
    }

    # ---- 交互自测：程序化点击控件，验证点击真的落到配置/注册表 ----
    if ($TestInteractions) {
        $bk = $script:ConfigPath + '.testbak'
        Copy-Item $script:ConfigPath $bk -Force
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point 20, 20
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()

        $tp = 0; $tf = 0
        $results = @()
        function CHK([string]$n, [bool]$ok, [string]$d = '') {
            if ($ok) { $script:tp++ } else { $script:tf++ }
            Write-Host ('  [' + $(if ($ok) { 'OK  ' } else { 'FAIL' }) + '] ' + $n + $(if ($d) { '  → ' + $d } else { '' }))
        }
        $script:tp = 0; $script:tf = 0
        $mi = [System.Windows.Forms.Control].GetMethod('OnClick', [System.Reflection.BindingFlags]'Instance,NonPublic')
        # 反射调 OnClick 时不能直接传 @((New-Object EventArgs))：
        # PowerShell 会把参数包成 PSObject，Invoke 报类型不匹配。必须显式 object[]
        $clickArgs = New-Object 'object[]' 1
        $clickArgs[0] = [System.EventArgs]::Empty

        # 1) 界面缩放
        Show-Page -Page 'system'
        [System.Windows.Forms.Application]::DoEvents()
        $scaleButtons['150'].PerformClick()
        CHK '点「150%」写入 uiScale' ($script:EditCfg.uiScale -eq '150') $script:EditCfg.uiScale
        $scaleButtons['75'].PerformClick()
        CHK '点「75%」写入 uiScale' ($script:EditCfg.uiScale -eq '75') $script:EditCfg.uiScale
        $scaleButtons['auto'].PerformClick()
        CHK '点「自适应」写入 uiScale' ($script:EditCfg.uiScale -eq 'auto') $script:EditCfg.uiScale

        # 2) 悬浮大小
        $dockButtons['0.75'].PerformClick()
        CHK '点「小」写入 dockScale' ([double]$script:EditCfg.dockScale -eq 0.75) $script:EditCfg.dockScale
        $dockButtons['1.25'].PerformClick()
        CHK '点「大」写入 dockScale' ([double]$script:EditCfg.dockScale -eq 1.25) $script:EditCfg.dockScale
        $dockButtons['1'].PerformClick()
        CHK '点「默认」写入 dockScale' ([double]$script:EditCfg.dockScale -eq 1.0) $script:EditCfg.dockScale

        # 2b) 透明度：既要写进配置，也要真的作用到主悬浮窗
        $opacityButtons['0.3'].PerformClick()
        CHK '点「30%」写入 opacity' ([Math]::Abs([double]$script:EditCfg.opacity - 0.3) -lt 0.001) $script:EditCfg.opacity
        $mainOp = 1.0
        try { $mainOp = $script:MainForm.Opacity } catch { }
        CHK '主悬浮窗立刻变 30% 透明' ([Math]::Abs($mainOp - 0.3) -lt 0.01) ('Opacity=' + $mainOp)
        $opacityButtons['0.7'].PerformClick()
        $mainOp = 1.0
        try { $mainOp = $script:MainForm.Opacity } catch { }
        CHK '点「70%」→ 窗口 0.7' ([Math]::Abs($mainOp - 0.7) -lt 0.01) ('Opacity=' + $mainOp)
        $opacityButtons['1'].PerformClick()
        $mainOp = 1.0
        try { $mainOp = $script:MainForm.Opacity } catch { }
        CHK '点「100%」→ 窗口回到 1.0' ([Math]::Abs($mainOp - 1.0) -lt 0.01) ('Opacity=' + $mainOp)

        # 2c) 取消回滚：点 30% 后走取消路径，必须回到打开时的值（用户特别要求的稳定性）
        $opBefore = 1.0
        try { $opBefore = $script:MainForm.Opacity } catch { }
        $opacityButtons['0.3'].PerformClick()
        $opMid = 1.0
        try { $opMid = $script:MainForm.Opacity } catch { }
        Restore-DockPreview
        $opAfter = 1.0
        try { $opAfter = $script:MainForm.Opacity } catch { }
        CHK '取消回滚：30% 恢复原值' (([Math]::Abs($opMid - 0.3) -lt 0.01) -and ([Math]::Abs($opAfter - $opBefore) -lt 0.01)) ('点后 ' + $opMid + ' → 回滚 ' + $opAfter)

        # 3) 开机自启（真实写注册表，测完复原）
        $before = if (Get-Command Get-AutostartEnabled -ErrorAction SilentlyContinue) { Get-AutostartEnabled } else { $false }
        $mi.Invoke($swAuto, $clickArgs)
        [System.Windows.Forms.Application]::DoEvents()
        $afterOn = if (Get-Command Get-AutostartEnabled -ErrorAction SilentlyContinue) { Get-AutostartEnabled } else { $false }
        CHK '点开机自启 → 注册表真的变了' ($afterOn -ne $before) ('注册表 ' + $afterOn)
        $mi.Invoke($swAuto, $clickArgs)
        [System.Windows.Forms.Application]::DoEvents()
        $afterOff = if (Get-Command Get-AutostartEnabled -ErrorAction SilentlyContinue) { Get-AutostartEnabled } else { $false }
        CHK '再点一次 → 注册表复原' ($afterOff -eq $before) ('注册表 ' + $afterOff)

        # 4) 模板切换 → provider.tpl 与字段行可见性
        Show-Page -Page 'account'
        [System.Windows.Forms.Application]::DoEvents()
        $tplButtons['newapi'].PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        CHK '点「NewAPI」写入 provider.tpl' ($script:EditCfg.providers[0].tpl -eq 'newapi') $script:EditCfg.providers[0].tpl
        CHK 'NewAPI 显示 AccessToken 行、隐藏 Key 行' ($rows['newapi'].Visible -and -not $rows['key'].Visible)
        $tplButtons['balance'].PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        CHK '点「账户余额」显示供应商行' ($rows['preset'].Visible -and -not $rows['url'].Visible)
        $tplButtons['tokenplan'].PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        CHK '点回「Token Plan」' ($script:EditCfg.providers[0].tpl -eq 'tokenplan') $script:EditCfg.providers[0].tpl

        # 5) 超时/间隔 + 保存落盘
        #    保存前把界面缩放/悬浮大小/配色点回打开时的值，保证测试留下的文件是「中性」的
        $dsv = 0.0
        if (-not [double]::TryParse([string]$Cfg.dockScale, [ref]$dsv) -or $dsv -le 0) { $dsv = 1.0 }
        $dsKey = if ($dsv -lt 0.9) { '0.75' } elseif ($dsv -gt 1.1) { '1.25' } else { '1' }
        $dockButtons[$dsKey].PerformClick()
        $scCfg = [string]$Cfg.uiScale
        if (-not $scCfg) { $scCfg = 'auto' }
        $scaleButtons[$scCfg].PerformClick()
        $thCfg = [string]$Cfg.theme
        if ($thCfg -notin @('dark', 'light')) { $thCfg = 'dark' }
        $themeButtons[$thCfg].PerformClick()
        $tbTimeout.Text = '25'
        $tbInterval.Text = '7'
        # 透明度 chip 在系统页上；PerformClick 要求控件可见（CanSelect），
        # 账户页时这些控件是隐藏的，点了不触发 —— 必须先切回系统页
        Show-Page -Page 'system'
        [System.Windows.Forms.Application]::DoEvents()
        $opacityButtons['0.5'].PerformClick()      # 用非默认值验证落盘
        $btnSave.PerformClick()
        Start-Sleep -Milliseconds 400
        $sv = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        CHK '保存后 timeout=25' ($sv.timeout -eq 25) ([string]$sv.timeout)
        CHK '保存后 refreshMinutes=7' ($sv.refreshMinutes -eq 7) ([string]$sv.refreshMinutes)
        CHK '保存后 uiScale / dockScale 都在' (($null -ne $sv.uiScale) -and ($null -ne $sv.dockScale)) ($sv.uiScale + ' / ' + $sv.dockScale)
        CHK '保存后 opacity=0.5 落盘' ([Math]::Abs([double]$sv.opacity - 0.5) -lt 0.001) ([string]$sv.opacity)
        CHK '保存后 dockScale 与打开时一致' ([double]$sv.dockScale -eq $dsv) ([string]$sv.dockScale + ' vs ' + $dsv)
        CHK '保存后 theme 与打开时一致' ([string]$sv.theme -eq $thCfg) ([string]$sv.theme)
        CHK '保存后账户仍是 tokenplan/minimax' (($sv.providers[0].tpl -eq 'tokenplan') -and ($sv.providers[0].type -eq 'minimax')) ($sv.providers[0].tpl + '/' + $sv.providers[0].type)

        Copy-Item $bk $script:ConfigPath -Force
        Remove-Item $bk -Force
        Write-Host ('  配置已还原；通过 ' + $script:tp + ' / ' + ($script:tp + $script:tf))
        return ($script:tf -eq 0)
    }

    # ---- 布局自检 ----
    if ($DumpLayout) {
        # 必须先 Show 一次：未显示的窗口里所有子控件的 Visible 都是 false，判断不出页面切换
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point 20, 20
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Write-Host ('界面缩放 = ' + $scaleCfg + '  (f=' + $f + ')')
        Write-Host ('窗口基准 ' + $W + ' x ' + $H + '  实际 ' + $form.Width + ' x ' + $form.Height)
        Show-Page -Page 'account'
        [System.Windows.Forms.Application]::DoEvents()
        Write-Host ('  [account  ] card2 可见=' + $card2.Visible + ' 系统卡片可见=' + @($sysCtrls | Where-Object { $_.Visible }).Count + ' 窗口高 ' + $form.Height)
        foreach ($t in $tpls) {
            Set-Template -Id $t.Id
            [System.Windows.Forms.Application]::DoEvents()
            $vis = @()
            foreach ($k in $layoutMap[$t.Id]) { $vis += ($k + '@' + $rows[$k].Top) }
            $sbBottom = $statusBar.Top + $statusBar.Height
            $firstTop = $rows[$layoutMap[$t.Id][0]].Top
            Write-Host ('  [' + $t.Id.PadRight(9) + '] ' + ($vis -join ' ') +
                ' | 状态栏底 ' + $sbBottom + '/' + $card2.Height +
                ' 窗口高 ' + $form.Height +
                $(if ($firstTop -lt (X $yDyn)) { '  重叠!' } else { '' }) +
                $(if ($sbBottom -gt $card2.Height) { '  溢出!' } else { '' }))
        }
        Show-Page -Page 'system'
        [System.Windows.Forms.Application]::DoEvents()
        Write-Host ('  [system   ] card2 可见=' + $card2.Visible + ' 系统卡片可见=' + @($sysCtrls | Where-Object { $_.Visible }).Count +
            ' 窗口高 ' + $form.Height + ' 卡片底 ' + ($s5.Top + $s5.Height))
        Write-Host ('  开机自启注册表 = ' + $(if (Get-Command Get-AutostartEnabled -ErrorAction SilentlyContinue) { Get-AutostartEnabled } else { 'n/a' }))
        $form.Close()
        $form.Dispose()
        return $false
    }

    if ($CapturePath) {
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point 20, 20
        $form.TopMost = $true
        $form.Show()
        $form.Activate()
        [System.Windows.Forms.Application]::DoEvents()
        # 切模板要在 Show 之后：Resize-ForPage 改的是窗口高度，
        # 未显示的窗口改高度会被 Show 重置回初始值（截出来底部会被裁掉）
        if ($OnlyTpl) {
            Set-Template -Id $OnlyTpl
            [System.Windows.Forms.Application]::DoEvents()
        }
        Start-Sleep -Milliseconds 700
        [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap $form.Width, $form.Height
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $form.Width, $form.Height))
        $bmp.Save($CapturePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $form.Close()
        $form.Dispose()
        return $false
    }

    # 无人值守验证：定时点缩放档 + 定时关窗（只在 -AutoScaleClick / -AutoClose 时挂）
    if ($AutoScaleClick) {
        $script:autoScaleTimer = New-Object System.Windows.Forms.Timer
        $script:autoScaleTimer.Interval = 700
        $script:autoScaleTimer.add_Tick({
            $script:autoScaleTimer.Stop()
            $b = $scaleButtons[$AutoScaleClick]
            if ($b) { $b.PerformClick() } else { $form.Tag = 'cancel'; $form.Close() }
        })
        $script:autoScaleTimer.Start()
    }
    if ($AutoClose) {
        $script:autoCloseTimer = New-Object System.Windows.Forms.Timer
        $script:autoCloseTimer.Interval = 3200
        $script:autoCloseTimer.add_Tick({
            $script:autoCloseTimer.Stop()
            $script:CWLastSize = [string]$form.Width + 'x' + [string]$form.Height
            $form.Tag = 'cancel'
            $form.Close()
        })
        $script:autoCloseTimer.Start()
    }

    # 无人值守验证时把配置页置顶，否则会被主悬浮窗（TopMost）压在后面，截不到
    if ($AutoClose -or $AutoScaleClick) { $form.TopMost = $true }

    $form.ShowDialog() | Out-Null

    # 改了界面缩放：带着未保存的编辑、当前页、当前模板、窗口位置重建一次
    if ($form.Tag -eq 'rescale') {
        $next = $script:EditCfg
        $pg = $script:ReopenPage
        $tp = $script:ReopenTpl
        $pos = $script:ReopenPos
        $form.Dispose()
        return (Show-ConfigWindow -Cfg $next -StartPage $pg -StartTpl $tp -StartPos $pos -AutoClose:$AutoClose)
    }

    $saved = ($form.Tag -eq 'saved')
    # 没保存（取消 / 点 ✕）→ 悬浮窗还原成打开前的系数
    if (-not $saved) { Restore-DockPreview }
    $form.Dispose()
    return $saved
}
