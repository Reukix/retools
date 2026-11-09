import Foundation
import Security

enum SecureStore {
    private static let service = "com.reukix.retools.signing"
    static func saveData(_ data: Data, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.retools.ios.accounts", kSecAttrAccount as String: key]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let status = update == errSecItemNotFound ? SecItemAdd(query.merging(attributes) { _, b in b } as CFDictionary, nil) : update
        guard status == errSecSuccess else { throw WorkspaceFailure("无法保存设备钥匙串（\(status)）。") }
    }
    static func data(key: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.retools.ios.accounts", kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw WorkspaceFailure("无法读取设备钥匙串（\(status)）。") }
        return result as? Data
    }
    static func deleteData(key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.retools.ios.accounts", kSecAttrAccount as String: key]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WorkspaceFailure("无法移除设备凭据（\(status)）。") }
    }
    static func save(password: String, id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let status: OSStatus
        if update == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, b in b } as CFDictionary, nil) }
        else { status = update }
        guard status == errSecSuccess else { throw WorkspaceFailure("无法把证书密码保存到钥匙串（\(status)）。") }
    }
    static func password(id: UUID) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let result = String(data: data, encoding: .utf8) else { throw WorkspaceFailure("无法读取证书密码，请重新导入证书。") }
        return result
    }
    static func delete(id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WorkspaceFailure("无法删除钥匙串中的证书密码（\(status)）。") }
    }
}
