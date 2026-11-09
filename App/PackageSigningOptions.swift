import Foundation

enum SigningExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case ipa, tipa
    var id: String { rawValue }
}
enum SigningGameMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, enabled, disabled
    var id: String { rawValue }
    var title: String { switch self { case .original: return "保持原始设置"; case .enabled: return "开启"; case .disabled: return "关闭" } }
}

struct PackageSigningOptions: Codable, Hashable, Sendable {
    var displayName = ""
    var bundleID = ""
    var version = ""
    var note = ""
    var iconFile: String?
    var outputName = ""
    var format: SigningExportFormat = .ipa
    var fileSharing = true
    var removeURLSchemes = false
    var repairWhiteIcon = false
    var repairDarkIcon = true
    var directInjection = true
    var removeEmbedded = false
    var removeWatch = true
    var newPluginsFirst = false
    var gameMode: SigningGameMode = .original
    var minimumOS = ""
    var customEntitlements: Data?
    var identityID: UUID?
    var identityFingerprint: String?
    var identityScopeFingerprint: String?

    mutating func selectIdentity(_ identity: SigningIdentity?) {
        identityID = identity?.id; identityFingerprint = identity?.fingerprint; identityScopeFingerprint = identity?.profileScopeFingerprint
    }
    func selectedIdentity(in identities: [SigningIdentity]) -> SigningIdentity? {
        guard let identityID else { return nil }
        if let exact = identities.first(where: { $0.id == identityID }) { return exact }
        guard let identityFingerprint, let identityScopeFingerprint else { return nil }
        return identities.first { $0.fingerprint == identityFingerprint && $0.profileScopeFingerprint == identityScopeFingerprint }
    }

    func name(for package: AppPackage) -> String { displayName.isEmpty ? package.name : displayName }
    func identifier(for package: AppPackage) -> String { bundleID.isEmpty ? package.bundleID : bundleID }
    func appVersion(for package: AppPackage) -> String { version.isEmpty ? package.version : version }
    func fileName(for package: AppPackage) throws -> String {
        let rawDefault = "\(name(for: package))_\(appVersion(for: package))-signed"
        let safeDefault = rawDefault.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\"))).joined(separator: "-")
        var shortened = ""
        for character in safeDefault { if shortened.utf8.count + character.utf8.count > 220 { break }; shortened.append(character) }
        let proposed = outputName.isEmpty ? (shortened.isEmpty ? "App-signed" : shortened) : outputName
        let stem = ["ipa", "tipa"].contains((proposed as NSString).pathExtension.lowercased()) ? (proposed as NSString).deletingPathExtension : proposed
        guard !stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, stem != ".", stem != "..",
              !stem.contains("/"), !stem.contains("\\"), !stem.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              stem.utf8.count <= 230 else { throw WorkspaceFailure("输出文件名无效，请勿包含路径、换行或过长的名称。") }
        return stem + "." + format.rawValue
    }
    func validate(for package: AppPackage) throws {
        guard identifier(for: package).range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else { throw WorkspaceFailure("请填写有效的 Bundle ID。") }
        guard displayName.count <= 120, version.count <= 40, note.count <= 2000 else { throw WorkspaceFailure("应用名称、版本或备注过长。") }
        if !version.isEmpty, version.range(of: "^[0-9]+(\\.[0-9]+){0,2}$", options: .regularExpression) == nil { throw WorkspaceFailure("应用版本请使用数字格式，例如 13.1.2。") }
        if repairWhiteIcon && repairDarkIcon { throw WorkspaceFailure("白色图标重建与深色资源修复请选择一种。") }
        if let iconFile { guard iconFile == (iconFile as NSString).lastPathComponent, iconFile.hasSuffix(".png") else { throw WorkspaceFailure("自定义图标路径无效。") } }
        _ = try fileName(for: package)
        if !minimumOS.isEmpty { _ = try Self.versionNumber(minimumOS) }
        if let customEntitlements { _ = try Self.entitlements(customEntitlements) }
    }
    static func entitlements(_ data: Data) throws -> [String: Any] {
        guard data.count <= 262144, let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw WorkspaceFailure("Entitlements 必须是小于 256 KB 的 plist 字典。") }
        return result
    }
    static func versionNumber(_ value: String) throws -> UInt32 {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let values = parts.compactMap { UInt32($0) }
        guard (1...3).contains(parts.count), values.count == parts.count, let first = values.first, (1...65535).contains(first),
              values.dropFirst().allSatisfy({ $0 <= 255 }) else { throw WorkspaceFailure("系统版本格式无效，例如 17.0 或 18.2.1。") }
        return values[0] << 16 | (values.count > 1 ? values[1] << 8 : 0) | (values.count > 2 ? values[2] : 0)
    }
}

/// 用 Apple ID 签名别人的应用时使用的 Bundle ID，规则与 SideStore / AltStore 相同。
///
/// App ID 在所有开发者团队之间全局唯一，原作者已注册的标识（如 app.swiftgram.ios）别的团队无法注册，
/// Apple 会返回 9401。所以默认改成「原 Bundle ID.团队 ID」；之前已用带本团队 ID 的标识签过的继续沿用，
/// 续签时不会变；用户自己填写的 Bundle ID 保持不变。
enum AppleIDBundleIdentifier {
    static func resolve(original: String, team: String, custom: String = "", previous: String? = nil) -> String {
        guard custom.isEmpty else { return custom }
        guard !team.isEmpty else { return original }
        if let previous, previous.hasPrefix(original + "."), previous.hasSuffix("." + team) { return previous }
        if original.hasSuffix("." + team) { return original }
        return original + "." + team
    }
}

/// Apple ID 签名时一个 bundle（主应用或扩展）向开发者网站申请的内容。
struct AppleBundleRequest: Codable, Hashable, Sendable {
    let bundleID: String
    let name: String
    /// 原可执行文件声明的授权键，用来决定要开启的功能。
    let entitlementKeys: [String]
    /// 原应用声明的 App Group；会以「分组.团队 ID」注册。
    let appGroups: [String]
    enum CodingKeys: String, CodingKey { case bundleID = "bundle_id", name, entitlementKeys = "entitlement_keys", appGroups = "app_groups" }
}

/// Apple ID 为一个应用（含扩展）取得的签名材料。
struct AppleAppCredentials: Sendable {
    let p12: Data
    let password: String
    /// 键为 bundle ID。
    let profiles: [String: Data]
    /// 每个 bundle 实际分配到的 App Group（已加团队 ID）。
    let appGroups: [String: [String]]
    let teamType: String
    /// 可用 App ID 不足时只保留主应用。
    let extensionsRemoved: Bool
}

/// Apple ID 签名的准备结果：已按项目配置改好的签名副本（位于临时目录）与各 bundle 的申请内容。
struct AppleSigningPlan: Sendable {
    let packageID: UUID
    let bundleID: String
    let options: PackageSigningOptions
    let persistOptions: Bool
    let temp: URL
    let app: URL
    /// 主应用在前。
    let bundles: [AppleBundleRequest]
    /// 原可执行文件的授权（二进制 plist），键为 bundle ID。
    let entitlements: [String: Data]
    /// bundle 在应用中的相对路径，主应用为空字符串。
    let folders: [String: String]
}

/// 开发者团队中的一个 App ID。
struct AppleAppID: Identifiable, Hashable, Sendable {
    let identifier: String
    let name: String
    let expiresAt: Date?
    var id: String { identifier }
}

struct AppleAppIDList: Sendable {
    let appIDs: [AppleAppID]
    /// 团队允许同时持有的 App ID 数量（免费账号为 10）；接口未返回时为 nil。
    let maximum: Int?
    /// 还能注册的数量。
    let available: Int?
    let teamType: String
}

/// 团队中的一张 iOS 开发证书。
struct AppleCertificate: Identifiable, Hashable, Sendable {
    let serialNumber: String
    let name: String
    let machineName: String?
    let expiresAt: Date?
    /// 证书本身（DER），用于与本机应用的签名证书比对。
    let content: Data?
    var id: String { serialNumber }
    var fingerprint: String? { content.map(ProfileRefresh.fingerprint) }
}

struct AppleCertificateList: Sendable {
    let certificates: [AppleCertificate]
    /// 团队允许同时持有的开发证书数量；接口未返回时为 nil。
    let maximum: Int?
    let teamType: String
}
