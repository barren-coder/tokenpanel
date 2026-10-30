# preview-schemes.ps1 — 三个方案 × 三档尺寸（含垂直居中修正、余额与用量同笔宽）
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# 颜色（全部加 Clr 前缀，避免和 $cx/$cy 坐标撞名）
$ClrBg = '#1C1F27'; $ClrTrack = '#2A2F3A'; $ClrInk = '#FFFFFF'
$ClrOk = '#2DD4BF'; $ClrBad = '#F04452'; $ClrLbl = '#9AA5B5'; $ClrDim = '#6B7686'
function C([string]$h) { [System.Drawing.ColorTranslator]::FromHtml($h) }

# ---- 与 TokenPanel.ps1 一致的几何常量 ----
$DOCK = 68; $RingRad = 20; $PadTop = 7; $RingGap = 3; $LblH = 11
$DpiRef = 1.5
$LblMinScale = 0.9
# 垂直居中修正系数：由质心标定得出（measure-center.ps1），不是拍的
$CenterFix = 0.075

$sfTypo = [System.Drawing.StringFormat]::GenericTypographic
$fgLeft = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
$fgMid = $fgLeft -bor [System.Windows.Forms.TextFormatFlags]::HorizontalCenter

# ---- 三个方案 ----
# 注意：笔宽会被物理像素取整吃掉差异。默认档(150%DPI)下可用值只有
#   pen 2.0 → p3 / pen 2.5~3.0 → p4 / pen 3.5 → p5 / pen 4.0 → p6
# 所以三档必须落在 p3 / p4 / p5 上，否则肉眼看不出区别（2.5 与 3.0 实测同渲染）
$schemes = @(
    @{ Key = 'A'; N = 'A 你的方案';     Pen = 3.0; Num = 15; PctR = 0.62; PctDrop = 3; Lbl = 8.0
       Note = '笔宽3.0(p4) / 数字15 SemiBold / %0.62 下标式 / 名8' },
    @{ Key = 'B'; N = 'B 我的①·轻盈清晰'; Pen = 2.0; Num = 15; PctR = 0.75; PctDrop = 2; Lbl = 8.0
       Note = '笔宽2.0(p3) 更细 / %0.75 放大好读 / 名8' },
    @{ Key = 'C'; N = 'C 我的②·稳重聚焦'; Pen = 3.5; Num = 15; PctR = 0.55; PctDrop = 3; Lbl = 7.5
       Note = '笔宽3.5(p5) 更实 / %0.55 退后 / 名7.5 让数字主导' }
)
$sizes = @(
    @{ N = '小 51';   K = 0.75 },
    @{ N = '默认 68'; K = 1.0  },
    @{ N = '大 85';   K = 1.25 }
)

$unitMax = [int][Math]::Round($DOCK * 1.25 * $DpiRef)      # 128
$cellW = $unitMax * 2 + 30                                 # 两个环并排
$cellH = $unitMax + 62
$padX = 22
$headH = 46
$W = $padX * 2 + $cellW * $sizes.Count
$H = $headH + $cellH * $schemes.Count + 54

$bmp = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.Clear((C '#0E1216'))

$fHead = New-Object System.Drawing.Font 'Microsoft YaHei UI', 14, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$fSub = New-Object System.Drawing.Font 'Microsoft YaHei UI', 11, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
$fFoot = New-Object System.Drawing.Font 'Microsoft YaHei UI', 12, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)

# 列标题
for ($ci = 0; $ci -lt $sizes.Count; $ci++) {
    $x = $padX + $cellW * $ci
    $r1 = New-Object System.Drawing.Rectangle $x, 8, $cellW, 20
    [System.Windows.Forms.TextRenderer]::DrawText($g, $sizes[$ci].N, $fHead, $r1, (C '#E6EDF3'), ($fgMid -bor [System.Windows.Forms.TextFormatFlags]::NoPadding))
}

for ($si = 0; $si -lt $schemes.Count; $si++) {
    $sc = $schemes[$si]
    $rowTop = $headH + $cellH * $si

    # 行标题
    $r0 = New-Object System.Drawing.Rectangle $padX, $rowTop, ($cellW * $sizes.Count), 20
    [System.Windows.Forms.TextRenderer]::DrawText($g, ($sc.N + '    ' + $sc.Note), $fHead, $r0, (C '#E6EDF3'), ([System.Windows.Forms.TextFormatFlags]::NoPadding))

    for ($ci = 0; $ci -lt $sizes.Count; $ci++) {
        $k = $sizes[$ci].K
        $unitP = $DOCK * $k * $DpiRef
        $cellLeft = $padX + $cellW * $ci
        $cellMid = $cellLeft + $cellW / 2
        $cyBase = $rowTop + 28

        $ringPx = $RingRad * $k * $DpiRef
        $penPx = [int][Math]::Round($sc.Pen * $k * $DpiRef); if ($penPx -lt 1) { $penPx = 1 }
        $showLbl = ($k -ge $LblMinScale)
        $cy = if ($showLbl) { $cyBase + ($PadTop * $k * $DpiRef) + $ringPx } else { $cyBase + $unitP / 2 }

        # ---------- 左：65% 用量环 ----------
        $cx1 = $cellMid - $unitP / 2 - 4
        $box = ($ringPx - $penPx / 2) * 2
        $bx = $cx1 - $box / 2; $by = $cy - $box / 2

        $penBg = New-Object System.Drawing.Pen (C $ClrTrack), ([single]$penPx)
        $g.DrawEllipse($penBg, $bx, $by, $box, $box); $penBg.Dispose()
        $penArc = New-Object System.Drawing.Pen (C $ClrOk), ([single]$penPx)
        $penArc.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $penArc.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $g.DrawArc($penArc, $bx, $by, $box, $box, -90, [single](360 * 0.65)); $penArc.Dispose()

        $fsNum = [single]($sc.Num * $k * $DpiRef)
        $fsPct = [single][Math]::Round($fsNum * $sc.PctR)
        # 垂直居中修正：VerticalCenter 对齐行框，数字无下伸部 → 墨迹比圆心低约 0.09×字号
        $dyNum = [int][Math]::Round($fsNum * $CenterFix)
        $dyPct = [int][Math]::Round($fsPct * $CenterFix)
        $fNum = New-Object System.Drawing.Font 'Segoe UI Semibold', $fsNum, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
        $fPct = New-Object System.Drawing.Font 'Segoe UI Semibold', $fsPct, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)

        $wNum = $g.MeasureString('65', $fNum, 1000, $sfTypo).Width
        $wPct = $g.MeasureString('%', $fPct, 1000, $sfTypo).Width
        $gapPx = 0
        $sx = [int]($cx1 - ($wNum + $gapPx + $wPct) / 2)
        $rNum = New-Object System.Drawing.Rectangle $sx, ([int]($cy - $ringPx - $dyNum)), ([int][Math]::Ceiling($wNum)), ([int]($ringPx * 2))
        [System.Windows.Forms.TextRenderer]::DrawText($g, '65', $fNum, $rNum, (C $ClrInk), $fgLeft)
        $rPct = New-Object System.Drawing.Rectangle ($sx + [int][Math]::Ceiling($wNum) + $gapPx), ([int]($cy - $ringPx + ($sc.PctDrop * $k * $DpiRef) - $dyPct)), ([int][Math]::Ceiling($wPct) + 2), ([int]($ringPx * 2))
        [System.Windows.Forms.TextRenderer]::DrawText($g, '%', $fPct, $rPct, (C $ClrInk), $fgLeft)
        $fNum.Dispose(); $fPct.Dispose()

        # ---------- 右：¥-0.49 余额环（同笔宽）----------
        $cx2 = $cellMid + $unitP / 2 + 4
        $bx2 = $cx2 - $box / 2; $by2 = $cy - $box / 2
        $penBg2 = New-Object System.Drawing.Pen (C $ClrTrack), ([single]$penPx)
        $g.DrawEllipse($penBg2, $bx2, $by2, $box, $box); $penBg2.Dispose()
        $penM = New-Object System.Drawing.Pen (C $ClrBad), ([single]$penPx)
        $g.DrawEllipse($penM, $bx2, $by2, $box, $box); $penM.Dispose()

        $fsM = [single](11 * $k * $DpiRef)
        $dyM = [int][Math]::Round($fsM * $CenterFix)
        $fM = New-Object System.Drawing.Font 'Segoe UI', $fsM, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        $padM = [int](3 * $k * $DpiRef)
        $rM = New-Object System.Drawing.Rectangle ([int]($cx2 - $ringPx - $padM)), ([int]($cy - $ringPx - $dyM)), ([int](($ringPx + $padM) * 2)), ([int]($ringPx * 2))
        [System.Windows.Forms.TextRenderer]::DrawText($g, '¥-0.49', $fM, $rM, (C $ClrBad), $fgMid)
        $fM.Dispose()

        # 账户名
        if ($showLbl) {
            $fLbl = New-Object System.Drawing.Font 'Microsoft YaHei UI', ([single]($sc.Lbl * $k * $DpiRef)), ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
            foreach ($pair in @(@{ Cx = $cx1; T = 'MX2421' }, @{ Cx = $cx2; T = 'Deepseek' })) {
                $lr = New-Object System.Drawing.Rectangle ([int]($pair.Cx - $unitP / 2 + 6 * $k * $DpiRef)), ([int]($cy + $ringPx + $RingGap * $k * $DpiRef)), ([int]($unitP - 12 * $k * $DpiRef)), ([int]($LblH * $k * $DpiRef))
                [System.Windows.Forms.TextRenderer]::DrawText($g, $pair.T, $fLbl, $lr, (C $ClrLbl), ($fgMid -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis))
            }
            $fLbl.Dispose()
        }

        # 该格实际物理笔宽
        $fT = New-Object System.Drawing.Font 'Segoe UI', 11, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
        $tRect = New-Object System.Drawing.Rectangle ([int]$cellLeft), ([int]($rowTop + $cellH - 26)), ([int]$cellW), 14
        [System.Windows.Forms.TextRenderer]::DrawText($g, ('笔宽 ' + $penPx + 'px'), $fT, $tRect, (C '#4A5568'), ($fgMid -bor [System.Windows.Forms.TextFormatFlags]::NoPadding))
        $fT.Dispose()
    }
}

$note = '每个格子左＝用量环(65%)，右＝余额环(¥-0.49)，两者笔宽已统一。数字已做垂直居中修正（上移 0.075×字号，质心标定）'
$nr = New-Object System.Drawing.Rectangle $padX, ($H - 30), ($W - $padX * 2), 18
[System.Windows.Forms.TextRenderer]::DrawText($g, $note, $fFoot, $nr, (C $ClrDim), ($fgMid -bor [System.Windows.Forms.TextFormatFlags]::NoPadding))

$out = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'scheme-compare.png'
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
$fHead.Dispose(); $fSub.Dispose(); $fFoot.Dispose()
Write-Host ('已生成 ' + $out + '  (' + $W + 'x' + $H + ')')
