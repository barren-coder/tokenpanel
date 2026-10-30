import SwiftUI

/// 与 Windows 版 lib/QuotaCore.ps1 的 Get-MainTheme 保持同一套色值，
/// 两个平台看起来才像同一个产品。
struct Palette {
    let bg: Color
    let bgHover: Color
    let track: Color
    let line: Color
    let tx: Color
    let tx2: Color
    let tx3: Color
    let cy: Color
    let am: Color
    let rd: Color
    let ringText: Color
    let trackRing: Color
    let foot: Color
    let border: Color
    let isDark: Bool
}

enum Theme {
    static let dark = Palette(
        bg: Color(hex: 0x1C1F27),
        bgHover: Color(hex: 0x21252E),
        track: Color(hex: 0x22262F),
        line: Color(hex: 0x2E333F),
        tx: Color(hex: 0xE6EDF3),
        tx2: Color(hex: 0x9AA5B5),
        tx3: Color(hex: 0x6B7686),
        cy: Color(hex: 0x2DD4BF),
        am: Color(hex: 0xF5A524),
        rd: Color(hex: 0xF04452),
        ringText: Color.white,
        trackRing: Color(hex: 0x333947),
        foot: Color(hex: 0x55606F),
        border: Color.clear,
        isDark: true
    )

    static let light = Palette(
        bg: Color(hex: 0xF7F7F8),
        bgHover: Color(hex: 0xEFEFF1),
        track: Color(hex: 0xE3E3E6),
        line: Color(hex: 0xDDDDDF),
        tx: Color(hex: 0x1B1B1B),
        tx2: Color(hex: 0x5A5A5E),
        tx3: Color(hex: 0x8B8B90),
        cy: Color(hex: 0x0E7C6B),
        am: Color(hex: 0xB45309),
        rd: Color(hex: 0xC42B1C),
        ringText: Color(hex: 0x1B1B1B),
        trackRing: Color(hex: 0xDCDCDE),
        foot: Color(hex: 0x8B8B90),
        border: Color(hex: 0xE2E2E4),
        isDark: false
    )

    /// 当前主题由配置的 theme 字段决定，默认深色（与 Windows 版一致）。
    static var current: Palette = .dark

    static func apply(_ name: String) {
        current = (name.lowercased() == "light") ? .light : .dark
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
