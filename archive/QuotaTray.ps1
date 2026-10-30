# QuotaTray.ps1 — Token Plan 额度托盘应用 v2
# 零依赖：Windows 自带 PowerShell 5.1 + WinForms + System.Drawing
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\QuotaTray.ps1              # 常驻托盘
#   powershell -ExecutionPolicy Bypass -File .\QuotaTray.ps1 -Config      # 直接打开设置
#   powershell -ExecutionPolicy Bypass -File .\QuotaTray.ps1 -Test        # 只查一次额度，打印结果
#   powershell -ExecutionPolicy Bypass -File .\QuotaTray.ps1 -Screenshot  # 导出图标样式对比图

param(
    [switch]$Test,
    [switch]$Config,
    [switch]$Screenshot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

$script:AppName    = 'QuotaTray'
$script:Version    = '2.0'
$script:ConfigDir  = Join-Path $env:APPDATA $script:AppName
$script:ConfigPath = Join-Path $script:ConfigDir 'config.json'
$script:LogPath    = Join-Path $script:ConfigDir 'app.log'

# ============================================================
# 主题
# 注意：变量名不要用 $T —— PowerShell 变量名不区分大小写，
# 会和函数内的局部变量 $t（TextBox）撞车，导致主题色静默失效。
# ============================================================
$Theme = @{
    Bg     = '#14161B'
    Card   = '#1C1F27'
    Field  = '#22262F'
    Line   = '#2E333F'
    Tx     = '#E6EDF3'
    Tx2    = '#9AA5B5'
    Tx3    = '#6B7686'
    Accent = '#2DD4BF'
    Warn   = '#F5A524'
    Danger = '#F04452'
    Ok     = '#2DD4BF'
}

function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }

function Get-LevelColor {
    param([int]$Percent)
    if ($Percent -lt 0) { return $Theme.Tx3 }
    $warn = 25
    $crit = 10
    if ($script:Cfg) {
        if ($null -ne $script:Cfg.warnThreshold) { $warn = [int]$script:Cfg.warnThreshold }
        if ($null -ne $script:Cfg.critThreshold) { $crit = [int]$script:Cfg.critThreshold }
    }
    if ($Percent -le $crit) { return $Theme.Danger }
    if ($Percent -le $warn) { return $Theme.Warn }
    return $Theme.Ok
}

function Get-LevelDarkColor {
    param([int]$Percent)
    if ($Percent -lt 0) { return '#2A2F38' }
    $warn = 25
    $crit = 10
    if ($script:Cfg) {
        if ($null -ne $script:Cfg.warnThreshold) { $warn = [int]$script:Cfg.warnThreshold }
        if ($null -ne $script:Cfg.critThreshold) { $crit = [int]$script:Cfg.critThreshold }
    }
    if ($Percent -le $crit) { return '#3A1216' }
    if ($Percent -le $warn) { return '#3A2A08' }
    return '#0E2E2A'
}

# ============================================================
# DPAPI 加解密（绑定当前 Windows 用户）
# ============================================================
function Protect-String {
    param([string]$Plain)
    if ([string]::IsNullOrEmpty($Plain)) { return '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
    $enc = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($enc)
}

function Unprotect-String {
    param([string]$Cipher)
    if ([string]::IsNullOrEmpty($Cipher)) { return '' }
    try {
        $bytes = [Convert]::FromBase64String($Cipher)
        $dec = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [System.Text.Encoding]::UTF8.GetString($dec)
    } catch { return '' }
}

# ============================================================
# 供应商预设
# ============================================================
function Get-ProviderPresets {
    return @(
        @{
            Id    = 'minimax'
            Label = 'MiniMax Coding Plan'
            Url   = 'https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains'
            Auth  = 'bearer'
            Hint  = '国内站 api.minimaxi.com；国际站 api.minimax.io 对国内账号无效'
        },
        @{
            Id    = 'kimi'
            Label = 'Kimi For Coding'
            Url   = 'https://api.kimi.com/coding/v1/usages'
            Auth  = 'bearer'
            Hint  = '全球账号用 api.kimi.ai/coding/v1/usages'
        },
        @{
            Id    = 'zhipu'
            Label = '智谱 GLM Coding Plan'
            Url   = 'https://open.bigmodel.cn/api/monitor/usage/quota/limit'
            Auth  = 'raw'
            Hint  = '智谱用裸 key，不加 Bearer 前缀；国际站 api.z.ai'
        },
        @{
            Id    = 'opencode'
            Label = 'OpenCode Go'
            Url   = 'https://opencode.ai/zen/go/v1/usage'
            Auth  = 'bearer'
            Hint  = '三个时间窗口（rolling / weekly / monthly）'
        },
        @{
            Id    = 'deepseek'
            Label = 'DeepSeek（余额）'
            Url   = 'https://api.deepseek.com/user/balance'
            Auth  = 'bearer'
            Hint  = '查询账户余额，不是套餐百分比'
        },
        @{
            Id    = 'custom'
            Label = '自定义（按 JSON 路径提取）'
            Url   = ''
            Auth  = 'bearer'
            Hint  = '填 API 地址 + 剩余百分比所在路径，如 data.remaining_percent'
        }
    )
}

function Get-PresetById {
    param([string]$Id)
    $p = Get-ProviderPresets | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($p) { return $p }
    return (Get-ProviderPresets)[0]
}

# ============================================================
# 配置
# ============================================================
function Get-DefaultConfig {
    return [pscustomobject]@{
        providers = @(
            [pscustomobject]@{
                name           = 'MiniMax Coding Plan'
                type           = 'minimax'
                apiUrl         = 'https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains'
                apiKey         = ''
                authMode       = 'bearer'
                refreshMinutes = 5
                enabled        = $true
                valuePath      = ''
                resetPath      = ''
            }
        )
        activeIndex   = 0
        iconStyle     = 'ring'
        warnThreshold = 25
        critThreshold = 10
        startWithBoot = $false
        showPercent   = $true
    }
}

function Load-Config {
    if (-not (Test-Path $script:ConfigPath)) {
        $cfg = Get-DefaultConfig
        Save-Config -Cfg $cfg
        return $cfg
    }
    try {
        $raw = Get-Content $script:ConfigPath -Raw -Encoding UTF8
        $obj = $raw | ConvertFrom-Json
        $def = Get-DefaultConfig
        foreach ($p in $def.PSObject.Properties) {
            if ($null -eq $obj.PSObject.Properties[$p.Name]) {
                $obj | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
            }
        }
        if (-not $obj.providers -or $obj.providers.Count -eq 0) { $obj.providers = $def.providers }
        return $obj
    } catch {
        Write-Log "配置读取失败，使用默认值: $($_.Exception.Message)"
        return Get-DefaultConfig
    }
}

function Save-Config {
    param($Cfg)
    if (-not (Test-Path $script:ConfigDir)) {
        New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
    }
    $json = $Cfg | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($script:ConfigPath, $json, [System.Text.Encoding]::UTF8)
}

function Write-Log {
    param([string]$Msg)
    try {
        if (-not (Test-Path $script:ConfigDir)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Msg
        Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
    } catch { }
}

# ============================================================
# HTTP（显式绕过系统代理）
# ============================================================
function Invoke-Http {
    param(
        [string]$Url,
        [hashtable]$Headers = @{},
        [int]$TimeoutSec = 15
    )
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Proxy = $null
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.Method = 'GET'
        $req.UserAgent = 'QuotaTray/' + $script:Version
        $req.Accept = 'application/json'
        # 注意：Content-Type / Accept / User-Agent 是 .NET 受限头，不能走 Headers 集合
        foreach ($k in $Headers.Keys) {
            if ($k -eq 'Content-Type') { $req.ContentType = $Headers[$k] }
            elseif ($k -eq 'Accept') { $req.Accept = $Headers[$k] }
            elseif ($k -eq 'User-Agent') { $req.UserAgent = $Headers[$k] }
            else { $req.Headers[$k] = $Headers[$k] }
        }

        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $body = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
        return @{ Status = 200; Body = $body }
    } catch [System.Net.WebException] {
        $e = $_.Exception
        if ($e.Response) {
            try {
                $sr = New-Object System.IO.StreamReader($e.Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $b = $sr.ReadToEnd(); $sr.Close()
                return @{ Status = [int]$e.Response.StatusCode; Body = $b }
            } catch { }
        }
        return @{ Status = 0; Body = ''; Error = $e.Message }
    } catch {
        return @{ Status = 0; Body = ''; Error = $_.Exception.Message }
    }
}

# ============================================================
# 解析层：各家响应 → 统一 Tiers
# ============================================================
function New-Tier {
    param(
        [string]$Name,
        [int]$Remain,
        $ResetMs,
        [int]$Status = 1,
        [string]$Display = ''
    )
    if ($Status -eq 3) { return $null }
    $reset = $null
    if ($ResetMs -and [int64]$ResetMs -gt 0) {
        try { $reset = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ResetMs).LocalDateTime } catch { }
    }
    if (-not $Display) { $Display = "$Remain%" }
    return [pscustomobject]@{
        Name    = $Name
        Remain  = $Remain
        Reset   = $reset
        Status  = $Status
        Display = $Display
    }
}

function Get-JsonPath {
    param($Obj, [string]$Path)
    if (-not $Path) { return $null }
    $cur = $Obj
    foreach ($seg in ($Path -split '\.')) {
        if ($null -eq $cur) { return $null }
        if ($seg -match '^\d+$') {
            $idx = [int]$seg
            if ($cur.Count -le $idx) { return $null }
            $cur = $cur[$idx]
        } else {
            $prop = $cur.PSObject.Properties[$seg]
            if ($null -eq $prop) { return $null }
            $cur = $prop.Value
        }
    }
    return $cur
}

function ConvertTo-IntSafe {
    param($v)
    if ($null -eq $v) { return 0 }
    $s = [string]$v
    $d = 0.0
    if ([double]::TryParse($s, [ref]$d)) { return [int][Math]::Round($d) }
    return 0
}

function Parse-MiniMax {
    param($Body)
    $d = $Body | ConvertFrom-Json
    if ($d.base_resp -and $d.base_resp.status_code -ne 0) {
        return @{ Ok = $false; Error = ('接口返回 {0}：{1}' -f $d.base_resp.status_code, $d.base_resp.status_msg) }
    }
    $g = $d.model_remains | Where-Object { $_.model_name -eq 'general' } | Select-Object -First 1
    if (-not $g) { return @{ Ok = $false; Error = '响应里没有 general 档位' } }

    $tiers = @()
    $t = New-Tier -Name '5 小时' -Remain (ConvertTo-IntSafe $g.current_interval_remaining_percent) `
        -ResetMs $g.end_time -Status (ConvertTo-IntSafe $g.current_interval_status)
    if ($t) { $tiers += $t }
    $t = New-Tier -Name '本周' -Remain (ConvertTo-IntSafe $g.current_weekly_remaining_percent) `
        -ResetMs $g.weekly_end_time -Status (ConvertTo-IntSafe $g.current_weekly_status)
    if ($t) { $tiers += $t }

    return @{ Ok = $true; PlanName = 'MiniMax Coding Plan'; Tiers = $tiers }
}

function Parse-Kimi {
    param($Body)
    $d = $Body | ConvertFrom-Json
    $tiers = @()

    if ($d.limits) {
        $first = $d.limits | Select-Object -First 1
        $det = $first.detail
        if ($det -and $det.limit) {
            $limit = [double]$det.limit
            $remain = [double]$det.remaining
            if ($limit -gt 0) {
                $usedPct = [int][Math]::Round(($limit - $remain) / $limit * 100)
                $t = New-Tier -Name '5 小时' -Remain (100 - $usedPct) -ResetMs $det.resetTime
                if ($t) { $tiers += $t }
            }
        }
    }
    if ($d.usage -and $d.usage.limit) {
        $limit = [double]$d.usage.limit
        $remain = [double]$d.usage.remaining
        if ($limit -gt 0) {
            $usedPct = [int][Math]::Round(($limit - $remain) / $limit * 100)
            $t = New-Tier -Name '本周' -Remain (100 - $usedPct) -ResetMs $d.usage.resetTime
            if ($t) { $tiers += $t }
        }
    }

    if ($tiers.Count -eq 0) { return @{ Ok = $false; Error = '未解析到额度字段' } }
    return @{ Ok = $true; PlanName = 'Kimi For Coding'; Tiers = $tiers }
}

function Parse-Zhipu {
    param($Body)
    $d = $Body | ConvertFrom-Json
    if ($d.success -eq $false) {
        return @{ Ok = $false; Error = ('接口返回：{0}' -f $d.msg) }
    }
    $tiers = @()
    if ($d.data -and $d.data.limits) {
        $i = 0
        foreach ($lim in $d.data.limits) {
            $ty = ([string]$lim.type).ToUpper()
            if ($ty -notmatch 'TOKEN|CREDIT') { continue }
            $usedPct = ConvertTo-IntSafe $lim.percentage
            $name = '窗口 ' + ($i + 1)
            if ($i -eq 0) { $name = '5 小时' }
            elseif ($i -eq 1) { $name = '本周' }
            $t = New-Tier -Name $name -Remain (100 - $usedPct) -ResetMs $lim.nextResetTime
            if ($t) { $tiers += $t }
            $i++
        }
    }
    if ($tiers.Count -eq 0) { return @{ Ok = $false; Error = '未解析到 limits' } }
    $plan = '智谱 GLM'
    if ($d.data -and $d.data.level) { $plan = '智谱 GLM ' + $d.data.level }
    return @{ Ok = $true; PlanName = $plan; Tiers = $tiers }
}

function Parse-OpenCode {
    param($Body)
    $d = $Body | ConvertFrom-Json
    $tiers = @()
    $map = @(
        @{ Key = 'rolling'; Name = '5 小时' },
        @{ Key = 'weekly';  Name = '本周' },
        @{ Key = 'monthly'; Name = '本月' }
    )
    foreach ($m in $map) {
        $w = $d.usage.($m.Key)
        if (-not $w) { continue }
        $usedPct = ConvertTo-IntSafe $w.percent
        $t = New-Tier -Name $m.Name -Remain (100 - $usedPct) -ResetMs $null
        if ($t) {
            if ($w.resetsAt) {
                try { $t.Reset = [DateTimeOffset]::Parse($w.resetsAt).LocalDateTime } catch { }
            }
            $tiers += $t
        }
    }
    if ($tiers.Count -eq 0) { return @{ Ok = $false; Error = '未解析到 usage 窗口' } }
    return @{ Ok = $true; PlanName = 'OpenCode Go'; Tiers = $tiers }
}

function Parse-DeepSeek {
    param($Body)
    $d = $Body | ConvertFrom-Json
    if ($d.is_available -eq $false) {
        $t0 = New-Tier -Name '余额' -Remain -1 -ResetMs 0 -Display '不可用'
        return @{ Ok = $true; PlanName = 'DeepSeek'; Tiers = @($t0) }
    }
    $b = $d.balance_infos | Select-Object -First 1
    if (-not $b) { return @{ Ok = $false; Error = '未找到 balance_infos' } }
    $cur = $b.currency
    $sym = '¥'
    if ($cur -eq 'USD') { $sym = '$' }
    $disp = '{0}{1}' -f $sym, $b.total_balance
    $t = New-Tier -Name '余额' -Remain -1 -ResetMs 0 -Display $disp
    return @{ Ok = $true; PlanName = ('DeepSeek 余额 (' + $cur + ')'); Tiers = @($t) }
}

function Parse-Custom {
    param($Body, $Provider)
    $d = $Body | ConvertFrom-Json
    $path = $Provider.valuePath
    if (-not $path) { return @{ Ok = $false; Error = '自定义供应商需要填「剩余百分比路径」' } }
    $v = Get-JsonPath -Obj $d -Path $path
    if ($null -eq $v) { return @{ Ok = $false; Error = ('路径 {0} 取不到值' -f $path) } }
    $pct = ConvertTo-IntSafe $v
    $t = New-Tier -Name '额度' -Remain $pct -ResetMs 0
    if ($Provider.resetPath) {
        $rv = Get-JsonPath -Obj $d -Path $Provider.resetPath
        if ($rv) {
            $n = [int64]0
            if ([int64]::TryParse([string]$rv, [ref]$n) -and $n -gt 0) {
                try { $t.Reset = [DateTimeOffset]::FromUnixTimeMilliseconds($n).LocalDateTime } catch { }
            } else {
                try { $t.Reset = [DateTimeOffset]::Parse([string]$rv).LocalDateTime } catch { }
            }
        }
    }
    return @{ Ok = $true; PlanName = $Provider.name; Tiers = @($t) }
}

# ============================================================
# 查询入口
# ============================================================
function Invoke-Provider {
    param($Provider, [string]$OverrideKey = '')

    $key = $OverrideKey
    if (-not $key) { $key = Unprotect-String $Provider.apiKey }
    if (-not $key) {
        return @{ Ok = $false; Error = '没有可用的 API Key'; Kind = 'auth' }
    }
    if (-not $Provider.apiUrl) {
        return @{ Ok = $false; Error = '未配置 API 地址'; Kind = 'config' }
    }

    $headers = @{}
    if ($Provider.authMode -eq 'raw') {
        $headers['Authorization'] = $key
    } else {
        $headers['Authorization'] = 'Bearer ' + $key
    }
    $headers['Content-Type'] = 'application/json'

    $res = Invoke-Http -Url $Provider.apiUrl -Headers $headers -TimeoutSec 15

    if ($res.Status -eq 0) {
        return @{ Ok = $false; Error = ('网络请求失败：' + $res.Error); Kind = 'network' }
    }
    if ($res.Status -eq 401 -or $res.Status -eq 403) {
        return @{ Ok = $false; Error = ('认证失败 (HTTP {0})，Key 可能已失效' -f $res.Status); Kind = 'auth' }
    }
    if ($res.Status -ne 200) {
        return @{ Ok = $false; Error = ('HTTP {0}' -f $res.Status); Kind = 'network' }
    }

    try {
        switch ($Provider.type) {
            'minimax'  { return Parse-MiniMax  -Body $res.Body }
            'kimi'     { return Parse-Kimi     -Body $res.Body }
            'zhipu'    { return Parse-Zhipu    -Body $res.Body }
            'opencode' { return Parse-OpenCode -Body $res.Body }
            'deepseek' { return Parse-DeepSeek -Body $res.Body }
            default    { return Parse-Custom   -Body $res.Body -Provider $Provider }
        }
    } catch {
        return @{ Ok = $false; Error = ('解析失败：' + $_.Exception.Message); Kind = 'parse' }
    }
}

# ============================================================
# 凭据自动探测
# ============================================================
function Find-CandidateKeys {
    $out = @()
    if ($env:MINIMAX_API_KEY) { $out += @{ Key = $env:MINIMAX_API_KEY; Src = '环境变量 MINIMAX_API_KEY' } }

    $codexAuth = Join-Path $env:USERPROFILE '.codex\auth.json'
    if (Test-Path $codexAuth) {
        try {
            $j = Get-Content $codexAuth -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.OPENAI_API_KEY) { $out += @{ Key = $j.OPENAI_API_KEY; Src = '.codex/auth.json' } }
        } catch { }
    }
    $claudeCfg = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (Test-Path $claudeCfg) {
        try {
            $j = Get-Content $claudeCfg -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.env.ANTHROPIC_AUTH_TOKEN) { $out += @{ Key = $j.env.ANTHROPIC_AUTH_TOKEN; Src = '.claude/settings.json' } }
        } catch { }
    }
    return $out
}

function Find-WorkingKey {
    param([string]$Type = 'minimax')
    $preset = Get-PresetById $Type
    $probe = [pscustomobject]@{
        name = $preset.Label; type = $preset.Id; apiUrl = $preset.Url
        apiKey = ''; authMode = $preset.Auth; refreshMinutes = 5; enabled = $true
        valuePath = ''; resetPath = ''
    }
    foreach ($c in (Find-CandidateKeys)) {
        $r = Invoke-Provider -Provider $probe -OverrideKey $c.Key
        if ($r.Ok) {
            return @{ Key = $c.Key; Src = $c.Src; Result = $r }
        }
    }
    return $null
}

# ============================================================
# 托盘图标绘制
# ============================================================
function New-QuotaIcon {
    param(
        [int]$Percent,
        [string]$Text = '',
        [string]$Style = 'ring'
    )

    if (-not $Text) {
        if ($Percent -lt 0) { $Text = '--' } else { $Text = [string]$Percent }
    }

    $size = 32
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)

    $hex = Get-LevelColor $Percent
    $col = C $hex
    $fontSize = 15
    if ($Text.Length -ge 3) { $fontSize = 11 }

    if ($Style -eq 'ring') {
        # 外环进度 + 深色内圆 + 白字：深浅任务栏都清晰，且有进度视觉
        $trackCol = [System.Drawing.Color]::FromArgb(70, 255, 255, 255)
        $track = New-Object System.Drawing.Pen $trackCol, 2.5
        $g.DrawEllipse($track, 2.25, 2.25, 27.5, 27.5)
        $track.Dispose()

        if ($Percent -gt 0) {
            $arc = New-Object System.Drawing.Pen $col, 2.5
            $arc.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $arc.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $sweep = [float](360.0 * $Percent / 100.0)
            if ($sweep -ge 359.5) { $sweep = 359.5 }
            $g.DrawArc($arc, 2.25, 2.25, 27.5, 27.5, -90, $sweep)
            $arc.Dispose()
        }

        # 内圆用阈值色的暗色版：低额度时环很短，靠内圆颜色也能看出状态
        $inner = New-Object System.Drawing.SolidBrush (C (Get-LevelDarkColor $Percent))
        $g.FillEllipse($inner, 6.5, 6.5, 19, 19)
        $inner.Dispose()

    } elseif ($Style -eq 'disk') {
        $disk = New-Object System.Drawing.SolidBrush $col
        $g.FillEllipse($disk, 1, 1, 29, 29)
        $disk.Dispose()

    } else {
        # text：纯数字 + 描边，最轻量
        $fontSize = 17
        if ($Text.Length -ge 3) { $fontSize = 13 }
        $font0 = New-Object System.Drawing.Font 'Segoe UI', $fontSize, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        $fmt0 = New-Object System.Drawing.StringFormat
        $fmt0.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt0.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rect0 = New-Object System.Drawing.RectangleF 0, 0, $size, $size
        $stroke = New-Object System.Drawing.SolidBrush (C '#000000')
        foreach ($d in @(@(-1, 0), @(1, 0), @(0, -1), @(0, 1), @(-1, -1), @(1, 1), @(-1, 1), @(1, -1))) {
            $r2 = New-Object System.Drawing.RectangleF $d[0], $d[1], $size, $size
            $g.DrawString($Text, $font0, $stroke, $r2, $fmt0)
        }
        $fill = New-Object System.Drawing.SolidBrush $col
        $g.DrawString($Text, $font0, $fill, $rect0, $fmt0)
        $stroke.Dispose(); $fill.Dispose(); $font0.Dispose(); $fmt0.Dispose()
        $g.Dispose()
        $h0 = $bmp.GetHicon()
        return @{ Icon = [System.Drawing.Icon]::FromHandle($h0); Bitmap = $bmp }
    }

    $font = New-Object System.Drawing.Font 'Segoe UI', $fontSize, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rect = New-Object System.Drawing.RectangleF 0, 0, $size, $size
    $g.DrawString($Text, $font, $brush, $rect, $fmt)
    $font.Dispose(); $brush.Dispose(); $fmt.Dispose(); $g.Dispose()

    $hicon = $bmp.GetHicon()
    return @{ Icon = [System.Drawing.Icon]::FromHandle($hicon); Bitmap = $bmp }
}

# ============================================================
# 自绘辅助
# ============================================================
function New-RoundedPath {
    param([int]$W, [int]$H, [int]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($R -le 0) {
        $p.AddRectangle((New-Object System.Drawing.Rectangle 0, 0, $W, $H))
        return $p
    }
    $d = $R * 2
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc($W - $d, 0, $d, $d, 270, 90)
    $p.AddArc($W - $d, $H - $d, $d, $d, 0, 90)
    $p.AddArc(0, $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-FlatButton {
    param(
        [string]$Text,
        [int]$X, [int]$Y, [int]$W, [int]$H,
        [string]$Kind = 'primary'
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point $X, $Y
    $b.Size = New-Object System.Drawing.Size $W, $H
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9.5
    $b.Cursor = 'Hand'
    if ($Kind -eq 'primary') {
        $b.BackColor = C $Theme.Accent
        $b.ForeColor = C '#0B0E14'
        $b.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9.5, ([System.Drawing.FontStyle]::Bold)
    } elseif ($Kind -eq 'ghost') {
        $b.BackColor = C $Theme.Field
        $b.ForeColor = C $Theme.Tx
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = C $Theme.Line
    } else {
        $b.BackColor = C $Theme.Card
        $b.ForeColor = C $Theme.Tx2
    }
    return $b
}

function New-FlatLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Color = '', [int]$Size = 9, [switch]$Bold, [string]$Bg = '')
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point $X, $Y
    $l.Size = New-Object System.Drawing.Size $W, $H
    # 不用 Transparent：WinForms 透明 Label 在深色窗体上会偶发丢字
    if ($Bg) { $l.BackColor = C $Bg } else { $l.BackColor = C $Theme.Bg }
    if ($Color) { $l.ForeColor = C $Color } else { $l.ForeColor = C $Theme.Tx2 }
    $style = [System.Drawing.FontStyle]::Regular
    if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
    $l.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', $Size, $style
    return $l
}

function New-FlatTextBox {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text = '', [switch]$Password)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point $X, $Y
    $t.Size = New-Object System.Drawing.Size $W, $H
    $t.Text = $Text
    $t.BackColor = C $Theme.Field
    $t.ForeColor = C $Theme.Tx
    $t.BorderStyle = 'FixedSingle'
    $t.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9.5
    $t.TextAlign = 'Left'      # 显式设置以触发句柄重建，确保 BackColor 生效
    if ($Password) { $t.UseSystemPasswordChar = $true }
    return $t
}

function Get-NumberOr {
    param([string]$Text, [int]$Default, [int]$Min, [int]$Max)
    $n = 0
    if ([int]::TryParse(($Text + '').Trim(), [ref]$n)) {
        if ($n -lt $Min) { $n = $Min }
        if ($n -gt $Max) { $n = $Max }
        return $n
    }
    return $Default
}

function New-FlatCombo {
    param([object[]]$Items, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Selected = 0)
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Location = New-Object System.Drawing.Point $X, $Y
    $c.Size = New-Object System.Drawing.Size $W, $H
    $c.DropDownStyle = 'DropDownList'
    $c.FlatStyle = 'Flat'
    $c.BackColor = C $Theme.Field
    $c.ForeColor = C $Theme.Tx
    $c.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9.5
    # WinForms ComboBox 的 BackColor 对下拉列表无效，必须自绘
    $c.DrawMode = 'OwnerDrawFixed'
    $c.ItemHeight = 20
    $c.Add_DrawItem({
        param($s, $e)
        $bg = C $Theme.Field
        $isSel = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
        if ($isSel) { $bg = C '#2F3745' }
        $b = New-Object System.Drawing.SolidBrush $bg
        $e.Graphics.FillRectangle($b, $e.Bounds)
        $b.Dispose()
        if ($e.Index -ge 0) {
            $tb = New-Object System.Drawing.SolidBrush (C $Theme.Tx)
            $rectF = New-Object System.Drawing.RectangleF ($e.Bounds.X + 6), ($e.Bounds.Y + 2), $e.Bounds.Width, $e.Bounds.Height
            $e.Graphics.DrawString([string]$s.Items[$e.Index], $e.Font, $tb, $rectF)
            $tb.Dispose()
        }
    })
    foreach ($i in $Items) { $c.Items.Add($i) | Out-Null }
    if ($c.Items.Count -gt 0) { $c.SelectedIndex = $Selected }
    return $c
}

# 数字输入：用 TextBox 而非 NumericUpDown（后者内部白底无法深色化）
function New-FlatNumber {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$Value)
    $t = New-FlatTextBox -X $X -Y $Y -W $W -H $H -Text ([string]$Value)
    $t.TextAlign = 'Center'
    # TextAlign 会触发句柄重建并丢失自定义背景色，必须重设
    $t.BackColor = C $Theme.Field
    $t.ForeColor = C $Theme.Tx
    return $t
}

function New-QuotaBar {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$Percent)
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point $X, $Y
    $p.Size = New-Object System.Drawing.Size $W, $H
    $p.BackColor = C $Theme.Bg
    $p.Tag = $Percent
    $p.Add_Paint({
        param($s, $e)
        $gr = $e.Graphics
        $gr.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $w = $s.Width; $h = $s.Height; $r = [int]($h / 2)
        $pct = [int]$s.Tag
        if ($pct -lt 0) { $pct = 0 }
        if ($pct -gt 100) { $pct = 100 }

        $pathBg = New-RoundedPath -W $w -H $h -R $r
        $bgb = New-Object System.Drawing.SolidBrush (C $Theme.Field)
        $gr.FillPath($bgb, $pathBg)
        $bgb.Dispose(); $pathBg.Dispose()

        if ($pct -gt 0) {
            $fw = [int]($w * $pct / 100.0)
            if ($fw -lt $h) { $fw = $h }
            $pathFg = New-RoundedPath -W $fw -H $h -R $r
            $fgb = New-Object System.Drawing.SolidBrush (C (Get-LevelColor $pct))
            $gr.FillPath($fgb, $pathFg)
            $fgb.Dispose(); $pathFg.Dispose()
        }
    })
    return $p
}

# ============================================================
# 详情面板
# ============================================================
function Show-DetailPanel {
    param($Result, [string]$ProviderName, [string]$CapturePath = '')

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Token Plan 额度'
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = C $Theme.Bg
    $form.ShowInTaskbar = $false
    $form.TopMost = $true

    $rowH = 74
    $h = 86 + ($Result.Tiers.Count * $rowH) + 58
    if ($h -lt 250) { $h = 250 }
    $form.Size = New-Object System.Drawing.Size 356, $h
    $form.Region = New-Object System.Drawing.Region (New-RoundedPath -W 356 -H $h -R 14)

    $script:drag = $false
    $script:dragPt = New-Object System.Drawing.Point 0, 0
    $form.Add_MouseDown({ param($s, $e) $script:drag = $true; $script:dragPt = $e.Location })
    $form.Add_MouseMove({
        param($s, $e)
        if ($script:drag) {
            $s.Location = New-Object System.Drawing.Point (
                ($s.Location.X + $e.X - $script:dragPt.X),
                ($s.Location.Y + $e.Y - $script:dragPt.Y))
        }
    })
    $form.Add_MouseUp({ $script:drag = $false })

    $title = New-FlatLabel -Text $ProviderName -X 20 -Y 18 -W 260 -H 22 -Color $Theme.Tx -Size 11 -Bold
    $form.Controls.Add($title)
    $sub = New-FlatLabel -Text ('更新于 ' + (Get-Date -Format 'HH:mm:ss')) -X 20 -Y 42 -W 200 -H 18 -Color $Theme.Tx3 -Size 8
    $form.Controls.Add($sub)

    $btnX = New-Object System.Windows.Forms.Label
    $btnX.Text = '✕'
    $btnX.Location = New-Object System.Drawing.Point 318, 16
    $btnX.Size = New-Object System.Drawing.Size 24, 24
    $btnX.TextAlign = 'MiddleCenter'
    $btnX.ForeColor = C $Theme.Tx3
    $btnX.BackColor = [System.Drawing.Color]::Transparent
    $btnX.Font = New-Object System.Drawing.Font 'Segoe UI', 10
    $btnX.Cursor = 'Hand'
    $btnX.Add_Click({ param($s, $e) $s.Parent.Close() })
    $btnX.Add_MouseEnter({ param($s, $e) $s.ForeColor = C $Theme.Tx })
    $btnX.Add_MouseLeave({ param($s, $e) $s.ForeColor = C $Theme.Tx3 })
    $form.Controls.Add($btnX)

    $line = New-Object System.Windows.Forms.Panel
    $line.Location = New-Object System.Drawing.Point 20, 68
    $line.Size = New-Object System.Drawing.Size 316, 1
    $line.BackColor = C $Theme.Line
    $form.Controls.Add($line)

    $y = 82
    foreach ($tier in $Result.Tiers) {
        $lbl = New-FlatLabel -Text $tier.Name -X 20 -Y $y -W 150 -H 20 -Color $Theme.Tx2 -Size 9
        $form.Controls.Add($lbl)

        $val = New-FlatLabel -Text $tier.Display -X 230 -Y $y -W 106 -H 20 -Color (Get-LevelColor $tier.Remain) -Size 10 -Bold
        $val.TextAlign = 'MiddleRight'
        $form.Controls.Add($val)

        if ($tier.Remain -ge 0) {
            $bar = New-QuotaBar -X 20 -Y ($y + 26) -W 316 -H 8 -Percent $tier.Remain
            $form.Controls.Add($bar)
        }

        if ($tier.Reset) {
            $span = $tier.Reset - (Get-Date)
            $txt = '重置 {0:MM-dd HH:mm}' -f $tier.Reset
            if ($span.TotalHours -gt 0) {
                if ($span.TotalHours -ge 24) {
                    $txt += ('（{0:N1} 天后）' -f $span.TotalDays)
                } else {
                    $txt += ('（{0:N1} 小时后）' -f $span.TotalHours)
                }
            }
            $r = New-FlatLabel -Text $txt -X 20 -Y ($y + 40) -W 290 -H 18 -Color $Theme.Tx3 -Size 8
            $form.Controls.Add($r)
        }
        $y += $rowH
    }

    $btnRefresh = New-FlatButton -Text '立即刷新' -X 20 -Y ($h - 46) -W 104 -H 30 -Kind 'ghost'
    $btnRefresh.Add_Click({ param($s, $e) $s.Parent.Tag = 'refresh'; $s.Parent.Close() })
    $form.Controls.Add($btnRefresh)

    $btnCfg = New-FlatButton -Text '设置' -X 134 -Y ($h - 46) -W 84 -H 30 -Kind 'ghost'
    $btnCfg.Add_Click({ param($s, $e) $s.Parent.Tag = 'config'; $s.Parent.Close() })
    $form.Controls.Add($btnCfg)

    if ($CapturePath) {
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point 10, 10
        $form.TopMost = $true
        $form.Show()
        $form.Activate()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 600
        [System.Windows.Forms.Application]::DoEvents()
        # 固定截左上角大区域，规避 DPI 缩放导致的坐标偏差
        $capRect = New-Object System.Drawing.Rectangle 0, 0, 620, 620
        $bmp = New-Object System.Drawing.Bitmap $capRect.Width, $capRect.Height
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen($capRect.Location, [System.Drawing.Point]::Empty, $capRect.Size)
        $gfx.Dispose()
        $bmp.Save($CapturePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $form.Close()
        $form.Dispose()
        return $null
    }

    $form.ShowDialog() | Out-Null
    $tag = $form.Tag
    $form.Dispose()
    return $tag
}

# ============================================================
# 设置窗口
# ============================================================
function Show-ConfigWindow {
    param($Cfg, [string]$CapturePath = '')

    $presets = Get-ProviderPresets
    $cur = $Cfg.providers[$Cfg.activeIndex]
    if (-not $cur) { $cur = $Cfg.providers[0] }

    $W = 580; $H = 700
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Token Plan 额度 · 设置'
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = C $Theme.Bg
    $form.Size = New-Object System.Drawing.Size $W, $H
    $form.ShowInTaskbar = $false
    $form.Region = New-Object System.Drawing.Region (New-RoundedPath -W $W -H $H -R 14)

    $bar = New-Object System.Windows.Forms.Panel
    $bar.Location = New-Object System.Drawing.Point 0, 0
    $bar.Size = New-Object System.Drawing.Size $W, 52
    $bar.BackColor = C $Theme.Bg
    $form.Controls.Add($bar)
    $script:cdrag = $false
    $script:cdragPt = New-Object System.Drawing.Point 0, 0
    $bar.Add_MouseDown({ param($s, $e) $script:cdrag = $true; $script:cdragPt = $e.Location })
    $bar.Add_MouseMove({
        param($s, $e)
        if ($script:cdrag) {
            $f = $s.Parent
            $f.Location = New-Object System.Drawing.Point (
                ($f.Location.X + $e.X - $script:cdragPt.X),
                ($f.Location.Y + $e.Y - $script:cdragPt.Y))
        }
    })
    $bar.Add_MouseUp({ $script:cdrag = $false })

    $t1 = New-FlatLabel -Text '额度设置' -X 24 -Y 16 -W 200 -H 24 -Color $Theme.Tx -Size 12 -Bold
    $bar.Controls.Add($t1)

    $btnClose = New-Object System.Windows.Forms.Label
    $btnClose.Text = '✕'
    $btnClose.Location = New-Object System.Drawing.Point 542, 14
    $btnClose.Size = New-Object System.Drawing.Size 24, 24
    $btnClose.TextAlign = 'MiddleCenter'
    $btnClose.ForeColor = C $Theme.Tx3
    $btnClose.BackColor = [System.Drawing.Color]::Transparent
    $btnClose.Font = New-Object System.Drawing.Font 'Segoe UI', 10
    $btnClose.Cursor = 'Hand'
    $btnClose.Add_Click({ param($s, $e) $s.Parent.Parent.Close() })
    $btnClose.Add_MouseEnter({ param($s, $e) $s.ForeColor = C $Theme.Tx })
    $btnClose.Add_MouseLeave({ param($s, $e) $s.ForeColor = C $Theme.Tx3 })
    $bar.Controls.Add($btnClose)

    $y = 68
    $form.Controls.Add((New-FlatLabel -Text '供应商类型' -X 24 -Y $y -W 200 -H 18 -Color $Theme.Tx3 -Size 8))
    $y += 22
    $labels = @()
    $selIdx = 0
    for ($i = 0; $i -lt $presets.Count; $i++) {
        $labels += $presets[$i].Label
        if ($presets[$i].Id -eq $cur.type) { $selIdx = $i }
    }
    $cbType = New-FlatCombo -Items $labels -X 24 -Y $y -W 532 -H 28 -Selected $selIdx
    $form.Controls.Add($cbType)
    $y += 36

    $lblHint = New-FlatLabel -Text $presets[$selIdx].Hint -X 24 -Y $y -W 532 -H 18 -Color $Theme.Tx3 -Size 8
    $form.Controls.Add($lblHint)
    $y += 26

    $form.Controls.Add((New-FlatLabel -Text 'API 地址' -X 24 -Y $y -W 200 -H 18 -Color $Theme.Tx3 -Size 8))
    $y += 22
    $tbUrl = New-FlatTextBox -X 24 -Y $y -W 532 -H 26 -Text $cur.apiUrl
    $form.Controls.Add($tbUrl)
    $y += 38

    $form.Controls.Add((New-FlatLabel -Text 'API Key' -X 24 -Y $y -W 200 -H 18 -Color $Theme.Tx3 -Size 8))
    $y += 22
    $tbKey = New-FlatTextBox -X 24 -Y $y -W 400 -H 26 -Text (Unprotect-String $cur.apiKey) -Password
    $form.Controls.Add($tbKey)

    $btnAuto = New-FlatButton -Text '自动探测' -X 432 -Y $y -W 124 -H 26 -Kind 'ghost'
    $form.Controls.Add($btnAuto)
    $y += 38

    $form.Controls.Add((New-FlatLabel -Text '刷新间隔（分钟）' -X 24 -Y $y -W 170 -H 18 -Color $Theme.Tx3 -Size 8))
    $form.Controls.Add((New-FlatLabel -Text '认证方式' -X 240 -Y $y -W 160 -H 18 -Color $Theme.Tx3 -Size 8))
    $y += 22
    $tbInterval = New-FlatNumber -X 24 -Y $y -W 120 -H 26 -Value ([int]$cur.refreshMinutes)
    $form.Controls.Add($tbInterval)

    $cbAuth = New-FlatCombo -Items @('Bearer 前缀（多数供应商）', '裸 Key（智谱等）') -X 240 -Y $y -W 200 -H 26
    if ($cur.authMode -eq 'raw') { $cbAuth.SelectedIndex = 1 } else { $cbAuth.SelectedIndex = 0 }
    $form.Controls.Add($cbAuth)
    $y += 38

    $form.Controls.Add((New-FlatLabel -Text '图标样式' -X 24 -Y $y -W 160 -H 18 -Color $Theme.Tx3 -Size 8))
    $y += 22
    $cbIcon = New-FlatCombo -Items @('环形进度 + 数字（推荐）', '实心圆盘 + 数字', '纯数字描边') -X 24 -Y $y -W 200 -H 26
    if ($Cfg.iconStyle -eq 'disk') { $cbIcon.SelectedIndex = 1 }
    elseif ($Cfg.iconStyle -eq 'text') { $cbIcon.SelectedIndex = 2 }
    else { $cbIcon.SelectedIndex = 0 }
    $form.Controls.Add($cbIcon)

    $previewBox = New-Object System.Windows.Forms.PictureBox
    $previewBox.Location = New-Object System.Drawing.Point 240, ($y - 2)
    $previewBox.Size = New-Object System.Drawing.Size 148, 48
    $previewBox.BackColor = C $Theme.Field
    $previewBox.SizeMode = 'Zoom'
    $form.Controls.Add($previewBox)

    $lblPreviewHint = New-FlatLabel -Text '预览：充裕 / 偏紧 / 未知' -X 240 -Y ($y + 48) -W 200 -H 16 -Color $Theme.Tx3 -Size 7
    $form.Controls.Add($lblPreviewHint)
    $y += 64

    $form.Controls.Add((New-FlatLabel -Text '偏紧阈值 (%)' -X 24 -Y $y -W 170 -H 18 -Color $Theme.Tx3 -Size 8))
    $form.Controls.Add((New-FlatLabel -Text '告急阈值 (%)' -X 240 -Y $y -W 160 -H 18 -Color $Theme.Tx3 -Size 8))
    $y += 22
    $tbWarn = New-FlatNumber -X 24 -Y $y -W 120 -H 26 -Value ([int]$Cfg.warnThreshold)
    $form.Controls.Add($tbWarn)

    $tbCrit = New-FlatNumber -X 240 -Y $y -W 120 -H 26 -Value ([int]$Cfg.critThreshold)
    $form.Controls.Add($tbCrit)
    $y += 38

    $chkBoot = New-Object System.Windows.Forms.CheckBox
    $chkBoot.Text = '开机时自动启动'
    $chkBoot.Location = New-Object System.Drawing.Point 24, $y
    $chkBoot.Size = New-Object System.Drawing.Size 200, 24
    $chkBoot.ForeColor = C $Theme.Tx2
    $chkBoot.BackColor = [System.Drawing.Color]::Transparent
    $chkBoot.FlatStyle = 'Flat'
    $chkBoot.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 9.5
    $chkBoot.Checked = [bool]$Cfg.startWithBoot
    $form.Controls.Add($chkBoot)
    $y += 34

    $lblVp = New-FlatLabel -Text '剩余百分比路径（自定义类型必填）' -X 24 -Y $y -W 300 -H 18 -Color $Theme.Tx3 -Size 8
    $tbVp = New-FlatTextBox -X 24 -Y ($y + 20) -W 532 -H 26 -Text $cur.valuePath
    $tbVp.Enabled = ($cur.type -eq 'custom')
    $form.Controls.Add($lblVp); $form.Controls.Add($tbVp)
    $y += 54

    $statusPanel = New-Object System.Windows.Forms.Panel
    $statusPanel.Location = New-Object System.Drawing.Point 24, $y
    $statusPanel.Size = New-Object System.Drawing.Size 532, 46
    $statusPanel.BackColor = C '#1B2230'
    $statusPanel.Add_Paint({
        param($s, $e)
        $gr = $e.Graphics
        $gr.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $p = New-RoundedPath -W ($s.Width - 1) -H ($s.Height - 1) -R 8
        $pen = New-Object System.Drawing.Pen (C $Theme.Line), 1
        $gr.DrawPath($pen, $p)
        $pen.Dispose(); $p.Dispose()
        # 左侧强调条
        $accent = New-Object System.Drawing.SolidBrush (C $Theme.Accent)
        $gr.FillRectangle($accent, 0, 10, 3, ($s.Height - 20))
        $accent.Dispose()
    })
    $form.Controls.Add($statusPanel)

    $statusText = New-FlatLabel -Text '填好信息后点「测试连接」' -X 12 -Y 13 -W 508 -H 20 -Color $Theme.Tx2 -Size 9 -Bg '#1B2230'
    $statusPanel.Controls.Add($statusText)

    $by = $H - 58
    $btnTest = New-FlatButton -Text '测试连接' -X 24 -Y $by -W 120 -H 34 -Kind 'ghost'
    $btnSave = New-FlatButton -Text '保存' -X 396 -Y $by -W 160 -H 34 -Kind 'primary'
    $form.Controls.Add($btnTest)
    $form.Controls.Add($btnSave)

    # ---- 事件 ----
    $updatePreview = {
        $style = 'ring'
        if ($cbIcon.SelectedIndex -eq 1) { $style = 'disk' }
        elseif ($cbIcon.SelectedIndex -eq 2) { $style = 'text' }
        $sheet = New-Object System.Drawing.Bitmap 148, 48
        $sg = [System.Drawing.Graphics]::FromImage($sheet)
        $sg.Clear((C '#202020'))
        $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $i1 = New-QuotaIcon -Percent 67 -Text '67' -Style $style
        $sg.DrawImage($i1.Bitmap, 10, 8, 32, 32)
        $i2 = New-QuotaIcon -Percent 15 -Text '15' -Style $style
        $sg.DrawImage($i2.Bitmap, 58, 8, 32, 32)
        $i3 = New-QuotaIcon -Percent -1 -Text '--' -Style $style
        $sg.DrawImage($i3.Bitmap, 106, 8, 32, 32)
        $sg.Dispose()
        $oldImg = $previewBox.Image
        $previewBox.Image = $sheet
        if ($oldImg) { $oldImg.Dispose() }
        $i1.Bitmap.Dispose(); $i2.Bitmap.Dispose(); $i3.Bitmap.Dispose()
    }
    $cbIcon.Add_SelectedIndexChanged($updatePreview)
    & $updatePreview

    $cbType.Add_SelectedIndexChanged({
        $p = $presets[$cbType.SelectedIndex]
        if ($p.Url) { $tbUrl.Text = $p.Url }
        if ($p.Auth -eq 'raw') { $cbAuth.SelectedIndex = 1 } else { $cbAuth.SelectedIndex = 0 }
        $lblHint.Text = $p.Hint
        $tbVp.Enabled = ($p.Id -eq 'custom')
    })

    $btnAuto.Add_Click({
        $btnAuto.Enabled = $false
        $btnAuto.Text = '探测中…'
        [System.Windows.Forms.Application]::DoEvents()
        $p = $presets[$cbType.SelectedIndex]
        $found = Find-WorkingKey -Type $p.Id
        if ($found) {
            $tbKey.Text = $found.Key
            $statusText.Text = ('✓ 从 {0} 找到可用 Key' -f $found.Src)
            $statusText.ForeColor = C $Theme.Ok
        } else {
            $statusText.Text = '✗ 未找到可用 Key，请手动填写'
            $statusText.ForeColor = C $Theme.Warn
        }
        $btnAuto.Enabled = $true
        $btnAuto.Text = '自动探测'
    })

    $btnTest.Add_Click({
        $p = $presets[$cbType.SelectedIndex]
        $probe = [pscustomobject]@{
            name = $p.Label; type = $p.Id; apiUrl = $tbUrl.Text.Trim()
            apiKey = ''; authMode = 'bearer'; refreshMinutes = 5; enabled = $true
            valuePath = $tbVp.Text.Trim(); resetPath = ''
        }
        if ($cbAuth.SelectedIndex -eq 1) { $probe.authMode = 'raw' }

        $statusText.Text = '正在测试…'
        $statusText.ForeColor = C $Theme.Tx2
        [System.Windows.Forms.Application]::DoEvents()

        $r = Invoke-Provider -Provider $probe -OverrideKey $tbKey.Text.Trim()
        if ($r.Ok) {
            $parts = @()
            foreach ($t in $r.Tiers) { $parts += ('{0} {1}' -f $t.Name, $t.Display) }
            $statusText.Text = ('✓ 连接成功 · ' + ($parts -join ' · '))
            $statusText.ForeColor = C $Theme.Ok
        } else {
            $statusText.Text = ('✗ ' + $r.Error)
            $statusText.ForeColor = C $Theme.Danger
        }
    })

    $btnSave.Add_Click({
        $p = $presets[$cbType.SelectedIndex]
        $style = 'ring'
        if ($cbIcon.SelectedIndex -eq 1) { $style = 'disk' }
        elseif ($cbIcon.SelectedIndex -eq 2) { $style = 'text' }

        $prov = [pscustomobject]@{
            name           = $p.Label
            type           = $p.Id
            apiUrl         = $tbUrl.Text.Trim()
            apiKey         = (Protect-String $tbKey.Text.Trim())
            authMode       = 'bearer'
            refreshMinutes = (Get-NumberOr -Text $tbInterval.Text -Default 5 -Min 1 -Max 1440)
            enabled        = $true
            valuePath      = $tbVp.Text.Trim()
            resetPath      = ''
        }
        if ($cbAuth.SelectedIndex -eq 1) { $prov.authMode = 'raw' }

        $Cfg.providers = @($prov)
        $Cfg.activeIndex = 0
        $Cfg.iconStyle = $style
        $Cfg.warnThreshold = (Get-NumberOr -Text $tbWarn.Text -Default 25 -Min 0 -Max 100)
        $Cfg.critThreshold = (Get-NumberOr -Text $tbCrit.Text -Default 10 -Min 0 -Max 100)
        $Cfg.startWithBoot = $chkBoot.Checked

        Save-Config -Cfg $Cfg
        Set-Autostart -Enable $chkBoot.Checked

        $form.Tag = 'saved'
        $form.Close()
    })

    # 开发用：非模态显示后用屏幕截取，校验真实渲染效果（DrawToBitmap 对原生控件不准）
    if ($CapturePath) {
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point 10, 10
        $form.TopMost = $true
        $form.Show()
        $form.Activate()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 700
        [System.Windows.Forms.Application]::DoEvents()
        # 截取固定大区域，规避 DPI 缩放导致的坐标偏差
        $capRect = New-Object System.Drawing.Rectangle 0, 0, 1100, 1150
        $bmp = New-Object System.Drawing.Bitmap $capRect.Width, $capRect.Height
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen($capRect.Location, [System.Drawing.Point]::Empty, $capRect.Size)
        $gfx.Dispose()
        $bmp.Save($CapturePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $form.Close()
        $form.Dispose()
        return $false
    }

    $form.ShowDialog() | Out-Null
    $saved = ($form.Tag -eq 'saved')
    $form.Dispose()
    return $saved
}

# ============================================================
# 开机自启
# ============================================================
function Set-Autostart {
    param([bool]$Enable)
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $name = 'QuotaTray'
    try {
        if ($Enable) {
            $scriptPath = $PSCommandPath
            if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
            $cmd = ('powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath)
            Set-ItemProperty -Path $runKey -Name $name -Value $cmd -Force
        } else {
            Remove-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log ('设置开机自启失败: ' + $_.Exception.Message)
    }
}

# ============================================================
# 主流程
# ============================================================
$script:Cfg = Load-Config
$script:LastResult = $null
$script:FailCount = 0

# 首次运行：配置里没有 Key 时自动探测（读 .codex / .claude / 环境变量，逐个试）
$firstProv = $script:Cfg.providers[0]
if ($firstProv -and -not (Unprotect-String $firstProv.apiKey)) {
    Write-Log '未配置 Key，尝试自动探测'
    $found = Find-WorkingKey -Type $firstProv.type
    if ($found) {
        $firstProv.apiKey = Protect-String $found.Key
        Save-Config -Cfg $script:Cfg
        Write-Log ('自动探测成功: ' + $found.Src)
    }
}

function Get-ActiveProvider {
    $p = $script:Cfg.providers[$script:Cfg.activeIndex]
    if (-not $p) { $p = $script:Cfg.providers[0] }
    return $p
}

function Update-Tray {
    $prov = Get-ActiveProvider
    $r = Invoke-Provider -Provider $prov
    if ($r.Ok) {
        $script:LastResult = $r
        $script:FailCount = 0

        $pct = -1
        if ($r.Tiers.Count -gt 0) { $pct = $r.Tiers[0].Remain }

        $text = '--'
        if ($pct -ge 0) { $text = [string]$pct }
        $ic = New-QuotaIcon -Percent $pct -Text $text -Style $script:Cfg.iconStyle
        $old = $script:tray.Icon
        $script:tray.Icon = $ic.Icon
        if ($old) { $old.Dispose() }

        $parts = @()
        foreach ($t in $r.Tiers) { $parts += ('{0} {1}' -f $t.Name, $t.Display) }
        $tip = ($prov.name + ' · ' + ($parts -join ' · '))
        if ($tip.Length -gt 62) { $tip = $tip.Substring(0, 62) }
        $script:tray.Text = $tip
    } else {
        $script:FailCount++
        $tip = ('额度查询失败：' + $r.Error)
        if ($tip.Length -gt 62) { $tip = $tip.Substring(0, 62) }
        $script:tray.Text = $tip
        Write-Log ('查询失败: ' + $r.Error)

        if (-not $script:LastResult) {
            $ic = New-QuotaIcon -Percent -1 -Text '--' -Style $script:Cfg.iconStyle
            $old = $script:tray.Icon
            $script:tray.Icon = $ic.Icon
            if ($old) { $old.Dispose() }
        }
    }
}

# ---- Test 模式 ----
if ($Test) {
    $prov = Get-ActiveProvider
    Write-Host ('供应商: {0}  ({1})' -f $prov.name, $prov.type)
    Write-Host ('地址  : {0}' -f $prov.apiUrl)
    Write-Host ''
    $r = Invoke-Provider -Provider $prov
    if ($r.Ok) {
        Write-Host ('套餐: ' + $r.PlanName) -ForegroundColor Cyan
        foreach ($t in $r.Tiers) {
            $line = '  {0,-8} 剩余 {1,-6}' -f $t.Name, $t.Display
            if ($t.Reset) { $line += ('  重置 {0:MM-dd HH:mm}' -f $t.Reset) }
            Write-Host $line
        }
    } else {
        Write-Host ('失败: ' + $r.Error) -ForegroundColor Red
    }
    exit 0
}

# ---- Config 模式 ----
if ($Config) {
    Show-ConfigWindow -Cfg $script:Cfg | Out-Null
    exit 0
}

# ---- Screenshot 模式 ----
if ($Screenshot) {
    $dir = $PSScriptRoot
    $sheet = New-Object System.Drawing.Bitmap 640, 130
    $sg = [System.Drawing.Graphics]::FromImage($sheet)
    $sg.Clear((C '#1A1A1A'))
    $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $styles = @('ring', 'disk', 'text')
    $names = @('ring', 'disk', 'text')
    $xs = 24
    for ($si = 0; $si -lt 3; $si++) {
        $st = $styles[$si]
        $i1 = New-QuotaIcon -Percent 67 -Text '67' -Style $st
        $sg.DrawImage($i1.Bitmap, $xs, 20, 44, 44)
        $i1.Bitmap.Dispose()
        $i2 = New-QuotaIcon -Percent 15 -Text '15' -Style $st
        $sg.DrawImage($i2.Bitmap, $xs, 76, 28, 28)
        $i2.Bitmap.Dispose()
        $i3 = New-QuotaIcon -Percent -1 -Text '--' -Style $st
        $sg.DrawImage($i3.Bitmap, ($xs + 36), 76, 28, 28)
        $i3.Bitmap.Dispose()
        $xs += 200
    }
    $sg.Dispose()
    $out = Join-Path $dir 'icon-styles.png'
    $sheet.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $sheet.Dispose()
    Write-Host "已导出: $out"

    $cfgShot = Join-Path $dir 'config-preview.png'
    Show-ConfigWindow -Cfg $script:Cfg -CapturePath $cfgShot | Out-Null
    Write-Host "已导出: $cfgShot"

    $r = Invoke-Provider -Provider (Get-ActiveProvider)
    if ($r.Ok) {
        $detailShot = Join-Path $dir 'detail-preview.png'
        Show-DetailPanel -Result $r -ProviderName (Get-ActiveProvider).name -CapturePath $detailShot | Out-Null
        Write-Host "已导出: $detailShot"
    }
    exit 0
}

# ---- 托盘模式 ----
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Visible = $true
$script:tray.ContextMenuStrip = New-Object System.Windows.Forms.ContextMenuStrip
$script:tray.ContextMenuStrip.BackColor = C $Theme.Card
$script:tray.ContextMenuStrip.ForeColor = C $Theme.Tx

$miRefresh = $script:tray.ContextMenuStrip.Items.Add('立即刷新')
$miDetail  = $script:tray.ContextMenuStrip.Items.Add('查看详情')
$script:tray.ContextMenuStrip.Items.Add('-') | Out-Null
$miConfig  = $script:tray.ContextMenuStrip.Items.Add('设置…')
$script:tray.ContextMenuStrip.Items.Add('-') | Out-Null
$miExit    = $script:tray.ContextMenuStrip.Items.Add('退出')

$miRefresh.add_Click({ Update-Tray })
$miDetail.add_Click({
    if ($script:LastResult) {
        $tag = Show-DetailPanel -Result $script:LastResult -ProviderName (Get-ActiveProvider).name
        if ($tag -eq 'refresh') { Update-Tray }
        elseif ($tag -eq 'config') { Invoke-ConfigFlow }
    }
})
$miConfig.add_Click({ Invoke-ConfigFlow })
$miExit.add_Click({
    $script:tray.Visible = $false
    $script:tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

function Invoke-ConfigFlow {
    if (Show-ConfigWindow -Cfg $script:Cfg) {
        $script:Cfg = Load-Config
        # 刷新间隔可能变了，重建定时器
        $p = Get-ActiveProvider
        $mins = 5
        if ($p -and $p.refreshMinutes) { $mins = [int]$p.refreshMinutes }
        $script:timer.Interval = [Math]::Max(1, $mins) * 60 * 1000
        Update-Tray
    }
}

$script:tray.add_MouseClick({
    param($s, $e)
    if ($e.Button -eq 'Left') {
        if ($script:LastResult) {
            $tag = Show-DetailPanel -Result $script:LastResult -ProviderName (Get-ActiveProvider).name
            if ($tag -eq 'refresh') { Update-Tray }
            elseif ($tag -eq 'config') { Invoke-ConfigFlow }
        } else {
            Update-Tray
        }
    }
})

$script:timer = New-Object System.Windows.Forms.Timer
$prov0 = Get-ActiveProvider
$intervalMin = 5
if ($prov0 -and $prov0.refreshMinutes) { $intervalMin = [int]$prov0.refreshMinutes }
$script:timer.Interval = [Math]::Max(1, $intervalMin) * 60 * 1000
$script:timer.add_Tick({ Update-Tray })
$script:timer.Start()

Write-Log ('启动 v' + $script:Version)
Update-Tray
[System.Windows.Forms.Application]::Run()
