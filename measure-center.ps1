# measure-center.ps1 — 用亮度加权质心精确标定数字的垂直偏移
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$fgV = [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
$famNum = 'Segoe UI Semibold'
$dpiRef = 1.5

# 返回：墨迹上下边界、bbox 中心、亮度加权质心（都是相对文本框顶部的坐标）
function Get-InkMetric {
    param([int]$BoxW, [int]$BoxH, [single]$FsPx, [int]$Shift)
    $f = New-Object System.Drawing.Font $famNum, $FsPx, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
    $bmp = New-Object System.Drawing.Bitmap $BoxW, $BoxH
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Black)
    $rect = New-Object System.Drawing.Rectangle 0, $Shift, $BoxW, $BoxH
    [System.Windows.Forms.TextRenderer]::DrawText($g, '65', $f, $rect, [System.Drawing.Color]::White, $fgV)
    $g.Dispose()

    $top = -1; $bot = -1
    $sumW = 0.0; $sumWY = 0.0
    for ($y = 0; $y -lt $BoxH; $y++) {
        $rowSum = 0
        for ($x = 0; $x -lt $BoxW; $x++) {
            $r = $bmp.GetPixel($x, $y).R
            $rowSum += $r
            if ($r -gt 40) { if ($top -lt 0) { $top = $y }; $bot = $y }
        }
        if ($rowSum -gt 0) { $sumW += $rowSum; $sumWY += $y * $rowSum }
    }
    $bmp.Dispose(); $f.Dispose()
    if ($top -lt 0) { return $null }
    return @{
        Top = $top; Bot = $bot
        Bbox = ($top + $bot) / 2
        Centroid = if ($sumW -gt 0) { $sumWY / $sumW } else { 0 }
    }
}

$cases = @(
    @{ N = '小';      K = 0.75; Fs = 15 },
    @{ N = '默认';    K = 1.0;  Fs = 15 },
    @{ N = '大';      K = 1.25; Fs = 15 },
    @{ N = '默认3位'; K = 1.0;  Fs = 11 }
)

Write-Host '=== 数字墨迹相对圆心（圆心 = 文本框中心）的偏移，正值 = 偏下 ==='
Write-Host '  档位     字号px   bbox偏移  质心偏移   推算系数(质心/字号)'

$ratios = @()
foreach ($case in $cases) {
    $fsPx = [single]($case.Fs * $case.K * $dpiRef)
    $ringR = [int][Math]::Round(20 * $case.K * $dpiRef)
    $boxW = $ringR * 2; $boxH = $ringR * 2
    $boxCenter = ($boxH - 1) / 2
    $m = Get-InkMetric -BoxW $boxW -BoxH $boxH -FsPx $fsPx -Shift 0
    if (-not $m) { continue }
    $offBbox = $m.Bbox - $boxCenter
    $offCen = $m.Centroid - $boxCenter
    $ratio = $offCen / $fsPx
    $ratios += $ratio
    Write-Host ('  ' + $case.N.PadRight(8) + ' ' + [Math]::Round($fsPx,1).ToString().PadLeft(6) +
        '   ' + ([Math]::Round($offBbox,2)).ToString().PadLeft(6) +
        '   ' + ([Math]::Round($offCen,2)).ToString().PadLeft(7) +
        '   ' + ([Math]::Round($ratio,4)).ToString().PadLeft(8))
}

$avg = ($ratios | Measure-Object -Average).Average
Write-Host ''
Write-Host ('平均系数 = ' + [Math]::Round($avg,4) + '  → 建议修正量 = round(字号 × ' + [Math]::Round($avg,3) + ')')

# 用标定出的系数验证残留
Write-Host ''
Write-Host '=== 用该系数修正后的残留 ==='
Write-Host '  档位     字号px  修正量  修正后质心偏移'
foreach ($case in $cases) {
    $fsPx = [single]($case.Fs * $case.K * $dpiRef)
    $ringR = [int][Math]::Round(20 * $case.K * $dpiRef)
    $boxW = $ringR * 2; $boxH = $ringR * 2
    $boxCenter = ($boxH - 1) / 2
    $dy = [int][Math]::Round($fsPx * $avg)
    $m = Get-InkMetric -BoxW $boxW -BoxH $boxH -FsPx $fsPx -Shift (-$dy)
    if (-not $m) { continue }
    $res = $m.Centroid - $boxCenter
    Write-Host ('  ' + $case.N.PadRight(8) + ' ' + [Math]::Round($fsPx,1).ToString().PadLeft(6) +
        '   -' + $dy.ToString().PadLeft(2) + 'px   ' + ([Math]::Round($res,2)).ToString().PadLeft(7) + 'px' +
        $(if ([Math]::Abs($res) -le 0.5) { '   居中' } else { '   偏差' }))
}
