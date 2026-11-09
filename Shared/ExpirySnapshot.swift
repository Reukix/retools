import Foundation
import Security

/// 主程序写入、桌面小组件读取的有效期快照。
/// 小组件扩展没有 App Group 共享容器，两者通过同一个钥匙串分组（`<团队前缀>.com.reukix.retools.shared`）交换这份数据；
/// 钥匙串分组只需团队前缀，开发与免费账号的描述文件都允许，不必额外注册 App Group。
struct ExpirySnapshot: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var expiry: Date?
        var autoRenew: Bool
        /// Retools 自身。
        var isHost: Bool
    }
    var items: [Item]
    var updatedAt: Date
    var lastRenewal: String?

    static let empty = ExpirySnapshot(items: [], updatedAt: .distantPast, lastRenewal: nil)

    /// 剩余整天数（向上取整，与应用内的天数显示一致）。
    static func daysLeft(_ expiry: Date, now: Date = Date()) -> Int { Int(ceil(expiry.timeIntervalSince(now) / 86_400)) }
}

enum ExpirySnapshotStore {
    private static let service = "dev.retools.expiry-snapshot"
    private static let account = "snapshot"

    static func load() -> ExpirySnapshot? {
        guard let group = SharedKeychainGroup.identifier else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecAttrAccessGroup as String: group, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ExpirySnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: ExpirySnapshot) -> Bool {
        guard let group = SharedKeychainGroup.identifier, let data = try? JSONEncoder().encode(snapshot) else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecAttrAccessGroup as String: group]
        // 锁屏后小组件仍需读取，因此使用「首次解锁后可用」。
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}

/// 共享钥匙串分组的完整名称。团队前缀在运行时从本进程默认分组读出，
/// 这样 Retools 用其他团队续签自身后（钥匙串分组前缀随之改变）仍然正确。
enum SharedKeychainGroup {
    static let suffix = "com.reukix.retools.shared"
    static let identifier: String? = {
        guard let prefix = teamPrefix() else { return nil }
        return prefix + "." + suffix
    }()

    private static func teamPrefix() -> String? {
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.retools.keychain-probe",
                                    kSecAttrAccount as String: "probe"]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(probe.merging([kSecReturnAttributes as String: true]) { $1 } as CFDictionary, &result)
        if status == errSecItemNotFound {
            status = SecItemAdd(probe.merging([kSecReturnAttributes as String: true, kSecValueData as String: Data(),
                                               kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]) { $1 } as CFDictionary, &result)
        }
        guard status == errSecSuccess, let attributes = result as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String,
              let prefix = group.split(separator: ".").first, !prefix.isEmpty else { return nil }
        return String(prefix)
    }
}
