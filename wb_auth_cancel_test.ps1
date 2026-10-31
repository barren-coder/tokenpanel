# wb_auth_cancel_test.ps1 — 验证授权结果文件（ok / cancel）与关窗立即退出
$ErrorActionPreference = 'Continue'
foreach ($n in @('HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy')) {
    if ($null -ne [Environment]::GetEnvironmentVariable($n)) { Remove-Item ("Env:" + $n) -ErrorAction SilentlyContinue }
}
$wbDir = 'D:\AppData\TokenPanel\lib\wb'
$resultFile = Join-Path $wbDir '.auth-result.json'
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) {
    $node = Get-ChildItem "$env:USERPROFILE\.workbuddy\binaries\node" -Recurse -Filter node.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}

function Clear-Orphans {
    foreach ($exeName in @('chrome.exe', 'msedge.exe')) {
        Get-CimInstance Win32_Process -Filter "Name='$exeName'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like ('*' + $wbDir + '*') } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*grab_cookie.js*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

Write-Host '===== A) 已登录态：应自动判成功并写 ok ====='
Clear-Orphans
if (Test-Path $resultFile) { Remove-Item $resultFile -Force }
$outA = Join-Path $env:TEMP 'wb_auth_a.txt'
$pA = Start-Process -FilePath $node -ArgumentList @('grab_cookie.js') -WorkingDirectory $wbDir -PassThru -NoNewWindow -RedirectStandardOutput $outA -RedirectStandardError (Join-Path $env:TEMP 'wb_auth_a_err.txt')
$sw = [Diagnostics.Stopwatch]::StartNew()
$doneA = $pA.WaitForExit(90000)
$sw.Stop()
Write-Host ("退出: " + $doneA + "  耗时 " + [int]($sw.Elapsed.TotalSeconds) + "s")
if (Test-Path $resultFile) {
    $r = Get-Content $resultFile -Raw -Encoding UTF8
    Write-Host ("结果文件: " + $r)
    $kind = ($r | ConvertFrom-Json).result
    Write-Host ("判定 A: " + $(if ($kind -eq 'ok') { '[OK] 结果=ok' } else { '[FAIL] 结果=' + $kind }))
} else {
    Write-Host '判定 A: [FAIL] 没有结果文件'
}
Get-Content $outA -Tail 4 -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '===== B) 关窗口：应写 cancel 且立即退出 ====='
Clear-Orphans
if (Test-Path $resultFile) { Remove-Item $resultFile -Force }
$outB = Join-Path $env:TEMP 'wb_auth_b.txt'
$pB = Start-Process -FilePath $node -ArgumentList @('grab_cookie.js') -WorkingDirectory $wbDir -PassThru -NoNewWindow -RedirectStandardOutput $outB -RedirectStandardError (Join-Path $env:TEMP 'wb_auth_b_err.txt')
$chrome = $null
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    $chrome = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like ('*' + $wbDir + '*') })
    if ($chrome.Count -gt 0) { break }
}
Write-Host ("浏览器进程数: " + $chrome.Count)
$mainPid = ($chrome | Sort-Object ParentProcessId | Select-Object -First 1).ProcessId
Start-Process -FilePath 'taskkill' -ArgumentList @('/PID', [string]$mainPid, '/T', '/F') -WindowStyle Hidden -Wait
$sw2 = [Diagnostics.Stopwatch]::StartNew()
$doneB = $pB.WaitForExit(30000)
$sw2.Stop()
Write-Host ("退出: " + $doneB + "  耗时 " + $sw2.ElapsedMilliseconds + "ms")
if (Test-Path $resultFile) {
    $r2 = Get-Content $resultFile -Raw -Encoding UTF8
    Write-Host ("结果文件: " + $r2)
    $kind2 = ($r2 | ConvertFrom-Json).result
    Write-Host ("判定 B: " + $(if ($kind2 -eq 'cancel' -and $doneB -and $sw2.ElapsedMilliseconds -lt 5000) { '[OK] 取消 + 立即退出' } else { '[FAIL] 结果=' + $kind2 + ' 退出=' + $doneB }))
} else {
    Write-Host '判定 B: [FAIL] 没有结果文件'
}
Get-Content $outB -Tail 3 -ErrorAction SilentlyContinue
