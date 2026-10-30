import Foundation

/// 定位 node 可执行文件。macOS 上常见位置：Homebrew（arm64/x86）、系统包、nvm。
enum NodeLocator {
    static func find() -> String? {
        let direct = [
            "/opt/homebrew/bin/node",      // Apple Silicon Homebrew
            "/usr/local/bin/node",         // Intel Homebrew
            "/usr/bin/node",
            "/opt/local/bin/node"          // MacPorts
        ]
        for path in direct where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // nvm：目录下按版本号倒序取第一个可用的
        let nvmRoot = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for version in versions.sorted(by: >) {
                let path = nvmRoot + "/" + version + "/bin/node"
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }
}

/// WorkBuddy 积分查询：调 lib/wb/wb_query.js（无头 Chrome 页面内请求，绕 TLS 指纹墙）。
/// 与 Windows 版共用同一份脚本，只依赖 node 与 Chrome，不依赖任何平台 API。
final class WorkBuddyService {
    static let shared = WorkBuddyService()

    private let summaryKey = "/billing/meter/get-user-resource-summary"
    private let checkinKey = "/billing/meter/checkin-status"

    func query(config: AppConfig) async throws -> [TierQuota] {
        guard let node = NodeLocator.find() else {
            throw QuotaError.parse("未找到 node，请先安装：brew install node")
        }
        let script = scriptURL()
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw QuotaError.parse("未找到 wb_query.js，请重新安装 TokenPanel")
        }

        let (status, output) = try await runProcess(
            node,
            arguments: [script.path, "--json"],
            timeout: TimeInterval(max(40, config.timeout * 2))
        )
        guard status == 0, !output.isEmpty else {
            throw QuotaError.parse("查询脚本退出码 \(status)，可能需要在设置里重新授权")
        }
        guard let data = output.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let root = any as? [String: Any] else {
            throw QuotaError.parse("查询输出不是 JSON")
        }

        guard let summary = root[summaryKey] as? [String: Any] else {
            throw QuotaError.parse("输出缺少积分汇总接口")
        }
        let code = (summary["status"] as? Int) ?? 0
        if code == 401 || code == 403 {
            throw QuotaError.auth(code)
        }
        guard code == 200 else {
            throw QuotaError.parse("积分汇总接口 HTTP \(code)")
        }
        guard let payload = decodeBody(summary["body"]) else {
            throw QuotaError.parse("积分汇总响应无 data 字段")
        }

        let credits = payload["TotalCredits"].flatMap { QuotaService.toDouble($0) } ?? 0
        let plan = (payload["SubscriptionPackageName"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "积分余额"

        var tiers: [TierQuota] = []
        tiers.append(TierQuota(
            name: plan,
            remain: -1,
            display: creditsText(credits) + " credits",
            money: credits,
            unit: "credits",
            resetAt: nil
        ))

        if let checkin = root[checkinKey] as? [String: Any],
           (checkin["status"] as? Int) == 200,
           let checkinPayload = decodeBody(checkin["body"]) {
            let active = (checkinPayload["active"] as? Bool) ?? false
            let checkedToday = (checkinPayload["today_checked_in"] as? Bool) ?? false
            let display: String
            if !active {
                display = "活动未开启"
            } else if checkedToday {
                display = "今日已签到"
            } else {
                display = "今日未签到"
            }
            tiers.append(TierQuota(
                name: "签到",
                remain: -1,
                display: display,
                money: nil,
                unit: nil,
                resetAt: nil
            ))
        }

        return tiers
    }

    // MARK: - 内部

    private func decodeBody(_ raw: Any?) -> [String: Any]? {
        guard let text = raw as? String,
              let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any],
              let payload = dict["data"] as? [String: Any] else { return nil }
        return payload
    }

    private func creditsText(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }

    private func scriptURL() -> URL {
        if let resource = Bundle.main.resourceURL {
            let bundled = resource.appendingPathComponent("wb/wb_query.js")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        // 开发态：从当前目录找
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("lib/wb/wb_query.js")
        return local
    }

    private func runProcess(_ executable: String, arguments: [String],
                            timeout: TimeInterval) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw QuotaError.parse("启动查询进程失败：" + error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if process.isRunning {
            process.terminate()
            throw QuotaError.network("WorkBuddy 查询超时（可能需要重新授权）")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
