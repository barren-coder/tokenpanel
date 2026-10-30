import AppKit

// 菜单栏常驻应用：不占 Dock，不显示主窗口，靠 NSStatusItem + NSPanel 存活。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
