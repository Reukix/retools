import Foundation
import CoreFoundation
import RetoolsNative

struct CertificatePermission: Identifiable, Sendable {
    let id: String
    let title: String
    let value: String
    let enabled: Bool?
    static func parse(profile: Data) throws -> [CertificatePermission] {
        let payload = try RTNative.profilePayload(profile)
        let plist = try PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any]
        return entries(plist?["Entitlements"] as? [String: Any] ?? [:])
    }
    static func entries(_ entitlements: [String: Any]) -> [CertificatePermission] {
        entitlements.keys.sorted().map { key in
            let value = entitlements[key]!
            let number = value as? NSNumber
            let boolean = number.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
            return CertificatePermission(id: key, title: names[key] ?? key, value: display(value), enabled: boolean)
        }
    }
    private static func display(_ value: Any) -> String {
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "允许（true）" : "不允许（false）" }
        if let text = value as? String { return text }
        if let data = value as? Data { return data.base64EncodedString() }
        if let array = value as? [String] { return array.joined(separator: "\n") }
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) { return String(decoding: data, as: UTF8.self) }
        return String(describing: value)
    }
    private static let names = [
        "application-identifier": "应用签名身份", "com.apple.developer.team-identifier": "开发者团队",
        "keychain-access-groups": "钥匙串访问组", "com.apple.security.application-groups": "App Groups 共享容器",
        "aps-environment": "推送通知环境", "get-task-allow": "调试与任务访问",
        "com.apple.developer.networking.networkextension": "网络扩展", "com.apple.developer.networking.vpn.api": "VPN 配置",
        "com.apple.developer.networking.multicast": "多播网络", "com.apple.developer.associated-domains": "关联域名",
        "com.apple.developer.icloud-container-identifiers": "iCloud 容器", "com.apple.developer.icloud-services": "iCloud 服务",
        "com.apple.developer.ubiquity-kvstore-identifier": "iCloud 键值存储", "com.apple.developer.ubiquity-container-identifiers": "iCloud 文档容器",
        "com.apple.developer.healthkit": "健康数据", "com.apple.developer.homekit": "家庭控制",
        "com.apple.developer.applesignin": "通过 Apple 登录", "com.apple.developer.in-app-payments": "Apple Pay",
        "com.apple.developer.siri": "Siri", "com.apple.developer.nfc.readersession.formats": "NFC 读取",
        "com.apple.developer.kernel.increased-memory-limit": "提高内存限制", "com.apple.developer.kernel.extended-virtual-addressing": "扩展虚拟地址空间",
        "com.apple.security.cs.allow-jit": "JIT 代码权限", "com.apple.security.cs.disable-library-validation": "关闭动态库验证",
        "beta-reports-active": "Beta 报告", "com.apple.developer.game-center": "Game Center"
    ]
}
