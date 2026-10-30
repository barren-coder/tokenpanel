import Foundation

/// 配置读写。路径与 Windows 版分离（不敢直接覆盖 %APPDATA% 那份），
/// 但 JSON 结构保持兼容，方便以后双向同步。
final class ConfigStore {
    private(set) var config = AppConfig()
    private let directory: URL

    var configURL: URL { directory.appendingPathComponent("config.json") }
    var stateURL: URL { directory.appendingPathComponent("state.json") }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        directory = base.appendingPathComponent("TokenPanel", isDirectory: true)
    }

    func ensureDirectory() {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func load() {
        ensureDirectory()
        guard let data = try? Data(contentsOf: configURL) else {
            save()
            return
        }
        do {
            config = try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            NSLog("TokenPanel: 配置解析失败，使用默认值 - \(error.localizedDescription)")
            config = AppConfig()
        }
    }

    func save() {
        ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            NSLog("TokenPanel: 配置写入失败 - \(error.localizedDescription)")
        }
    }

    func update(_ mutate: (inout AppConfig) -> Void) {
        mutate(&config)
        save()
    }
}
