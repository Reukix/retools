import Foundation
import SwiftUI
import AppleSigningFFI

struct DeveloperTeam: Codable, Identifiable, Sendable { let id: String; let name: String; let type: String }

final class TwoFactorBroker: ObservableObject, @unchecked Sendable {
    static let shared = TwoFactorBroker()
    @Published var prompt: TwoFactorPrompt?
    private let lock = NSLock()
    private var pending: (DispatchSemaphore, String)?
    struct TwoFactorPrompt: Identifiable {
        let id = UUID()
        let text: String
        let numbers: [(id: Int, number: String)]
        let requiresMethodSelection: Bool
        let isSMS: Bool
        let selectedNumberID: Int?
        init(json: String) {
            let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            requiresMethodSelection = object["unknown"] as? Bool ?? false
            isSMS = object["sms"] as? Bool ?? false
            selectedNumberID = object["selectedNumberId"] as? Int
            numbers = (object["numbers"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? Int else { return nil }
                return (id, $0["numberWithDialCode"] as? String ?? "受信任号码")
            }
            text = (object["lastError"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (requiresMethodSelection ? "请选择接收 Apple 验证码的方式。" : (isSMS ? "输入 Apple 发送到受信任手机的短信验证码。" : "输入 Apple 发送到受信任设备的验证码。"))
        }
    }
    func request(_ json: String) -> String {
        let prompt = TwoFactorPrompt(json: json)
        let semaphore = DispatchSemaphore(value: 0)
        lock.withLock { pending = (semaphore, "{\"action\":\"cancel\"}") }
        DispatchQueue.main.async { self.prompt = prompt }
        _ = semaphore.wait(timeout: .now() + 180)
        let answer = lock.withLock { let answer = pending?.1 ?? "{\"action\":\"cancel\"}"; pending = nil; return answer }
        DispatchQueue.main.async { if self.prompt?.id == prompt.id { self.prompt = nil } }
        return answer
    }
    func answer(action: String, code: String? = nil, id: Int? = nil) {
        var value: [String: Any] = ["action": action]
        if let code { value["code"] = code }; if let id { value["id"] = id }
        let json = String(data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), encoding: .utf8) ?? "{}"
        lock.withLock { pending?.1 = json; pending?.0.signal() }
    }
}

private let appleTwoFactorCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? = { request, _ in
    guard let request else { return nil }
    return strdup(TwoFactorBroker.shared.request(String(cString: request)))
}

actor AppleAccountService {
    private func request(email: String, anisetteURL: String) throws -> [String: Any] {
        let stateData = try SecureStore.data(key: "apple.state.\(email.lowercased())") ?? Data("{}".utf8)
        let endpoint = try AppleLoginConfiguration.validatedAnisetteURL(anisetteURL)
        let state = try JSONDecoder().decode([String: String].self, from: stateData)
        return ["email": email.lowercased(), "anisette_url": endpoint, "state": AppleLoginConfiguration.stateForEndpoint(state, endpoint: endpoint)]
    }
    private func decode(_ pointer: UnsafeMutablePointer<CChar>?, email: String?) throws -> [String: Any] {
        guard let pointer else { throw WorkspaceFailure("Apple ID 签名引擎没有返回结果。") }
        defer { rt_apple_string_free(pointer) }
        let bytes = Data(String(cString: pointer).utf8)
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw WorkspaceFailure("Apple ID 签名引擎返回格式无效。") }
        if let state = value["state"], let email { try SecureStore.saveData(JSONSerialization.data(withJSONObject: state), key: "apple.state.\(email.lowercased())") }
        guard value["ok"] as? Bool == true else { throw AppleAccountFailure(detail: value["error"] as? String ?? "Apple ID 操作失败。") }
        return value
    }
    /// Checks public Anisette client metadata and Apple's service directory; sends no account credentials.
    struct ServiceInfo: Sendable { let clientInfo: String; let userAgent: String }
    func checkService(anisetteURL: String) throws -> ServiceInfo {
        let request: [String: Any] = ["email": "connection-check@retools.invalid", "anisette_url": try AppleLoginConfiguration.validatedAnisetteURL(anisetteURL), "state": [:]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let result = try json.withCString { try decode(rt_apple_check_service($0), email: nil) }
        return ServiceInfo(clientInfo: result["client_info"] as? String ?? "", userAgent: result["user_agent"] as? String ?? "")
    }
    func login(email: String, password: String, anisetteURL: String) throws -> [DeveloperTeam] {
        var request = try request(email: email, anisetteURL: anisetteURL); request["password"] = password
        let json = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        let result = try json.withCString { try decode(rt_apple_login($0, appleTwoFactorCallback, nil), email: email) }
        guard let teams = result["teams"] else { throw WorkspaceFailure("没有可用的开发者团队。") }
        return try JSONDecoder().decode([DeveloperTeam].self, from: JSONSerialization.data(withJSONObject: teams))
    }
    struct Credentials: Sendable { let p12: Data; let profile: Data; let password: String }
    func credentials(email: String, anisetteURL: String, teamID: String, udid: String, bundleID: String, appName: String, provisioningBundleID: String? = nil) throws -> Credentials {
        var request = try request(email: email, anisetteURL: anisetteURL)
        let password = UUID().uuidString
        request.merge(["team_id":teamID,"udid":udid,"bundle_id":bundleID,"app_name":appName,"p12_password":password]) { _, b in b }
        if let provisioningBundleID { request["provisioning_bundle_id"] = provisioningBundleID }
        let json = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        let result = try json.withCString { try decode(rt_apple_profile($0), email: email) }
        guard let p12String = result["p12"] as? String, let profileString = result["profile"] as? String,
              let p12 = Data(base64Encoded: p12String), let profile = Data(base64Encoded: profileString) else { throw WorkspaceFailure("Apple 未返回有效的签名凭据。") }
        return Credentials(p12: p12, profile: profile, password: password)
    }
    /// 主应用与扩展的描述文件（SideStore 流程：注册 App ID、开启功能、注册并分配 App Group）。
    func appCredentials(email: String, anisetteURL: String, teamID: String, udid: String, bundles: [AppleBundleRequest]) throws -> AppleAppCredentials {
        var request = try request(email: email, anisetteURL: anisetteURL)
        let password = UUID().uuidString
        let items = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bundles))
        request.merge(["team_id": teamID, "udid": udid, "p12_password": password, "bundles": items]) { _, b in b }
        let json = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        let result = try json.withCString { try decode(rt_apple_app_profiles($0), email: email) }
        guard let p12String = result["p12"] as? String, let p12 = Data(base64Encoded: p12String),
              let entries = result["profiles"] as? [[String: Any]], !entries.isEmpty else { throw WorkspaceFailure("Apple 未返回有效的签名凭据。") }
        var profiles: [String: Data] = [:], groups: [String: [String]] = [:]
        for entry in entries {
            guard let id = entry["bundle_id"] as? String, let text = entry["profile"] as? String, let data = Data(base64Encoded: text) else { throw WorkspaceFailure("Apple 返回的描述文件无效。") }
            profiles[id] = data; groups[id] = entry["app_groups"] as? [String] ?? []
        }
        return AppleAppCredentials(p12: p12, password: password, profiles: profiles, appGroups: groups,
                                   teamType: result["team_type"] as? String ?? "unknown", extensionsRemoved: result["extensions_removed"] as? Bool ?? false)
    }
    /// 仅使用 Retools 内调用方选择的账号；不读取 Xcode 账号或本机签名身份。
    func hostCredentials(email: String, anisetteURL: String, teamID: String, udid: String, bundle: URL,
                         includeAppGroup: Bool) throws -> [String: Credentials] {
        let requests = try HostAppGroup.signingRequests(in: bundle, includeAppGroup: includeAppGroup)
        var materials: [String: Credentials] = [:]
        if includeAppGroup {
            let result = try appCredentials(email: email, anisetteURL: anisetteURL, teamID: teamID, udid: udid, bundles: requests)
            for item in requests {
                guard let profile = result.profiles[item.bundleID] else {
                    throw WorkspaceFailure("Apple 未返回 \(item.name) 的描述文件。请检查可用 App ID 数量，未生成不完整的安装包。")
                }
                materials[item.bundleID] = Credentials(p12: result.p12, profile: profile, password: result.password)
            }
        } else {
            let extensions = (try? FileManager.default.contentsOfDirectory(at: bundle.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil)) ?? []
            for (index, item) in requests.enumerated() {
                let target: URL? = index == 0 ? bundle : extensions
                    .first { (try? ArchiveService.metadata(at: $0)["CFBundleIdentifier"] as? String) == item.bundleID }
                let portalID = target.flatMap { DevelopmentSigningManifest.provisioningIdentifier(in: $0, team: teamID) }
                materials[item.bundleID] = try credentials(email: email, anisetteURL: anisetteURL, teamID: teamID, udid: udid,
                    bundleID: item.bundleID, appName: item.name, provisioningBundleID: portalID)
            }
        }
        for (index, item) in requests.enumerated() {
            guard let material = materials[item.bundleID] else { throw WorkspaceFailure("缺少自身签名配置。") }
            try HostAppGroup.validateProfile(material.profile, bundleID: item.bundleID, teamID: teamID, requireAppGroup: includeAppGroup && index == 0)
        }
        return materials
    }
    /// 团队已注册的 App ID、到期时间与剩余可注册数量（与 AltStore 的 App ID 页相同）。
    func appIDs(email: String, anisetteURL: String, teamID: String) throws -> AppleAppIDList {
        var request = try request(email: email, anisetteURL: anisetteURL)
        request["team_id"] = teamID
        let json = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        let result = try json.withCString { try decode(rt_apple_app_ids($0), email: email) }
        let items = (result["app_ids"] as? [[String: Any]] ?? []).compactMap { item -> AppleAppID? in
            guard let identifier = item["identifier"] as? String else { return nil }
            let expires = (item["expires"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return AppleAppID(identifier: identifier, name: item["name"] as? String ?? identifier, expiresAt: expires)
        }
        return AppleAppIDList(appIDs: items.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) },
                              maximum: (result["max"] as? NSNumber)?.intValue, available: (result["available"] as? NSNumber)?.intValue,
                              teamType: result["team_type"] as? String ?? "unknown")
    }
    /// 团队的 iOS 开发证书（只读）。
    func certificates(email: String, anisetteURL: String, teamID: String) throws -> AppleCertificateList {
        var request = try request(email: email, anisetteURL: anisetteURL); request["team_id"] = teamID
        let json = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        let result = try json.withCString { try decode(rt_apple_certificates($0), email: email) }
        let items = (result["certificates"] as? [[String: Any]] ?? []).compactMap { item -> AppleCertificate? in
            guard let serial = item["serial_number"] as? String else { return nil }
            return AppleCertificate(serialNumber: serial, name: item["name"] as? String ?? "开发证书", machineName: item["machine_name"] as? String,
                                    expiresAt: (item["expires"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                                    content: (item["content"] as? String).flatMap { Data(base64Encoded: $0) })
        }
        return AppleCertificateList(certificates: items, maximum: (result["max"] as? NSNumber)?.intValue, teamType: result["team_type"] as? String ?? "unknown")
    }
    /// 撤销开发证书。用它签名的应用会立即无法打开。
    func revokeCertificate(email: String, anisetteURL: String, teamID: String, serialNumber: String) throws {
        var request = try request(email: email, anisetteURL: anisetteURL); request["team_id"] = teamID; request["serial_number"] = serialNumber
        let json = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        _ = try json.withCString { try decode(rt_apple_revoke_certificate($0), email: email) }
    }
    func forget(email: String) throws { try SecureStore.deleteData(key: "apple.state.\(email.lowercased())") }
    func resetAnisette(email: String) throws {
        let key = "apple.state.\(email.lowercased())"
        guard let data = try SecureStore.data(key: key) else { return }
        var state = try JSONDecoder().decode([String: String].self, from: data)
        for key in ["anisette_state", "retools_anisette_endpoint", "retools_auth"] { state.removeValue(forKey: key) }
        try SecureStore.saveData(JSONEncoder().encode(state), key: key)
    }
}
