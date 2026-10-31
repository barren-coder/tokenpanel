# HANDOFF — Windows 脚本编码修复（v1.3.0 装完起不来 / 800A0409）

> 接手人先看这一节，再往下看细节。
> 日期：2026-10-31 ｜ 涉及版本：v1.3.0（tag `v1.3.0` / commit `c9656f2`）

## TL;DR

v1.3.0 的发布包在中文 Windows（ANSI 代码页 936）上**装完打不开**，是两个独立的编码问题：

1. `TokenPanel.vbs` 是 UTF-8 无 BOM → wscript 按 GBK 解码，吞掉 3 个引号 → 编译期报 **`未结束的字符串常量`（800A0409）**，脚本一行都没跑。
2. 4 个 `.ps1` 是 UTF-8 无 BOM → PowerShell 5.1 按 GBK 解码 → **68 处语法错误**，即使绕过 VBS 也起不来。

本分支已修：`.vbs` / `.cmd` 改成**纯 ASCII**，并新增 `tools/fix-encoding.ps1` 一键给所有 `.ps1` 补 BOM。

**你需要做的 3 件事**（详见第 5 节）：跑一次 `tools/fix-encoding.ps1` 并提交 → 重打 `release/` 包 → 发 v1.3.1。

---

## 1. 现象

用户在中文 Windows 11 上双击 `TokenPanel.lnk`，弹出 Windows Script Host 对话框：

```
脚本错误：未结束的字符串常量
代码：800A0409
源：Microsoft VBScript 编译器错误
```

点「是/否」都起不来，`%APPDATA%\TokenPanel\app.log` 没有任何新记录 —— 说明卡在 VBScript 编译阶段，PowerShell 根本没被拉起。

## 2. 根因

Windows 上这三类脚本的「默认编码」各不相同，而仓库里全部存成了 UTF-8 无 BOM：

| 文件 | 读取方 | 无 BOM 时的解码方式 | 后果 |
|---|---|---|---|
| `*.vbs` | wscript.exe | ANSI（本机 CP936） | UTF-8 三字节汉字的第 3 字节被当成 GBK 前导字节，把紧跟的 `"` 吞进双字节字符 → 字符串未闭合 → **编译期直接失败** |
| `*.ps1` | powershell.exe 5.1 | ANSI（本机 CP936） | 中文全变乱码，`#` 注释和字符串边界错乱 → 解析出大量语法错误 |
| `*.cmd` | cmd.exe | OEM/ANSI | 只影响 `echo` 显示，会乱码但**不会**中断执行 |

`TokenPanel.vbs` 里被吞掉的引号共 3 处，全在「找不到文件」的 `MsgBox` 分支（原文件第 22–24 行）：

```vbs
MsgBox "找不到 TokenPanel.ps1。" & vbCrLf & vbCrLf & _      ' 结尾引号被吞
       "请确认 TokenPanel.vbs 与程序文件在同一个文件夹里。" & vbCrLf & _   ' 同上
       "当前目录：" & baseDir, 16, "TokenPanel"                ' 同上
```

`.ps1` 侧的量化证据：把 `TokenPanel.ps1` 按 CP936 解码后再交给 PowerShell 解析器，报 **68 个语法错误**；按 UTF-8 解码解析则 **0 错误** —— 内容本身没问题，纯粹是解码方式错了。

> 注意：这个问题**只**在 ANSI 代码页不是 65001 的机器上暴露。开发机如果开了「Beta: 使用 Unicode UTF-8 提供全球语言支持」，本地怎么测都是好的，所以很容易漏掉。

## 3. 本机已完成的验证（可作为验收基准）

在中文 Win11（ACP=936，PowerShell 5.1.18362，未装 pwsh 7）上：

| 步骤 | 结果 |
|---|---|
| 原始发布包直接双击 | 800A0409，无日志 |
| 4 个 `.ps1` 补 UTF-8 BOM 后 | 解析 0 错误 |
| `.vbs` 转 UTF-16LE+BOM（或纯 ASCII）后 | VBS 编译通过，PowerShell 被正常拉起 |
| 启动后 `app.log` | `单实例锁已获取` → `启动 v1.3.0 内测版，账户数 3` → `初始窗口 119x40 @ 1801,1000 方向 h 吸附 right/bottom` → `置顶断言后 EXSTYLE=0x00010008` |
| 浮窗表现 | 置顶正常（`WS_EX_TOPMOST` 已置位），3 个账户数据正常 |

## 4. 本分支改了什么

分支：`fix/encoding-bom-ascii`

| 文件 | 改动 | 说明 |
|---|---|---|
| `TokenPanel.vbs` | 重写为**纯 ASCII** | 注释与报错文案改英文；逻辑与原文件完全一致（同样的 `sh.Run cmdLine, 0, False`）。文件头写明「必须保持 ASCII」的原因，防止有人再存回 UTF-8 |
| `start-token-panel.cmd` | 纯 ASCII | 注释 / `echo` 文案改英文，消除 CP936 下的乱码 |
| `debug-token-panel.cmd` | 纯 ASCII | 同上 |
| `创建快捷方式.cmd` | 纯 ASCII | 同上（文件名保留中文，不影响） |
| `tools/fix-encoding.ps1` | **新增** | 幂等工具：给所有 `.ps1` 补 UTF-8 BOM；并检查 `.vbs`/`.cmd` 是否残留非 ASCII 且非 UTF-16。已在副本上验证：26 个文件补齐，第二次运行 0 改动 |
| `HANDOFF-encoding-fix.md` | 新增 | 本文件 |

**没有**在本分支里直接改 4 个 `.ps1` 的字节（`TokenPanel.ps1` 91KB、`ConfigWindow.ps1` 80KB、`QuotaCore.ps1` 71KB、`make-shortcut.ps1` 1KB，合计约 244KB），因为本次提交走的是 GitHub API，纯文本增量太大。改用 `tools/fix-encoding.ps1` 在本地一次性完成，效果完全等价（见第 5 节第 1 步）。

## 5. 你需要做的（按顺序）

### 第 1 步：给 `.ps1` 补 BOM 并提交

```powershell
git checkout fix/encoding-bom-ascii
powershell -NoProfile -ExecutionPolicy Bypass -File tools\fix-encoding.ps1
git add -A
git commit -m "fix(encoding): 为所有 .ps1 补 UTF-8 BOM，修复 CP936 下语法错误"
```

预期输出：`PS1 files scanned : 27` / `PS1 files fixed : 26`（含 `release/` 下那份副本）。
再跑一次应显示 `fixed : 0`，用于确认幂等。

### 第 2 步：重打发布包

`release/TokenPanel-1.3.0/` 目录和 `release/TokenPanel-1.3.0.zip` 里躺的还是修复前的旧文件，**必须重打**：

1. `release/TokenPanel-1.3.0/` 下的 `TokenPanel.vbs` 和三个 `.cmd` **本分支已同步替换**，无需再动；
2. 确认该目录下的 `.ps1` 已被第 1 步补上 BOM（`tools/fix-encoding.ps1` 会递归处理 `release/`）；
3. 重新压缩（**注意：zip 内不要出现 UTF-8 无 BOM 的 .ps1**）：

```powershell
Compress-Archive -Path release\TokenPanel-1.3.0 -DestinationPath release\TokenPanel-1.3.0.zip -Force
```

4. 在干净的机器（或至少把 `%APPDATA%\TokenPanel` 改名）上解压 → 双击 `TokenPanel.vbs` → 能出浮窗即为通过。

### 第 3 步：发版

- 打 tag `v1.3.1`；
- **建议改用 GitHub Release 附 zip**，而不是把 zip 提交进仓库 —— 仓库里的二进制既难 review，也容易忘记重打（本次事故的一部分原因）；
- Release notes 里注明：修复 CP936 下 `800A0409` / `.ps1` 语法错误。

### 可选清理（顺手，别单开 PR）

- `使用说明.md` 第 25、146 行写的是 `debug-token-pocket.cmd`，实际文件名是 `debug-token-panel.cmd`（`pocket` 是旧品牌残留）。
- `使用说明.md` 里「技术栈」段落之后可以补一句：**修改 `.vbs`/`.cmd` 时不要存成 UTF-8**。

## 6. 验收清单

- [ ] `git grep -l $'\xef\xbb\xbf' -- '*.ps1'` 覆盖全部 `.ps1`（或用 `tools/fix-encoding.ps1` 复查 `fixed : 0`）
- [ ] `TokenPanel.vbs`、`*.cmd` 无非 ASCII 字节：`tools/fix-encoding.ps1` 的 non-ASCII 检查应输出 `all clean`
- [ ] 解压新 zip → 双击 → `%APPDATA%\TokenPanel\app.log` 出现 `启动 v1.3.x`
- [ ] 浮窗置顶、右键菜单、账户额度刷新正常

## 7. 以后的打包铁律

| 类型 | 编码 | 备注 |
|---|---|---|
| `*.ps1` | **UTF-8 with BOM** | 唯一能让 PS 5.1 正确识别中文的方式 |
| `*.vbs` | **纯 ASCII**（首选）或 UTF-16 LE + BOM | 绝不能用 UTF-8 |
| `*.cmd` | **纯 ASCII**（首选）或 ANSI/GBK | 绝不能用 UTF-8 |
| `*.md` / `*.js` / `*.swift` | UTF-8（无 BOM） | 正常 |

CI 里可加一步 `tools/fix-encoding.ps1 -WhatIf` 做守卫（`-WhatIf` 只报告不改动）。

## 8. 本次排查中额外发现（与编码无关，但接手要知道）

1. **配置目录迁移**：`lib\QuotaCore.ps1` 有一套「谁的 `config.json` 更新就迁谁」的逻辑，会读取旧品牌目录 `%APPDATA%\TokenPocket`。实测从旧版（`D:\Program Files\TokenPocket-1.1.2`，v1.1.x）升级时，新目录 `%APPDATA%\TokenPanel` 一度只生成了默认配置（1 个空 MiniMax 账户），真实 3 个账户（MX0568 / MX2421 / Deepseek）仍留在 `TokenPocket` 目录里，需手工回填。
   → 建议：升级路径上加一次显式校验（迁完比对账户数，不一致就提示而不是静默用默认值）。
2. **两套安装并存**：旧版 1.1.x 仍安装在 `D:\Program Files\TokenPocket-1.1.2`，与新版写的是两个不同的配置目录，同时运行会出现两个浮窗 + 两份配置。
   → 建议：发版说明里明确「先退出旧版」。
3. **账户密钥**：API Key 用 DPAPI 加密存在 `%APPDATA%\<AppId>\config.json`，只能同一 Windows 用户解密。迁移目录时**不要**跨用户复制 config.json。
4. `app.log` 会自我轮转（超过阈值截断），排查「启动即失败」时如果日志很短，不要以为程序跑起来了 —— 要看有没有本次时间戳。

## 9. 关键路径

| 用途 | 路径 |
|---|---|
| 安装目录（本机实测） | `D:\Tools\TokenPanel` |
| 配置 / 日志 | `%APPDATA%\TokenPanel\config.json`、`app.log` |
| 旧版配置（迁移来源） | `%APPDATA%\TokenPocket` |
| 旧版程序 | `D:\Program Files\TokenPocket-1.1.2` |
| 打包工具 | `tools/fix-encoding.ps1` |
