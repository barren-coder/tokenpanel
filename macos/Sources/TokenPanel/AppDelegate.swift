import AppKit
import SwiftUI

/// 无边框悬浮窗。NSPanel + .nonactivatingPanel 让它不抢焦点，
/// 也不出现在 Mission Control 的窗口列表里（配 .stationary 更贴近"贴纸"手感）。
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private let state = UIState()
    private let store = ConfigStore()

    private var collapsedSize = NSSize(width: 172, height: 78)
    private var expandedSize = NSSize(width: 352, height: 448)

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.load()
        Theme.apply(store.config.theme)

        setupStatusItem()
        setupPanel()
        startRefreshLoop()
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "chart.bar.xaxis",
                accessibilityDescription: "TokenPanel"
            )
            button.image?.isTemplate = true
            button.toolTip = "TokenPanel \(AppInfo.version)"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "显示 / 隐藏悬浮窗", action: #selector(togglePanelVisible), keyEquivalent: "")
        menu.addItem(withTitle: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 TokenPanel", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    // MARK: - 悬浮窗

    private func setupPanel() {
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating                       // 等价于 Windows 的 TOPMOST，且不会丢位
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true      // 按住任意空白处就能拖
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow

        state.onToggle = { [weak self] in self?.toggleExpanded() }

        let host = NSHostingView(rootView: RootView(state: state))
        host.frame = NSRect(origin: .zero, size: collapsedSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        moveToDefaultCorner()
        panel.orderFrontRegardless()
    }

    private func moveToDefaultCorner() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let x = vf.maxX - collapsedSize.width - CGFloat(store.config.dockRight)
        let y = vf.minY + CGFloat(store.config.dockBottom)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func toggleExpanded() {
        state.expanded.toggle()
        let target = state.expanded ? expandedSize : collapsedSize
        // 右下角锚定：展开时向上、向左生长
        let old = panel.frame
        let origin = NSPoint(x: old.maxX - target.width, y: old.minY)
        panel.setFrame(NSRect(origin: origin, size: target), display: true, animate: true)
    }

    // MARK: - 刷新

    private func startRefreshLoop() {
        state.items = []
        state.statusLine = "尚未查询"
        refreshNow()
    }

    @objc private func refreshNow() {
        state.refreshing = true
        let config = store.config
        Task {
            let accounts = await QuotaService.shared.refreshAll(
                config: config,
                keychain: Keychain.shared
            )
            await MainActor.run {
                self.state.refreshing = false
                self.state.accounts = accounts
                self.state.items = accounts.map { $0.toDockItem() }
                self.state.statusLine = "更新于 " + AppDelegate.clockText()
            }
        }
    }

    private static func clockText() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    // MARK: - 菜单动作

    @objc private func togglePanelVisible() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(store: store) { [weak self] in
            Theme.apply(self?.store.config.theme ?? "dark")
            self?.refreshNow()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

enum AppInfo {
    static let version = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0"
}
