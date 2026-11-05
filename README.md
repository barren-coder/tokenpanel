# TokenPanel

Windows 桌面悬浮窗，实时显示各个 AI 套餐的**额度使用量**和账户**余额**。纯 PowerShell + WinForms，不用安装运行时、不用管理员权限、不向任何服务器上传数据。

## 特性

- **置顶悬浮窗**：单击展开明细、双击刷新、拖动换位；靠近屏幕左右边缘自动竖排，位置会被记住
- **6 类模板**：Token Plan（MiniMax / Kimi / GLM）、官方（Claude Code / Codex / WorkBuddy 积分）、账户余额（DeepSeek / 硅基流动 / OpenRouter / 阶跃）、通用 OpenAI 兼容网关、NewAPI、自定义 JSON 接口
- **本地存储**：API Key 用 Windows DPAPI 加密后存 `%APPDATA%\TokenPanel\config.json`，只在本机可解
- **开机自启**：可选，写 `HKCU\...\Run`，不需要提权

## 快速开始

1. 获取代码：`git clone git@github.com:barren-coder/tokenpanel.git`，或从 Releases 下载压缩包
2. **双击 `TokenPanel.vbs`** —— 全程无黑窗
3. 想要快捷方式：双击 `创建快捷方式.cmd`，会在同目录生成 `TokenPanel.lnk`

> `.lnk` 存的是绝对路径，**移动文件夹后要重新运行一次 `创建快捷方式.cmd`**；`.vbs` 按自身位置找程序，随便移动都能用。

## 目录结构

| 路径 | 用途 |
|---|---|
| `TokenPanel.ps1` | 主程序：窗口绘制、托盘、刷新调度、菜单 |
| `TokenPanel.vbs` | 无窗口启动器 |
| `lib/QuotaCore.ps1` | 查询内核：模板、请求、解析、加密存储 |
| `lib/ConfigWindow.ps1` | 设置面板 |
| `lib/wb/` | WorkBuddy 积分查询（无头 Chrome） |
| `TokenPanel.ico` | 应用 / 窗口 / 托盘统一图标 |
| `make-shortcut.ps1`、`创建快捷方式.cmd` | 生成快捷方式 |
| `start-token-panel.cmd` | 带控制台的启动入口 |
| `debug-token-panel.cmd` | 调试启动（保留报错窗口） |
| `setup-accounts.ps1` | 账户配置辅助脚本 |
| `docs/` | 使用说明、技术方案、界面方案、交接文档、截图 |
| `macos/` | macOS 版（Swift，GitHub Actions 构建） |

## 文档

- [使用说明](docs/使用说明.md) —— 面向使用者：怎么启动、怎么配账户、系统配置、常见问题
- [HANDOFF](docs/HANDOFF.md) —— 面向开发者：架构、调试参数、历史坑与决策记录
- [技术方案](docs/技术方案.html) ｜ [界面方案](docs/界面方案.html) ｜ [需求与目标对齐](docs/需求与目标对齐.html)
- [待优化问题](docs/待优化问题.txt)

## 运行环境

- Windows 10 / 11（x64），PowerShell 5.1，无需 .NET SDK 或 Python
- macOS 版见 [`macos/README.md`](macos/README.md)

## 打包发版

仓库不再提交 `release/` 目录（打包产物与源码容易不同步）。发版流程：改源码 → 打 zip → 挂到 GitHub Releases → 打 tag。

## License

见 [LICENSE](LICENSE)。
