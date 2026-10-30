import Foundation
import SwiftUI

enum QuotaError: LocalizedError {
    case badURL
    case missingKey
    case network(String)
    case auth(Int)
    case http(Int)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "请求地址不合法"
        case .missingKey:
            return "未填写 API Key"
        case .network(let message):
            return "网络失败：" + message
        case .auth(let code):
            return "认证失败 (HTTP \(code))，请检查 Key / Token"
        case .http(let code):
            return "HTTP \(code)"
        case .parse(let message):
            return message
        }
    }
}

/// 按 "a.b.c" 或 "a.0.b" 取值，对应 Windows 版的 Get-JsonPath
enum JSONPath {
    static func value(_ root: Any, _ path: String) -> Any? {
        var current: Any? = root
        for segment in path.split(separator: ".") {
            guard let node = current else { return nil }
            let key = String(segment)
            if let index = Int(key), let array = node as? [Any] {
                if index < 0 || index >= array.count { return nil }
                current = array[index]
            } else if let dict = node as? [String: Any] {
                current = dict[key]
            } else {
                return nil
            }
        }
        return current
    }

    static func double(_ root: Any, _ path: String) -> Double? {
        guard let raw = value(root, path) else { return nil }
        return QuotaService.toDouble(raw)
    }

    static func string(_ root: Any, _ path: String) -> String? {
        guard let raw = value(root, path) else { return nil }
        if let text = raw as? String { return text }
        if let number = raw as? Double { return String(number) }
        if let integer = raw as? Int { return String(integer) }
        return nil
    }

    static func firstExisting(_ root: Any, _ paths: [String]) -> Any? {
        for path in paths {
            if let found = value(root, path) { return found }
        }
        return nil
    }
}

final class QuotaService {
    static let shared = QuotaService()
    private let userAgent = "TokenPanel/1.3.0 (macOS)"

    func refreshAll(config: AppConfig, keychain: Keychain) async -> [AccountQuota] {
        var results: [AccountQuota] = []
        for provider in config.providers {
            let quota = await query(provider: provider, config: config, keychain: keychain)
            results.append(quota)
        }
        return results
    }

    private func query(provider: ProviderConfig, config: AppConfig,
                       keychain: Keychain) async -> AccountQuota {
        let unit = provider.unit.isEmpty ? nil : provider.unit
        do {
            let tiers = try await fetch(provider: provider, config: config, keychain: keychain)
            guard let first = tiers.first else {
                throw QuotaError.parse("没有可显示的额度")
            }
            let tint = Threshold.tint(unit: unit, money: first.money, config: config)
            return AccountQuota(
                id: provider.id,
                name: provider.name,
                short: provider.short,
                kind: provider.moneyKind ? "money" : "percent",
                ok: true,
                tiers: tiers,
                primaryText: first.display,
                tint: tint,
                unit: unit,
                money: first.money,
                errorText: nil
            )
        } catch {
            return AccountQuota(
                id: provider.id,
                name: provider.name,
                short: provider.short,
                kind: provider.moneyKind ? "money" : "percent",
                ok: false,
                tiers: [],
                primaryText: "--",
                tint: Theme.current.tx3,
                unit: unit,
                money: nil,
                errorText: error.localizedDescription
            )
        }
    }

    // MARK: - 请求

    private func fetch(provider: ProviderConfig, config: AppConfig,
                       keychain: Keychain) async throws -> [TierQuota] {
        // WorkBuddy 走无头 Chrome（TLS 指纹墙），不经 HTTP
        if provider.type == "workbuddy" {
            return try await WorkBuddyService.shared.query(config: config)
        }

        let key = keychain.get(provider.keyRef) ?? ""
        if provider.authMode != "none" && provider.authMode != "oauth" && key.isEmpty {
            throw QuotaError.missingKey
        }

        let url = try endpoint(provider: provider)
        var headers: [String: String] = [
            "Accept": "application/json",
            "User-Agent": userAgent
        ]
        switch provider.authMode {
        case "bearer":
            headers["Authorization"] = "Bearer " + key
        case "raw":
            headers["Authorization"] = key          // 智谱：裸 key，不加 Bearer
        case "newapi":
            headers["Authorization"] = "Bearer " + key
            if !provider.extra.isEmpty { headers["New-Api-User"] = provider.extra }
        default:
            break
        }

        let data = try await get(url, headers: headers, timeout: config.timeout)
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw QuotaError.parse("响应不是 JSON，可能被代理或登录页拦截")
        }
        return try parse(provider: provider, root: root)
    }

    private func endpoint(provider: ProviderConfig) throws -> URL {
        var raw = provider.apiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw QuotaError.badURL }
        while raw.hasSuffix("/") { raw.removeLast() }
        switch provider.tpl {
        case "general":
            raw += "/user/balance"
        case "newapi":
            raw += "/api/user/self"
        default:
            break
        }
        guard let url = URL(string: raw), url.scheme != nil else { throw QuotaError.badURL }
        return url
    }

    private func get(_ url: URL, headers: [String: String], timeout: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(max(5, timeout))
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { throw QuotaError.auth(code) }
            if code != 200 { throw QuotaError.http(code) }
            return data
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }
    }

    // MARK: - 解析分发

    private func parse(provider: ProviderConfig, root: Any) throws -> [TierQuota] {
        switch provider.tpl {
        case "tokenplan":
            return try parseTokenPlan(provider: provider, root: root)
        case "balance":
            return try parseBalance(provider: provider, root: root)
        case "official":
            return try parseOfficial(provider: provider, root: root)
        case "general":
            return try parseGeneral(root: root)
        case "newapi":
            return try parseNewAPI(root: root)
        default:
            return try parseCustom(provider: provider, root: root)
        }
    }

    // MARK: - tokenplan：MiniMax / Kimi / 智谱 / OpenCode

    private func parseTokenPlan(provider: ProviderConfig, root: Any) throws -> [TierQuota] {
        var tiers: [TierQuota] = []

        switch provider.type {
        case "minimax":
            if let code = JSONPath.double(root, "base_resp.status_code"), code != 0 {
                let message = JSONPath.string(root, "base_resp.status_msg") ?? ""
                throw QuotaError.parse("接口 \(Int(code))：\(message)")
            }
            guard let list = JSONPath.value(root, "model_remains") as? [[String: Any]],
                  let general = list.first(where: { ($0["model_name"] as? String) == "general" }) else {
                throw QuotaError.parse("响应缺少 general 档位")
            }
            let intervalRemain = intValue(general["current_interval_remaining_percent"])
            if intValue(general["current_interval_status"]) != 3 {
                tiers.append(TierQuota(
                    name: "5小时",
                    remain: intervalRemain,
                    display: "\(intervalRemain)%",
                    money: nil,
                    unit: nil,
                    resetAt: resetFromMilliseconds(general["end_time"])
                ))
            }
            let weeklyRemain = intValue(general["current_weekly_remaining_percent"])
            if intValue(general["current_weekly_status"]) != 3 {
                tiers.append(TierQuota(
                    name: "7天",
                    remain: weeklyRemain,
                    display: "\(weeklyRemain)%",
                    money: nil,
                    unit: nil,
                    resetAt: resetFromMilliseconds(general["weekly_end_time"])
                ))
            }

        case "kimi":
            if let detail = JSONPath.value(root, "limits.0.detail") as? [String: Any] {
                let limit = doubleValue(detail["limit"])
                let remaining = doubleValue(detail["remaining"])
                if limit > 0 {
                    let usedPercent = Int(((limit - remaining) / limit * 100).rounded())
                    let remain = 100 - usedPercent
                    tiers.append(TierQuota(
                        name: "5小时",
                        remain: remain,
                        display: "\(remain)%",
                        money: nil,
                        unit: nil,
                        resetAt: resetFromMilliseconds(detail["resetTime"])
                    ))
                }
            }
            if let usage = JSONPath.value(root, "usage") as? [String: Any] {
                let limit = doubleValue(usage["limit"])
                let remaining = doubleValue(usage["remaining"])
                if limit > 0 {
                    let usedPercent = Int(((limit - remaining) / limit * 100).rounded())
                    let remain = 100 - usedPercent
                    tiers.append(TierQuota(
                        name: "7天",
                        remain: remain,
                        display: "\(remain)%",
                        money: nil,
                        unit: nil,
                        resetAt: resetFromMilliseconds(usage["resetTime"])
                    ))
                }
            }

        case "zhipu":
            if let success = JSONPath.value(root, "success") as? Bool, success == false {
                let message = JSONPath.string(root, "msg") ?? "接口返回失败"
                throw QuotaError.parse("接口返回：\(message)")
            }
            if let limits = JSONPath.value(root, "data.limits") as? [[String: Any]] {
                var index = 0
                for limit in limits {
                    let type = (limit["type"] as? String ?? "").uppercased()
                    if !type.contains("TOKEN") && !type.contains("CREDIT") { continue }
                    let name: String
                    if index == 0 { name = "5h" }
                    else if index == 1 { name = "本周" }
                    else { name = "窗口\(index + 1)" }
                    let used = intValue(limit["percentage"])
                    let remain = 100 - used
                    tiers.append(TierQuota(
                        name: name,
                        remain: remain,
                        display: "\(remain)%",
                        money: nil,
                        unit: nil,
                        resetAt: resetFromMilliseconds(limit["nextResetTime"])
                    ))
                    index += 1
                }
            }

        case "opencode":
            let windows: [(String, String)] = [("rolling", "5h"), ("weekly", "本周"), ("monthly", "本月")]
            for (key, name) in windows {
                guard let window = JSONPath.value(root, "usage.\(key)") as? [String: Any] else { continue }
                let used = intValue(window["percent"])
                let remain = 100 - used
                tiers.append(TierQuota(
                    name: name,
                    remain: remain,
                    display: "\(remain)%",
                    money: nil,
                    unit: nil,
                    resetAt: resetFromISO(window["resetsAt"])
                ))
            }

        default:
            throw QuotaError.parse("未支持的 tokenplan 供应商：\(provider.type)")
        }

        if tiers.isEmpty {
            throw QuotaError.parse("未解析到额度字段")
        }
        return tiers
    }

    // MARK: - balance：钱包余额

    private func parseBalance(provider: ProviderConfig, root: Any) throws -> [TierQuota] {
        switch provider.type {
        case "deepseek":
            // 注意：欠费时接口仍返回 balance_infos（可能是负数），不能按 is_available 判空
            if let first = (JSONPath.value(root, "balance_infos") as? [[String: Any]])?.first {
                let currency = first["currency"] as? String ?? "CNY"
                let symbol = currency == "USD" ? "$" : "¥"
                let amount = doubleValue(first["total_balance"])
                let rawText = textValue(first["total_balance"])
                return [TierQuota(
                    name: "余额",
                    remain: -1,
                    display: symbol + rawText,
                    money: amount,
                    unit: nil,
                    resetAt: nil
                )]
            }
            if let available = JSONPath.value(root, "is_available") as? Bool, available == false {
                return [TierQuota(name: "余额", remain: -1, display: "不可用",
                                  money: nil, unit: nil, resetAt: nil)]
            }
            throw QuotaError.parse("未找到 balance_infos")

        case "siliconflow":
            guard let raw = JSONPath.firstExisting(root, ["data.totalBalance", "data.balance"]) else {
                throw QuotaError.parse("未找到 data.totalBalance")
            }
            return [TierQuota(
                name: "余额",
                remain: -1,
                display: "¥" + textValue(raw),
                money: doubleValue(raw),
                unit: nil,
                resetAt: nil
            )]

        case "openrouter":
            guard let totalCredits = JSONPath.double(root, "data.total_credits") else {
                throw QuotaError.parse("未找到 data.total_credits")
            }
            let used = JSONPath.double(root, "data.total_usage") ?? 0
            let remain = totalCredits - used
            return [TierQuota(
                name: "余额",
                remain: -1,
                display: String(format: "$%.2f / $%.2f", remain, totalCredits),
                money: remain,
                unit: nil,
                resetAt: nil
            )]

        default:
            // 阶跃星辰等：容错扫描常见余额字段
            guard let raw = JSONPath.firstExisting(root, [
                "data.balance", "balance", "data.total_balance",
                "data.totalBalance", "data.available_balance"
            ]) else {
                throw QuotaError.parse("未识别的余额字段，可改用「自定义」模板")
            }
            return [TierQuota(
                name: "余额",
                remain: -1,
                display: "¥" + textValue(raw),
                money: doubleValue(raw),
                unit: nil,
                resetAt: nil
            )]
        }
    }

    // MARK: - official：Claude / Codex（读本机 OAuth 凭据，接口返回使用百分比）

    private func parseOfficial(provider: ProviderConfig, root: Any) throws -> [TierQuota] {
        var tiers: [TierQuota] = []

        if provider.type == "claude" {
            let windows: [(String, String)] = [
                ("five_hour", "5小时"),
                ("seven_day", "7天"),
                ("seven_day_opus", "7天 Opus")
            ]
            for (key, name) in windows {
                guard let window = JSONPath.value(root, key) as? [String: Any] else { continue }
                let used = intValue(window["utilization"])
                let remain = 100 - used
                tiers.append(TierQuota(
                    name: name,
                    remain: remain,
                    display: "\(remain)%",
                    money: nil,
                    unit: nil,
                    resetAt: resetFromISO(window["resets_at"])
                ))
            }
        } else {
            let windows: [(String, String)] = [
                ("primary_window", "5小时"),
                ("secondary_window", "7天")
            ]
            for (key, name) in windows {
                guard let window = JSONPath.value(root, "rate_limit.\(key)") as? [String: Any] else { continue }
                let used = intValue(window["used_percent"])
                let remain = 100 - used
                tiers.append(TierQuota(
                    name: name,
                    remain: remain,
                    display: "\(remain)%",
                    money: nil,
                    unit: nil,
                    resetAt: resetFromSeconds(window["reset_at"])
                ))
            }
        }

        if tiers.isEmpty {
            throw QuotaError.parse("响应里没有可识别的额度窗口")
        }
        return tiers
    }

    // MARK: - general / newapi / custom

    private func parseGeneral(root: Any) throws -> [TierQuota] {
        if let raw = JSONPath.firstExisting(root, [
            "balance", "data.balance", "total_balance", "data.total_balance"
        ]) {
            let amount = doubleValue(raw)
            let unit = JSONPath.string(root, "unit") ?? "USD"
            return [TierQuota(
                name: "余额",
                remain: -1,
                display: String(format: "%.2f %@", amount, unit),
                money: amount,
                unit: nil,
                resetAt: nil
            )]
        }
        if let active = JSONPath.value(root, "is_active") as? Bool, active == false {
            return [TierQuota(name: "余额", remain: -1, display: "账户不可用",
                              money: nil, unit: nil, resetAt: nil)]
        }
        throw QuotaError.parse("响应里找不到 balance 字段，可改用「自定义」模板指定路径")
    }

    private func parseNewAPI(root: Any) throws -> [TierQuota] {
        guard let success = JSONPath.value(root, "success") as? Bool, success == true,
              JSONPath.value(root, "data") != nil else {
            let message = JSONPath.string(root, "message") ?? "未登录或 Access Token 无效"
            throw QuotaError.parse("接口返回：" + message)
        }
        let quota = JSONPath.double(root, "data.quota") ?? 0
        let used = JSONPath.double(root, "data.used_quota") ?? 0
        let remainUSD = quota / 500000.0
        let usedUSD = used / 500000.0
        let totalUSD = remainUSD + usedUSD
        let plan = JSONPath.string(root, "data.group") ?? "默认套餐"
        return [TierQuota(
            name: plan,
            remain: -1,
            display: String(format: "$%.2f / $%.2f", remainUSD, totalUSD),
            money: remainUSD,
            unit: nil,
            resetAt: nil
        )]
    }

    private func parseCustom(provider: ProviderConfig, root: Any) throws -> [TierQuota] {
        guard !provider.extractor.isEmpty else {
            throw QuotaError.parse("自定义类型需要填「提取路径」")
        }
        guard let raw = JSONPath.value(root, provider.extractor) else {
            throw QuotaError.parse("路径 \(provider.extractor) 取不到值")
        }
        guard let number = Self.toDouble(raw) else {
            throw QuotaError.parse("路径 \(provider.extractor) 不是数字：\(textValue(raw))")
        }

        let unit = provider.unit
        let isPercent = unit.isEmpty || unit == "%" || unit.lowercased() == "percent"
        if isPercent {
            let remain = max(0, min(100, Int(number.rounded())))
            return [TierQuota(name: "额度", remain: remain, display: "\(remain)%",
                              money: nil, unit: nil, resetAt: nil)]
        }
        let symbol: String
        switch unit.uppercased() {
        case "CNY", "RMB", "¥": symbol = "¥"
        case "USD", "$": symbol = "$"
        default: symbol = unit + " "
        }
        let text = String(format: "%.2f", number)
        return [TierQuota(
            name: "余额",
            remain: -1,
            display: symbol + text,
            money: number,
            unit: unit.lowercased() == "credits" ? "credits" : nil,
            resetAt: nil
        )]
    }

    // MARK: - 小工具

    static func toDouble(_ raw: Any) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? Bool { return value ? 1 : 0 }
        if let value = raw as? String { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }

    private func doubleValue(_ raw: Any?) -> Double {
        guard let raw = raw else { return 0 }
        return Self.toDouble(raw) ?? 0
    }

    private func intValue(_ raw: Any?) -> Int {
        guard let raw = raw else { return 0 }
        guard let value = Self.toDouble(raw) else { return 0 }
        return Int(value.rounded())
    }

    private func textValue(_ raw: Any?) -> String {
        guard let raw = raw else { return "" }
        if let text = raw as? String { return text }
        if let value = raw as? Double {
            return value == value.rounded() ? String(format: "%.0f", value) : String(value)
        }
        if let value = raw as? Int { return String(value) }
        return ""
    }

    private func resetFromMilliseconds(_ raw: Any?) -> String? {
        guard let raw = raw, let ms = Self.toDouble(raw), ms > 0 else { return nil }
        return isoText(Date(timeIntervalSince1970: ms / 1000.0))
    }

    private func resetFromSeconds(_ raw: Any?) -> String? {
        guard let raw = raw, let sec = Self.toDouble(raw), sec > 0 else { return nil }
        return isoText(Date(timeIntervalSince1970: sec))
    }

    private func resetFromISO(_ raw: Any?) -> String? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return isoText(date) }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return isoText(date) }
        return nil
    }

    private func isoText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
