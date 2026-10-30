import SwiftUI
import AppKit

/// 与 Windows 版 Get-ProviderPresets 对应的预设表
struct Preset: Identifiable {
    let id: String
    let label: String
    let short: String
    let tpl: String
    let url: String
    let authMode: String
    let moneyKind: Bool
    let unit: String
}

enum Presets {
    static let all: [Preset] = [
        // tokenplan
        Preset(id: "minimax", label: "MiniMax Coding Plan", short: "MiniMax", tpl: "tokenplan",
               url: "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains",
               authMode: "bearer", moneyKind: false, unit: ""),
        Preset(id: "kimi", label: "Kimi For Coding", short: "Kimi", tpl: "tokenplan",
               url: "https://api.kimi.com/coding/v1/usages",
               authMode: "bearer", moneyKind: false, unit: ""),
        Preset(id: "zhipu", label: "智谱 GLM Coding", short: "智谱", tpl: "tokenplan",
               url: "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
               authMode: "raw", moneyKind: false, unit: ""),
        Preset(id: "opencode", label: "OpenCode Go", short: "OpenCode", tpl: "tokenplan",
               url: "https://opencode.ai/zen/go/v1/usage",
               authMode: "bearer", moneyKind: false, unit: ""),
        // balance
        Preset(id: "deepseek", label: "DeepSeek", short: "DeepSeek", tpl: "balance",
               url: "https://api.deepseek.com/user/balance",
               authMode: "bearer", moneyKind: true, unit: ""),
        Preset(id: "siliconflow", label: "硅基流动", short: "硅基", tpl: "balance",
               url: "https://api.siliconflow.cn/v1/user/info",
               authMode: "bearer", moneyKind: true, unit: ""),
        Preset(id: "openrouter", label: "OpenRouter", short: "OR", tpl: "balance",
               url: "https://openrouter.ai/api/v1/credits",
               authMode: "bearer", moneyKind: true, unit: ""),
        Preset(id: "stepfun", label: "阶跃星辰", short: "阶跃", tpl: "balance",
               url: "https://api.stepfun.com/v1/accounts/balance",
               authMode: "bearer", moneyKind: true, unit: ""),
        // official
        Preset(id: "claude", label: "Claude Code", short: "Claude", tpl: "official",
               url: "https://api.anthropic.com/api/oauth/usage",
               authMode: "oauth", moneyKind: false, unit: ""),
        Preset(id: "codex", label: "Codex", short: "Codex", tpl: "official",
               url: "https://chatgpt.com/backend-api/wham/usage",
               authMode: "oauth", moneyKind: false, unit: ""),
        Preset(id: "workbuddy", label: "WorkBuddy", short: "WB", tpl: "official",
               url: "https://www.workbuddy.cn",
               authMode: "wbprofile", moneyKind: true, unit: "credits"),
        // general / newapi / custom
        Preset(id: "general", label: "通用余额", short: "余额", tpl: "general",
               url: "", authMode: "bearer", moneyKind: true, unit: ""),
        Preset(id: "newapi", label: "New API", short: "NewAPI", tpl: "newapi",
               url: "", authMode: "newapi", moneyKind: true, unit: ""),
        Preset(id: "custom", label: "自定义", short: "自定义", tpl: "custom",
               url: "", authMode: "bearer", moneyKind: false, unit: "%")
    ]

    static func byTpl(_ tpl: String) -> [Preset] {
        all.filter { $0.tpl == tpl }
    }

    static func find(_ id: String) -> Preset? {
        all.first { $0.id == id }
    }

    static let templates: [(String, String)] = [
        ("tokenplan", "套餐额度"),
        ("balance", "账户余额"),
        ("official", "官方 Agent"),
        ("general", "通用余额"),
        ("newapi", "New API"),
        ("custom", "自定义")
    ]
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(store: ConfigStore, onSave: @escaping () -> Void) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = SettingsView(store: store) { [weak self] in
            self?.window?.close()
            self?.window = nil
            onSave()
        }
        let hosting = NSHostingController(rootView: root)
        let win = NSWindow(contentViewController: hosting)
        win.title = "TokenPanel 设置"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.setContentSize(NSSize(width: 760, height: 540))
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    let store: ConfigStore
    let onClose: () -> Void

    @State private var providers: [ProviderConfig]
    @State private var selection: Int? = 0
    @State private var keyInput: String = ""
    @State private var theme: String
    @State private var refreshMinutes: Int
    @State private var message: String = ""

    init(store: ConfigStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        _providers = State(initialValue: store.config.providers)
        _theme = State(initialValue: store.config.theme)
        _refreshMinutes = State(initialValue: store.config.refreshMinutes)
    }

    private var currentIndex: Int? {
        guard !providers.isEmpty,
              let index = selection,
              index >= 0,
              index < providers.count else { return nil }
        return index
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                accountList
                    .frame(minWidth: 220, idealWidth: 240)
                detailPane
                    .frame(minWidth: 420)
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { loadKeyForSelection() }
        .onChange(of: selection) { _ in loadKeyForSelection() }
    }

    // MARK: - 左侧列表

    private var accountList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Array(providers.enumerated()), id: \.offset) { index, provider in
                    HStack(spacing: 6) {
                        Text(provider.short)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Text(provider.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                    }
                    .tag(Optional(index))
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 6) {
                Button {
                    addProvider()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)

                Button {
                    removeSelection()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(currentIndex == nil)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 右侧表单

    @ViewBuilder
    private var detailPane: some View {
        if let index = currentIndex {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field("名称") {
                        TextField("显示名", text: $providers[index].name)
                    }
                    HStack(spacing: 12) {
                        field("短名") {
                            TextField("圆圈下的标签", text: $providers[index].short)
                        }
                        field("单位") {
                            TextField("credits / CNY / %", text: $providers[index].unit)
                        }
                    }
                    field("模板") {
                        Picker("", selection: $providers[index].tpl) {
                            ForEach(Presets.templates, id: \.0) { tpl, label in
                                Text(label).tag(tpl)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    field("供应商") {
                        Picker("", selection: $providers[index].type) {
                            ForEach(Presets.byTpl(providers[index].tpl)) { preset in
                                Text(preset.label).tag(preset.id)
                            }
                        }
                        .labelsHidden()
                    }
                    field("请求地址") {
                        TextField("https://…", text: $providers[index].apiUrl)
                            .disabled(providers[index].authMode == "wbprofile")
                    }
                    if providers[index].authMode != "oauth" && providers[index].authMode != "wbprofile" {
                        field("API Key") {
                            SecureField("粘贴 Key（存 Keychain）", text: $keyInput)
                        }
                    }
                    if providers[index].tpl == "custom" {
                        field("提取路径") {
                            TextField("data.balance", text: $providers[index].extractor)
                        }
                    }
                    if providers[index].authMode == "wbprofile" {
                        Text("WorkBuddy 用浏览器登录态查询，首次需在 Windows 版完成授权，或在本机把 .browser-profile 拷到 lib/wb/ 下。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Divider()
                    HStack(spacing: 12) {
                        Text("主题")
                            .font(.system(size: 12))
                            .frame(width: 64, alignment: .leading)
                        Picker("", selection: $theme) {
                            Text("深色").tag("dark")
                            Text("浅色").tag("light")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                    }
                    HStack(spacing: 12) {
                        Text("刷新间隔")
                            .font(.system(size: 12))
                            .frame(width: 64, alignment: .leading)
                        Stepper(value: $refreshMinutes, in: 1...120) {
                            Text("\(refreshMinutes) 分钟")
                                .font(.system(size: 12))
                        }
                    }
                }
                .padding(16)
            }
        } else {
            Text("左侧还没有账户，点 + 添加一个")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func field<Content: View>(_ label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 64, alignment: .leading)
            content()
        }
    }

    // MARK: - 底部

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Button("取消") { onClose() }
            Button("保存并刷新") { save() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 动作

    private func loadKeyForSelection() {
        guard let index = currentIndex else {
            keyInput = ""
            return
        }
        keyInput = Keychain.shared.get(providers[index].keyRef) ?? ""
    }

    private func addProvider() {
        let preset = Presets.all[0]
        let newProvider = ProviderConfig(
            id: UUID().uuidString,
            name: preset.label,
            short: preset.short,
            tpl: preset.tpl,
            type: preset.id,
            apiUrl: preset.url,
            authMode: preset.authMode,
            keyRef: "key-" + UUID().uuidString.prefix(8),
            moneyKind: preset.moneyKind,
            unit: preset.unit
        )
        providers.append(newProvider)
        selection = providers.count - 1
        message = "已添加，记得填 API Key"
    }

    private func removeSelection() {
        guard let index = currentIndex else { return }
        let removed = providers.remove(at: index)
        Keychain.shared.delete(removed.keyRef)
        selection = providers.isEmpty ? nil : min(index, providers.count - 1)
        message = "已删除 \(removed.name)"
    }

    private func save() {
        if let index = currentIndex, !keyInput.isEmpty {
            Keychain.shared.set(keyInput, for: providers[index].keyRef)
        }
        // 切换供应商时套用预设的地址/认证方式，避免手填残留
        for i in providers.indices {
            if let preset = Presets.find(providers[i].type) {
                providers[i].authMode = preset.authMode
                providers[i].moneyKind = preset.moneyKind
                if providers[i].apiUrl.isEmpty && !preset.url.isEmpty {
                    providers[i].apiUrl = preset.url
                }
            }
        }
        store.update { config in
            config.providers = providers
            config.theme = theme
            config.refreshMinutes = refreshMinutes
        }
        message = "已保存"
        onClose()
    }
}
