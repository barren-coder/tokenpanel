# wb_start_only.ps1 — 只启动面板，不做任何点击
$ErrorActionPreference = 'Continue'
foreach ($n in @('HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy')) {
    if ($null -ne [Environment]::GetEnvironmentVariable($n)) { Remove-Item ("Env:" + $n) -ErrorAction SilentlyContinue }
}
$ps = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*-File*TokenPanel.ps1*' }
foreach ($p in $ps) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
$null = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'D:\AppData\TokenPanel\TokenPanel.ps1') `
    -WorkingDirectory 'D:\AppData\TokenPanel' -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 12
Get-Content "$env:APPDATA\TokenPanel\app.log" -Tail 5
