# QuotaCore.ps1 — 数据层（多账户额度查询）
# 被 TokenPanel.ps1 dot-source 引入
# 职责：配置读写 / 凭据加解密 / 各供应商请求与解析

# ============================================================
# 应用身份（改名/改版本只需动这三行）
# ============================================================
$script:AppName    = 'TokenPanel'
$script:AppVersion = '1.3.0'
$script:AppChannel = '内测版'
$script:AppId      = 'TokenPanel'
# UserAgent 不能带空格，单独给一个
$script:UserAgent  = 'TokenPanel/' + $script:AppVersion

$script:CoreVersion = '4.1'
$script:ConfigDir   = Join-Path $env:APPDATA $script:AppId
$script:ConfigPath  = Join-Path $script:ConfigDir 'config.json'
$script:LogPath     = Join-Path $script:ConfigDir 'app.log'
$script:HttpTimeout = 15      # 秒，由配置里的 timeout 覆盖

# WorkBuddy 积分查询（无头 Chrome 页面内请求，见 lib\wb\wb_query.js 头注释）
$script:WbDir       = Join-Path $PSScriptRoot 'wb'
$script:WbStatePath = Join-Path $script:ConfigDir 'wb_state.json'   # 运行态：时间戳/冷却/授权时间
$script:WbLastPath  = Join-Path $script:ConfigDir 'wb_last.json'    # 上次原始查询输出（单独存文件：
                                                                    # PS 5.1 的 ConvertTo-Json 会把超长字符串
                                                                    # 包装成 {"value":...} 对象，不能塞状态 JSON）
$script:WbCacheMin  = 30        # 查询结果缓存分钟数（不再短于此间隔重复拉起 Chrome）
$script:WbCooldownH = 1         # 登录态过期（401/403）后的冷却小时数
$script:WbTimeoutMs = 30000     # 单次查询超时（毫秒），超时强杀进程树

# 配置目录迁移。品牌改过三次：TokenPanel(旧托盘版) → TokenPocket(v1.0.5~v1.2.3) → TokenPanel(现在)。
# 本机实测 %APPDATA%\TokenPanel 里还留着 10-29 的陈旧配置，若按「目标不存在才复制」的旧规则，
# 会读到那份旧账户/旧密钥。规则改成：**config.json 更新的那份胜出**，输的一份改名备份、不删除。
try {
    $legacies = @('TokenPocket', 'TokenPanel') | Where-Object { $_ -ne $script:AppId }
    $curTime = if (Test-Path $script:ConfigPath) { (Get-Item $script:ConfigPath).LastWriteTimeUtc } else { [datetime]::MinValue }
    $bestDir = $null
    $bestTime = $curTime
    foreach ($legacy in $legacies) {
        $d = Join-Path $env:APPDATA $legacy
        $c = Join-Path $d 'config.json'
        if (Test-Path $c) {
            $t = (Get-Item $c).LastWriteTimeUtc
            if ($t -gt $bestTime) { $bestTime = $t; $bestDir = $d }
        }
    }
    if ($bestDir) {
        if (Test-Path $script:ConfigDir) {
            $bak = $script:ConfigDir + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Move-Item -LiteralPath $script:ConfigDir -Destination $bak -Force
            Write-CoreLog ('旧配置目录已备份到 ' + $bak)
        }
        Copy-Item -LiteralPath $bestDir -Destination $script:ConfigDir -Recurse -Force
        Write-CoreLog ('已从 ' + $bestDir + ' 迁移配置（时间更新的一份）')
    }
} catch { }

# ============================================================
# 日志
# ============================================================
function Write-CoreLog {
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
# DPAPI（绑定当前 Windows 用户）
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
# 模板（对照 CC Switch 的用量查询模板体系）
# 每个模板决定三件事：显示哪些字段 / 用什么认证头 / 用什么解析器
# ============================================================
function Get-TemplateDefs {
    return @(
        @{ Id = 'custom';    Label = '自定义';    Hint = '自己填请求地址 + 提取路径，可指定倍数与单位（% 或 ¥ / $）' }
        @{ Id = 'general';   Label = '通用模板';  Hint = '标准余额接口：GET {BaseURL}/user/balance，读取 balance 字段' }
        @{ Id = 'newapi';    Label = 'NewAPI';    Hint = 'New API 中转站：Access Token + User ID，读取 quota / used_quota' }
        @{ Id = 'tokenplan'; Label = 'Token Plan'; Hint = '内置套餐额度：选供应商自动填地址与解析器，显示 5 小时 / 7 天窗口' }
        @{ Id = 'balance';   Label = '账户余额'; Hint = '官方钱包余额：DeepSeek / 硅基流动 / OpenRouter / 阶跃星辰' }
        @{ Id = 'official';  Label = '官方';      Hint = '官方 agent 额度：Claude / Codex 读本机 CLI 的 OAuth，WorkBuddy 点「授权登录」后查询积分' }
    )
}

# ============================================================
# 配色（两套：深色 / 浅色，浅色对齐 Windows 11 浅色系统配色）
#   TokenPanel.ps1 用 Get-MainTheme，配置页用 Get-CwTheme。
#   两边键名一一对应，改配色只动这里，不要再往绘制代码里写死颜色。
# ============================================================
function Get-MainTheme {
    param([string]$Name = 'dark')
    if ($Name -eq 'light') {
        return @{
            Bg        = '#F7F7F8'     # 悬浮窗底
            BgHover   = '#EFEFF1'
            Track     = '#E3E3E6'     # 进度条底
            Line      = '#DDDDDF'
            Tx        = '#1B1B1B'
            Tx2       = '#5A5A5E'
            Tx3       = '#8B8B90'
            Cy        = '#0E7C6B'     # 正常（加深以保证浅底上的对比度）
            Am        = '#B45309'
            Rd        = '#C42B1C'
            RingText  = '#1B1B1B'     # 圆环里的数字
            TrackRing = '#DCDCDE'     # 圆环底环
            Glow      = '#0067C0'     # 双击刷新动效的光弧（浅底上用强调蓝）
            Foot      = '#8B8B90'     # 底部状态文字
            Border    = '#E2E2E4'     # 浅色下需要一条描边，否则白窗贴白墙看不见
        }
    }
    return @{
        Bg        = '#1C1F27'
        BgHover   = '#21252E'
        Track     = '#22262F'
        Line      = '#2E333F'
        Tx        = '#E6EDF3'
        Tx2       = '#9AA5B5'
        Tx3       = '#6B7686'
        Cy        = '#2DD4BF'
        Am        = '#F5A524'
        Rd        = '#F04452'
        RingText  = '#FFFFFF'
        TrackRing = '#333947'
        Glow      = '#8CF5E3'       # 双击刷新动效的光弧（深底上用亮青）
        Foot      = '#55606F'
        Border    = ''
    }
}

function Get-CwTheme {
    param([string]$Name = 'dark')
    if ($Name -eq 'light') {
        return @{
            Bg      = '#F3F3F3'
            Card    = '#FFFFFF'
            Field   = '#FFFFFF'
            Line    = '#D8D8DC'
            Tx      = '#1A1A1A'
            Tx2     = '#5D5D62'
            Tx3     = '#8A8A8F'
            Accent  = '#0067C0'
            AccentH = '#1976D2'
            Cy      = '#0E7C6B'
            Am      = '#B45309'
            Rd      = '#C42B1C'
            Sunken  = '#F5F5F7'      # 状态条 / 内嵌块
            CodeBg  = '#FBFBFD'      # 提取器代码框
            CodeFg  = '#1F5F3F'
            Sel     = '#E5F0FB'      # 账户列表选中项
            DelFg   = '#B42318'
            DelLine = '#E7C3C0'
        }
    }
    return @{
        Bg      = '#1A1A1A'
        Card    = '#232323'
        Field   = '#1E1E1E'
        Line    = '#333333'
        Tx      = '#E8E8E8'
        Tx2     = '#9A9A9A'
        Tx3     = '#6A6A6A'
        Accent  = '#2563EB'
        AccentH = '#3B82F6'
        Cy      = '#2DD4BF'
        Am      = '#F5A524'
        Rd      = '#F04452'
        Sunken  = '#1E1E1E'
        CodeBg  = '#151515'
        CodeFg  = '#8FB89B'
        Sel     = '#2E2E2E'
        DelFg   = '#C97A7A'
        DelLine = '#4A2626'
    }
}

# ============================================================
# 模板透明化：CC Switch 的用量模板是「request + extractor 函数 + 变量占位符」
#   支持变量：{{apiKey}} {{baseUrl}} {{accessToken}} {{userId}}
#   extractor 返回契约（从 CC Switch 二进制里核对过）：
#     isValid / invalidMessage / remaining / unit / total / used / planName / extra
# 我们没有 JS 引擎，执行的是 PowerShell 原生解析器，
# 所以这里只做「等价脚本」的生成展示：字段一改，展示的代码立刻跟着变，可直接复制回 CC Switch。
# ============================================================
function Get-TemplateVars {
    param([string]$Tpl)
    $s = '变量：{{apiKey}}  {{baseUrl}}  {{accessToken}}  {{userId}}'
    switch ($Tpl) {
        'newapi'   { $s += '　（本模板不用 {{apiKey}}）' }
        'official' { $s += '　（本模板不用密钥，读本机 CLI 的 OAuth）' }
    }
    return $s
}

function Get-ExtractorPreview {
    param([string]$Tpl, [string]$Type, [string]$Url, [string]$ValuePath, [string]$Scale, [string]$Unit)

    $u = if ($Url) { $Url } else { 'https://…' }
    $pv = if ($ValuePath) { $ValuePath } else { 'data.balance' }
    $sc = if ($Scale) { $Scale } else { '1' }
    $un = if ($Unit) { $Unit } else { '%' }
    $a = @()

    switch ($Tpl) {
        'custom' {
            $a = @(
                '// 自定义模板：URL 与提取路径都由你填',
                '({',
                '  request: {',
                ('    url: "' + $u + '",'),
                '    method: "GET",',
                '    headers: { "Authorization": "Bearer {{apiKey}}" }',
                '  },',
                '  extractor: function (response) {',
                ('    var v = response.' + $pv + '        // ← 提取路径'),
                ('    // 倍数 ' + $sc + '；单位 "' + $un + '"（% 表示额度百分比，¥ / $ 表示余额）'),
                '    return {',
                '      isValid: v !== undefined && v !== null,',
                ('      remaining: v * ' + $sc + ','),
                ('      unit: "' + $un + '"'),
                '    }',
                '  }',
                '})'
            )
        }
        'general' {
            $a = @(
                '// 通用模板：{baseUrl}/user/balance 读取 balance',
                '({',
                '  request: {',
                '    url: "{{baseUrl}}/user/balance",',
                '    method: "GET",',
                '    headers: { "Authorization": "Bearer {{apiKey}}" }',
                '  },',
                '  extractor: function (response) {',
                '    return {',
                '      isValid: response.is_active !== false,',
                '      remaining: response.balance,',
                '      unit: response.unit || "USD"',
                '    }',
                '  }',
                '})'
            )
        }
        'newapi' {
            $a = @(
                '// NewAPI：额度单位 500000 = 1 USD',
                '({',
                '  request: {',
                '    url: "{{baseUrl}}/api/user/self",',
                '    method: "GET",',
                '    headers: {',
                '      "Authorization": "Bearer {{accessToken}}",',
                '      "New-Api-User": "{{userId}}"',
                '    }',
                '  },',
                '  extractor: function (response) {',
                '    if (!response.success) return { isValid: false, invalidMessage: response.message }',
                '    var quota = response.data.quota / 500000',
                '    var used  = response.data.used_quota / 500000',
                '    return { isValid: true, remaining: quota, used: used,',
                '             total: quota + used, unit: "USD", planName: response.data.group }',
                '  }',
                '})'
            )
        }
        'tokenplan' {
            switch ($Type) {
                'minimax' {
                    $a = @(
                        '// MiniMax Coding Plan：双窗口（5小时 / 7天）',
                        '({',
                        '  request: {',
                        ('    url: "' + $u + '",'),
                        '    method: "GET",',
                        '    headers: { "Authorization": "Bearer {{apiKey}}" }',
                        '  },',
                        '  extractor: function (response) {',
                        '    var g = response.model_remains.filter(function (m) { return m.model_name === "general" })[0]',
                        '    return [',
                        '      { name: "5小时", remaining: g.current_interval_remaining_percent, resetAt: g.end_time },',
                        '      { name: "7天",   remaining: g.current_weekly_remaining_percent, resetAt: g.weekly_end_time }',
                        '    ]',
                        '  }',
                        '})'
                    )
                }
                'kimi' {
                    $a = @(
                        '// Kimi For Coding：用 limit / remaining 反算百分比',
                        '({',
                        '  request: { url: "' + $u + '", method: "GET",',
                        '             headers: { "Authorization": "Bearer {{apiKey}}" } },',
                        '  extractor: function (r) {',
                        '    var a = r.limits[0].detail, b = r.usage',
                        '    return [',
                        '      { name: "5小时", remaining: 100 * (1 - (a.limit - a.remaining) / a.limit), resetAt: a.resetTime },',
                        '      { name: "7天",   remaining: 100 * (1 - (b.limit - b.remaining) / b.limit), resetAt: b.resetTime }',
                        '    ]',
                        '  }',
                        '})'
                    )
                }
                'zhipu' {
                    $a = @(
                        '// 智谱 GLM：裸 Key，不加 Bearer 前缀',
                        '({',
                        '  request: { url: "' + $u + '", method: "GET",',
                        '             headers: { "Authorization": "{{apiKey}}" } },',
                        '  extractor: function (r) {',
                        '    return r.data.limits.map(function (l, i) {',
                        '      return { name: i === 0 ? "5h" : "本周",',
                        '               remaining: 100 - l.percentage, resetAt: l.nextResetTime }',
                        '    })',
                        '  }',
                        '})'
                    )
                }
                default {
                    $a = @(
                        '// OpenCode Go：rolling / weekly / monthly 三个窗口',
                        '({',
                        '  request: { url: "' + $u + '", method: "GET",',
                        '             headers: { "Authorization": "Bearer {{apiKey}}" } },',
                        '  extractor: function (r) {',
                        '    return ["rolling", "weekly", "monthly"].map(function (k) {',
                        '      var w = r.usage[k]',
                        '      return { name: k, remaining: 100 - w.percent }',
                        '    })',
                        '  }',
                        '})'
                    )
                }
            }
        }
        'balance' {
            switch ($Type) {
                'deepseek' {
                    $a = @(
                        '// DeepSeek 钱包余额：欠费时 is_available=false，但 balance_infos 仍是真实负数',
                        '({',
                        '  request: { url: "' + $u + '", method: "GET",',
                        '             headers: { "Authorization": "Bearer {{apiKey}}" } },',
                        '  extractor: function (r) {',
                        '    var b = r.balance_infos[0]',
                        '    return { isValid: r.is_available !== false,',
                        '             remaining: parseFloat(b.total_balance),',
                        '             unit: b.currency === "USD" ? "$" : "¥" }',
                        '  }',
                        '})'
                    )
                }
                'siliconflow' {
                    $a = @(
                        '// 硅基流动：读 data.totalBalance',
                        '({',
                        '  request: { url: "' + $u + '", method: "GET",',
                        '             headers: { "Authorization": "Bearer {{apiKey}}" } },',
                        '  extractor: function (r) {',
                        '    return { isValid: true, remaining: parseFloat(r.data.totalBalance), unit: "¥" }',
                        '  }',
                        '})'
                    )
                }
                'openrouter' {
                    $a = @(
                        '// OpenRouter：总额度 − 已用 = 剩余',
                        '({',
                        '  request: { url: "' + $u + '", method: "GET",',
                        '             headers: { "Authorization": "Bearer {{apiKey}}" } },',
                        '  extractor: function (r) {',
                        '    return { isValid: true,',
                        '             remaining: r.data.total_credits - r.data.total_usage,',
                        '             total: r.data.total_credits, unit: "$" }',
                        '  }',
                        '})'
                    )
                }
                default {
                    $a = @(
                        '// 阶跃星辰等：容错扫描常见余额字段',
                        '({',
                        '  request: { url: "' + $u + '", method: "GET",',
                        '             headers: { "Authorization": "Bearer {{apiKey}}" } },',
                        '  extractor: function (r) {',
                        '    var v = r.data.balance || r.balance || r.data.total_balance',
                        '    return { isValid: v !== undefined, remaining: parseFloat(v), unit: "¥" }',
                        '  }',
                        '})'
                    )
                }
            }
        }
        default {
            # official
            if ($Type -eq 'workbuddy') {
                $a = @(
                    '// 官方模板（WorkBuddy）：无头 Chrome 页面内 fetch（网关按 TLS 指纹放行浏览器）',
                    '({',
                    '  request: {',
                    '    url: "https://www.workbuddy.cn/billing/meter/get-user-resource-summary",',
                    '    method: "POST", body: "{}"   // 经 Chromium 网络栈发出',
                    '  },',
                    '  extractor: function (r) {',
                    '    return { isValid: r.code === 0,',
                    '             remaining: parseFloat(r.data.TotalCredits),',
                    '             unit: "credits", planName: r.data.SubscriptionPackageName }',
                    '  }',
                    '})'
                )
            } elseif ($Type -eq 'claude') {
                $a = @(
                    '// 官方模板：不使用 {{apiKey}}，Token 来自 ~/.claude/.credentials.json',
                    '({',
                    '  request: {',
                    '    url: "https://api.anthropic.com/api/oauth/usage",',
                    '    method: "GET",',
                    '    headers: { "Authorization": "Bearer <本机 OAuth token>",',
                    '               "anthropic-beta": "oauth-2025-04-20",',
                    '               "anthropic-version": "2023-06-01" }',
                    '  },',
                    '  extractor: function (r) {',
                    '    return [',
                    '      { name: "5小时", remaining: 100 - r.five_hour.utilization },',
                    '      { name: "7天",   remaining: 100 - r.seven_day.utilization }',
                    '    ]',
                    '  }',
                    '})'
                )
            } else {
                $a = @(
                    '// 官方模板（Codex）：Token 来自 ~/.codex/auth.json（auth_mode=chatgpt）',
                    '({',
                    '  request: {',
                    '    url: "https://chatgpt.com/backend-api/wham/usage",',
                    '    method: "GET",',
                    '    headers: { "Authorization": "Bearer <本机 OAuth token>" }',
                    '  },',
                    '  extractor: function (r) {',
                    '    var p = r.rate_limit.primary_window, s = r.rate_limit.secondary_window',
                    '    return [',
                    '      { name: "5小时", remaining: 100 - p.used_percent, resetAt: p.reset_at },',
                    '      { name: "7天",   remaining: 100 - s.used_percent, resetAt: s.reset_at }',
                    '    ]',
                    '  }',
                    '})'
                )
            }
        }
    }

    $a += '// 返回字段：isValid / invalidMessage / remaining / unit / total / used / planName / extra'
    return ($a -join "`r`n")
}

function Get-TemplateById {
    param([string]$Id)
    $t = Get-TemplateDefs | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($t) { return $t }
    return (Get-TemplateDefs)[3]   # 默认 Token Plan
}

# ============================================================
# 供应商预设（按模板分组，地址均已实测端点存在）
# ============================================================
function Get-ProviderPresets {
    param([string]$Tpl = '')

    $all = @{
        tokenplan = @(
            @{ Id = 'minimax';  Label = 'MiniMax Coding Plan'; Short = 'MiniMax'
               Url = 'https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains'; Auth = 'bearer'
               Hint = '国内站 api.minimaxi.com；国际站对国内账号无效' },
            @{ Id = 'kimi';     Label = 'Kimi For Coding'; Short = 'Kimi'
               Url = 'https://api.kimi.com/coding/v1/usages'; Auth = 'bearer'
               Hint = '全球账号用 api.kimi.ai/coding/v1/usages' },
            @{ Id = 'zhipu';    Label = '智谱 GLM Coding'; Short = '智谱'
               Url = 'https://open.bigmodel.cn/api/monitor/usage/quota/limit'; Auth = 'raw'
               Hint = '智谱用裸 key，不加 Bearer 前缀' },
            @{ Id = 'opencode'; Label = 'OpenCode Go'; Short = 'OpenCode'
               Url = 'https://opencode.ai/zen/go/v1/usage'; Auth = 'bearer'
               Hint = '三个时间窗口 rolling / weekly / monthly' }
        )
        balance = @(
            @{ Id = 'deepseek';    Label = 'DeepSeek'; Short = 'DeepSeek'
               Url = 'https://api.deepseek.com/user/balance'; Auth = 'bearer'
               Hint = '钱包余额，按币种显示' },
            @{ Id = 'siliconflow'; Label = '硅基流动'; Short = '硅基'
               Url = 'https://api.siliconflow.cn/v1/user/info'; Auth = 'bearer'
               Hint = '读取 data.totalBalance' },
            @{ Id = 'openrouter';  Label = 'OpenRouter'; Short = 'OR'
               Url = 'https://openrouter.ai/api/v1/credits'; Auth = 'bearer'
               Hint = '总额度 − 已用 = 剩余' },
            @{ Id = 'stepfun';     Label = '阶跃星辰'; Short = '阶跃'
               Url = 'https://api.stepfun.com/v1/accounts/balance'; Auth = 'bearer'
               Hint = '读取账户余额字段' }
        )
        official = @(
            @{ Id = 'claude'; Label = 'Claude Code'; Short = 'Claude'
               Url = 'https://api.anthropic.com/api/oauth/usage'; Auth = 'oauth'
               Hint = '读 ~/.claude/.credentials.json，需先用 Claude Code 登录' },
            @{ Id = 'codex';  Label = 'Codex'; Short = 'Codex'
               Url = 'https://chatgpt.com/backend-api/wham/usage'; Auth = 'oauth'
               Hint = '读 ~/.codex/auth.json（auth_mode=chatgpt），需先用 Codex 登录' },
            @{ Id = 'workbuddy'; Label = 'WorkBuddy'; Short = 'WB'
               Url = 'https://www.workbuddy.cn'; Auth = 'wbprofile'
               Hint = '无头 Chrome 页面内查询；先点「授权登录」一次，之后 30 分钟缓存自动刷新' }
        )
        general = @(
            @{ Id = 'general'; Label = '通用余额'; Short = '余额'; Url = ''; Auth = 'bearer'
               Hint = '填 Base URL，程序自动请求 /user/balance 并读取 balance 字段' }
        )
        newapi = @(
            @{ Id = 'newapi'; Label = 'New API'; Short = 'NewAPI'; Url = ''; Auth = 'newapi'
               Hint = '填站点地址、Access Token、User ID；额度单位 500000 = 1 USD' }
        )
        custom = @(
            @{ Id = 'custom'; Label = '自定义'; Short = '自定义'; Url = ''; Auth = 'bearer'
               Hint = '填请求地址 + 提取路径；单位填 % 表示额度百分比，填 CNY / USD 表示余额金额' }
        )
    }

    if ($Tpl -and $all.ContainsKey($Tpl)) {
        $out = $all[$Tpl]
        # 坑：单元素数组在哈希表字面量里会被 PowerShell 解包成 Hashtable，
        # 表现为 .Count 等于键数（6）。这里还原成数组。
        # 注意：调用方必须用 @(...) 包裹，否则单元素数组仍会被解包成元素本身。
        if ($out -is [hashtable]) { return @($out) }
        return $out
    }
    return $all
}

# 跨模板按 Id 找预设（先查本模板，再全量查）
function Get-PresetById {
    param([string]$Id, [string]$Tpl = '')
    if ($Tpl) {
        $p = (Get-ProviderPresets -Tpl $Tpl) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
        if ($p) { return $p }
    }
    $all = Get-ProviderPresets
    foreach ($k in $all.Keys) {
        $p = $all[$k] | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
        if ($p) { return $p }
    }
    return (Get-ProviderPresets -Tpl 'tokenplan')[0]
}

# ============================================================
# 配置
# ============================================================
function New-ProviderObject {
    param($Preset, [string]$Tpl = 'tokenplan')
    return [pscustomobject]@{
        name           = $Preset.Label
        short          = $Preset.Short
        tpl            = $Tpl              # 模板：决定字段与解析器
        type           = $Preset.Id        # 模板内的供应商预设
        apiUrl         = $Preset.Url
        apiKey         = ''
        accessToken    = ''                # NewAPI 用
        userId         = ''                # NewAPI 用
        authMode       = $Preset.Auth
        refreshMinutes = 5
        enabled        = $true
        valuePath      = ''                # 自定义模板：提取路径
        resetPath      = ''                # 自定义模板：重置时间路径
        scale          = 1                 # 自定义模板：倍数
        unit           = '%'               # 自定义模板：% 或 CNY / USD
    }
}

function Get-DefaultConfig {
    return [pscustomobject]@{
        providers      = @((New-ProviderObject (Get-PresetById 'minimax' 'tokenplan') 'tokenplan'))
        warnThreshold  = 25
        critThreshold  = 10
        refreshMinutes = 5
        timeout        = 15
        startWithBoot  = $false
        dockRight      = 48
        dockBottom     = 72
        startMode      = 'dock'
        maxDockItems   = 3
        theme          = 'dark'            # dark | light
        uiScale        = 'auto'            # auto | 50 | 75 | 100 | 150
        dockScale      = 1.0               # 0.75 小 / 1.0 默认 / 1.25 大
        opacity        = 1.0               # 悬浮窗不透明度：1.0 / 0.7 / 0.5 / 0.3
        moneyWarn      = 20                # 余额低于该值显示黄色（负数一律红色）
        moneyCrit      = 5                 # 余额低于等于该值显示红色（2026-10-30 定案）
    }
}

function Repair-Config {
    param($Obj)
    $def = Get-DefaultConfig
    foreach ($p in $def.PSObject.Properties) {
        if ($null -eq $Obj.PSObject.Properties[$p.Name]) {
            $Obj | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
        }
    }
    # providers 单条时 ConvertFrom-Json 可能返回对象而非数组
    if ($null -ne $Obj.providers -and $Obj.providers -isnot [array]) {
        $Obj.providers = @($Obj.providers)
    }
    if (-not $Obj.providers -or $Obj.providers.Count -eq 0) {
        $Obj.providers = $def.providers
    }
    # 补齐 provider 缺失字段
    foreach ($pv in $Obj.providers) {
        $defaults = @{
            short          = $pv.name
            tpl            = 'tokenplan'
            type           = 'minimax'
            apiUrl         = ''
            apiKey         = ''
            accessToken    = ''
            userId         = ''
            authMode       = 'bearer'
            refreshMinutes = 5
            enabled        = $true
            valuePath      = ''
            resetPath      = ''
            scale          = 1
            unit           = '%'
        }
        foreach ($f in @('short', 'tpl', 'type', 'apiUrl', 'apiKey', 'accessToken', 'userId',
                         'authMode', 'refreshMinutes', 'enabled', 'valuePath', 'resetPath',
                         'scale', 'unit')) {
            if ($null -eq $pv.PSObject.Properties[$f]) {
                $pv | Add-Member -NotePropertyName $f -NotePropertyValue $defaults[$f]
            }
        }
        if (-not $pv.short) { $pv.short = $pv.name }
        if (-not $pv.tpl) { $pv.tpl = 'tokenplan' }
        if (-not $pv.unit) { $pv.unit = '%' }
        if (-not $pv.scale) { $pv.scale = 1 }
    }
    # 旧配置没有 uiScale/dockScale，用默认值补上并做合法性校验
    if ($Obj.uiScale -notin @('auto', '50', '75', '100', '150')) { $Obj.uiScale = 'auto' }
    $ds = 0.0
    if (-not [double]::TryParse([string]$Obj.dockScale, [ref]$ds) -or $ds -le 0) { $Obj.dockScale = 1.0 }
    # 透明度：只允许四档，落在档位之间的值向最近的档位吸附（防手改配置写坏）
    $op = 0.0
    if (-not [double]::TryParse([string]$Obj.opacity, [ref]$op) -or $op -le 0) {
        $Obj.opacity = 1.0
    } else {
        $best = 1.0; $bd = 9.0
        foreach ($lv in @(1.0, 0.7, 0.5, 0.3)) {
            $d = [Math]::Abs($op - $lv)
            if ($d -lt $bd) { $bd = $d; $best = $lv }
        }
        $Obj.opacity = $best
    }
    # 配色与折叠态显示数量
    if ($Obj.theme -notin @('dark', 'light')) { $Obj.theme = 'dark' }
    $md = 0
    if (-not [int]::TryParse([string]$Obj.maxDockItems, [ref]$md) -or $md -lt 1) { $Obj.maxDockItems = 3 }
    if ($md -gt 5) { $Obj.maxDockItems = 5 }
    return $Obj
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
        return (Repair-Config $obj)
    } catch {
        Write-CoreLog "配置读取失败，使用默认值: $($_.Exception.Message)"
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
    if ($env:TokenPanel_DEBUG_SAVE) {
        $st = (Get-PSCallStack | ForEach-Object { $_.Command }) -join ' > '
        Write-CoreLog ('Save-Config 调用栈: ' + $st)
    }
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
        $req.Proxy = $null                     # 关键：不走系统代理
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.Method = 'GET'
        $req.UserAgent = $script:UserAgent
        $req.Accept = 'application/json'
        # Content-Type / Accept / User-Agent 是 .NET 受限头，必须走属性
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
# 解析层
# ============================================================
function New-Tier {
    param(
        [string]$Name,
        [int]$Remain,
        $ResetMs,
        [int]$Status = 1,
        [string]$Display = '',
        $Money = $null,         # 金额类账户的数值（负数表示欠费/透支），百分比账户为 $null
        [string]$Unit = ''      # 'credits' = WorkBuddy 积分类（阈值 ≤20 红 / ≤50 黄，区别于 ¥ 金额的 5/20）
    )
    if ($Status -eq 3) { return $null }
    $reset = $null
    if ($ResetMs -and [int64]$ResetMs -gt 0) {
        try { $reset = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ResetMs).ToLocalTime().ToString('o') } catch { }
    }
    if (-not $Display) { $Display = "$Remain%" }
    return [pscustomobject]@{ Name = $Name; Remain = $Remain; ResetAt = $reset; Status = $Status; Display = $Display; Money = $Money; Unit = $Unit }
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
    $d = 0.0
    if ([double]::TryParse([string]$v, [ref]$d)) { return [int][Math]::Round($d) }
    return 0
}

function Parse-MiniMax {
    param($Body)
    $d = $Body | ConvertFrom-Json
    if ($d.base_resp -and $d.base_resp.status_code -ne 0) {
        return @{ Ok = $false; Error = ('接口 {0}：{1}' -f $d.base_resp.status_code, $d.base_resp.status_msg) }
    }
    $g = $d.model_remains | Where-Object { $_.model_name -eq 'general' } | Select-Object -First 1
    if (-not $g) { return @{ Ok = $false; Error = '响应缺少 general 档位' } }
    $tiers = @()
    $t = New-Tier -Name '5小时' -Remain (ConvertTo-IntSafe $g.current_interval_remaining_percent) `
        -ResetMs $g.end_time -Status (ConvertTo-IntSafe $g.current_interval_status)
    if ($t) { $tiers += $t }
    $t = New-Tier -Name '7天' -Remain (ConvertTo-IntSafe $g.current_weekly_remaining_percent) `
        -ResetMs $g.weekly_end_time -Status (ConvertTo-IntSafe $g.current_weekly_status)
    if ($t) { $tiers += $t }
    return @{ Ok = $true; Tiers = $tiers }
}

function Parse-Kimi {
    param($Body)
    $d = $Body | ConvertFrom-Json
    $tiers = @()
    if ($d.limits) {
        $det = ($d.limits | Select-Object -First 1).detail
        if ($det -and [double]$det.limit -gt 0) {
            $used = [int][Math]::Round(([double]$det.limit - [double]$det.remaining) / [double]$det.limit * 100)
            $t = New-Tier -Name '5小时' -Remain (100 - $used) -ResetMs $det.resetTime
            if ($t) { $tiers += $t }
        }
    }
    if ($d.usage -and [double]$d.usage.limit -gt 0) {
        $used = [int][Math]::Round(([double]$d.usage.limit - [double]$d.usage.remaining) / [double]$d.usage.limit * 100)
        $t = New-Tier -Name '7天' -Remain (100 - $used) -ResetMs $d.usage.resetTime
        if ($t) { $tiers += $t }
    }
    if ($tiers.Count -eq 0) { return @{ Ok = $false; Error = '未解析到额度字段' } }
    return @{ Ok = $true; Tiers = $tiers }
}

function Parse-Zhipu {
    param($Body)
    $d = $Body | ConvertFrom-Json
    if ($d.success -eq $false) { return @{ Ok = $false; Error = ('接口返回：{0}' -f $d.msg) } }
    $tiers = @()
    if ($d.data -and $d.data.limits) {
        $i = 0
        foreach ($lim in $d.data.limits) {
            if (([string]$lim.type).ToUpper() -notmatch 'TOKEN|CREDIT') { continue }
            $name = if ($i -eq 0) { '5h' } elseif ($i -eq 1) { '本周' } else { '窗口' + ($i + 1) }
            $t = New-Tier -Name $name -Remain (100 - (ConvertTo-IntSafe $lim.percentage)) -ResetMs $lim.nextResetTime
            if ($t) { $tiers += $t }
            $i++
        }
    }
    if ($tiers.Count -eq 0) { return @{ Ok = $false; Error = '未解析到 limits' } }
    return @{ Ok = $true; Tiers = $tiers }
}

function Parse-OpenCode {
    param($Body)
    $d = $Body | ConvertFrom-Json
    $tiers = @()
    foreach ($m in @(@{K='rolling';N='5h'}, @{K='weekly';N='本周'}, @{K='monthly';N='本月'})) {
        $w = $d.usage.($m.K)
        if (-not $w) { continue }
        $t = New-Tier -Name $m.N -Remain (100 - (ConvertTo-IntSafe $w.percent)) -ResetMs $null
        if ($t) {
            if ($w.resetsAt) {
                try { $t.ResetAt = [DateTimeOffset]::Parse($w.resetsAt).ToLocalTime().ToString('o') } catch { }
            }
            $tiers += $t
        }
    }
    if ($tiers.Count -eq 0) { return @{ Ok = $false; Error = '未解析到 usage 窗口' } }
    return @{ Ok = $true; Tiers = $tiers }
}

function Parse-DeepSeek {
    param($Body)
    $d = $Body | ConvertFrom-Json
    if ($d.is_available -eq $false) {
        return @{ Ok = $true; Tiers = @((New-Tier -Name '余额' -Remain -1 -ResetMs 0 -Display '不可用')) }
    }
    $b = $d.balance_infos | Select-Object -First 1
    if (-not $b) { return @{ Ok = $false; Error = '未找到 balance_infos' } }
    $sym = if ($b.currency -eq 'USD') { '$' } else { '¥' }
    $disp = '{0}{1}' -f $sym, $b.total_balance
    $num = 0.0; [void][double]::TryParse([string]$b.total_balance, [ref]$num)
    return @{ Ok = $true; Tiers = @((New-Tier -Name '余额' -Remain -1 -ResetMs 0 -Display $disp -Money $num)) }
}

function Parse-Custom {
    param($Body, $Provider)
    if (-not $Provider.valuePath) { return @{ Ok = $false; Error = '自定义类型需要填「提取路径」' } }
    $d = $Body | ConvertFrom-Json
    $v = Get-JsonPath -Obj $d -Path $Provider.valuePath
    if ($null -eq $v) { return @{ Ok = $false; Error = ('路径 {0} 取不到值' -f $Provider.valuePath) } }
    $raw = 0.0
    if (-not [double]::TryParse([string]$v, [ref]$raw)) {
        return @{ Ok = $false; Error = ('路径 {0} 不是数字：{1}' -f $Provider.valuePath, [string]$v) }
    }

    # 倍数：把接口的原始单位换算成我们要显示的单位（如 NewAPI 的 quota 需 ÷500000）
    $sc = 1.0
    if ($Provider.scale) {
        $tmp = 0.0
        if ([double]::TryParse([string]$Provider.scale, [ref]$tmp) -and $tmp -gt 0) { $sc = $tmp }
    }
    $num = $raw * $sc

    $unit = [string]$Provider.unit
    $isPct = (-not $unit) -or ($unit -eq '%') -or ($unit -eq 'percent')

    if ($isPct) {
        $rem = [int][Math]::Round($num)
        if ($rem -lt 0) { $rem = 0 }
        if ($rem -gt 100) { $rem = 100 }
        $t = New-Tier -Name '额度' -Remain $rem -ResetMs 0
    } else {
        $sym = switch ($unit) {
            'CNY' { '¥' } 'RMB' { '¥' } '¥' { '¥' }
            'USD' { '$' } '$' { '$' }
            default { $unit + ' ' }
        }
        $t = New-Tier -Name '余额' -Remain -1 -ResetMs 0 -Display ($sym + $num.ToString('0.##')) -Money $num
    }

    if ($Provider.resetPath) {
        $rv = Get-JsonPath -Obj $d -Path $Provider.resetPath
        if ($rv) {
            $n = [int64]0
            if ([int64]::TryParse([string]$rv, [ref]$n) -and $n -gt 0) {
                try { $t.ResetAt = [DateTimeOffset]::FromUnixTimeMilliseconds($n).ToLocalTime().ToString('o') } catch { }
            } else {
                try { $t.ResetAt = [DateTimeOffset]::Parse([string]$rv).ToLocalTime().ToString('o') } catch { }
            }
        }
    }
    return @{ Ok = $true; Tiers = @($t) }
}

# ============================================================
# WorkBuddy 积分（official 模板 type=workbuddy）
# 网关按 TLS 指纹拦截普通 HTTP 客户端（同 cookie 下 curl 一律 401），
# 必须经无头 Chrome 在页面上下文里发请求（lib\wb\wb_query.js，原理见其头注释）。
# 运行态（结果缓存/冷却/授权时间）独立存 %APPDATA%\TokenPanel\wb_state.json，
# 不动 config.json 结构，配置三处同步逻辑不受影响。
# ============================================================
function Get-WorkBuddyState {
    $st = @{ lastOkAt = $null; lastData = ''; cooldownUntil = $null; authAt = $null }
    if (Test-Path $script:WbStatePath) {
        try {
            $j = Get-Content $script:WbStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $st.lastOkAt = $j.lastOkAt; $st.cooldownUntil = $j.cooldownUntil; $st.authAt = $j.authAt
        } catch { }
    }
    if (Test-Path $script:WbLastPath) {
        try { $st.lastData = Get-Content $script:WbLastPath -Raw -Encoding UTF8 } catch { }
    }
    return $st
}

function Save-WorkBuddyState {
    param($State)
    try {
        if (-not (Test-Path $script:ConfigDir)) {
            New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        }
        $json = [pscustomobject]@{
            lastOkAt      = $State.lastOkAt
            cooldownUntil = $State.cooldownUntil
            authAt        = $State.authAt
        } | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($script:WbStatePath, $json, [System.Text.Encoding]::UTF8)
        # 原始查询输出单独存文件，绕开 ConvertTo-Json 长字符串包装 bug
        if ($State.lastData) {
            [System.IO.File]::WriteAllText($script:WbLastPath, [string]$State.lastData, [System.Text.Encoding]::UTF8)
        } elseif (Test-Path $script:WbLastPath) {
            Remove-Item $script:WbLastPath -Force -ErrorAction SilentlyContinue
        }
    } catch { Write-CoreLog ('wb_state 写入失败: ' + $_.Exception.Message) }
}

function Test-WbProfileReady {
    return (Test-Path (Join-Path $script:WbDir '.browser-profile'))
}

# 读授权结果文件（grab_cookie.js 写，面板读）。
# 不用进程退出码：PS 5.1 的 Start-Process -PassThru 读出来恒为 null，会把「取消」误判成「成功」。
# 返回 @{ result='ok'|'cancel'|'timeout'|'fail'; detail=''; at='' } 或 $null
function Get-WorkBuddyAuthResult {
    $p = Join-Path $script:WbDir '.auth-result.json'
    if (-not (Test-Path $p)) { return $null }
    try {
        $j = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        return @{ result = [string]$j.result; detail = [string]$j.detail; at = [string]$j.at }
    } catch { return $null }
}

# 清理上次异常残留：挂着我们 profile 的 chrome/msedge + 还在跑 grab_cookie.js 的 node。
# 授权前必须清，否则旧 Chrome 占着 profile，新实例起不来（之前会表现为「点了没反应」）。
function Clear-WorkBuddyOrphans {
    foreach ($exeName in @('chrome.exe', 'msedge.exe')) {
        $stale = @(Get-CimInstance Win32_Process -Filter "Name='$exeName'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like ('*' + $script:WbDir + '*') })
        foreach ($p in $stale) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    $nodes = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*grab_cookie.js*' })
    foreach ($p in $nodes) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Find-NodeExe {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # 兜底：WorkBuddy 自带的 managed node（PATH 里没有 node 时）
    $wbNode = Join-Path $env:USERPROFILE '.workbuddy\binaries\node'
    if (Test-Path $wbNode) {
        $n = Get-ChildItem $wbNode -Recurse -Filter node.exe -ErrorAction SilentlyContinue |
             Select-Object -First 1
        if ($n) { return $n.FullName }
    }
    return $null
}

# 解析 wb_query.js --json 的输出（四接口聚合 JSON）
function Parse-WorkBuddy {
    param([string]$Body)
    if (-not $Body) { return @{ Ok = $false; Error = '查询输出为空' } }
    $d = $null
    try { $d = $Body | ConvertFrom-Json } catch { return @{ Ok = $false; Error = '查询输出不是 JSON' } }
    $sum = $d.'/billing/meter/get-user-resource-summary'
    if (-not $sum) { return @{ Ok = $false; Error = '输出缺少积分汇总接口' } }
    if ($sum.status -in 401, 403) {
        return @{ Ok = $false; AuthFail = $true; Error = "登录态过期 (HTTP $($sum.status))，请重新授权" }
    }
    if ($sum.status -ne 200) { return @{ Ok = $false; Error = "积分汇总接口 HTTP $($sum.status)" } }
    $sd = $null
    try { $sd = ($sum.body | ConvertFrom-Json).data } catch { }
    if (-not $sd) { return @{ Ok = $false; Error = '积分汇总响应无 data 字段' } }
    $credits = 0.0
    [void][double]::TryParse([string]$sd.TotalCredits, [ref]$credits)
    $plan = if ($sd.SubscriptionPackageName) { [string]$sd.SubscriptionPackageName } else { '积分余额' }
    # Unit='credits'：折叠态阈值走积分档（≤20 红 / ≤50 黄），区别于 ¥ 金额档（≤5 红 / ≤20 黄）
    $tiers = @((New-Tier -Name $plan -Remain -1 -ResetMs 0 `
        -Display ('{0} credits' -f $credits.ToString('0.##')) -Money $credits -Unit 'credits'))
    # 签到状态作为第二条（展开态可见）
    $ck = $d.'/billing/meter/checkin-status'
    if ($ck -and $ck.status -eq 200) {
        try {
            $cd = ($ck.body | ConvertFrom-Json).data
            if ($cd) {
                $cdisp = if (-not $cd.active) { '活动未开启' }
                         elseif ($cd.today_checked_in) { '今日已签到' }
                         else { '今日未签到' }
                $t = New-Tier -Name '签到' -Remain -1 -ResetMs 0 -Display $cdisp
                if ($t) { $tiers += $t }
            }
        } catch { }
    }
    return @{ Ok = $true; Tiers = $tiers }
}

function Invoke-WorkBuddy {
    param($Provider)

    $state = Get-WorkBuddyState
    $now = Get-Date

    # ---- 冷却中：登录态过期后 1 小时内不再拉起 Chrome ----
    if ($state.cooldownUntil) {
        $cd = [datetime]::MinValue
        if ([datetime]::TryParse([string]$state.cooldownUntil, [ref]$cd) -and $cd -gt $now) {
            return @{ Ok = $false; AuthFail = $true; Error = ('登录态过期，冷却至 {0:HH:mm}，请重新授权' -f $cd) }
        }
    }

    # ---- 缓存命中：30 分钟内直接复用上次结果，不拉 Chrome ----
    if ($state.lastData -and $state.lastOkAt) {
        $last = [datetime]::MinValue
        if ([datetime]::TryParse([string]$state.lastOkAt, [ref]$last) -and
            (($now - $last).TotalMinutes -lt $script:WbCacheMin)) {
            try { return (Parse-WorkBuddy -Body $state.lastData) } catch { }
        }
    }

    if (-not (Test-WbProfileReady)) {
        return @{ Ok = $false; AuthFail = $true; Error = '未授权：请在配置页点「授权登录」' }
    }
    $node = Find-NodeExe
    if (-not $node) { return @{ Ok = $false; Error = '未找到 node.exe，无法运行查询脚本' } }

    # ---- 并发护栏：文件锁（PID 存活检查）----
    $lockFile = Join-Path $script:ConfigDir 'wb-query.lock'
    if (Test-Path $lockFile) {
        $lockPid = 0
        try { $lockPid = [int](Get-Content $lockFile -Raw) } catch { }
        if ($lockPid -gt 0 -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
            return @{ Ok = $false; Error = '上一次 WorkBuddy 查询仍在运行，本轮跳过' }
        }
    }
    [System.IO.File]::WriteAllText($lockFile, [string]$PID)
    try {
        # 孤儿兜底：只清挂着我们自己 profile 目录的残留 chrome / msedge
        Clear-WorkBuddyOrphans

        # 环境变量重复键坑：系统注入的 HTTP_PROXY/http_proxy 大小写重复会让
        # Start-Process -RedirectStandardOutput 直接报错（HANDOFF §15）
        foreach ($name in @('HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy')) {
            if ($null -ne [Environment]::GetEnvironmentVariable($name)) {
                Remove-Item ("Env:" + $name) -ErrorAction SilentlyContinue
            }
        }

        $outFile = Join-Path $script:ConfigDir 'wb-out.json'
        $errFile = Join-Path $script:ConfigDir 'wb-err.txt'
        $proc = Start-Process -FilePath $node `
            -ArgumentList @('wb_query.js', '--json') `
            -WorkingDirectory $script:WbDir -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $proc.WaitForExit($script:WbTimeoutMs)) {
            Start-Process -FilePath 'taskkill' -ArgumentList @('/PID', [string]$proc.Id, '/T', '/F') -WindowStyle Hidden -Wait
            return @{ Ok = $false; Error = 'WorkBuddy 查询超时 30 秒，已终止' }
        }
        $raw = ''
        try { $raw = Get-Content $outFile -Raw -Encoding UTF8 } catch { }
        # PS 5.1 的 Start-Process -PassThru 偶发读不到 ExitCode（实测为 null 但输出正常），
        # 所以判定以输出文件为准，退出码只做辅助
        if ($proc.ExitCode -eq 2 -or ($null -eq $proc.ExitCode -and -not $raw)) {
            return @{ Ok = $false; AuthFail = $true; Error = '未授权或登录态缺失，请在配置页点「授权登录」' }
        }
        if (-not $raw) {
            return @{ Ok = $false; Error = ('查询无输出（退出码 ' + $proc.ExitCode + '）') }
        }

        $r = Parse-WorkBuddy -Body $raw
        if ($r.Ok) {
            $state.lastOkAt = $now.ToString('o')
            $state.lastData = $raw
            Save-WorkBuddyState $state
        } elseif ($r.AuthFail) {
            $state.cooldownUntil = $now.AddHours($script:WbCooldownH).ToString('o')
            Save-WorkBuddyState $state
        }
        return $r
    } finally {
        Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    }
}

# 授权登录：弹 headful Chrome 让用户登 WorkBuddy（grab_cookie.js 检测到登录态后自动关窗）
# 返回进程对象，调用方轮询 HasExited；退出码 0 = 成功
function Start-WorkBuddyAuth {
    $node = Find-NodeExe
    if (-not $node) { return $null }
    foreach ($name in @('HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy')) {
        if ($null -ne [Environment]::GetEnvironmentVariable($name)) {
            Remove-Item ("Env:" + $name) -ErrorAction SilentlyContinue
        }
    }
    # 先清上次取消/崩溃留下的 Chrome 与 grab_cookie 进程，否则 profile 被占、新窗口起不来
    Clear-WorkBuddyOrphans
    # 清掉上一轮的结果文件，避免把旧结果当成本轮结果
    $oldResult = Join-Path $script:WbDir '.auth-result.json'
    if (Test-Path $oldResult) { Remove-Item $oldResult -Force -ErrorAction SilentlyContinue }
    $outFile = Join-Path $script:ConfigDir 'wb-auth-out.txt'
    $errFile = Join-Path $script:ConfigDir 'wb-auth-err.txt'
    try {
        return Start-Process -FilePath $node `
            -ArgumentList @('grab_cookie.js') `
            -WorkingDirectory $script:WbDir -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    } catch {
        Write-CoreLog ('WorkBuddy 授权启动失败: ' + $_.Exception.Message)
        return $null
    }
}

# 授权成功后调用：记录授权时间、清冷却、清缓存（下一次查询拉新数据）
function Complete-WorkBuddyAuth {
    $state = Get-WorkBuddyState
    $state.authAt = (Get-Date).ToString('o')
    $state.cooldownUntil = $null
    $state.lastData = ''
    $state.lastOkAt = $null
    Save-WorkBuddyState $state
}


# ============================================================
# 官方 OAuth 凭据读取（Claude Code / Codex）
# ============================================================
function Get-ClaudeOAuthToken {
    $p = Join-Path $env:USERPROFILE '.claude\.credentials.json'
    if (-not (Test-Path $p)) { return $null }
    try {
        $j = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.claudeAiOauth.accessToken) { return [string]$j.claudeAiOauth.accessToken }
    } catch { }
    return $null
}

function Get-CodexOAuthToken {
    $p = Join-Path $env:USERPROFILE '.codex\auth.json'
    if (-not (Test-Path $p)) { return $null }
    try {
        $j = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        # 只有 OAuth 登录（auth_mode=chatgpt）才有 tokens.access_token；
        # 用 API Key 登录的账号查不了订阅额度
        if ($j.auth_mode -eq 'chatgpt' -and $j.tokens.access_token) {
            return [string]$j.tokens.access_token
        }
    } catch { }
    return $null
}

# ============================================================
# 通用模板：GET {BaseURL}/user/balance → { "is_active": true, "balance": 12.34 }
# ============================================================
function Parse-General {
    param($Body)
    $d = $Body | ConvertFrom-Json
    $v = $null
    foreach ($path in @('balance', 'data.balance', 'total_balance', 'data.total_balance')) {
        $v = Get-JsonPath -Obj $d -Path $path
        if ($null -ne $v) { break }
    }
    # is_active=false 时如果还带着余额字段，照实显示（欠费场景），别把数字吞掉
    if ($null -eq $v) {
        if ($d.is_active -eq $false) {
            return @{ Ok = $true; Tiers = @((New-Tier -Name '余额' -Remain -1 -ResetMs 0 -Display '账户不可用')) }
        }
        return @{ Ok = $false; Error = '响应里找不到 balance 字段，可改用「自定义」模板指定路径' }
    }
    $num = 0.0
    [void][double]::TryParse([string]$v, [ref]$num)
    $unit = if ($d.unit) { [string]$d.unit } else { 'USD' }
    $disp = ('{0:N2} {1}' -f $num, $unit)
    return @{ Ok = $true; Tiers = @((New-Tier -Name '余额' -Remain -1 -ResetMs 0 -Display $disp -Money $num)) }
}

# ============================================================
# NewAPI：GET {BaseURL}/api/user/self → data.quota / data.used_quota
# 额度单位：500000 = 1 USD
# ============================================================
function Parse-NewApi {
    param($Body)
    $d = $Body | ConvertFrom-Json
    if ($d.success -ne $true -or -not $d.data) {
        $msg = if ($d.message) { [string]$d.message } else { '未登录或 Access Token 无效' }
        return @{ Ok = $false; Error = ('接口返回：' + $msg) }
    }
    $quota = 0.0; [void][double]::TryParse([string]$d.data.quota, [ref]$quota)
    $used  = 0.0; [void][double]::TryParse([string]$d.data.used_quota, [ref]$used)
    $remUsd   = $quota / 500000
    $usedUsd  = $used / 500000
    $totalUsd = $remUsd + $usedUsd
    $plan = if ($d.data.group) { [string]$d.data.group } else { '默认套餐' }
    $disp = ('${0:N2} / ${1:N2}' -f $remUsd, $totalUsd)
    return @{ Ok = $true; Tiers = @((New-Tier -Name $plan -Remain -1 -ResetMs 0 -Display $disp -Money $remUsd)) }
}

# ============================================================
# 账户余额：按供应商取字段（都是钱包余额，没有百分比窗口）
# ============================================================
function Parse-Balance {
    param($Body, $Provider)
    $d = $Body | ConvertFrom-Json
    switch ($Provider.type) {
        'deepseek' {
            # 注意：is_available=false 不等于「没有余额数据」。
            # 实测欠费时接口仍返回 balance_infos（如 -0.49 CNY），
            # 早期版本在这里直接返回「不可用」，把真实负数吞掉了，用户只能看到「不可用」。
            $b = $d.balance_infos | Select-Object -First 1
            if (-not $b) {
                if ($d.is_available -eq $false) {
                    return @{ Ok = $true; Tiers = @((New-Tier -Name '余额' -Remain -1 -ResetMs 0 -Display '不可用')) }
                }
                return @{ Ok = $false; Error = '未找到 balance_infos' }
            }
            $sym = if ($b.currency -eq 'USD') { '$' } else { '¥' }
            $num = 0.0; [void][double]::TryParse([string]$b.total_balance, [ref]$num)
            return @{ Ok = $true; Tiers = @((New-Tier -Name '余额' -Remain -1 -ResetMs 0 `
                -Display ($sym + [string]$b.total_balance) -Money $num)) }
        }
        'siliconflow' {
            $v = Get-JsonPath -Obj $d -Path 'data.totalBalance'
            if ($null -eq $v) { $v = Get-JsonPath -Obj $d -Path 'data.balance' }
            if ($null -eq $v) { return @{ Ok = $false; Error = '未找到 data.totalBalance' } }
            $num = 0.0; [void][double]::TryParse([string]$v, [ref]$num)
            return @{ Ok = $true; Tiers = @((New-Tier -Name '余额' -Remain -1 -ResetMs 0 `
                -Display ('¥' + [string]$v) -Money $num)) }
        }
        'openrouter' {
            $tc = Get-JsonPath -Obj $d -Path 'data.total_credits'
            $tu = Get-JsonPath -Obj $d -Path 'data.total_usage'
            if ($null -eq $tc) { return @{ Ok = $false; Error = '未找到 data.total_credits' } }
            $a = 0.0; $b2 = 0.0
            [void][double]::TryParse([string]$tc, [ref]$a)
            [void][double]::TryParse([string]$tu, [ref]$b2)
            $rem = $a - $b2
            return @{ Ok = $true; Tiers = @((New-Tier -Name '余额' -Remain -1 -ResetMs 0 `
                -Display ('${0:N2} / ${1:N2}' -f $rem, $a) -Money $rem)) }
        }
        default {
            # 阶跃星辰等：容错扫描常见余额字段
            $v = $null
            foreach ($path in @('data.balance', 'balance', 'data.total_balance', 'data.totalBalance', 'data.available_balance')) {
                $v = Get-JsonPath -Obj $d -Path $path
                if ($null -ne $v) { break }
            }
            if ($null -eq $v) {
                return @{ Ok = $false; Error = '未识别的余额字段，请改用「自定义」模板并指定 JSON 路径' }
            }
            $num = 0.0; [void][double]::TryParse([string]$v, [ref]$num)
            return @{ Ok = $true; Tiers = @((New-Tier -Name '余额' -Remain -1 -ResetMs 0 `
                -Display ('¥' + [string]$v) -Money $num)) }
        }
    }
}

# ============================================================
# 官方订阅：Claude /api/oauth/usage、Codex backend-api/wham/usage
# 两者返回的都是「使用百分比」，这里统一转成剩余
# ============================================================
function Parse-Official {
    param($Body, $Provider)
    $d = $Body | ConvertFrom-Json
    $tiers = @()

    if ($Provider.type -eq 'claude') {
        foreach ($m in @(
            @{ K = 'five_hour';      N = '5小时' },
            @{ K = 'seven_day';      N = '7天' },
            @{ K = 'seven_day_opus'; N = '7天 Opus' })) {
            $w = $d.($m.K)
            if (-not $w) { continue }
            $util = ConvertTo-IntSafe $w.utilization
            $t = New-Tier -Name $m.N -Remain (100 - $util) -ResetMs 0
            if ($t -and $w.resets_at) {
                try { $t.ResetAt = [DateTimeOffset]::Parse([string]$w.resets_at).ToLocalTime().ToString('o') } catch { }
            }
            if ($t) { $tiers += $t }
        }
    } else {
        $rl = $d.rate_limit
        foreach ($m in @(
            @{ K = 'primary_window';   N = '5小时' },
            @{ K = 'secondary_window'; N = '7天' })) {
            $w = $rl.($m.K)
            if (-not $w) { continue }
            $used = ConvertTo-IntSafe $w.used_percent
            $t = New-Tier -Name $m.N -Remain (100 - $used) -ResetMs 0
            if ($t -and $w.reset_at) {
                try { $t.ResetAt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$w.reset_at).ToLocalTime().ToString('o') } catch { }
            }
            if ($t) { $tiers += $t }
        }
    }

    if ($tiers.Count -eq 0) { return @{ Ok = $false; Error = '响应里没有可识别的额度窗口' } }
    return @{ Ok = $true; Tiers = $tiers }
}

# ============================================================
# 查询入口
# ============================================================
function Get-ProviderRequestUrl {
    param($Provider)
    $u = [string]$Provider.apiUrl
    if (-not $u) { return '' }
    switch ($Provider.tpl) {
        'general' { return ($u.TrimEnd('/') + '/user/balance') }
        'newapi'  { return ($u.TrimEnd('/') + '/api/user/self') }
        default   { return $u }
    }
}

# 统一发请求 + 状态码检查，返回 @{ Ok; Body } 或 @{ Ok=$false; Error }
function Invoke-QuotaRequest {
    param([string]$Url, [hashtable]$Headers)
    $res = Invoke-Http -Url $Url -Headers $Headers -TimeoutSec ([int]$script:HttpTimeout)
    if ($res.Status -eq 0)        { return @{ Ok = $false; Error = '网络失败：' + $res.Error } }
    if ($res.Status -in 401, 403) { return @{ Ok = $false; Error = "认证失败 (HTTP $($res.Status))，请检查 Key / Token" } }
    if ($res.Status -ne 200)      { return @{ Ok = $false; Error = "HTTP $($res.Status)" } }
    return @{ Ok = $true; Body = $res.Body }
}

function Invoke-Provider {
    param($Provider, [string]$OverrideKey = '')

    $tpl = [string]$Provider.tpl
    if (-not $tpl) { $tpl = 'tokenplan' }

    # ---------- 官方模板：Key 来自本机 OAuth，不用界面里的 API Key ----------
    if ($tpl -eq 'official') {
        # WorkBuddy：无头 Chrome 页面内查询，不走 HTTP / OAuth token
        if ($Provider.type -eq 'workbuddy') {
            try { return Invoke-WorkBuddy -Provider $Provider }
            catch { return @{ Ok = $false; Error = 'WorkBuddy 查询异常：' + $_.Exception.Message } }
        }
        $tok = if ($Provider.type -eq 'claude') { Get-ClaudeOAuthToken } else { Get-CodexOAuthToken }
        if (-not $tok) {
            $hint = if ($Provider.type -eq 'claude') {
                '~/.claude/.credentials.json'
            } else {
                '~/.codex/auth.json（需要 auth_mode=chatgpt 的 OAuth 登录）'
            }
            return @{ Ok = $false; Error = ('未找到 OAuth 凭据：' + $hint) }
        }
        $hdrs = @{
            'Authorization' = 'Bearer ' + $tok
            'Content-Type'  = 'application/json'
            'Accept'        = 'application/json'
        }
        if ($Provider.type -eq 'claude') {
            $hdrs['anthropic-beta']    = 'oauth-2025-04-20'
            $hdrs['anthropic-version'] = '2023-06-01'
        }
        $r = Invoke-QuotaRequest -Url $Provider.apiUrl -Headers $hdrs
        if (-not $r.Ok) { return $r }
        try { return Parse-Official -Body $r.Body -Provider $Provider }
        catch { return @{ Ok = $false; Error = '解析失败：' + $_.Exception.Message } }
    }

    # ---------- NewAPI：Access Token + User ID 双要素 ----------
    if ($tpl -eq 'newapi') {
        $at = $OverrideKey
        if (-not $at) { $at = Unprotect-String $Provider.accessToken }
        if (-not $at) { return @{ Ok = $false; Error = '未配置 Access Token' } }
        if (-not $Provider.userId) { return @{ Ok = $false; Error = '未配置 User ID' } }
        $url = Get-ProviderRequestUrl -Provider $Provider
        if (-not $url) { return @{ Ok = $false; Error = '未配置站点地址' } }
        $hdrs = @{
            'Authorization' = 'Bearer ' + $at
            'New-Api-User'  = [string]$Provider.userId
            'Content-Type'  = 'application/json'
        }
        $r = Invoke-QuotaRequest -Url $url -Headers $hdrs
        if (-not $r.Ok) { return $r }
        try { return Parse-NewApi -Body $r.Body }
        catch { return @{ Ok = $false; Error = '解析失败：' + $_.Exception.Message } }
    }

    # ---------- 其余模板：走 API Key ----------
    $key = $OverrideKey
    if (-not $key) { $key = Unprotect-String $Provider.apiKey }
    if (-not $key) { return @{ Ok = $false; Error = '未配置 API Key' } }

    $url = Get-ProviderRequestUrl -Provider $Provider
    if (-not $url) { return @{ Ok = $false; Error = '未配置 API 地址' } }

    $headers = @{
        'Authorization' = if ($Provider.authMode -eq 'raw') { $key } else { 'Bearer ' + $key }
        'Content-Type'  = 'application/json'
    }
    $r = Invoke-QuotaRequest -Url $url -Headers $headers
    if (-not $r.Ok) { return $r }

    try {
        switch ($tpl) {
            'tokenplan' {
                switch ($Provider.type) {
                    'minimax'  { return Parse-MiniMax  -Body $r.Body }
                    'kimi'     { return Parse-Kimi     -Body $r.Body }
                    'zhipu'    { return Parse-Zhipu    -Body $r.Body }
                    'opencode' { return Parse-OpenCode -Body $r.Body }
                    default    { return @{ Ok = $false; Error = '未知的 Token Plan 供应商' } }
                }
            }
            'balance' { return Parse-Balance -Body $r.Body -Provider $Provider }
            'general' { return Parse-General -Body $r.Body }
            default   { return Parse-Custom  -Body $r.Body -Provider $Provider }
        }
    } catch {
        return @{ Ok = $false; Error = '解析失败：' + $_.Exception.Message }
    }
}

# ============================================================
# 凭据探测
# ============================================================
function Find-CandidateKeys {
    $out = @()
    if ($env:MINIMAX_API_KEY) { $out += @{ Key = $env:MINIMAX_API_KEY; Src = '环境变量' } }
    $codex = Join-Path $env:USERPROFILE '.codex\auth.json'
    if (Test-Path $codex) {
        try {
            $j = Get-Content $codex -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.OPENAI_API_KEY) { $out += @{ Key = $j.OPENAI_API_KEY; Src = '.codex/auth.json' } }
        } catch { }
    }
    $claude = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (Test-Path $claude) {
        try {
            $j = Get-Content $claude -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.env.ANTHROPIC_AUTH_TOKEN) { $out += @{ Key = $j.env.ANTHROPIC_AUTH_TOKEN; Src = '.claude/settings.json' } }
        } catch { }
    }
    return $out
}

function Find-WorkingKey {
    param([string]$Type = 'minimax', [string]$Tpl = 'tokenplan')
    $preset = Get-PresetById $Type $Tpl
    $probe = New-ProviderObject -Preset $preset -Tpl $Tpl
    foreach ($c in (Find-CandidateKeys)) {
        $r = Invoke-Provider -Provider $probe -OverrideKey $c.Key
        if ($r.Ok) { return @{ Key = $c.Key; Src = $c.Src } }
    }
    return $null
}

# ============================================================
# 聚合查询：返回给前端的统一结构
# ============================================================
function Get-AllQuota {
    param($Cfg)

    $accounts = @()
    foreach ($prov in $Cfg.providers) {
        if ($prov.enabled -eq $false) { continue }
        $r = Invoke-Provider -Provider $prov
        if ($r.Ok) {
            $primary = -1
            if ($r.Tiers.Count -gt 0) { $primary = $r.Tiers[0].Remain }
            $kind = if (@($r.Tiers | Where-Object { $null -ne $_.Money }).Count -gt 0) { 'money' } else { 'pct' }
            $accounts += [pscustomobject]@{
                id      = $prov.type
                name    = $prov.name
                short   = $prov.short
                ok      = $true
                error   = $null
                kind    = $kind
                primary = $primary
                tiers   = @($r.Tiers | ForEach-Object {
                    [pscustomobject]@{
                        name     = $_.Name
                        remain   = $_.Remain
                        reset_at = $_.ResetAt
                        display  = $_.Display
                        money    = $_.Money
                        unit     = $_.Unit
                    }
                })
            }
        } else {
            $accounts += [pscustomobject]@{
                id      = $prov.type
                name    = $prov.name
                short   = $prov.short
                ok      = $false
                error   = $r.Error
                kind    = 'pct'
                primary = -1
                tiers   = @()
            }
            Write-CoreLog ("[$($prov.name)] " + $r.Error)
        }
    }

    return [pscustomobject]@{
        accounts   = @($accounts)
        fetched_at = (Get-Date).ToString('o')
    }
}
