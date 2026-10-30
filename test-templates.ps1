# test-templates.ps1 — 验证 6 个模板的预设、字段、解析器
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib\QuotaCore.ps1')

$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Cond, [string]$Detail = '') {
    if ($Cond) { $script:pass++; Write-Host ("  [OK  ] " + $Name + $(if ($Detail) { "  $Detail" } else { '' })) }
    else       { $script:fail++; Write-Host ("  [FAIL] " + $Name + $(if ($Detail) { "  $Detail" } else { '' })) }
}

Write-Host "=== 1. 模板定义 ==="
$tpls = Get-TemplateDefs
Check "模板数量 = 6" ($tpls.Count -eq 6) ("实际 " + $tpls.Count)
foreach ($t in $tpls) {
    $ps = @(Get-ProviderPresets -Tpl $t.Id)
    $expect = @{ custom=1; general=1; newapi=1; tokenplan=4; balance=4; official=3 }[$t.Id]
    Check ("  " + $t.Id + " 预设数=" + $expect) ($ps.Count -eq $expect -and $ps[0].Id) ($ps.Count.ToString() + " 个")
}

Write-Host ""
Write-Host "=== 2. 各模板预设互不相同（不再共用一套）==="
$idsByTpl = @{}
foreach ($t in $tpls) { $idsByTpl[$t.Id] = (Get-ProviderPresets -Tpl $t.Id | ForEach-Object { $_.Id }) -join ',' }
foreach ($k in $idsByTpl.Keys) { Write-Host ("  " + $k.PadRight(10) + " -> " + $idsByTpl[$k]) }
Check "tokenplan 与 balance 预设不同" ($idsByTpl['tokenplan'] -ne $idsByTpl['balance'])
Check "official 预设是 claude/codex/workbuddy" ($idsByTpl['official'] -eq 'claude,codex,workbuddy')

Write-Host ""
Write-Host "=== 3. 解析器（合成响应）==="

# 通用模板
$b = '{"is_active":true,"balance":12.34,"unit":"USD"}'
$r = Parse-General -Body $b
Check "通用模板 余额 12.34" ($r.Ok -and $r.Tiers[0].Display -like '12.34*') $r.Tiers[0].Display

$b = '{"is_active":false}'
$r = Parse-General -Body $b
Check "通用模板 账户不可用" ($r.Ok -and $r.Tiers[0].Display -eq '账户不可用') $r.Tiers[0].Display

# NewAPI：quota 500000 = 1 USD
$b = '{"success":true,"data":{"group":"vip","quota":500000,"used_quota":250000}}'
$r = Parse-NewApi -Body $b
Check "NewAPI 剩1.00/共1.50" ($r.Ok -and $r.Tiers[0].Display -eq '$1.00 / $1.50') $r.Tiers[0].Display
Check "NewAPI 套餐名 vip" ($r.Tiers[0].Name -eq 'vip') $r.Tiers[0].Name

$b = '{"success":false,"message":"无权进行此操作"}'
$r = Parse-NewApi -Body $b
Check "NewAPI 失败提示" ((-not $r.Ok) -and $r.Error -like '*无权*') $r.Error

# 账户余额
$p = @{ type = 'deepseek' }
$r = Parse-Balance -Body '{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"88.50"}]}' -Provider $p
Check "DeepSeek 余额 ¥88.50" ($r.Ok -and $r.Tiers[0].Display -eq '¥88.50') $r.Tiers[0].Display

$p = @{ type = 'siliconflow' }
$r = Parse-Balance -Body '{"code":20000,"data":{"balance":"1.00","totalBalance":"9.90"}}' -Provider $p
Check "硅基流动 余额 ¥9.90" ($r.Ok -and $r.Tiers[0].Display -eq '¥9.90') $r.Tiers[0].Display

$p = @{ type = 'openrouter' }
$r = Parse-Balance -Body '{"data":{"total_credits":10,"total_usage":3.5}}' -Provider $p
Check "OpenRouter 剩6.50/共10.00" ($r.Ok -and $r.Tiers[0].Display -eq '$6.50 / $10.00') $r.Tiers[0].Display

$p = @{ type = 'stepfun' }
$r = Parse-Balance -Body '{"data":{"balance":"55.5"}}' -Provider $p
Check "阶跃星辰 容错取 balance" ($r.Ok -and $r.Tiers[0].Display -eq '¥55.5') $r.Tiers[0].Display

# 官方
$p = @{ type = 'claude' }
$b = '{"five_hour":{"utilization":8,"resets_at":"2026-10-29T07:00:00Z"},"seven_day":{"utilization":34,"resets_at":"2026-11-02T00:00:00Z"}}'
$r = Parse-Official -Body $b -Provider $p
Check "Claude 5h 使用8→剩92" ($r.Ok -and $r.Tiers[0].Remain -eq 92) ($r.Tiers[0].Remain.ToString() + '%')
Check "Claude 7天 使用34→剩66" ($r.Tiers[1].Remain -eq 66) ($r.Tiers[1].Remain.ToString() + '%')

$p = @{ type = 'codex' }
$b = '{"rate_limit":{"primary_window":{"used_percent":12,"reset_at":1793000000},"secondary_window":{"used_percent":45,"reset_at":1793500000}}}'
$r = Parse-Official -Body $b -Provider $p
Check "Codex 5h 使用12→剩88" ($r.Ok -and $r.Tiers[0].Remain -eq 88) ($r.Tiers[0].Remain.ToString() + '%')

# Token Plan（复用已有解析器，确认没被破坏）
$r = Parse-MiniMax -Body '{"base_resp":{"status_code":0},"model_remains":[{"model_name":"general","current_interval_remaining_percent":92,"current_interval_status":1,"end_time":1793000000000,"current_weekly_remaining_percent":66,"current_weekly_status":1,"weekly_end_time":1793500000000}]}'
Check "TokenPlan MiniMax 92/66" ($r.Ok -and $r.Tiers[0].Remain -eq 92 -and $r.Tiers[1].Remain -eq 66)

Write-Host ""
Write-Host "=== 4. 请求地址拼接 ==="
$p = [pscustomobject]@{ tpl = 'general'; apiUrl = 'https://api.example.com/' }
Check "通用模板 拼 /user/balance" ((Get-ProviderRequestUrl -Provider $p) -eq 'https://api.example.com/user/balance') (Get-ProviderRequestUrl -Provider $p)
$p = [pscustomobject]@{ tpl = 'newapi'; apiUrl = 'https://api.example.com' }
Check "NewAPI 拼 /api/user/self" ((Get-ProviderRequestUrl -Provider $p) -eq 'https://api.example.com/api/user/self') (Get-ProviderRequestUrl -Provider $p)
$p = [pscustomobject]@{ tpl = 'tokenplan'; apiUrl = 'https://x/y/remains' }
Check "TokenPlan 原样用" ((Get-ProviderRequestUrl -Provider $p) -eq 'https://x/y/remains')

Write-Host ""
Write-Host "=== 5. 官方模板无 OAuth 凭据时给出可操作提示 ==="
$p = [pscustomobject]@{ tpl = 'official'; type = 'codex'; apiUrl = 'https://chatgpt.com/backend-api/wham/usage' }
$r = Invoke-Provider -Provider $p
Check "Codex 无凭据时报错含路径" ((-not $r.Ok) -and $r.Error -like '*auth.json*') $r.Error

Write-Host ""
Write-Host "=== 6. 余额账户：数值化 + 负数照实显示 ==="
$p = @{ type = 'deepseek' }
$r = Parse-Balance -Body '{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"88.50"}]}' -Provider $p
Check "DeepSeek 正余额带数值" ($r.Ok -and $r.Tiers[0].Money -eq 88.5 -and $r.Tiers[0].Display -eq '¥88.50') ([string]$r.Tiers[0].Money)

$r = Parse-Balance -Body '{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"-0.49"}]}' -Provider $p
Check "DeepSeek 欠费仍显示 -0.49（不再吞成「不可用」）" ($r.Ok -and $r.Tiers[0].Money -eq -0.49 -and $r.Tiers[0].Display -eq '¥-0.49') $r.Tiers[0].Display

$r = Parse-Balance -Body '{"is_available":false}' -Provider $p
Check "DeepSeek 无余额字段才回退「不可用」" ($r.Ok -and $r.Tiers[0].Display -eq '不可用' -and $null -eq $r.Tiers[0].Money) $r.Tiers[0].Display

$p = @{ type = 'openrouter' }
$r = Parse-Balance -Body '{"data":{"total_credits":10,"total_usage":12.5}}' -Provider $p
Check "OpenRouter 透支为负" ($r.Ok -and $r.Tiers[0].Money -eq -2.5) ([string]$r.Tiers[0].Money)

$p = @{ type = 'siliconflow' }
$r = Parse-Balance -Body '{"data":{"totalBalance":"9.90"}}' -Provider $p
Check "硅基流动带数值" ($r.Ok -and $r.Tiers[0].Money -eq 9.9) ([string]$r.Tiers[0].Money)

Write-Host ""
Write-Host "=== 7. 自定义模板：倍数 / 单位 ==="
$pc = [pscustomobject]@{ valuePath = 'data.remain'; scale = '1'; unit = '%'; resetPath = '' }
$r = Parse-Custom -Body '{"data":{"remain":80}}' -Provider $pc
Check "单位 % → 百分比额度" ($r.Ok -and $r.Tiers[0].Remain -eq 80 -and $null -eq $r.Tiers[0].Money) ([string]$r.Tiers[0].Remain)

$pc = [pscustomobject]@{ valuePath = 'data.remain'; scale = '0.5'; unit = '%'; resetPath = '' }
$r = Parse-Custom -Body '{"data":{"remain":80}}' -Provider $pc
Check "倍数 0.5 → 40%" ($r.Ok -and $r.Tiers[0].Remain -eq 40) ([string]$r.Tiers[0].Remain)

$pc = [pscustomobject]@{ valuePath = 'data.quota'; scale = '0.000002'; unit = 'USD'; resetPath = '' }
$r = Parse-Custom -Body '{"data":{"quota":500000}}' -Provider $pc
Check "单位 USD → 金额模式 1 美元" ($r.Ok -and $r.Tiers[0].Money -eq 1 -and $r.Tiers[0].Display -eq '$1') ($r.Tiers[0].Display + ' / ' + [string]$r.Tiers[0].Money)

$pc = [pscustomobject]@{ valuePath = 'data.x'; scale = '1'; unit = '%'; resetPath = '' }
$r = Parse-Custom -Body '{"data":{"x":"abc"}}' -Provider $pc
Check "非数字给出明确报错" ((-not $r.Ok) -and $r.Error -like '*不是数字*') $r.Error

Write-Host ""
Write-Host "=== 8. 提取器代码 / 变量说明（对齐 CC Switch 契约）==="
foreach ($t in @('custom', 'general', 'newapi', 'tokenplan', 'balance', 'official')) {
    $ps2 = @(Get-ProviderPresets -Tpl $t)
    $code = Get-ExtractorPreview -Tpl $t -Type $ps2[0].Id -Url 'https://api.example.com/x' -ValuePath 'data.v' -Scale '1' -Unit '%'
    Check ("  " + $t + " 生成脚本含 request + extractor") ($code -like '*request:*' -and $code -like '*extractor: function*')
    $vars = Get-TemplateVars -Tpl $t
    Check ("  " + $t + " 变量说明含 4 个占位符") ($vars -like '*{{apiKey}}*' -and $vars -like '*{{baseUrl}}*' -and $vars -like '*{{accessToken}}*' -and $vars -like '*{{userId}}*')
}
$code = Get-ExtractorPreview -Tpl 'custom' -Type 'custom' -Url 'https://a/b' -ValuePath 'data.balance' -Scale '0.5' -Unit 'CNY'
Check "自定义脚本回填路径/倍数/单位" (($code -like '*response.data.balance*') -and ($code -like '*0.5*') -and ($code -like '*CNY*'))
$code = Get-ExtractorPreview -Tpl 'official' -Type 'claude' -Url '' -ValuePath '' -Scale '' -Unit ''
Check "官方模板脚本不使用 {{apiKey}}" ($code -like '*不使用 {{apiKey}}*')

Write-Host ""
Write-Host "=== 9. 配色调色板 ==="
$needMain = @('Bg', 'BgHover', 'Track', 'Line', 'Tx', 'Tx2', 'Tx3', 'Cy', 'Am', 'Rd', 'RingText', 'TrackRing', 'Foot', 'Border', 'Glow')
$needCw = @('Bg', 'Card', 'Field', 'Line', 'Tx', 'Tx2', 'Tx3', 'Accent', 'AccentH', 'Cy', 'Am', 'Rd',
            'Sunken', 'CodeBg', 'CodeFg', 'Sel', 'DelFg', 'DelLine')
foreach ($n in @('dark', 'light')) {
    $pal = Get-MainTheme $n
    $miss = @($needMain | Where-Object { $null -eq $pal[$_] })
    Check ("主窗 " + $n + " 配色键齐全") ($miss.Count -eq 0) ($miss -join ',')
    $pal2 = Get-CwTheme $n
    $miss2 = @($needCw | Where-Object { $null -eq $pal2[$_] })
    Check ("配置页 " + $n + " 配色键齐全") ($miss2.Count -eq 0) ($miss2 -join ',')
}
Check "深色/浅色背景确实不同" ((Get-MainTheme 'dark').Bg -ne (Get-MainTheme 'light').Bg)
Check "浅色背景是浅色" ((Get-MainTheme 'light').Bg -eq '#F7F7F8') (Get-MainTheme 'light').Bg

Write-Host ""
Write-Host ("通过 " + $pass + " / " + ($pass + $fail))
if ($fail -gt 0) { exit 1 }
