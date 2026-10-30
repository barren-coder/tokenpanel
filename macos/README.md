# TokenPanel for macOS

Windows 版（PowerShell + WinForms）的原生 macOS 重写。菜单栏常驻 + 无边框悬浮窗，
看各家 AI 套餐额度与余额。

- **原生 Swift / AppKit**，约 190 KB，不依赖 Electron
- 目标系统：**macOS 13+**，编译产物为 **Apple Silicon (arm64)**
- 未签名（ad-hoc），自用无需 Apple Developer 账号

---

## 一、怎么拿到 .app

仓库已配好 GitHub Actions，**不需要有 Mac 也能出包**：

1. 打开 <https://github.com/barren-coder/tokenpanel/actions/workflows/macos.yml>
2. 点最新一次绿色的运行
3. 页面底部 **Artifacts** → 下载 `TokenPanel-macOS`
4. 解压得到 `TokenPanel-macos.zip`，再解压出 `TokenPanel.app`

> 没登录 GitHub 也能看列表，但下载 artifact 需要登录自己的账号。

## 二、安装与首次启动

```bash
# 1) 解压
unzip TokenPanel-macos.zip

# 2) 拖进应用程序目录（可选）
mv TokenPanel.app /Applications/

# 3) 解除隔离属性（关键！下载来的 zip 会被 Gatekeeper 打标记）
xattr -dr com.apple.quarantine /Applications/TokenPanel.app
```

然后双击启动。**第一次如果被拦**（提示"无法打开，因为来自身份不明的开发者"）：
右键点图标 → 打开 → 再点"打开"，只需一次。

启动后不会出现在 Dock，只会在**菜单栏**出现一个柱状图图标（这是正常的，它是个
`LSUIElement` 应用）。悬浮窗会贴在屏幕右下角。

## 三、用法

| 操作 | 效果 |
|---|---|
| 点悬浮窗 | 展开成账户列表（再点右上角箭头收起） |
| 按住悬浮窗空白处拖动 | 移动位置 |
| 菜单栏图标 → 显示/隐藏悬浮窗 | 收起或唤出 |
| 菜单栏图标 → 立即刷新 | 手动查一轮 |
| 菜单栏图标 → 设置… | 加账户、填 Key、切主题 |

折叠态是圆圈：**青色**正常、**黄色**预警、**红色**告急。
阈值与 Windows 版一致：

- 积分：≤20 红 / 20~50 黄 / >50 青
- 金额：≤5 元红 / 5~20 元黄 / >20 元青

## 四、配置文件在哪

| 内容 | 路径 |
|---|---|
| 配置 | `~/Library/Application Support/TokenPanel/config.json` |
| 运行状态 | `~/Library/Application Support/TokenPanel/state.json` |
| WorkBuddy 登录态 | `~/Library/Application Support/TokenPanel/wb/.browser-profile` |
| API Key | **Keychain**（服务名 `com.barrencoder.tokenpanel`） |

**API Key 不落盘**，存在系统钥匙串里。首次读取时 macOS 可能弹一次
「TokenPanel 想要访问钥匙串」——点「始终允许」。

> 未签名的 app 每次重新编译签名指纹都会变，所以重新出包后可能再弹一次，属正常。

## 五、WorkBuddy 积分

WorkBuddy 的网关按 TLS 指纹拦截普通 HTTP 客户端（同 cookie 下 curl 一律 401），
所以必须用无头 Chrome 在页面上下文里发请求。macOS 版**复用同一份 `wb_query.js`**，
需要：

1. **node**：`brew install node`（脚本会自动找 Homebrew / nvm / 系统路径）
2. **Chrome 或 Edge**：装在 `/Applications` 下
3. **登录态**：把 Windows 版 `D:\AppData\TokenPanel\lib\wb\.browser-profile`
   整个目录拷到 `~/Library/Application Support/TokenPanel/wb/.browser-profile`

拷完在设置里点「立即刷新」，圆圈应显示 `2.1k` 这样的积分。

## 六、已知限制

- **只编译 arm64**。Intel Mac 需要改 `Package.swift` 里加 `arch` 参数，或在 CI 里
  换 `macos-13` runner（Intel）。
- **未签名未公证**。分发给别人需要 Apple Developer（$99/年）签名 + 公证，
  否则对方要手动解除隔离（见上文 `xattr` 命令）。
- **没有 Windows 版的全部功能**：开机自启、透明度调节、贴边吸附、主题自定义
  这些还没搬。菜单栏常驻已经替代了「开机自启」的大部分需求。
- **Claude / Codex 需要本机 OAuth**：读 `~/.claude/.credentials.json` 与
  `~/.codex/auth.json`，这部分在 macOS 版里还没接（先做的是 HTTP 系供应商）。

## 七、本地开发

有 Mac 的话：

```bash
cd macos
swift build -c release            # 编译
swift run                         # 直接跑（调试用，有控制台日志）
```

出包走 CI 或手工：

```bash
swift build -c release
BIN=$(swift build -c release --show-bin-path)
mkdir -p TokenPanel.app/Contents/{MacOS,Resources/wb}
cp "$BIN/TokenPanel" TokenPanel.app/Contents/MacOS/
cp Resources/Info.plist TokenPanel.app/Contents/
cp ../lib/wb/wb_query.js ../lib/wb/grab_cookie.js TokenPanel.app/Contents/Resources/wb/
codesign --force --deep --sign - TokenPanel.app
```

## 八、代码地图

| 文件 | 职责 | 对应 Windows 版 |
|---|---|---|
| `main.swift` | 入口，`.accessory` 策略（不占 Dock） | — |
| `AppDelegate.swift` | 菜单栏、悬浮窗、刷新循环 | `TokenPanel.ps1` |
| `Views.swift` | 折叠态圆圈、展开态列表 | 同上（绘制部分） |
| `SettingsWindow.swift` | 设置窗口、预设表 | `lib/ConfigWindow.ps1` |
| `Models.swift` | 数据模型、阈值上色 | `lib/QuotaCore.ps1`（模型 + 阈值） |
| `QuotaService.swift` | HTTP 请求 + 10 个解析器 | 同上（`Invoke-*` / `Parse-*`） |
| `WorkBuddyService.swift` | 调 node 脚本查积分 | `Invoke-WorkBuddy` |
| `Keychain.swift` | 存 API Key | `Protect-String` / DPAPI |
| `ConfigStore.swift` | 配置读写 | `Load-Config` / `Save-Config` |
| `Theme.swift` | 配色（与 Windows 同一套值） | `Get-MainTheme` |
