# wb_restart_and_shots.ps1 — 重启面板（加载新代码）并截折叠/展开两态
$ErrorActionPreference = 'Continue'
foreach ($n in @('HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy')) {
    if ($null -ne [Environment]::GetEnvironmentVariable($n)) { Remove-Item ("Env:" + $n) -ErrorAction SilentlyContinue }
}
$ps = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*TokenPanel.ps1*' }
foreach ($p in $ps) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
$null = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'D:\AppData\token消耗面板\TokenPanel.ps1') `
    -WorkingDirectory 'D:\AppData\token消耗面板' -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 15
Get-Content "$env:APPDATA\TokenPocket\app.log" -Tail 4
& 'D:\AppData\token消耗面板\wb_expand_shot.ps1'
