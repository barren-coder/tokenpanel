Add-Type -AssemblyName System.Security
. 'D:\AppData\TokenPanel\lib\QuotaCore.ps1'

$cfgPath = $script:ConfigPath
Copy-Item $cfgPath ($cfgPath + '.bak') -Force
Write-Output ("已备份: " + $cfgPath + '.bak')

$py = 'C:\Users\barren.wu\.workbuddy-ai\binaries\python\versions\3.13.12\python.exe'
$tmpPy = Join-Path $env:TEMP 'extract_mm.py'
$tmpOut = Join-Path $env:TEMP 'minimax_keys.txt'

# 输出格式：app|name|key  每行一条，避免 JSON 解析歧义
$pyCode = @'
import sqlite3, os, sys

db = os.path.expanduser(r'~\.cc-switch\cc-switch.db')
out_path = sys.argv[1]

def find_keys(obj):
    keys = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, str):
                kl = k.lower()
                if len(v) > 40 and (k == 'OPENAI_API_KEY' or 'auth_token' in kl or 'api_key' in kl or 'apikey' in kl):
                    keys.append(v)
            else:
                keys.extend(find_keys(v))
    elif isinstance(obj, list):
        for v in obj:
            keys.extend(find_keys(v))
    return keys

c = sqlite3.connect(db)
rows = c.execute("select app_type, name, settings_config from providers").fetchall()

seen = set()
lines = []
for app, name, cfg in rows:
    try:
        j = __import__('json').loads(cfg)
    except Exception:
        continue
    for key in find_keys(j):
        if key.startswith('sk-cp-') and key not in seen:
            seen.add(key)
            safe_name = (name or '').replace('|', ' ')
            lines.append(app + '|' + safe_name + '|' + key)

with open(out_path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))
'@
Set-Content -Path $tmpPy -Value $pyCode -Encoding UTF8
& $py $tmpPy $tmpOut
Remove-Item $tmpPy -Force

$lines = @(Get-Content $tmpOut -Encoding UTF8 | Where-Object { $_ -match '\|' })
Remove-Item $tmpOut -Force
Write-Output ("提取到 " + $lines.Count + " 条候选")

$valid = @()
foreach ($line in $lines) {
    $parts = $line -split '\|', 3
    if ($parts.Count -lt 3) { continue }
    $app = $parts[0]; $nm = $parts[1]; $k = $parts[2]

    $h = @{ 'Authorization' = 'Bearer ' + $k; 'Content-Type' = 'application/json' }
    $r = Invoke-Http -Url 'https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains' -Headers $h -TimeoutSec 15
    $ok = $false; $desc = ''
    if ($r.Status -eq 200) {
        try {
            $d = $r.Body | ConvertFrom-Json
            if (-not $d.base_resp -or $d.base_resp.status_code -eq 0) {
                $g = $d.model_remains | Where-Object { $_.model_name -eq 'general' } | Select-Object -First 1
                if ($g) {
                    $ok = $true
                    $desc = '使用量 5小时 ' + (100 - $g.current_interval_remaining_percent) + '% / 7天 ' + (100 - $g.current_weekly_remaining_percent) + '%'
                }
            } else { $desc = '接口 ' + $d.base_resp.status_code }
        } catch { $desc = '解析失败' }
    } else { $desc = 'HTTP ' + $r.Status }

    $mark = if ($ok) { '有效' } else { '失效' }
    Write-Output ("  [" + $mark + "] " + $app + " / " + $nm + "  ->  " + $desc)
    if ($ok) { $valid += @{ name = $nm; key = $k } }
}

if ($valid.Count -eq 0) { Write-Output "没有可用账号，配置未改动"; exit 1 }

$cfg = Load-Config
$newProvs = @()
foreach ($v in $valid) {
    $short = $v.name
    if ($short -match '(\d{3,})') { $short = $Matches[1] }
    if ($short.Length -gt 10) { $short = $short.Substring(0, 10) }
    $newProvs += [pscustomobject]@{
        name           = $v.name
        short          = $short
        type           = 'minimax'
        apiUrl         = 'https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains'
        apiKey         = (Protect-String $v.key)
        authMode       = 'bearer'
        refreshMinutes = 5
        enabled        = $true
        valuePath      = ''
        resetPath      = ''
    }
}

$cfg.providers = $newProvs
Save-Config -Cfg $cfg

Write-Output ""
Write-Output ("已写入 " + $newProvs.Count + " 个账户：")
foreach ($p in $newProvs) { Write-Output ("  " + $p.name + "  (短名 " + $p.short + ")") }
