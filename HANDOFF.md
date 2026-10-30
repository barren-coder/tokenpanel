# Token Pocket — 项目交接文档

> 面向接手本项目的 Agent。读完这份文档，你应该能直接改代码、验证、交付，不需要重新摸索。
> 最后更新：2026-10-30 13:55 ｜ 版本 v1.1.6 内测版 ｜ 文档作者：上一手 Agent

---

## 0. 30 秒速览

| 项 | 值 |
|---|---|
| 是什么 | Windows 桌面悬浮窗小工具，实时显示各 AI 套餐（Token Plan）的**使用量**与账户**余额** |
| 技术栈 | PowerShell 5.1 + WinForms + GDI+ **全自绘**，零第三方依赖、零安装 |
| 项目位置 | `D:\AppData\token消耗面板\` |
| 体积 | 约 900 KB（含截图与备份） |
| 代码量 | 4175 行（3 个主 .ps1 + 1 个测试） |
| 启动 | 双击 `start-token-pocket.cmd` |
| 配置 | `%APPDATA%\TokenPocket\config.json`（**UTF-8 BOM**，见 §7.9） |
| 日志 | `%APPDATA%\TokenPocket\app.log` |
| 当前状态 | 可用。三轮共 14 条问题全部修复（§8） |

**先跑这三条确认环境没坏：**

```powershell
cd "D:\AppData\token消耗面板"
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -SelfTest        # 期望：颜色逻辑 10/10
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-templates.ps1              # 期望：通过 49 / 49
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -TestUI          # 期望：通过 16 / 16
```

---

## 1. 项目定位（方向错了会白干）

**这是预警工具，不是监控工具。**

用户的原话是"显示额度的小 APP"，但单纯"把后台数字搬到桌面"没有价值——他还得主动去看。真正的价值是**在额度耗尽之前主动告诉他**。

由此推导出的判断标准：**一个功能该不该做，不看"能不能实现"，看"能不能帮用户避免一次被打断"。**

### 明确不做（这条线很重要）

| 不做 | 原因 |
|---|---|
| API 代理转发 | 那是 CC Switch 的职责，重复造轮子还会互相打架 |
| Key 管理与切换 | 同上 |
| Token 计费统计 | 各家口径不同算不准，反而误导决策 |
| 跨平台 | UI 层 100% WinForms + GDI+，macOS 上等于重写（见 §7.13）。用户日常只有 Windows |

最容易失控的方向是"顺手把 CC Switch 也做了"。一旦开始管 Key 和切换，它就从预警工具变成半个代理管理器，复杂度翻十倍，而用户真正需要的那个数字反而没人管。

### 核心用户场景

用户订阅了 **MiniMax Coding Plan**（两个账号）+ **DeepSeek 余额**，日常在 CC Switch 里切换供应商跑 Codex/Claude Code。他需要一眼看出哪个账号快用完了。

---

## 2. 运行与调试

### 2.1 启动方式

```
Token Pocket.lnk              ← 推荐入口，双击零闪（wscript + VBS，全程无控制台）
TokenPocket.vbs               ← 无窗口启动器本体；也可直接双击，同样零闪
start-token-pocket.cmd        ← 兼容入口，内部转调 VBS；cmd 自己的控制台会闪一下（约 50ms）
start-token-panel.cmd         ← 旧名转发 stub，保留是为了不让已有快捷方式失效
debug-token-pocket.cmd        ← 保留控制台，启动失败时看报错
```

**为什么不用 `start "" powershell.exe -WindowStyle Hidden`**（旧写法，已废弃）：
`start` 会先给 powershell 开一个**可见**的控制台窗口，PowerShell 启动后才执行
`-WindowStyle Hidden` 把它藏起来——中间那一下就是用户看到的黑窗闪。
VBS 的 `Run cmd, 0, False` 是**从创建起就隐藏**，不存在可见阶段。

**单实例保护**：`TokenPanel.ps1` 启动时抢命名 Mutex `TokenPocket_SingleInstance`，
抢不到就写日志退出。所有 `-Xxx` 验证开关会跳过该检查（否则测试会被运行中的实例挡住）。
这条同时解决了「双击两次 → 两个悬浮窗 + 闪两轮」的问题。

**注意**：用 Agent 的后台任务启动，任务结束时进程会被回收，看起来像崩溃。这不是 bug。
要常驻必须让用户双击（独立进程）。

**移动文件夹后**：`.lnk` 里的路径是绝对路径，会失效；跑 `make-shortcut.ps1` 重新生成即可
（`.vbs` 自己按脚本所在目录解析路径，是便携的）。

### 2.2 全部调试开关

| 开关 | 作用 | 期望输出 |
|---|---|---|
| `-SelfTest` | 拉一次数据 + 颜色逻辑边界测试，不建窗口 | `通过 10/10` |
| `-Shot` | 截图折叠态 + 展开态后退出 | `shot-dock.png` / `shot-panel.png` |
| `-Demo` | 用 3 个假账户（青/黄/红三色）验证布局 | 配合 `-Shot` |
| `-ConfigShot` | 配置页截图后退出 | `shot-config.png` |
| `-ConfigShot -ConfigPage system` | 系统配置页截图 | 同上 |
| `-ConfigShot -ConfigTpl custom` | 切到指定模板再截图 | 同上 |
| `-LayoutCheck` | 逐模板输出行位置、溢出、页面切换可见性 | 见 §6.3 |
| `-TestAutostart` | 开机自启读写双向回验 | `结论: 通过` |
| `-TestUI` | **程序化点击配置页控件**，16 项断言，测完自动还原配置 | `通过 16 / 16` |
| `-TestScale` | 界面缩放五档**实际窗口尺寸**断言 | `通过 4 / 4` |
| `-TestRescaleLive` | **真的点一次缩放 chip**，验证窗口被重建（无人值守） | `通过 2 / 2` |
| `-GeomTest` | 贴边吸附 / 横纵排 / DPI 重算 / 浮窗预览 / 显示数量 / 配色 共 21 项 | `通过 21 / 21` |
| `-Shot -ForceOrient v` | 强制纵排再截图，输出 `shot-dock-v.png` | 4 张图 |
| `-Shot -ForceTheme light` | 强制浅色再截图（只影响本次运行，不写配置） | `shot-dock-light.png` 等 |
| `-Shot -Anim` | 停在动效的某一帧截图（不启动定时器） | `shot-dock-anim.png` |
| `-DumpMenu` | 打印右键菜单项与勾选态 | 菜单文本 |

`-TestUI` 是最有价值的开关：它真的去 `PerformClick()` 按钮、反射调 `OnClick` 拨开关，验证「点击 → 配置 → 注册表 → 落盘」整条链路，而不是只看界面长得对。

`-TestScale` 和 `-GeomTest` 是 v1.1.0 新增的：前者量出「50/75/100/150 点下去窗口到底多大」，后者真的把窗口摆到屏幕边上再验证吸附方向和尺寸。**这两个开关就是 §8.1/8.2/8.3/8.6 的回归防线**，改这几块必须跑。

### 2.3 独立测试脚本

```
test-templates.ps1   49 项：6 模板的预设/解析器/URL 拼接/官方无凭据提示
                      + 余额数值化（含负数、透支）+ 自定义 scale/unit + 提取器脚本生成
test-shape.ps1        6 项：预设数组形态回归（防 PowerShell 解包坑复发，见 §7.1）
```

---

## 3. 文件职责地图

```
D:\AppData\token消耗面板\
├── TokenPanel.ps1              1088 行  ← 主程序：窗口/绘制/交互/托盘/菜单
├── lib\
│   ├── QuotaCore.ps1            838 行  ← 数据层：配置/加密/HTTP/各供应商解析
│   └── ConfigWindow.ps1        1230 行  ← 配置页：账户页 + 系统页 + 缩放
├── start-token-pocket.cmd               启动入口
├── debug-token-panel.cmd                带控制台启动
├── setup-accounts.ps1                   一次性迁移脚本（从 cc-switch.db 导账户）
├── cleanup-tauri.cmd                    一次性清理（卸 VS Build Tools，需管理员）
├── test-templates.ps1 / test-shape.ps1  回归测试
├── shot-*.png                           验证截图
├── 待优化问题.txt                        ← 用户手写的 6 条问题（§8 的来源）
├── HANDOFF.md                           ← 本文档
└── archive\                             废弃实现备份（QuotaTray.ps1 托盘版、WebView2 版）
```

### 3.1 TokenPanel.ps1 函数索引

| 行 | 函数 | 职责 |
|---|---|---|
| 116 | `C` | hex → Color |
| 122–163 | `Get-AccountMoney / Get-MoneyHex / Get-AccountMoneyText / Get-MoneyFontPx / Get-AccountMoneyShort` | 金额账户取值、配色、字号自适应、圆环短文本 |
| 179 | `Get-TierLevel` | 单窗口告警等级 0/1/2 |
| 197 | `Get-AccountLevel` | 账户取所有窗口最严重等级 |
| 250 / 256 | `S` / `DS` | 逻辑 → 物理像素（DS 额外乘悬浮系数，仅折叠态） |
| 261 | `Get-PanelHeight` | 展开态高度 |
| 271–284 | `Get-DockCount / Get-DockWidth / Get-DockHeight` | 折叠态尺寸，**按横排/纵排分支** |
| 293 / 307 | `New-RoundedPath` / `New-RoundedPathEx` | 圆角路径；Ex 版四角半径独立（贴边削平用） |
| 345 | `Draw-Ring` | 圆环 + 数字 + 小号 % |
| 427 | `Draw-MoneyRing` | 余额圆环：细描边整圈 + 居中金额（不画进度弧） |
| 408 | `Draw-Bar` | 进度条 |
| 426 | `Format-Reset` | 重置时间紧凑格式（49m / 4h42m / 3d9h） |
| 443 | `Get-MaxUsed` | 账户最大使用量（**展开态大号数字用**；折叠态圆环已改用 `Get-PrimaryTier`） |
| 455 | `Get-PrimaryTier` | 取第一个有效窗口 = **5 小时**，折叠态圆环的数字与颜色都以它为准 |
| 521 | `Get-FlickerText` | 动效期间的乱跳数字：位数/货币符号/小数位不变，数值每 3 帧随机 |
| 456 | `Get-SortedAccounts` | 按最大使用量降序 |
| 471 | `Draw-Dock` | 折叠态绘制（横排/纵排、圆环/金额胶囊） |
| 551 | `Draw-Panel` | 展开态绘制 |
| 744 | `Get-WorkArea` | 取窗口所在屏的可用区域（跨屏取交集最大那块） |
| 756 | `Update-WindowRegion` | 按吸附边削平圆角后设 Region |
| 769 | `Apply-Mode` | dock/panel 切换 + 尺寸 + **贴边锚点** + 钳制回工作区 |
| 880 | `Update-DockGeometry` | DPI 重读 / 吸附判定 / 横纵排切换，返回 `Resize/Moved/X/Y/W/H` |
| 994 | `Preview-DockScale` | 配置页点「小/默认/大」时的实时预览入口 |
| 1044 | `Preview-Theme` | 配置页点「深色/浅色」时换色 + 重建右键菜单 + 强制重绘 |
| 1001 | `Open-ConfigFile` | 打开配置页并应用变更 |
| 1030–1063 | `Get/Set-AutostartEnabled`、`Sync-AutostartFromRegistry` | 注册表读写 + 回验 |
| 1116 | `New-PanelMenu` | 悬浮窗与托盘共用菜单 |
| 1200+ | 事件绑定区 | 拖动/点击/吸附/定时刷新；`$script:UserMoving` 守卫在此 |

### 3.2 QuotaCore.ps1 函数索引

| 行 | 函数 | 职责 |
|---|---|---|
| 33 | `Write-CoreLog` | 写日志（只在失败/关键节点写） |
| 47/56 | `Protect/Unprotect-String` | DPAPI 加解密（绑当前 Windows 用户） |
| 71 | `Get-TemplateDefs` | 6 个模板定义 |
| 87 / 125 | `Get-MainTheme` / `Get-CwTheme` | 深色/浅色两套调色板（浮窗 / 设置页） |
| 90 | `Get-TemplateVars` | 该模板支持/用到的 `{{变量}}` 说明文案 |
| 100 | `Get-ExtractorPreview` | 按当前字段值生成「等价 CC Switch 脚本」 |
| 346 | `Get-TemplateById` | 按 Id 取模板 |
| 356 | `Get-ProviderPresets` | **按模板分组的**供应商预设 |
| 422 | `Get-PresetById` | 跨模板按 Id 查预设 |
| 439 | `New-ProviderObject` | 建账户对象（含 tpl/type/scale/unit） |
| 460 | `Get-DefaultConfig` | 默认配置（新增字段记得同步这里 + Repair-Config） |
| 478 | `Repair-Config` | **补齐缺失字段 + 合法性校验**（改字段必改这里） |
| 530/546 | `Load/Save-Config` | 读写 config.json |
| 558 | `Invoke-Http` | HTTP（**显式绕过系统代理**） |
| 604 | `New-Tier` | 建窗口对象；`-Money` 传金额数值，status=3 返回 $null |
| 622 | `Get-JsonPath` | 按 `a.b.0.c` 取 JSON 值 |
| 649–793 | `Parse-MiniMax/Kimi/Zhipu/OpenCode/DeepSeek/Custom` | 各家解析器 |
| 740 | `Parse-Custom` | **按 `unit` 分流百分比/金额，按 `scale` 换算** |
| 793/803 | `Get-ClaudeOAuthToken` / `Get-CodexOAuthToken` | 读本机 OAuth |
| 820–926 | `Parse-General/NewApi/Balance/Official` | 新模板解析器 |
| 968 | `Get-ProviderRequestUrl` | 按模板拼 URL |
| 980 | `Invoke-QuotaRequest` | 发请求 + 状态码检查（统一错误文案） |
| 989 | `Invoke-Provider` | **查询总入口，按 tpl 分发** |
| 1078 | `Find-WorkingKey` | 自动探测可用 Key（用真实请求验证） |
| 1112 | `Get-AllQuota` | 聚合所有账户 → 前端结构（输出 `kind` / `money`） |

### 3.3 ConfigWindow.ps1 函数索引

| 行 | 函数 | 职责 |
|---|---|---|
| 33 | `X` | 基准逻辑 → 当前缩放后的像素（`× cwF`） |
| 52 | `CW-Font` | 字体工厂（**像素单位 + 乘 cwF**） |
| 60–147 | `CW-Label/Text/Btn/Chip` | 控件工厂 |
| 147 | `CW-Switch` | 自绘开关（尺寸按自身大小算，缩放不变形） |
| 188 | `Scale-CtrlFonts` | **递归缩放字体**（Form.Scale 不缩字体，见 §7.2） |
| 206 | `Show-ConfigWindow` | 主入口。改缩放会**递归重建**自己，参数见 §2.2 |
| 675 | `Get-ScaleHint` | 缩放档位说明文案 |
| 686 | `Update-SystemHints` | 系统页所有状态回显 |
| 712 | `Restore-DockPreview` | 取消/关闭时把浮窗系数还原 |
| 719 | `Update-Extractor` | 生成「变量 + 提取器代码」展示 |
| 730 | `Show-Page` | 账户页 / 系统页切换 |
| 748 | `Resize-ForPage` | 按当前页/模板算窗口高度（**含提取器区块高度**） |
| 773 | `Rebuild-Presets` | 重建供应商胶囊 |
| 829 | `Apply-TemplateLayout` | **按模板重排字段行** + 定位状态栏/提取器块 |
| 855 | `Set-Template` | 切模板（含 type 合法性修正） |
| 979 | `Save-UIToAccount` | UI → 账户对象（只存本模板用到的凭据 + scale/unit） |

### 3.4 截图清单（都是当前版本的真实渲染，可随时重出）

| 文件 | 内容 | 重出方式 |
|---|---|---|
| `shot-dock.png` | 折叠态 · 默认档（68）深色 | `-Shot` |
| `shot-dock-small.png` | 折叠态 · 小档（51） | `dockScale` 设 0.75 后 `-Shot` |
| `shot-dock-large.png` | 折叠态 · 大档（85） | `dockScale` 设 1.25 后 `-Shot` |
| `shot-dock-v.png` | 折叠态 · 纵排 | `-Shot -ForceOrient v` |
| `shot-dock-light.png` | 折叠态 · 浅色主题 | `-Shot -ForceTheme light` 后改名 |
| `shot-dock-anim.png` | 双击刷新动效的某一帧 | `-Shot -Anim` 后改名 |
| `shot-panel.png` | 展开态 | `-Shot` 会自动同时产出 |
| `shot-config.png` | 配置页 · 账户 | `-ConfigShot` |
| `shot-cfg-system.png` | 配置页 · 系统 | `-ConfigShot -ConfigPage system` |
| `scheme-compare.png` | 排版方案 A/B/C 对比（v1.1.4 定方案的依据） | `preview-schemes.ps1` |

**注意**：`-Shot` 只在 `-ForceOrient` 时改文件名，`-ForceTheme` / `-Anim` 产出的仍是
`shot-dock.png`，需要手工改名——这也是历史上截图反复过期的原因。
**改完 UI 必须重出这些图**，否则截图与代码不一致，比没有截图更误导人。

## 4. 架构与数据流

### 4.1 三层

```
┌─ 表现层 ─────────────────────────────────────────┐
│ TokenPanel.ps1      折叠态/展开态 GDI+ 自绘       │
│ ConfigWindow.ps1    设置窗口（WinForms 控件）     │
└───────────────────┬──────────────────────────────┘
                    │ Get-AllQuota -Cfg
┌─ 数据层 ──────────▼──────────────────────────────┐
│ QuotaCore.ps1                                    │
│   Load-Config → Repair-Config                    │
│   Invoke-Provider → 按 tpl 分发 → Parse-*        │
└───────────────────┬──────────────────────────────┘
                    │ HTTPS（Proxy = $null）
              各供应商额度接口
```

### 4.2 一次刷新的完整链路

1. `Timer.Tick`（间隔 = `Cfg.refreshMinutes` 分钟）或手动「立即刷新」
2. `Get-AllQuota -Cfg $Cfg`
3. 遍历 `Cfg.providers`，跳过 `enabled=false`
4. `Invoke-Provider`：
   - `tpl=official` → 读本机 OAuth，不走界面 Key
   - `tpl=newapi` → `Bearer accessToken` + `New-Api-User: userId`
   - 其余 → `Bearer apiKey`（`authMode=raw` 时不加前缀）
   - URL 由 `Get-ProviderRequestUrl` 按模板拼
5. `Invoke-QuotaRequest` → 状态码检查 → `Parse-*` 出 `Tiers`
6. 返回统一结构：

```powershell
[pscustomobject]@{
    accounts = @(
        [pscustomobject]@{
            id = 'minimax'; name = 'MiniMax-2421'; short = 'MX2421'
            ok = $true; error = $null; kind = 'pct'   # pct=额度百分比 / money=余额金额
            primary = 66                              # primary = 第一个窗口的 remain
            tiers = @(
                [pscustomobject]@{ name='5小时'; remain=92; reset_at='<ISO>'; display='92%'; money=$null }
                [pscustomobject]@{ name='7天';  remain=66; reset_at='<ISO>'; display='66%' }
            )
        }
    )
    fetched_at = '<ISO>'
}
```

7. `$canvas.Invalidate()` → `Draw-Dock` / `Draw-Panel`

### 4.3 关键约定：`remain` 是「剩余」，界面显示「使用量」

数据层全程用 **remain（剩余百分比）**；界面显示时统一转成 `used = 100 - remain`。这样和 CC Switch 一致（它显示已用 8%，我们显示 8% 而不是 92%）。

余额类账户没有百分比，`remain = -1`，靠 `display` 字段带单位文本（如 `¥88.50`）。

---

## 5. 关键机制详解

### 5.1 三层缩放（最容易搞错的地方）

项目里有**三套独立的缩放**，混用必然出 bug：

| 机制 | 符号 | 公式 | 作用域 |
|---|---|---|---|
| 系统 DPI | `$script:Scale` | `GetDpiForWindow() / 96`，本机 1.5 | 全局 |
| 悬浮窗大小 | `$script:DockScale` | 0.75 / 1.0 / 1.25 | **仅折叠态** |
| 界面缩放 | `$script:cwF` | 0.5 / 0.75 / 1.0 / 1.5 / auto | **仅配置页** |

- `S(v)` = `v × Scale` → 展开态、位置偏移用这个
- `DS(v)` = `v × Scale × DockScale` → 折叠态的圆环/字号/尺寸用这个
- `X(v)` = `v × cwF` → 配置页动态布局用这个

**`Scale` 不是常量**：v1.1.0 起每次拖动结束都会在 `Update-DockGeometry` 里重读 `GetDpiForWindow`，
跨不同缩放比例的显示器时自动改 `Scale` 并重建尺寸（见 §8.3）。改动前它只在启动时取一次，那是截断 bug 的根因。

**`cwF` 变化靠重建窗口**：点 50/75/100/150 时不做增量 `Form.Scale`，而是把未保存的编辑带出来、
关掉窗口、用新系数重新建一个（`Show-ConfigWindow` 递归调用自己）。增量缩放会让字体尺寸累积舍入误差，
点十次之后字会明显不齐；重建没有这个问题，代价是闪一下。

**为什么必须 `SetThreadDpiAwarenessContext(-4)`**：PowerShell 宿主的 manifest 锁死了 DPI 感知级别，`SetProcessDpiAwareness` 返回成功但 `DpiX` 仍是 96。只有线程级 API 能覆盖。不设的话 Windows 把整个窗口当位图拉伸 1.5 倍，字体必然糊——这是本项目最大的一个坑，排查了两轮才定位。

**为什么 `AutoScaleMode = None` + `SetWindowPos`**：DPI 感知后 WinForms 的 `Form.Size` 还会二次缩放（设 89 渲染成 202）。必须用 Win32 `SetWindowPos` 直接设物理像素。

### 5.2 告警颜色规则

按**使用量**判断（不是剩余量）：

| 窗口 | 黄 | 红 |
|---|---|---|
| 5 小时 | 使用 ≥ 80% | 使用 ≥ 90% |
| 周/天 | 使用 ≥ 90% | 使用 ≥ 95% |

账户圆圈取**两个窗口里最严重的一级**（周告警会联动 5h 圆圈）。`Get-TierLevel` 里用正则 `周|天|week|weekly|month|月` 判断是否周窗口。

折叠态圆圈显示的数值也取**最严重的窗口**——因为两个 MiniMax 账号的 5 小时用量经常相同（都 8%），只取 5h 会让两个圆圈一模一样、失去区分度。

### 5.3 模板体系

CC Switch 的模板本质是**「请求地址 + 认证头 + 提取器」三件套**。本项目实现 6 个：

| 模板 | 请求 | 认证 | 解析 | 显示 |
|---|---|---|---|---|
| `custom` 自定义 | 用户填完整 URL | Bearer / 裸 Key | `valuePath` + `scale` + `unit` | 百分比 **或** 金额 |
| `general` 通用模板 | `{BaseURL}/user/balance` | Bearer | `balance` 字段 | 金额 + unit |
| `newapi` NewAPI | `{BaseURL}/api/user/self` | `Bearer accessToken` + `New-Api-User: userId` | `data.quota / 500000` USD | `$剩 / $总` |
| `tokenplan` Token Plan | 内置 4 家完整 URL | 各家不同 | 各家专属解析器 | 5小时/7天 双窗口 |
| `balance` 第三方余额 | 内置 4 家完整 URL | Bearer | 各家字段 | 金额 |
| `official` 官方 | Claude / Codex OAuth 接口 | 读本机凭据 | `utilization` / `used_percent` | 双窗口 |

**自定义模板的 `scale` / `unit`**（v1.1.0 新增，是「提取器」能力的落地）：
- `valuePath` 取值后先 `× scale`，再按 `unit` 决定语义
- `unit = %`（默认）→ 当成剩余百分比，画圆环
- `unit = CNY / USD / ¥ / $` → 当成钱包余额，画金额胶囊，负数红色
- 例：NewAPI 的 `quota` 要 `scale=0.000002` + `unit=USD` 才是 1 美元

**提取器展示（配置页底部）**：CC Switch 的模板是「request + extractor 函数 + `{{apiKey}}` 占位符」。
我们没有 JS 引擎跑不了它，所以 `Get-ExtractorPreview` 按**当前填写的值实时生成**等价脚本，
配 `Get-TemplateVars` 列出 4 个变量。看到的就是会执行的东西，也能直接复制回 CC Switch。
CC Switch 的 extractor 返回契约（从其二进制核对）：`isValid / invalidMessage / remaining / unit / total / used / planName / extra`。

**内置供应商清单（端点全部用 curl 探测过存在性）：**

| 模板 | Id | 地址 | 认证 | 探测结果 |
|---|---|---|---|---|
| tokenplan | minimax | `api.minimaxi.com/v1/api/openplatform/coding_plan/remains` | bearer | 200 ✅ |
| tokenplan | kimi | `api.kimi.com/coding/v1/usages` | bearer | 401 ✅ |
| tokenplan | zhipu | `open.bigmodel.cn/api/monitor/usage/quota/limit` | **raw** | 200 ✅ |
| tokenplan | opencode | `opencode.ai/zen/go/v1/usage` | bearer | 401 ✅ |
| balance | deepseek | `api.deepseek.com/user/balance` | bearer | 401 ✅ |
| balance | siliconflow | `api.siliconflow.cn/v1/user/info` | bearer | 401 ✅ |
| balance | openrouter | `openrouter.ai/api/v1/credits` | bearer | 401 ✅ |
| balance | stepfun | `api.stepfun.com/v1/accounts/balance` | bearer | 401 ✅ |
| official | claude | `api.anthropic.com/api/oauth/usage` | oauth | 403 ✅ |
| official | codex | `chatgpt.com/backend-api/wham/usage` | oauth | 网络受限 |

**未收录（探测不通，不要盲目加）：**
- Novita `api.novita.ai/v3/*` → 全部 400，语义不明
- Command Code `api.commandcode.ai/api/v1/usage` → 404

**智谱的坑**：它用**裸 Key**（不加 `Bearer ` 前缀），`authMode='raw'`。很多工具会在这里翻车。

### 5.4 配置结构（完整字段）

```jsonc
{
  "providers": [
    {
      "name": "MiniMax-2421",          // 展开态显示名
      "short": "MX2421",               // 折叠态圆圈下方标签
      "tpl": "tokenplan",              // 模板：决定字段与解析器
      "type": "minimax",               // 模板内的供应商预设
      "apiUrl": "https://...",         // 完整 URL（tokenplan/official/custom）或 BaseURL（general/newapi）
      "apiKey": "<DPAPI 密文 base64>", // 456 字符
      "accessToken": "",               // 仅 newapi
      "userId": "",                    // 仅 newapi
      "authMode": "bearer",            // bearer | raw | newapi | oauth
      "refreshMinutes": 5,             // 单账户级（当前未生效，全局用下面的）
      "enabled": true,                 // 对应「启用用量查询」开关
      "valuePath": "",                 // 仅 custom：提取路径
      "resetPath": "",                 // 仅 custom：重置时间 JSON 路径
      "scale": 1,                      // 仅 custom：倍数（接口原始值 × 该倍数）
      "unit": "%"                      // 仅 custom：% 表示额度百分比，CNY/USD 表示余额
    }
  ],
  "warnThreshold": 25,                 // 旧字段，已被固定阈值取代，保留兼容
  "critThreshold": 10,
  "refreshMinutes": 5,                 // 全局刷新间隔（系统配置页）
  "timeout": 15,                       // HTTP 超时秒数（系统配置页）
  "startWithBoot": true,               // 与注册表双向同步
  "dockRight": 80,                     // 距屏幕右下角的逻辑偏移
  "dockBottom": 198,
  "startMode": "dock",                 // dock | panel
  "maxDockItems": 3,                   // 折叠态显示几个（1–5，系统配置页可调）
  "theme": "dark",                     // dark | light（系统配置页可切）
  "uiScale": "auto",                   // auto | 50 | 75 | 100 | 150
  "dockScale": 1,                      // 0.75 | 1.0 | 1.25
  "moneyWarn": 20                      // 余额低于该值转黄（负数一律红）
}
```

**新增字段必须同时改三处**：`Get-DefaultConfig`（默认值）、`Repair-Config`（补齐 + 校验）、`Save-UIToAccount` 或保存处理器（写值）。漏改 `Repair-Config` 会导致老配置读出来是 `$null`，然后静默失效——这个坑踩过。

### 5.5 密钥存储

`Protect-String` / `Unprotect-String` 用 **Windows DPAPI**（`DataProtectionScope.CurrentUser`）：

- 密文绑定当前 Windows 用户，换机器 / 换用户解不开
- 明文从不落盘，日志里也不打
- **不要把密钥打印到控制台或写进文档**

### 5.6 开机自启

写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\TokenPocket`，值：

```
powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "D:\AppData\token消耗面板\TokenPanel.ps1"
```

`Set-AutostartEnabled` 会**写后回读**验证，返回 `$true/$false`。UI 层以返回值决定是否打勾——写失败就回滚显示，避免"界面勾了但注册表没写"。

改名时会把旧键 `TokenPanel` 一并删除，避免开机启动两次。

### 5.7 悬浮窗几何：吸附 / 横纵排 / 圆角（v1.1.0 新增）

折叠态有两种排布，由**吸附到哪条边**决定，只存在于折叠态（展开态固定 340 宽）：

| 吸附边 | 排布 | 尺寸 |
|---|---|---|
| 无 / 上 / 下 | 横排 `h` | `DS(68 × n)` × `DS(68)` |
| 左 / 右（且离任务栏 ≥150 物理像素） | 纵排 `v` | `DS(68)` × `DS(68 × n)` |

- **吸附阈值** `S 24`：离工作区边 < 24 物理像素就贴上去，横竖两个轴独立判断（角落里会同时贴两条边）
- **方向只在真的贴上竖边时切换**。曾经试过「离竖边 150px 内就提前竖起来」，结果默认位置（差 120px）
  一启动就竖着，非常惊悚，已回退
- **锚点跟吸附边走**：贴左固定左边缘并贴齐，贴右下固定右下。`Apply-Mode` 里用 `switch ($script:SnapEdgeH/V)` 实现。
  如果只按「当前 rect 的右下角」锚定，贴边 Resize 后窗口会从边上弹开 12px
- **圆角按吸附侧削平**：`Update-WindowRegion` 用 `New-RoundedPathEx` 传四个角半径，
  贴哪条边就把那条边两端的角设 0，看起来才像「长在屏幕边上」而不是浮着
- **谁触发重算**：`Update-DockGeometry`（返回 `Resize/Moved/X/Y/W/H`）。
  拖动 → `moveTimer` 500ms 后调一次；启动摆完位置也调一次（上次贴右边退出，这次开机就得竖着起来）

**`$script:UserMoving` 是关键守卫**：`LocationChanged` 会被程序自己的展开/收起/截图触发，
无条件当成拖动去吸附+落盘，会把用户的 `dockRight/dockBottom` 写花（本项目踩过，把 80/198 写成了 0/0）。
只有画布上检测到真实拖动（位移 > 4px）才置 true。

### 5.8 余额账户的显示（v1.1.1：改回圆环）

数据层给每个 tier 带 `money`（数值）和账户级 `kind`（`pct` / `money`）：

- 折叠态：`kind='money'` 用 `Draw-MoneyRing` —— 与百分比圆环同骨架，**描边细一档（DS 2）且不画进度弧**，
  金额居中、字号按长度自适应（14/11/9）；只显示「当前金额」（`Get-AccountMoneyShort` 截掉 `/ 总额`）
- 颜色：`money < 0` 红 / `< moneyWarn(20)` 黄 / 否则青
- 展开态：右上角大号数字位置显示金额，宽度从 `S 46` 放宽到 `S 104`，负数下面再加一行「已欠费」
- `Get-MaxUsed` 对金额账户返回 -1（不参与告警等级）；排序已改为**配置顺序**，不再按告警程度排

### 5.9 配色（v1.1.1）

两套调色板在 `QuotaCore`：`Get-MainTheme`（浮窗）/ `Get-CwTheme`（设置页），键名一一对应。
`$script:Cfg.theme` 决定用哪套，缺键会让绘制静默失败，所以 `test-templates.ps1` §9 专门断言键齐全。

关键约束：
- 浅色下**必须**有 `$Theme.Border` 那条 1px 描边，否则白窗贴白墙看不见
- 圆环里的数字不能写死白色，用 `$Theme.RingText`；底环用 `$Theme.TrackRing`
- 设置页 `$CW` 在 `Show-ConfigWindow` 开头按配置重设，不要再用文件顶部的静态值
- 切配色走「重建窗口」流程（和改缩放同一条路），主窗由 `Preview-Theme` 立即重画
- 光弧/高亮色用主题键 `Glow`（深色 `#8CF5E3` / 浅色 `#0067C0`），别在绘制代码里写死

### 5.10 双击刷新动效（v1.1.2）

- 动画状态：`$script:AnimActive / AnimFrame / AnimAngle / AnimSeed`；定时器 `animTimer` 33ms × 30 帧
- 单击动作挂 `clickTimer` 240ms 防抖，用来把「单击展开」和「双击刷新」分开（代价：单击展开慢 240ms）
- 动效期间数字走 `Get-FlickerText`，**位数/货币符号/小数位必须稳定**，否则 `Draw-Ring` 的测宽会抖
- 到 30 帧：先 `Refresh()` 画一帧静止，再 `Refresh-Data` 同步拉数据（这段时间主线程阻塞，见 §8.16）


---

## 6. 已验证的事实（不要重复验证）

### 6.1 端点探测（2026-10-29，curl，`--noproxy '*'`）

见 §5.3 表格。判断标准：`401/403` = 端点存在需鉴权；`200` = 存在；`404` = 地址错；`400` = 语义不明。

### 6.2 尺寸实测（150% DPI，3 账户横排，v1.1.3）

| 悬浮大小 | 系数 | 物理像素 | 逻辑像素 |
|---|---|---|---|
| 小 | 0.75 | 230×76 | 153×51 |
| 默认 | 1.0 | 306×102 | 204×68 |
| 大 | 1.25 | 382×128 | 255×85 |

配置页：基准 880×658，150% → 1320×987，75% → 660×494。

### 6.3 测试通过数

```
-SelfTest       颜色逻辑 10/10
test-templates  55/55（6 模板预设 + 解析器断言 + 金额数值化 + 自定义 scale/unit + 提取器脚本 + URL 拼接 + 官方无凭据 + 配色键齐全）
test-shape      6/6（数组形态）
-TestUI         18/18（含注册表真写/复原、保存落盘、且保存前会把缩放/浮窗/配色点回原值，不污染配置）
-TestScale       4/4（50/75/100/150 四档宽度分别 ≈ 440/660/880/1320）
-TestRescaleLive 2/2（真点 150% → 窗口重建为 1320×996；点 75% → 660×498）
-GeomTest       27/27（贴右纵排、贴底横排、中间漂浮、DPI 重算、浮窗预览、显示数量、配色切换、双击动效）
-LayoutCheck    6 模板无重叠无溢出；账户页/系统页切换正常
```

### 6.4 用户当前的账户配置（截至 2026-10-29 17:00）

| 顺序 | name | short | tpl / type | 说明 |
|---|---|---|---|---|
| 1 | MiniMax-2421 | MX2421 | tokenplan / minimax | 主力账号，key 前缀 `sk-cp-` |
| 2 | MiniMax-0568 | MX0568 | tokenplan / minimax | 第二账号，额度独立 |
| 3 | Deepseek | Deepseek | **balance / deepseek** | 用户自己加的余额账户，**触发 §8.5 的 bug** |

其他配置：`startWithBoot=true`、`uiScale=auto`、`dockScale=1`、`dockRight=80`、`dockBottom=198`。

**注意**：CC Switch 里还有 1 个 MiniMax 配置的 key 已失效（返回 `1004 cookie is missing`），不要重复导入。从 `~/.cc-switch/cc-switch.db` 的 `providers` 表可提取全部配置，`setup-accounts.ps1` 是当时的迁移脚本（**注意它有已知 bug，见脚本内注释，需要重新验证每个 key 有效性**）。

---

## 7. 踩过的坑（改代码前必读）

> 这一节是整个文档最值钱的部分。每条都是真实踩过、且排查了不止一轮的。

### 7.1 PowerShell 单元素数组会被解包两次

**现象**：`Get-ProviderPresets -Tpl 'custom'` 返回的对象 `.Count` 等于 **6**（哈希表的键数），遍历拿不到 `Id`。

**根因**：两层解包叠加
1. 哈希表字面量 `@{ custom = @(@{...}) }` 里的单元素数组被解包成 Hashtable
2. 函数返回时管道又把单元素数组解包成元素本身

**正确做法**：函数内 `if ($out -is [hashtable]) { return @($out) }`，**调用方一律 `@()` 包裹**。

**反例**：`Write-Output -NoEnumerate` 和 `return ,$out` 都会让 `@()` 拿到**嵌套数组**（`.Count` 变成 1），反而更糟。已试错并记录在 `test-shape.ps1` 里防复发。

### 7.2 `Form.Scale(SizeF)` 只缩 Bounds，不缩字体

**现象**：配置页设 150%，控件框变大了，但字还是原来大小 → 看起来"不统一"。

**实测证据**：`Label` 200×30 / 12px 字体，`Form.Scale(1.5)` 后变成 300×45 / **仍 12px**。

**正确做法**：`Form.Scale(f)` 之后必须自己递归走一遍 `Scale-CtrlFonts(form, f)`。之后动态创建的控件由 `CW-Font` 直接乘 `cwF`，不要再被 Scale 一遍。

### 7.3 PowerShell 变量名不区分大小写

**现象**：主题色表 `$T` 和函数里的 `$t`（TextBox）是同一个变量。一创建控件，主题表被覆盖成 TextBox 对象，`C $T.Field` 取到空值，所有输入框**静默变白底**。

**正确做法**：主题表命名 `$Theme`，控件变量避免单字母同名。排查了两轮才定位。

### 7.4 `DrawToBitmap` 对原生控件不可信

**现象**：截图显示白底，实际运行是深色；反过来也发生过。

**正确做法**：判断 UI 对不对必须用 `CopyFromScreen` 截真实屏幕。但**自绘 Panel**（`Draw-Dock`/`Draw-Panel`）用 `DrawToBitmap` 反而更准，因为它不受 DPI 缩放和窗口遮挡影响。

### 7.5 `Graphics.DrawString` 画小字会发虚

**现象**：深色背景 + 9px 中文，`DrawString`（GDI+）边缘糊。

**正确做法**：改用 `TextRenderer.DrawText`（GDI，走 ClearType + 整数像素对齐）。做过 A/B 对比图确认，差异明显。这也是腾讯管家字体清晰的原因。

### 7.6 `TextRenderer.MeasureText` 带 overhang padding

**现象**：圆环里"92"和"%"之间空了一大块。

**正确做法**：用 `Graphics.MeasureString(..., [StringFormat]::GenericTypographic)` 精确测量，再手动扣 2px。

### 7.7 `Content-Type` 是 .NET 受限头

**现象**：`$req.Headers['Content-Type'] = ...` 抛异常。

**正确做法**：必须走属性 `$req.ContentType`。`Accept` / `User-Agent` 同理。

### 7.8 系统代理会让请求超时

**现象**：curl 通、Python 通、PowerShell 超时；看起来像接口挂了。

**根因**：本机有系统级代理（`http_proxy` 等），连 `127.0.0.1` 也会被接管。

**正确做法**：`$req.Proxy = $null` 显式绕过（已在 `Invoke-Http` 里做了）。命令行验证必须加 `--noproxy '*'`。

### 7.9 config.json 是 UTF-8 BOM

`[System.IO.File]::WriteAllText(..., [System.Text.Encoding]::UTF8)` 在 .NET Framework 下**带 BOM**。PowerShell 的 `Get-Content -Raw | ConvertFrom-Json` 能处理，但 Python 必须用 `utf-8-sig`：

```python
json.loads(open(p,'rb').read().decode('utf-8-sig'))
```

### 7.10 未 Show 的窗口里所有子控件 `Visible` 都是 `$false`

做页面切换自检时必须先 `$form.Show()` 再判断，否则会误判"卡片没显示"。

### 7.11 反射调 `Control.OnClick` 不能传 `@((New-Object EventArgs))`

PowerShell 会把参数包成 `PSObject`，报 `cannot be converted to type 'System.EventArgs'`。

**正确做法**：

```powershell
$args = New-Object 'object[]' 1
$args[0] = [System.EventArgs]::Empty
$mi.Invoke($sw, $args)
```

### 7.12 并排 Label 会互相遮挡

左列 Label 的矩形背景会盖掉右列 Label 的首字（「认证方式」显示成「证方式」）。纯粹是布局坐标重叠，`BackColor=Transparent` 也救不了。

### 7.13 不要用 WebView2（已穷尽）

本项目最初想做 Tauri，后来退到 WebView2 + HTML，**四种初始化方式全部失败**：

1. 系统注册运行时 → `Couldn't find a compatible Webview2 Runtime`
2. 显式指定路径（EdgeWebView 134 / EdgeCore 134·135 / Edge 135 全试过）→ 同上
3. 32 位宿主 + x86 Loader（PE 头校验过位数）→ 同上
4. 消息泵等待（排除 STA 死锁）→ 同上

已排除：SDK 版本、位数、目录权限、组策略、安全软件、运行时完整性（742 MB / 394 文件齐全）。

**结论：本机 WebView2 不可用，不要回头再试。** 备份在 `archive/TokenPanel.webview2.ps1.bak`。

### 7.14 `is_available=false` 不代表没有余额数据

**现象**：用户 DeepSeek 账户余额 `-0.49`，界面只显示「不可用」，看不到数字，更看不到红色。

**根因**：`Parse-Balance` 里 `if ($d.is_available -eq $false) { return '不可用' }` 提前返回，把真实负数吞了。
实际响应是 `{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"-0.49"}]}` —— 欠费时字段照常返回。

**正确做法**：先取 `balance_infos`，有值就照实显示（负数红色）；只有真的没有余额字段才回退「不可用」。

### 7.15 未 Show 的窗口改高度会被还原

**现象**：`-ConfigShot -ConfigTpl custom` 截出来的图，底部代码框被裁掉一截。

**根因**：`Set-Template` → `Resize-ForPage` → `$form.Height = X $nh` 在 `$form.Show()` **之前**执行，
WinForms 在首次 Show 时会把高度恢复成创建时的值。

**正确做法**：截图/自检分支里 `Show()` 之后再切模板（`-LayoutCheck` 一直是对的，因为它先 Show）。

### 7.16 `LocationChanged` 不等于「用户拖动」

**现象**：改完吸附逻辑后，`-Shot` / `-TestUI` 跑几次，用户的 `dockRight/dockBottom` 从 80/198 变成 0/0，
悬浮窗次次贴着右下角竖着起来。

**根因**：程序自己展开/收起/摆初始位置都会触发 `LocationChanged`，原来的代码无条件重启 `moveTimer` 去吸附 + `Save-Config`。

**正确做法**：加 `$script:UserMoving` 守卫，只有画布 MouseMove 里检测到 > 4px 的真实位移才允许触发。

顺带：Tauri 路线也不通——本机没有 MSVC 编译器和 Windows SDK，装 VS Build Tools 时中途被打断留下损坏的安装实例（`vswhere` 查不到路径、`--installPath` 被忽略、提权进程占文件锁），还把 C 盘从 15 GB 吃到 4 GB。用 `cleanup-tauri.cmd` 可回收约 2 GB。

---

### 7.17 PowerShell 是动态作用域，裸变量会被「调用方」劫持

**现象**：在配置页点「悬浮窗大小」，结果**设置窗口自己被压成 89×89**，主悬浮窗纹丝不动。

**根因**：PowerShell 函数里读变量是动态作用域——先在本地找，再往**调用栈**上找，
而不是往「定义处」的作用域找。

```powershell
$form = '主窗'
function Read-Form { return $form }
function Inner { $form = '子窗'; return (Read-Form) }
Read-Form   # → 主窗
Inner       # → 子窗   ← 读到的是调用方的局部变量
```

本项目 `TokenPanel.ps1` 的主窗叫 `$form`，`ConfigWindow.ps1` 的配置窗口也叫 `$form`。
`Preview-DockScale → Apply-Mode` 这条链在配置窗口的栈帧里执行，`Apply-Mode` 里的 `$form` 就解析成了配置窗口。

**正确做法**：跨窗口调用的函数一律用显式作用域变量 `$script:MainForm`。
涉及 `Get-WorkArea / Update-WindowRegion / Apply-Mode / Update-DockGeometry / Show-Panel`。

**同类风险**：`$W / $H / $f / $CW / $Theme` 这种短名，两边都在用；新增跨窗口调用时先想一遍会不会撞。

## 8. 第一轮 6 条问题（v1.1.0）




> 来源：`待优化问题.txt`（用户手写，2026-10-29 16:58）。下面是「根因 → 改法 → 怎么验证」，
> 后续改动不要回退这些行为，改完必须跑对应开关。

### 8.1 界面缩放点了没变化（第 1 条）— 已修复

**根因**：`uiScale` 只在窗口构建时读一次；点 chip 只改了 `$script:EditCfg.uiScale` 和提示文字，
窗口完全没重建，用户看不到任何反馈（所以他的 config 里 `uiScale` 一直是 `auto`）。

**改法**：chip 点击 → 把未保存编辑、当前页、当前模板、窗口位置存到 `$script:Reopen*` →
`$form.Tag='rescale'` → `Close()` → `ShowDialog` 返回后 `return (Show-ConfigWindow -Cfg $script:EditCfg -StartPage ... )`
递归重建。**不做增量 `Form.Scale`**，避免累积舍入误差。

顺带加了两条保护：
- `$script:NoRescale`：`-TestInteractions` 模式下不重建（否则会销毁测试正在点的控件）
- 缩放后若超出屏幕工作区，自动降档（`maxF = min((waH-48)/form.Height, (waW-48)/form.Width)`）

**验证**：`-TestScale` → 50/75/100/150 宽度必须是 440/660/880/1320。

### 8.2 悬浮窗大小点了没变化（第 2 条）— 已修复

**根因**：chip 只写 `EditCfg.dockScale`，主悬浮窗要等「保存」后由 `Open-ConfigFile` 重算。

**改法**：`TokenPanel.ps1` 新增 `Preview-DockScale`，chip 点击直接改 `$script:DockScale` + `Apply-Mode 'dock'`。
配置页模态，主悬浮窗就在后面，肉眼可见。**取消 / 点 ✕ 时 `Restore-DockPreview` 回滚**到打开前的系数，
避免「没保存却生效了」。

**验证**：`-GeomTest` 最后两项（点「大」→ 400×134 变 501×167；恢复默认 → 回落）。

### 8.3 跨不同缩放比例的显示器拖动后截断（第 3 条）— 已修复

**根因**：`$script:Scale` 只在启动时取一次 `GetDpiForWindow`；PerMonitorV2 下拖到 100% 屏仍按 1.5 倍绘制，
内容超出窗口被 Region 裁掉。

**改法**：`Update-DockGeometry` 里每次都重读 DPI，变化超过 0.01 就更新 `Scale` 并返回 `Resize=$true`，
调用方走 `Apply-Mode` 重建尺寸与 Region。`Apply-Mode` 末尾还会把窗口钳制回工作区。

**验证**：`-GeomTest` 第 4 项（把 `Scale` 故意写成 1.0，下一次几何更新必须纠正回 1.5 并按真实 DPI 重建）。

### 8.4 模板缺少「提取器代码」与「支持的变量」（第 4 条）— 已修复

**做了什么**（两条都做了，不是二选一）：
1. **只读展示区**：账户页底部固定一块 —— 一行 `Get-TemplateVars`（4 个占位符；newapi/official 额外说明不用 apiKey）
   + 一个 150px 只读等宽代码框 `Get-ExtractorPreview`。代码是**按当前字段值实时生成**的，
   `$tbUrl / $tbValuePath / $tbScale / $tbUnit` 挂 `TextChanged`，切模板/切供应商也会重算
2. **迷你 DSL 落地**：`custom` 模板新增 `scale`（倍数）与 `unit`（% / CNY / USD），
   `Parse-Custom` 按 unit 分流「百分比额度」还是「余额金额」。NewAPI 那种 `quota` 要 ÷500000 的接口，
   现在用自定义模板就能接

**参考依据**：CC Switch 是 Tauri 应用，模板定义编译在 `cc-switch.exe` 里。从其二进制里核对到的契约：
- 变量：`{{apiKey}} {{baseUrl}} {{accessToken}} {{userId}}`
- extractor 返回：`isValid / invalidMessage / remaining / unit / total / used / planName / extra`
- 沙箱是 QuickJS，请求必须 HTTPS 且与 base_url 同源

**验证**：`test-templates.ps1` §7 §8（20 条断言）。

### 8.5 余额账户显示 `--`、负数不红（第 5 条）— 已修复

**根因有两层**：
1. `Get-MaxUsed` 跳过 `remain < 0`，折叠态走 `Draw-Ring -Pct -1` 画成 `--`
2. 更深的坑：DeepSeek 欠费时返回 `is_available=false` + `total_balance=-0.49`，
   `Parse-Balance` 提前 return「不可用」，把真实数字吞了（详见 §7.14）

**改法**：
- `New-Tier` 增加 `Money`，各余额解析器回填数值；`Get-AllQuota` 输出 `kind`（pct/money）与 tier.money
- 折叠态金额账户画「金额胶囊」，负数红 / < moneyWarn(20) 黄 / 否则青，字号按长度 14/11/9 自适应
- 展开态右上角显示金额（宽度 46→104），负数下面加一行「已欠费」

**验证**：用户真实 DeepSeek 账户 `¥-0.49` 显示为红色胶囊；`test-templates.ps1` §6（6 条断言）。

### 8.6 贴边吸附与靠边自动纵排（第 6 条）— 已修复

**改法**（细节见 §5.7）：
- 吸附阈值 20 → **24**，横竖两轴独立判断，角落里两条边一起贴
- 贴左右边 → **纵排**（`DS 68` 宽 × n 行，v1.1.3 起还需离任务栏 ≥150 物理像素）；贴上下边或无吸附 → 横排
- 锚点跟着吸附边走：贴左固定左边缘**并贴齐**，不再从边上弹开
- 贴边侧圆角削平（**v1.1.3 已改为四角始终圆角**，见 §17.3）
- 新增 `$script:UserMoving` 守卫，程序自身位移不再触发吸附/落盘（§7.16）

**验证**：`-GeomTest` 前三组（贴右→纵排 134×400 且贴齐；贴底→横排 400×134 且贴齐；中间→不吸附）。

## 8B. 第二轮 6 条（v1.1.1）

### 8.7 余额也改用圆环（第 7 条）— 已修复

**要求**：余额别用矩形胶囊，也用圆环显示。

**改法**：新增 `Draw-MoneyRing` —— 与百分比圆环同一套骨架（同半径、同底环），
只是描边细一档（`DS 2` vs `DS 4`）且**不画进度弧**，避免被误读成「用满了」；金额居中，字号按长度 14/11/9 自适应。
圆环里只放「当前金额」（`Get-AccountMoneyShort` 会把 `$1.00 / $2.50` 截成 `$1.00`）。
颜色仍按 `Get-MoneyHex`：负数红 / 低于 moneyWarn 黄 / 其余青。

**验证**：`shot-dock.png`（深色）与 `shot-dock-light.png`（浅色）。

### 8.8 浮窗改小后外框不变、设置界面也错乱（第 8 条）— 已修复

**这是本项目最隐蔽的 bug，根因是 PowerShell 的动态作用域，详见 §7.17。**

`Apply-Mode / Get-WorkArea / Update-WindowRegion / Update-DockGeometry` 都用裸 `$form`。
PowerShell 函数查变量是动态作用域——找「调用方」的局部变量，不是定义处的。
配置窗口内部也叫 `$form`，于是从配置页点「小/默认/大」时：

1. `Preview-DockScale` → `Apply-Mode 'dock'`
2. `Apply-Mode` 里的 `$form` 解析成**设置窗口**
3. `SetWindowPos` 把设置窗口改成浮窗尺寸，`Region` 也套到设置窗口上
4. 真正的主悬浮窗一点没动 → 「圆圈没变化、设置界面错乱」

**改法**：主窗加 `$script:MainForm = $form`，凡是被跨窗口调用的函数一律写 `$script:MainForm`。

### 8.9 「第三方余额」改名「账户余额」（第 9 条）— 已修复

`Get-TemplateDefs` 的 `balance.Label` 改成 `账户余额`；`-TestUI` 断言文案、注释同步。
`Id` 仍是 `balance`，老配置不用迁移。

### 8.10 账户手动排序 + 折叠态显示数量（第 10 条）— 已修复

- **排序**：账户页新增 `↑ 上移` / `↓ 下移`，直接交换 `providers` 数组元素。
  同时**取消**了 v1.1.0 的「按告警程度自动排序」——自动排序会让列表在用户眼皮底下乱跳，
  和「人工排序」互斥。`Get-SortedAccounts` 现在直接返回配置顺序。
- **显示数量**：系统页「外观与显示」新增输入框（1–5，默认 3），存 `maxDockItems`；
  `Get-DockCount` 读它，超出账户数按账户数算。展开态不受影响，始终显示全部。

**验证**：`-GeomTest` 第 6 组。

### 8.11 深色 / 浅色两套配色（第 11 条）— 已修复

- 调色板集中到 `QuotaCore`：`Get-MainTheme`（浮窗）+ `Get-CwTheme`（设置页），各两套、键名一一对应
- 浅色对齐 Windows 11 浅色：底 `#F7F7F8` / 卡片 `#FFFFFF` / 主文字 `#1B1B1B` / 强调 `#0067C0`；
  正常/警告/告警三个语义色压深一档（`#0E7C6B` / `#B45309` / `#C42B1C`），否则浅底上糊成一片
- 浅色必须补 **1px 描边**（`$Theme.Border`），否则白窗贴白墙完全看不见
- 圆环文字、底环、底部状态字全部改用主题键（原来硬编码 `White` / `#55606F`，浅色下直接消失）
- 右键菜单：`DarkColorTable` 改名 `TokenColorTable`，加 `Light` 字段切两套
- 配置页 `$CW` 改为按配置取；点「深色/浅色」走和缩放一样的**重建**流程，主窗用 `Preview-Theme` 立即重画
- 取消/关闭时 `Restore-DockPreview` 连配色一起回滚

**验证**：`test-templates.ps1` §9（配色键齐全）、`-GeomTest` 第 7 组、`-Shot -ForceTheme light`、
`-ConfigShot -ForceTheme light`。

### 8.12 字体能否商用（第 12 条）— 已确认

见 §13。

### 8.13 已知但未做（别当成 bug）

### 8.14 折叠态圆环要显示 5 小时额度（第 13 条）— 已修复

**现象**：MX2421 的 5 小时用量 1%、7 天用量 34%，圆环却显示 34%。

**根因**：`Get-MaxUsed` 取两个窗口里的最大值，用户看到的可能是周额度。

**改法**：新增 `Get-PrimaryTier`（解析器输出的第一个有效窗口 = 5 小时），
`Draw-Dock` 的数字与颜色都改用它的使用量；展开态的两条进度条和账户级告警色不变。

**验证**：`shot-dock.png` 的 1% / 7% 与 `shot-panel.png` 里的「5小时 1% / 7%」一致。

### 8.15 双击刷新动效（第 14 条）— 已修复

**要求**：双击悬浮窗，额度圆环出现旋转光效、环内数字处于动效状态，1 秒后停下来显示最新额度。

**改法**：
- `Draw-Ring` / `Draw-MoneyRing` 在 `$script:AnimActive` 时多画一段 64° 的 `$Theme.Glow` 光弧，
  每帧角度 +24°（33ms/帧，30 帧 ≈ 1 秒）
- 动效期间数字走 `Get-FlickerText`：位数/货币符号/小数位保持不变，数值每 3 帧随机跳一次（老虎机效果），
  结束后自然回落到真实值
- 定时器到 30 帧：先 `Refresh()` 画一帧静止，再 `Refresh-Data` 同步拉最新数据
- **单击与双击的区分**：单击原本直接切换展开/收起，双击会先触发两次单击。
  现在单击动作挂 240ms 防抖——定时器还在跑又来一次点击就判定为双击，播放动效；
  代价是单击展开有 240ms 延迟（可接受）
- 展开态没有圆环，双击直接刷新不播动效

**验证**：`-GeomTest` 第 8 组（动效开启、文本位数稳定且在多帧间变化、1 秒自动停止、`fetched_at` 真的更新）；
`-Shot -Anim` 出静止帧截图 `shot-dock-anim.png`。

**遗留**：刷新走同步 HTTP，1 秒动效结束后主线程会阻塞 0.5–2 秒（取决于网络），
期间窗口不响应。这是 `-SelfTest` 之外所有「立即刷新」的既有行为，没做异步化。

### 8.16 已知但未做（别当成 bug）

| 项 | 原因 |
|---|---|
| 提取器不能真的执行 JS | 没有 JS 引擎；`scale/unit` 已覆盖绝大多数场景 |
| 显示器热插拔（不拖动）不重算 | 只在拖动结束时检测；靠 `-GeomTest` 保证逻辑对，热插拔下一次拖动就恢复 |
| 折叠态最多 3 个账户 | `maxDockItems` 设计如此，纵排也一样 |
| 金额胶囊只在折叠态 | 展开态用大号数字 + 「已欠费」表达 |


## 9. 扩展指南

### 9.1 新增一个 Token Plan 供应商

1. `QuotaCore.ps1:92` `Get-ProviderPresets` 的 `tokenplan` 数组里加一项（`Id`/`Label`/`Short`/`Url`/`Auth`/`Hint`）
2. 在 `Parse-*` 区新增解析器，返回 `@{ Ok; Tiers }`，`Tiers` 用 `New-Tier` 构造
3. `Invoke-Provider` 里 `tokenplan` 分支的 `switch ($Provider.type)` 加一条
4. **先用 curl 确认端点存在**（401/403/200 都算存在，404 是地址错）
5. 跑 `test-templates.ps1` 加一条断言

### 9.2 新增一个模板

1. `Get-TemplateDefs` 加定义
2. `Get-ProviderPresets` 的 `$all` 加一组预设
3. 新解析器 + `Invoke-Provider` 加分支 + `Get-ProviderRequestUrl` 加 URL 拼接规则（如果需要）
4. `ConfigWindow.ps1` 的 `$layoutMap` 加一行，声明这个模板显示哪些字段行
5. 如果字段行不够用，在"动态字段行"区新建一个 `$rowXxx` 面板并注册到 `$rows`
6. 跑 `-LayoutCheck` 确认无重叠无溢出，跑 `-ConfigShot -ConfigTpl xxx` 看截图

### 9.3 改配色 / 尺寸

- 主面板配色：`TokenPanel.ps1:101` 的 `$Theme`
- 配置页配色：`ConfigWindow.ps1:12` 的 `$CW`
- 折叠态单元尺寸：`TokenPanel.ps1` 约 267 行的 `$DOCK_W` / `$DOCK_H`（逻辑像素，**68**）
- 展开态宽度：`TokenPanel.ps1:179` 的 `$PANEL_W`（340）
- 贴边吸附距离：`Update-DockGeometry` 里的 `$snap = S 24`
- 纵排门槛：同函数里的 `$distToBottom -ge 150`（物理像素）
- DPI 缩放取值：`TokenPanel.ps1:587`（**只在启动时取一次，这是 §8.3 的根因**）

**改完必须重跑 `-Shot` 和 `-ConfigShot` 看截图**，不能只看代码。

---

## 10. 禁忌

| 不要 | 原因 |
|---|---|
| 再试 WebView2 / Tauri | 已穷尽验证不可用，见 §7.13 |
| `Form.Scale` 后不缩字体 | 框变大字不变，见 §7.2 |
| 用 `DrawString` 画小字 | 发虚，必须 `TextRenderer`，见 §7.5 |
| 在函数里 `return $array` 让调用方直接 `.Count` | 单元素会被解包，见 §7.1 |
| 用单字母变量名当主题表 | 大小写不敏感会互相覆盖，见 §7.3 |
| 把密钥写进日志/文档/控制台 | 违反用户明确要求 |
| 删除 `.workbuddy-ai` 目录 | 那是项目数据不是缓存 |
| 改 `providers` 结构却不改 `Repair-Config` | 老配置读出来是 `$null`，静默失效 |
| 用 Agent 后台任务验证"能常驻" | 任务结束进程被回收，会误判崩溃 |
| 在配置页加需要管理员权限的操作 | 用户明确不喜欢弹 UAC |

---

## 11. 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 托盘原型 | 10-28 | PowerShell 托盘图标版（`archive/QuotaTray.ps1`），零安装验证数据通路 |
| v3.x | 10-29 上午 | 改桌面悬浮窗；WebView2 失败后改 WinForms 全自绘 |
| v4.0 | 10-29 下午 | DPI 修复（PerMonitorV2 + SetWindowPos）；显示改「使用量」；多账户 |
| v1.0.5 | 10-29 17:00 | 改名 Token Pocket + 版本号；6 模板真正区分；系统配置页（缩放/悬浮大小/开机自启） |
| v1.1.0 | 10-29 17:45 | 修完第一轮 6 条：缩放实时重建、浮窗实时预览、跨 DPI 自适应、提取器代码+变量、余额金额与负数红色、贴边吸附+靠边纵排；新增 `-GeomTest / -TestScale / -ForceOrient` |
| v1.1.1 | 10-29 18:40 | 修完第二轮 6 条：余额改圆环、修 PowerShell 动态作用域导致的「设置页被压扁」、账户余额改名、手动排序+显示数量、深浅双配色、字体授权确认；新增 `-TestRescaleLive / -ForceTheme` |
| **v1.1.2** | 10-29 19:20 | 折叠态圆环改为显示 5 小时额度（不再取两窗口最大值）；双击刷新动效（旋转光弧 + 数字跳动 + 1 秒后拉新数据）；`-TestUI` 不再把 dockScale/uiScale/theme 写进用户配置；新增 `-Shot -Anim` |
| **v1.1.3** | 10-30 11:30 | 折叠态单元 89→**68**、数字字号 14→16、小档隐藏账户名；贴边保持四角圆角（删掉置零逻辑）；纵排加「离任务栏 ≥150 **物理**像素」门槛；新增透明度 100/70/50/30 |
| **v1.1.4** | 10-30 12:20 | 排版精修（方案 B）：笔宽 4→**2**（用量环与余额环统一）、数字 16 Bold→**15 SemiBold**、% 比例 0.62→**0.75**、% 间距 −2→**0**、账户名 9→**8**、**数字垂直居中修正**（0.075×字号）；排版参数全部抽成常量 |
| **v1.1.5** | 10-30 12:40 | 启动不再闪黑窗：新增 `TokenPocket.vbs` 无窗口启动器 + `Token Pocket.lnk` 零闪快捷方式；新增**单实例保护**（Mutex）；自启命令改走 VBS；清理 7 张冗余截图 |
| **v1.1.6** | 10-30 13:55 | 修复**悬浮窗不置顶**（`Form.TopMost` 未落到 `WS_EX_TOPMOST`，改为显式读-改-写样式位 + `SetWindowPos(HWND_TOPMOST)`，并在 Show / Hide→Show / 改透明度后重新断言）；新增 `diag-topmost.ps1` 探针 |

**版本号规则**：以后每次改动递增，只改 `lib/QuotaCore.ps1` 顶部的 `$script:AppVersion` 一行。当前 `1.1.6`。

---

## 12. 接手后的第一步

```powershell
cd "D:\AppData\token消耗面板"

# 1. 确认基线没坏（7 条，全绿才动手）
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -SelfTest
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-templates.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-shape.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -TestUI
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -TestScale
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -TestRescaleLive
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -GeomTest
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -LayoutCheck

# 2. 看当前界面长什么样（深浅两套）
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -Shot
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -Shot -ForceOrient v
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -Shot -ForceTheme light
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -Shot -Anim
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -ConfigShot
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -ConfigShot -ConfigPage system
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -ConfigShot -ConfigPage system -ForceTheme light
powershell -NoProfile -ExecutionPolicy Bypass -File .\TokenPanel.ps1 -ConfigShot -ConfigTpl custom

# 3. 读用户的问题清单
notepad .\待优化问题.txt
```

然后按 §8 的顺序开工（那 6 条已修完，新的需求另起编号）。**每改一步跑一次对应的验证开关，通过再进下一步**——这是用户明确要求的工作方式（"每执行一步要求检验没有问题后再推进"）。

⚠️ 跑任何会 `Show()` 窗口的开关前记住：`-Shot / -ConfigShot` 会读真实配置并可能触发 `Save-Config`。
v1.1.0 已用 `$script:UserMoving` 挡住程序自身位移，但如果你改了吸附逻辑，跑完**务必确认**
`%APPDATA%\TokenPocket\config.json` 里的 `dockRight/dockBottom` 没被写花。

---


---

## 13. 字体与商用授权（用户第 12 条）

### 现在用的三个字体

| 字体 | 用在哪 | 来源 |
|---|---|---|
| `Microsoft YaHei UI` | 所有中文界面文字（浮窗标签、面板、设置页） | Windows 自带（Vista 起） |
| `Segoe UI` | 数字、百分号、金额、托盘图标字母、✕ | Windows 自带 |
| `Consolas` | 设置页「提取器代码」只读框 | Windows 自带（Vista 起） |

### 能不能商用

**能。** 代码里只是**按名字向系统要字体**（`New-Object System.Drawing.Font 'Microsoft YaHei UI', ...`），
项目目录里**没有任何 .ttf/.otf 文件**，安装包也不打包字体。这种情况下字体由 Windows 提供并渲染，
微软的字体授权允许在 Windows 上运行的应用程序使用系统字体，不构成再分发。

**不能做的事**（会踩授权）：
- 把 `msyh.ttc` / `segoeui.ttf` / `consola.ttf` 从系统目录拷出来，放进安装包或仓库
- 把字体嵌入 PDF / 图片素材里对外分发（这属于 font embedding，需要 Monotype/微软的嵌入授权）
- 打包成 macOS / Linux 版本时继续指望这三个字体（那边没有）

### 已知风险

- 字体缺失时 GDI 会**静默回退**到系统默认字体（中文可能变宋体），不会崩，但观感会变
- 以后若要跨平台或做「自带字体」的绿色版，换成 SIL OFL 授权的开源字体：
  中文 `Source Han Sans SC` / `Noto Sans SC`，西文数字 `Inter` / `IBM Plex Sans`，等宽 `JetBrains Mono`

---

## 14. 怎么发布给别的 Windows 用户

### 结论先说

这是**本地 Windows 桌面程序**（PowerShell 5.1 + WinForms），不是网站。
所以不能用「发布为在线链接」那套（那是给静态站点/小游戏用的，对方点了链接也跑不起来桌面程序）。
对外分发只有两条路：**压缩包**（首发推荐）或**安装包**（Inno Setup / NSIS / WinRAR SFX）。

### 当前发布物（v1.1.6）

```
release/
├─ TokenPocket-1.1.6.zip      ← 直接发这个（约 193 KB）
└─ TokenPocket-1.1.6/         ← zip 的源目录，改完重新打包
   ├─ TokenPocket.vbs             ★ 推荐入口，双击启动、零黑窗
   ├─ 创建快捷方式.cmd            ★ 生成 Token Pocket.lnk（一次性）
   ├─ start-token-pocket.cmd      兼容入口，转调 VBS
   ├─ debug-token-pocket.cmd      调试启动器，留窗口显示报错
   ├─ make-shortcut.ps1           由「创建快捷方式.cmd」调用
   ├─ TokenPanel.ps1
   ├─ lib/QuotaCore.ps1
   ├─ lib/ConfigWindow.ps1
   ├─ 使用说明.md
   └─ 截图/（6 张）
```

**不要打包 `.lnk`**：里面存的是开发机的绝对路径，到别人电脑上直接失效。
包里放 `创建快捷方式.cmd`，让对方在自己机器上生成。

### 重新打包（三步）

```powershell
# 1) 同步源码到包目录（保持 md5 一致，别手改包里的副本）
cd "D:\AppData\token消耗面板"
$R = "release\TokenPocket-1.1.6"
Copy-Item TokenPanel.ps1 $R -Force
Copy-Item lib\QuotaCore.ps1,lib\ConfigWindow.ps1 "$R\lib" -Force
Copy-Item TokenPocket.vbs,start-token-pocket.cmd,debug-token-pocket.cmd,make-shortcut.ps1 $R -Force
Copy-Item shot-dock.png,shot-dock-v.png,shot-dock-light.png,shot-panel.png,shot-config.png,shot-cfg-system.png "$R\截图" -Force

# 2) 打包（用系统自带 cmdlet，不依赖 WinRAR）
Compress-Archive -Path $R -DestinationPath "release\TokenPocket-1.1.6.zip" -Force

# 3) 冒烟测试（必做，见下）
powershell -NoProfile -ExecutionPolicy Bypass -File .\smoke-release.ps1
```

**`smoke-release.ps1` 会做 19 项检查**：解压到全新临时目录 → 校验文件清单 →
确认不含 `config.json` → 从新目录启动 → 验证进程/窗口/置顶（`WS_EX_TOPMOST`）→
校验日志版本号 → 生成 `.lnk` 并确认指向新目录 → 清理。

为什么要从**全新目录**启动：能一并验证 `.vbs` 的路径解析是相对的、不依赖开发机路径。

**打包前必做**（踩过的坑）：
1. **永远不要把 `%APPDATA%\TokenPocket\config.json` 放进包**。里面是 DPAPI 加密的 API Key，
   DPAPI 绑的是「当前 Windows 用户 + 机器」，别人解不开，只会得到一个打不开的配置。
   打包后一定要 `python -c "import zipfile;..."` 之类的手段核一遍清单。
2. 排除 `*.log`、`test-*.ps1`、`HANDOFF.md`、`archive\`、`*.testbak`。
3. `debug-token-panel.cmd` 是旧名（指向 32 位 PowerShell、日志路径还是 `TokenPanel`），
   别发出去；对外的是 `debug-token-pocket.cmd`。

### 发布前检查清单（v1.1.2 已逐条验过）

| 检查项 | 怎么验 | 结果 |
|---|---|---|
| 真·首装（从没跑过） | 把 `$env:APPDATA` 指到临时目录再启动 | ✅ 自动建 `TokenPocket\{config.json,app.log}`，1 个示例账户，界面显示「未配置 API Key」 |
| 配置损坏/丢失 | `Load-Config` 有 try/catch 回落默认值 | ✅ |
| 不需要额外运行时 | 只用 PowerShell 5.1 + WinForms，Win10/11 自带 | ✅ 不用装 .NET / Python |
| 执行策略 | 启动器带 `-ExecutionPolicy Bypass` | ✅ 不需要用户改策略 |
| 不需要管理员权限 | 自启写 `HKCU\...\Run`，配置写 `%APPDATA%` | ✅ |
| 多 DPI / 多显示器 | `-GeomTest` + 拖动重算 | ✅ 100/125/150% 都试过 |
| 字体 | 只用 Windows 自带三款，不打包字体文件 | ✅ 见 §13 |
| 你的配置没被污染 | `-TestUI` 保存前会把缩放/浮窗/配色点回原值 | ✅ 24/24 |
| 发布包能独立运行 | `smoke-release.ps1` 解压到全新目录再启动 | ✅ 19/19 |
| 启动无黑窗 | 枚举窗口判 `ConsoleWindowClass` 可见性 | ✅ `visibleConsole=0` |
| 悬浮窗置顶 | 读 `GWL_EXSTYLE` 判 `WS_EX_TOPMOST` | ✅ `0x00090008` |

### 三条分发路线

| 方式 | 做法 | 适合 | 注意 |
|---|---|---|---|
| **ZIP（现在这个）** | 微信/邮件/网盘发 `TokenPocket-1.1.6.zip` | 首发、小范围 | 没有开始菜单项，用户自己跑一次「创建快捷方式.cmd」 |
| **WinRAR SFX 单文件 exe** | `WinRAR a -sfx -z<脚本注释>` ，注释里写 `Setup=` / `Shortcut=` | 想「一个文件搞定」 | 未签名 → SmartScreen 会弹「Windows 已保护你的电脑」，用户要点「更多信息→仍要运行」 |
| **Inno Setup 安装包** | 写 `.iss`，装 `Inno Setup 6`（免费）后编译 | 正式对外、要卸载入口 | 本机没装 Inno Setup；同样有 SmartScreen 问题 |

**代码签名**：买 OV 证书（约几百元/年）后 SmartScreen 警告才会消失。
没签名之前，ZIP 是体验最好的——解压出来的 `.cmd` / `.ps1` 不会触发 SmartScreen。
杀毒软件对 PowerShell 脚本偶有误报，让人把文件夹加白名单就行。

### 还没做的（下一步候选）

- 自动更新：启动时请求一个版本文件对比 `$script:AppVersion`，提示后打开下载页
- 安装包 + 卸载入口（需要装 Inno Setup）
- 首次运行向导：现在第一次启动只有一个空 Key 的示例账户，靠 `使用说明.md` 引导

---

## 15. WorkBuddy 积分查询集成（2026-10-29 预研完成，待接入）

> 状态：**方案已验证，能查到真实数据，尚未接入面板**。
> Demo 全部代码在 `D:\WorkBuddy AI\2026-10-29-17-14-03\workbuddy-credits-demo\`，
> 详细文档见该目录 `README.md`（接口字段、踩坑清单都在里面）。

### 15.1 已验证的关键结论

| 结论 | 说明 |
|---|---|
| 积分接口 | `POST https://www.workbuddy.cn/billing/meter/get-user-resource-summary`，`data.TotalCredits` 是剩余总积分；签到状态走 `/billing/meter/checkin-status` |
| **cookie 拿出来没用** | 同一组 cookie（8 项 6611 字符），Chrome 页面内 fetch 返回 200，curl / Python 全部 401。网关按 TLS/HTTP2 指纹区分客户端。`wb_credits.py` 的 cookie 直连方案已废弃 |
| Node fetch 不可信 | WorkBuddy 注入 `NODE_OPTIONS` shim + 系统代理 127.0.0.1:14482，返回假 200（响应里没有 data）。验证请求一律用 curl `--noproxy '*'` 或页面内 fetch |
| 唯一可行方案 | **无头 Chrome 在页面上下文发请求**（`wb_query.js`，已实现，3~5 秒出结果） |
| TCP 调试端口不可用 | 本机安全策略丢弃对 127.0.0.1:9333 的连接（SYN 超时，netstat 显示 LISTENING 也没用）。必须 `--remote-debugging-pipe` 走 stdio |
| cookie 必须按 path 过滤 | `getAllCookies` 会混入 Keycloak 的 path 限定 cookie，一起塞进请求头必 401（demo 已处理） |

用户当前数据（2026-10-29）：`TotalCredits = 1870.91`，体验版，平台奖励积分 1870.91/3178，签到活动未开启。

### 15.2 内存实测（连续 5 次查询 + 每秒采样）

| 模式 | 峰值 | 进程数 | 持续 |
|---|---|---|---|
| 加载官网首页 | ~515 MB | 8 | 4~6 秒 |
| robots.txt 轻量页（**当前默认**） | ~382 MB | 7 | 4~6 秒 |

短命进程设计：查完 `taskkill /T /F` 整棵树，内存归零，连续 5 次验证无残留。382MB 是 Chromium 多进程架构的地板价，再压空间有限。

### 15.3 接入方案（待办）

面板新增"外部命令"型数据源，调 `node wb_query.js --json`，解析 `TotalCredits`。按顺序做：

1. `QuotaCore.ps1` 新增模板 `workbuddy`：不走 `Invoke-Http`，改用 `Start-Process node -ArgumentList 'wb_query.js','--json'` 拿 stdout JSON。node 路径兜底 `C:\Users\barren.wu\.workbuddy\binaries\node\versions\22.22.2-6\node.exe`，先 `where node` 探测。
2. 子进程超时 30 秒强杀：`taskkill /PID <pid> /T /F`。
3. **孤儿兜底（必做，唯一真实的内存风险）**：每次查询前按 profile 路径（`workbuddy-credits-demo\.browser-profile`）清理残留 chrome.exe；加文件锁防并发刷新。面板强杀子进程时 Chrome 树不会被连带清理，会残留 ~380MB。
4. **401 处理**：输出里 status 非 200 = 登录态过期，该账户显示"需重新登录（双击 获取Cookie.cmd）"，不要显示旧数据。
5. 显示字段：主数值 `data.TotalCredits`（字符串，注意 `TryParse`），副显示 `SubscriptionPackageName`。余额类账户走 `kind='money'` 的文本块绘制（参考 §8.5），不画圆环。
6. **刷新间隔 ≥30 分钟**：每次刷新起一个 Chrome（380MB / 5 秒 CPU 尖峰），5 分钟一次用户能感知。查询放后台线程，别卡面板绘制。

### 15.4 用户侧入口（已可用）

- `获取Cookie.cmd`：登录一次，登录态存 `.browser-profile`，长期有效
- `查询积分.cmd`：手动查询，双击即用

**安全**：`.browser-profile`（内含登录态）等同账号权限，不进 git、不外传、不写日志。

---

## 16. Git 工作流（2026-10-30 建立）

### 16.1 仓库现状

| 项 | 值 |
|---|---|
| 位置 | `D:\AppData\token消耗面板\.git` |
| 分支 | `main` |
| 首个提交 | `33d94b7` — 49 文件 / 13900 行 |
| 标签 | `v1.1.2`（指向 v1.1.2 发布状态） |
| 身份 | **仓库级**：`barren.wu` / `barren.wu@local`（未改全局配置） |
| 换行 | `core.autocrlf=false`，文件按原字节提交，避免 CRLF 改写 |
| 文件名 | `core.quotepath=false`，中文名正常显示 |

### 16.2 每次改动的流程

```
1. 改代码
2. 跑验证（见 §2.2 / §6.3），必须全绿
3. 改 lib\QuotaCore.ps1 顶部的 $script:AppVersion（递增）
4. 同步更新 HANDOFF.md 的 §11 版本历史
5. git add -A
6. git commit -m "type: 一句话说明"
7. git tag -a vX.Y.Z -m "该版本要点"
```

**tag 必须打**——这个项目的交付形态是"给用户一个 zip"，tag 是唯一能找回"当时发的是哪一版"的方式。

### 16.3 提交信息约定

前缀用 Conventional Commits，中文描述：

| 前缀 | 用途 |
|---|---|
| `feat:` | 新功能 |
| `fix:` | 修 bug（**写清根因**，例如 `fix: 缩放点击无反馈——uiScale 只在构建时读取`） |
| `docs:` | 只改文档 |
| `chore:` | 打包、清理、仓库维护 |
| `test:` | 测试脚本 |
| `refactor:` | 重构不改行为 |

这个项目的 bug 大多有"隐蔽根因"，**提交信息里写根因比写现象有用**，下次改到同一块能直接搜到。

### 16.4 绝对不能提交的东西

`.gitignore` 已覆盖，但仍要心里有数：

| 路径 | 原因 |
|---|---|
| `config.json` | 含 DPAPI 密文（虽绑当前用户，仍不该入库） |
| `.browser-profile/` | **内含 Cookie，等同账号权限，泄露 = 账号被接管**（§15） |
| `*Cookie*.txt` / `cookie*.json` | 同上 |
| 任何 `sk-` / `sk-cp-` 明文 | 违反用户明确要求 |

**提交前自检**（30 秒）：

```bash
git diff --cached | grep -nE "sk-[A-Za-z0-9_-]{20,}|Bearer [A-Za-z0-9]{25,}|[A-Za-z0-9+/]{200,}={0,2}"
```

无输出 = 干净。有输出 = 停下来查。

### 16.5 常用命令

```bash
git log --oneline                    # 看历史
git tag -n1                          # 看所有版本标签
git show v1.1.2 --stat               # 看某版本改了哪些文件
git diff v1.1.2 -- lib/QuotaCore.ps1 # 和某版本比差异
git status                           # 当前状态
```

### 16.6 release 目录的取舍

`release/` 里的 zip 与解压目录**故意纳入版本管理**：

- 好处：每个 tag 都能取到当时可直接发给用户的完整产物，不用重新打包
- 代价：目录里的 3 个 .ps1 是源码副本，会与 `lib/` 漂移

**规则**：`release/` 只在发版时更新，**永远不要直接改 release 里的 .ps1**。改源码 → 重新打包 → 再提交。发现两者不一致时，以根目录源码为准。

---

## 17. 折叠态尺寸与外观（v1.1.3）

### 17.1 68×68 单元的内部配平（不能等比缩）

89 → 68 不是乘以 0.76 就完事：89 时代的 `上边距 12 / 圆环 52 / 间距 4 / 标签 12` 加起来 80，塞不进 68。必须重新配平：

```
上边距 7 + 圆环 40 + 环下间距 3 + 标签 11 + 下边距 7 = 68
```

常量集中在 `TokenPanel.ps1` 约 267 行：`$DOCK_W/$DOCK_H = 68`、`$RING_R = 20`、`$DOCK_PAD_TOP = 7`、`$DOCK_RING_GAP = 3`、`$DOCK_LBL_H = 11`、`$DOCK_LBL_MIN_SCALE = 0.9`。

**字号**：`Draw-Ring` 里数字 14 → **16**（+14%），三位数（100）11 → 12。
选 +14% 不是 +20%：40px 圆环的内径只有 32，再大就顶壁。`-SelfTest` 新增了量化断言，实测填充率：

| 档位 | 「58%」宽 | 内径 | 填充率 |
|---|---|---|---|
| 小 51 | 18.8 | 24 | 78% |
| 默认 68 | 25.0 | 32 | 78% |
| 大 85 | 31.3 | 40 | 78% |

78% 是刻意选的：低于 70% 显得飘，高于 85% 显得挤。

### 17.2 小档隐藏账户名（用户选方案 B）

`$DOCK_LBL_MIN_SCALE = 0.9` —— `DockScale < 0.9` 时不画标签。原因：51px 单元里标签只有约 6px 高，笔画糊成一团，不如不画。

不画标签时圆环要**垂直居中**（`$cy = $oy + $unitH / 2`），否则会偏上留一大块空白。

### 17.3 贴边保持四角圆角

根因不是渲染，是 `Update-WindowRegion` 里**主动**把贴边那侧置 0：

```powershell
# 已删除的旧代码
if ($script:SnapEdgeV -eq 'bottom') { $rbr = 0; $rbl = 0 }
if ($script:SnapEdgeH -eq 'right')  { $rtr = 0; $rbr = 0 }
```

删掉后四角始终是 `DS 18`（折叠态）/ `S 18`（展开态）。贴边时角落会露出 1~2px 桌面，这是圆角的必然结果，用户要的就是这个效果。

**验证方法（比看图可靠）**：`Region.IsVisible(Point)` —— 圆角时角落像素不在 Region 内，直角时在。`-GeomTest` 里的 `GT-Corners` 就是取四角内侧 2px 的点，断言 4 个都不在区域内。

### 17.4 纵排的 150 物理像素门槛

旧逻辑「贴左右边就纵排」会让右下角（最常见位置）竖起来挡视线。新逻辑：

```powershell
$distToBottom = $wa.Bottom - ($ny + $ch)
$orient = 'h'
if ($eH -ne 'none' -and $distToBottom -ge 150) { $orient = 'v' }
```

**150 是物理像素，不做 `S()` 换算**（用户明确指定）。150% 屏上视觉约 100 逻辑像素。

贴住底部时距离为 0 → 自然横排。`-GeomTest` 断言边界：离底 149 → 横排、151 → 纵排。

### 17.5 透明度四档（100 / 70 / 50 / 30）

`Form.Opacity` 实现，只作用于主悬浮窗（设置窗口始终不透明，否则调 30% 时自己都看不清）。

- 配置字段 `config.opacity`，`Repair-Config` 会把非档位值向最近档位吸附（防手改写坏）
- `Preview-Opacity -V <double>` 定义在 `$script:MainForm = $form` 之后，因为它要引用 MainForm
- 点 chip 立即生效；取消由 `Restore-DockPreview` 回滚；保存后重启由启动段恢复

**UI 排版**：配色与透明度并排一行（配色 18~126，透明度 200~430），两句说明合成一行避免卡片撑高。
连带调整：卡片 S3 高 152→180、S4 452→480、S5 644→672、`$SYS_H` 826→854。

### 17.6 本轮新踩的坑

1. **`PerformClick()` 要求控件可见** —— 它内部判断 `CanSelect`（可见 + 可用 + 父级可见）。在「账户页」点「系统页」的 chip 完全不触发，测试会误报成功能 bug。`-TestUI` 里点系统页控件前必须先 `Show-Page -Page 'system'`。
2. **`TextBox.Text` 赋值不受可见性影响** —— 所以同一段测试里 timeout 断言能过、opacity 断言挂了，很容易误判。
3. **`Repair-Config` 补的字段只在内存里** —— 老配置磁盘上没有 `opacity` 键，第一次保存后才写进去。写脚本改配置时必须先判断属性是否存在再赋值，否则 `$c.opacity = 0.5` 会抛 `property cannot be found`。
4. **金额字号与圆环尺寸耦合** —— `Get-MoneyFontPx` 返回 14/11/9，是按 52px 圆环调的。68 时代圆环只有 40，`¥-0.49`（6 字符）走 11px 仍能放下，但再加长就会贴边，靠 `EndEllipsis` 兜底。改圆环半径时要一并复核这个函数。

### 17.7 本轮验证基线

```
-SelfTest       文字溢出 9/9  +  颜色逻辑 10/10
-GeomTest       31/31（含贴边四角圆角、149/151 边界）
-TestUI         24/24（含透明度落盘、取消回滚）
test-templates  55/55
test-shape      6/6
-TestAutostart  读写双向一致
```

三档实测物理尺寸（150% DPI，3 账户横排）：

| 档位 | 系数 | 窗口物理 | 逻辑 |
|---|---|---|---|
| 小 | 0.75 | 230×76 | 153×51 |
| 默认 | 1.0 | 306×102 | 204×68 |
| 大 | 1.25 | 382×128 | 255×85 |

---

## 18. 折叠态排版精修（v1.1.4，方案 B）

用户反馈「65% 文字太粗太大」，前后对了四轮图才定稿。最终参数：

| 常量 | 值 | 说明 |
|---|---|---|
| `$DOCK_PEN` | 2.0 | 圆环笔宽，**用量环与余额环共用**（用户要求统一） |
| `$NUM_SIZE` | 15 | 中心数字字号，字族 `Segoe UI Semibold` + Regular 样式 |
| `$NUM_SIZE_3` | 11 | 三位数（100%）字号 |
| `$PCT_RATIO` | 0.75 | 百分号 = 数字 × 0.75（旧值 0.62 太小，扫一眼容易漏） |
| `$PCT_DROP` | 2 | 百分号下沉量 |
| `$PCT_GAP` | 0.0 | 数字与百分号间距（旧值 −2 会挤压） |
| `$DOCK_LBL_SIZE` | 8 | 账户名字号（旧值 9 抢视觉重心） |
| `$CENTER_FIX` | 0.075 | 垂直居中修正系数 |

实测填充率：`58%` → 73%、`100%` → 65%（旧参数是 78%，偏挤）。

### 18.1 数字确实偏下，根因和修法

用户凭感觉说「数字好像有点偏下」，量了才发现是真的：**偏下 1~2 物理像素**。

**根因**：`TextRenderer.DrawText` 的 `VerticalCenter` 对齐的是「行框」，而数字没有下伸部（descender），行框下半截的空白把墨迹顶低了。

**标定方法**（`measure-center.ps1`）：用**亮度加权质心**而不是边界框。边界框只有整数精度（误差 ±0.5px），质心是亚像素精度，能算出准确系数。实测四档平均 0.075，修正后残留全部 ≤0.32px：

```
小      -1px →  0.20px   默认   -2px →  0.16px
大      -2px → -0.32px   3位数  -1px →  0.20px
```

注意：`CENTER_FIX` 必须乘**物理字号**（`$fs` 已经是 DS 换算后的值），不是逻辑字号。

### 18.2 笔宽被物理像素取整吃掉

**踩坑**：第一版给了「笔宽 2.5」和「3.0」两个方案，渲染出来**完全一样**。原因是默认档（150% DPI）下：

```
round(2.5 × 1.5) = round(3.75) = 4
round(3.0 × 1.5) = round(4.5)  = 4   ← 银行家舍入，也落到 4
```

所以默认档实际可用笔宽只有 p3 / p4 / p5 / p6 四档。**给用户出方案前必须先算实际渲染值，不能只看逻辑参数**，否则会给出两个「看起来不同、实际一样」的选项。

### 18.3 「100 %」中间的空隙（已知，未修）

三位数的 `%` 与数字之间比两位数松约 2~3px（大档最明显）。原因不是测量引擎选错（实测 GDI+ 误差 0.5~2.2px，GDI 反而 10~19px，现在用 GDI+ 是对的），而是**末位字形是「0」时右侧留白天生更大**。换引擎、调间距都只能治一个尺寸、坏另一个。

只有额度耗尽时才出现，影响面小，保留现状。真要修，得按末位字符查表补偿，收益不抵复杂度。

### 18.4 这轮又踩的坑

1. **`$PEN` 与 `$pen`、`$Cy` 与 `$cy` 是同一个变量** —— PowerShell 变量名不区分大小写。画笔对象覆盖了笔宽数值（报 `op_Multiply`），青色常量被圆心坐标覆盖（`FromHtml` 收到 62.5 报错）。这是 §7.3 记过的坑，**同一会话踩了两次**。写绘图脚本时颜色/笔宽变量一律加前缀（`$ClrXxx` / `$PenW`）。
2. **测试断言的基准取错** —— `-TestUI` 里「取消回滚」断言拿 `MainForm.Opacity` 当前值当基准，但前面刚点过 100%，基准变成 1.0，而回滚正确回到了打开时的 0.5 → 误报失败。**回滚类断言必须以「打开时的快照」为基准**（`$script:OpacityOrig`），不能读运行时当前值。
3. **测试把用户配置写脏了** —— 上述误报那次运行把 `opacity=0.5` 落盘并留在了配置里。虽然 `-TestUI` 有备份/还原，但备份本身若已被污染就救不回来。**跑完测试要独立复核配置是否回到原值**，不能只信「配置已还原」这句输出。

### 18.5 本轮验证基线

```
-SelfTest       填充率 9/9（58%→73%、100%→65%）+ 颜色 10/10
-GeomTest       31/31
-TestUI         24/24（含透明度落盘、取消回滚）
test-templates  55/55 ｜ test-shape 6/6 ｜ -TestAutostart 通过
measure-center  四档残留 ≤0.32px 全部居中
```

三档实测（150% DPI，3 账户横排）：小 230×76 / 默认 306×102 / 大 382×128 物理像素。

---

## 19. 启动不闪黑窗（v1.1.5）

### 19.1 根因

旧启动方式：`start "Token Pocket" powershell.exe ... -WindowStyle Hidden`

`start` 会先给 powershell **创建一个可见的控制台窗口**，PowerShell 启动之后才执行
`-WindowStyle Hidden` 把它藏起来。中间那一下就是用户看到的黑窗闪。

而且如果双击两次、或自启实例已在跑，闪的次数会翻倍——用户反馈的「闪好几个」就是这么来的。

### 19.2 解法

**`TokenPocket.vbs`**：`WScript.Shell.Run cmdLine, 0, False`
第二个参数 0 = 窗口模式隐藏，**从创建起就隐藏**，不存在「先显示再隐藏」的阶段。

**`Token Pocket.lnk`**：指向 `wscript` + `//nologo <vbs>`。
wscript 是 GUI 子系统程序，双击不创建控制台 → 全程零窗口。

**`start-token-pocket.cmd`**：改为转调 VBS。cmd 自己的控制台仍会闪一下（约 50ms），
所以推荐入口换成了 `.lnk`。

**自启命令**同步改为 `wscript` + vbs 路径（`Get-AutostartCommand`），开机启动也不再闪。

### 19.3 验证方法（不靠肉眼）

`verify-launch.ps1`：启动后枚举该进程所有顶层窗口，统计
`class = ConsoleWindowClass 且 IsWindowVisible = true` 的个数，期望 0。

实测结果：

```
=== 通过 Token Pocket.lnk 启动 ===
  total=9 visibleConsole=0   → 控制台窗口存在但不可见
=== 通过 start-token-pocket.cmd 启动 ===
  total=9 visibleConsole=0
```

注意 `ConsoleWindowClass visible=False` 这一行：控制台**确实被创建了**，但从未可见。
这正是「不闪」的准确含义——不是没有控制台，而是它从不显示。

### 19.4 单实例保护

`TokenPanel.ps1` 启动时抢 `Mutex 'TokenPocket_SingleInstance'`（`[System.Threading.Mutex]::new`），
抢不到就写日志退出。所有 `-Xxx` 验证开关通过 `$script:IsTestMode` 跳过此检查，
否则测试会被正在运行的实例挡住。

实测：第二个实例 **259ms** 退出（正常启动要 2~3 秒建窗体），日志记
「已有实例在运行，本次启动直接退出（单实例保护）」。

### 19.5 排查中发现的两个问题

1. **一个残留实例把用户配置覆盖了** —— 排查时发现有个开机自启的旧实例（用改前的命令启动）
   一直在跑，它内存里的 `opacity=0.5` 在 12:25 保存时把文件覆盖回了 0.5，
   导致 12:22 手动还原的 1.0 白做。
   **教训：改配置前先确认没有实例在跑，否则会被 stale 内存覆盖。** 这类问题极难从日志看出来。
2. **`shot-config.png` 曾被覆盖成系统页截图** —— 两张图字节数完全相同才发现。
   重新生成后两者尺寸不同（账户页 1290 高、系统页 1281 高）。
   **教训：截图生成后要核对尺寸差异，别只看文件名。**

### 19.6 移动文件夹后

`.lnk` 里是绝对路径，移动后失效；跑 `make-shortcut.ps1` 重新生成。
`.vbs` 按自身所在目录解析路径，是便携的（可以直接双击 `.vbs`）。

---

## 20. 已知限制：圆角边缘是硬边阶梯（已评估，不修）

用户反馈悬浮窗圆角有锯齿。**已查清原因，结论是当前架构下无法消除，除非重构渲染。**

### 20.1 根因（已用数据证实）

窗口形状靠 `$form.Region = New-Object System.Drawing.Region $path` 裁剪。
**Windows 对窗口区域只做 1 位覆盖判定，从不抗锯齿**——这是 Win32 的固有限制，
不是路径画得不够圆、也不是参数没调对。

量化证据（`diag-corner.ps1` 抓四角放大 12 倍 + 与理想圆弧逐行比对）：

| 路径构造方式 | 与理想圆弧最大偏差 | 平均偏差 |
|---|---|---|
| 原路径 `AddArc`（Bezier 近似） | 1.08 px | 0.66 px |
| 显式 `Flatten(0.05)` 精细展平 | 1.00 px | 0.59 px |

展平前后几乎无变化 → **1px 就是 1 位覆盖光栅化的理论极限**，
再优化路径精度没有意义。调半径、加描边、换填充模式同样无效。

### 20.2 唯一真正的解法（评估后未采用）

换成**分层窗口 + 逐像素 alpha**：给窗口加 `WS_EX_LAYERED`，
用 `UpdateLayeredWindow` 推一张 32bpp 位图，圆角由 alpha 通道决定，可真正平滑。
代价是要重写渲染主干：绘制入口、`Form.Opacity`（与 ULW 互斥，需改为乘 alpha）、
`-Shot` 截图（`DrawToBitmap` 在分层窗口上失效）、相关测试断言都要改。

**为什么没做**：本机验证时 `UpdateLayeredWindow` 返回 OK，但分层窗口不参与合成，
抓不到任何像素。由于开发环境就是用户的生产环境，若分层窗口在其桌面同样不显示，
改完之后用户会得到一个**完全看不见、连右键菜单都点不到的悬浮窗**——
无法自行恢复。这个失败模式不可接受，故未采用。

**如果将来要做**：必须有人在旁边实时确认「窗口还在不在、圆角顺不顺」，
不能靠自动截图验证。同时应准备一个命令行开关或外部脚本，
在窗口不可见时能强制回退到 Region 方案。

### 20.3 可缓解的方向（未实施，供参考）

- **缩小圆角半径**：阶梯长度随半径减小而缩短，视觉上明显改善，零风险
- **改直角**：彻底无锯齿，但失去圆角观感
- **提高不透明度**：硬边与桌面的对比降低，锯齿感变弱（用户当前用 70%）

### 20.4 不要重复调查

已经排除了：路径精度、`AddArc` vs 精细展平、`Flatten` 容差、半径大小、描边覆盖。
**除非决定上分层窗口，否则这块没有可挖的东西了。**

---

## 21. 悬浮窗不置顶（v1.1.6 已修）

用户反馈：点一下别的窗口，悬浮窗就被盖住了。

### 21.1 根因（实测数据）

代码里明明写了 `$form.TopMost = $true`，但读窗口的扩展样式发现**根本没生效**：

| | 修复前 | 修复后 |
|---|---|---|
| `EXSTYLE` | `0x00090000` | `0x00090008` |
| `WS_EX_TOPMOST` | **否** | 是 |
| z 序位置 | #7（在 Chrome 之下） | **#3（置顶带内）** |
| 记事本抢焦点后 | 被覆盖 | 仍在 #3 置顶 |

`0x00090000` = `WS_EX_LAYERED(0x80000)` | `WS_EX_CONTROLPARENT(0x10000)`——
LAYERED 是透明度加的，而 `WS_EX_TOPMOST(0x8)` 位压根没置上。
所以 `TopMost` 属性在这套窗体配置下（无边框 + `ShowInTaskbar=false` + 设过 `Opacity`）
没有真正落到窗口样式上。

**教训**：WinForms 的 `TopMost` 属性不等于 `WS_EX_TOPMOST` 位。
涉及窗口层级/样式的行为，**要读 `GetWindowLong(GWL_EXSTYLE)` 验证，不要相信属性名**。

### 21.2 修法

`Assert-TopMost`（`TokenPanel.ps1` 内，紧邻 `Preview-Opacity`）做两件事：

1. 读-改-写 `GWL_EXSTYLE`，确保 `WS_EX_TOPMOST` 位被置上（保留其他位，不要直接赋值覆盖）
2. `SetWindowPos(HWND_TOPMOST=-1, ..., SWP_NOSIZE|SWP_NOMOVE|SWP_NOACTIVATE)` 真正抬进 topmost 带

**只做第 1 步不够**：光置样式位不会立刻重排 z 序，窗口还是压在别的窗口下面。

调用时机（这几个点都可能把置顶位弄丢）：
- `$form.Show()` 之后（句柄此时才真正建好）
- `Show-Panel` 里 `Hide()`→`Show()` 之后（关闭按钮走的是 `Hide`）
- `Preview-Opacity` 改完 `Opacity` 之后（走分层窗口路径，可能顺手清掉样式位）

### 21.3 验证工具

`diag-topmost.ps1`：启动程序 → 读 `GWL_EXSTYLE` 判 `TOPMOST` 位 →
枚举 z 序确认是否在置顶带内 → 再拉一个记事本抢焦点，看是否被覆盖。

**注意**：脚本必须自己做 DPI 感知（`SetThreadDpiAwarenessContext(-4)`），
否则 `GetWindowRect` 与 `CopyFromScreen` 坐标错位（这个坑在 §19/§20 也踩过两次）。

### 21.4 后续如果又出现被覆盖

按顺序查：
1. `diag-topmost.ps1` 看 `TOPMOST` 位是否还在
2. 如果位在但视觉上仍被覆盖 → 对方窗口可能也是 topmost，或全屏独占（如游戏、投屏）
3. 如果位丢了 → 找新加的 `Show()` / `Hide()` / `Opacity` / `SetWindowLong` 调用，
   在它之后补一次 `Assert-TopMost`
