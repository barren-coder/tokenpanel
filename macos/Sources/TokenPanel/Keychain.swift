import Foundation
import Security

/// API Key 存 Keychain，替代 Windows 的 DPAPI。
///
/// 注意：未签名 / ad-hoc 签名的 app 每次重新编译签名指纹都会变，
/// macOS 可能弹一次「TokenPanel 想要访问钥匙串」——点「始终允许」即可。
final class Keychain {
    static let shared = Keychain()
    private let service = "com.barrencoder.tokenpanel"

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    func set(_ value: String, for account: String) -> Bool {
        guard !account.isEmpty, let data = value.data(using: .utf8) else { return false }
        SecItemDelete(baseQuery(account) as CFDictionary)
        var attrs = baseQuery(account)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    func get(_ account: String) -> String? {
        guard !account.isEmpty else { return nil }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    @discardableResult
    func delete(_ account: String) -> Bool {
        guard !account.isEmpty else { return false }
        return SecItemDelete(baseQuery(account) as CFDictionary) == errSecSuccess
    }

    func has(_ account: String) -> Bool {
        get(account) != nil
    }
}
