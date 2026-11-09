import Foundation
import CryptoKit
import RetoolsNative

/// 像 AltStore/SideStore 一样只更新描述文件、不重装应用的可行性判断。
///
/// 应用的代码签名本身不会过期，过期的是描述文件。只要新描述文件
/// 1) 包含当前可执行文件实际使用的签名证书；
/// 2) 应用标识与可执行文件签名授权里的一致；
/// 3) 覆盖可执行文件签名授权中的每一项；
/// 系统就会用新描述文件继续认可这个应用，不必重签、重装，也就不会结束正在运行的进程。
/// 任一条件不满足都返回原因，调用方应退回整包重装。
enum ProfileRefresh {
    struct Profile {
        let uuid: String
        let expiry: Date
        let applicationIdentifier: String
        let entitlements: [String: Any]
        let certificates: [Data]
    }

    static func parse(_ data: Data) throws -> Profile {
        let payload = try RTNative.profilePayload(data)
        guard let plist = try PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any],
              let uuid = plist["UUID"] as? String, let expiry = plist["ExpirationDate"] as? Date,
              let entitlements = plist["Entitlements"] as? [String: Any],
              let appID = entitlements["application-identifier"] as? String,
              let certificates = plist["DeveloperCertificates"] as? [Data] else { throw WorkspaceFailure("描述文件内容不完整。") }
        return Profile(uuid: uuid, expiry: expiry, applicationIdentifier: appID, entitlements: entitlements, certificates: certificates)
    }

    /// 返回不能只更新描述文件的原因；nil 表示可以。
    static func blocker(profile: Profile, signingCertificate: Data?, signedEntitlements: [String: Any]?, currentExpiry: Date?, now: Date = Date()) -> String? {
        guard let signingCertificate else { return "无法读取当前签名证书" }
        guard profile.certificates.contains(signingCertificate) else { return "签名证书已更换" }
        guard let signedEntitlements, let signedAppID = signedEntitlements["application-identifier"] as? String else { return "无法读取当前签名授权" }
        guard signedAppID == profile.applicationIdentifier else { return "应用标识不一致（\(signedAppID) → \(profile.applicationIdentifier)）" }
        let missing = signedEntitlements.keys.filter { profile.entitlements[$0] == nil }.sorted()
        guard missing.isEmpty else { return "新描述文件缺少授权：" + missing.joined(separator: "、") }
        if let value = signedEntitlements[HostAppGroup.entitlement] {
            guard let signedGroups = value as? [String],
                  let allowedGroups = profile.entitlements[HostAppGroup.entitlement] as? [String],
                  Set(signedGroups).isSubset(of: Set(allowedGroups)) else { return "新描述文件未授权当前 App Group" }
        }
        guard profile.expiry > now else { return "新描述文件已过期" }
        // 有效期没有延长时整包重装也无法延长，只装描述文件至少不会打断使用，所以不作为阻止条件。
        _ = currentExpiry
        return nil
    }

    /// 针对已安装在本机的某个可执行文件做判断。
    static func blocker(profile: Profile, executable: URL, currentExpiry: Date?) -> String? {
        let certificate = try? RTNative.signingCertificate(ofExecutable: executable.path)
        let entitlements = (try? RTNative.entitlements(ofExecutable: executable.path)) as? [String: Any]
        return blocker(profile: profile, signingCertificate: certificate, signedEntitlements: entitlements, currentExpiry: currentExpiry)
    }

    static func fingerprint(_ certificate: Data) -> String { SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined() }

    /// 当前运行的 Retools 所用签名证书的指纹；进程内不会改变。
    static let runningCertificateFingerprint: String? = {
        guard let path = Bundle.main.executablePath, let certificate = try? RTNative.signingCertificate(ofExecutable: path) else { return nil }
        return fingerprint(certificate)
    }()
}
