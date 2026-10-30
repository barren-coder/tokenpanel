import SwiftUI

// MARK: - 数据模型

struct TierQuota: Identifiable {
    var id: String { name }
    let name: String
    let remain: Int
    let display: String
    let money: Double?
    let unit: String?
    let resetAt: String?
}

/// 一个账户的查询结果
struct AccountQuota: Identifiable {
    let id: String
    let name: String
    let short: String
    let kind: String            // percent | money
    let ok: Bool
    let tiers: [TierQuota]
    let primaryText: String
    let tint: Color
    let unit: String?
    let money: Double?
    let errorText: String?

    /// 折叠态圆圈的数值文字：积分类用 k 缩写（2.1k），金额类保留一位小数
    func dockText() -> String {
        guard ok, let m = money else { return "--" }
        if unit == "credits" {
            return Format.compactCredits(m)
        }
        return String(format: "%.1f", m)
    }

    /// 额度类账户的进度弧；余额类返回 nil（只描边）
    func progress() -> Double? {
        guard ok, kind != "money", let first = tiers.first else { return nil }
        return Double(max(0, min(100, first.remain))) / 100.0
    }

    func toDockItem() -> DockItem {
        DockItem(
            id: id,
            short: short,
            text: dockText(),
            tint: tint,
            ok: ok,
            progress: progress()
        )
    }
}

enum Format {
    static func compactCredits(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "%.1fk", value / 1000.0)
        }
        if value == value.rounded() {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    static func money(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

// MARK: - 配置

struct ProviderConfig: Codable, Identifiable {
    var id: String
    var name: String
    var short: String
    var tpl: String             // custom | general | newapi | tokenplan | balance | official
    var type: String            // minimax / kimi / deepseek / workbuddy ...
    var apiUrl: String
    var authMode: String        // bearer | header | newapi | wbprofile | oauth | none
    var keyRef: String          // Keychain 里的 account 名
    var moneyKind: Bool         // 是否余额类（对应 Windows 的 kind='money'）
    var unit: String            // credits / "" / "%"
    var extractor: String       // custom 模板的 JSON 路径表达式
    var extra: String           // NewAPI 的 User ID 之类附加参数

    enum CodingKeys: String, CodingKey {
        case id, name, short, tpl, type, apiUrl, authMode, keyRef
        case moneyKind = "money"
        case unit, extractor, extra
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名"
        short = try c.decodeIfPresent(String.self, forKey: .short) ?? "?"
        tpl = try c.decodeIfPresent(String.self, forKey: .tpl) ?? "custom"
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "custom"
        apiUrl = try c.decodeIfPresent(String.self, forKey: .apiUrl) ?? ""
        authMode = try c.decodeIfPresent(String.self, forKey: .authMode) ?? "bearer"
        keyRef = try c.decodeIfPresent(String.self, forKey: .keyRef) ?? ""
        moneyKind = try c.decodeIfPresent(Bool.self, forKey: .moneyKind) ?? false
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        extractor = try c.decodeIfPresent(String.self, forKey: .extractor) ?? ""
        extra = try c.decodeIfPresent(String.self, forKey: .extra) ?? ""
    }

    init(id: String, name: String, short: String, tpl: String, type: String,
         apiUrl: String, authMode: String, keyRef: String, moneyKind: Bool,
         unit: String = "", extractor: String = "", extra: String = "") {
        self.id = id
        self.name = name
        self.short = short
        self.tpl = tpl
        self.type = type
        self.apiUrl = apiUrl
        self.authMode = authMode
        self.keyRef = keyRef
        self.moneyKind = moneyKind
        self.unit = unit
        self.extractor = extractor
        self.extra = extra
    }
}

struct AppConfig: Codable {
    var providers: [ProviderConfig]
    var refreshMinutes: Int
    var timeout: Int
    var theme: String
    var dockRight: Double
    var dockBottom: Double
    var maxDockItems: Int
    var moneyWarn: Double
    var moneyCrit: Double
    var creditsWarn: Double
    var creditsCrit: Double
    var startWithBoot: Bool

    enum CodingKeys: String, CodingKey {
        case providers, refreshMinutes, timeout, theme
        case dockRight, dockBottom, maxDockItems
        case moneyWarn, moneyCrit, creditsWarn, creditsCrit, startWithBoot
    }

    init() {
        providers = [
            ProviderConfig(
                id: "deepseek-demo", name: "DeepSeek", short: "DeepSeek",
                tpl: "balance", type: "deepseek",
                apiUrl: "https://api.deepseek.com/user/balance",
                authMode: "bearer", keyRef: "", moneyKind: true
            )
        ]
        refreshMinutes = 5
        timeout = 15
        theme = "dark"
        dockRight = 48
        dockBottom = 72
        maxDockItems = 3
        moneyWarn = 20
        moneyCrit = 5
        creditsWarn = 50
        creditsCrit = 20
        startWithBoot = false
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decodeIfPresent([ProviderConfig].self, forKey: .providers) ?? []
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? 5
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout) ?? 15
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "dark"
        dockRight = try c.decodeIfPresent(Double.self, forKey: .dockRight) ?? 48
        dockBottom = try c.decodeIfPresent(Double.self, forKey: .dockBottom) ?? 72
        maxDockItems = try c.decodeIfPresent(Int.self, forKey: .maxDockItems) ?? 3
        moneyWarn = try c.decodeIfPresent(Double.self, forKey: .moneyWarn) ?? 20
        moneyCrit = try c.decodeIfPresent(Double.self, forKey: .moneyCrit) ?? 5
        creditsWarn = try c.decodeIfPresent(Double.self, forKey: .creditsWarn) ?? 50
        creditsCrit = try c.decodeIfPresent(Double.self, forKey: .creditsCrit) ?? 20
        startWithBoot = try c.decodeIfPresent(Bool.self, forKey: .startWithBoot) ?? false
    }
}

// MARK: - 阈值上色（与 Windows 版定案一致）

enum Threshold {
    /// credits：≤20 红 / 20~50 黄 / >50 青
    /// 金额：≤5 红 / 5~20 黄 / >20 青
    static func tint(unit: String?, money: Double?, config: AppConfig) -> Color {
        let t = Theme.current
        guard let value = money else { return t.tx3 }
        if unit == "credits" {
            if value <= config.creditsCrit { return t.rd }
            if value <= config.creditsWarn { return t.am }
            return t.cy
        }
        if value <= config.moneyCrit { return t.rd }
        if value < config.moneyWarn { return t.am }
        return t.cy
    }
}
