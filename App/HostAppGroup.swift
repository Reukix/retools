import Foundation
import RetoolsNative

/// 文件工具专用组；应用库、凭据和容器数据仍保存在宿主的私有沙盒。
enum HostAppGroup {
    static let entitlement = "com.apple.security.application-groups"
    static let metadataKey = "RetoolsFileToolsAppGroup"
    static let baseIdentifier = "group.dev.retools.filetools"

    static func identifier(teamID: String) -> String { baseIdentifier + "." + teamID }

    static func identifier(in entitlements: [String: Any]) -> String? {
        guard let team = entitlements["com.apple.developer.team-identifier"] as? String, !team.isEmpty,
              let groups = entitlements[entitlement] as? [String] else { return nil }
        let expected = identifier(teamID: team)
        if groups.contains(expected) { return expected }
        // 手动签名也可以使用由同一描述文件授权的基础名称。
        return groups.contains(baseIdentifier) ? baseIdentifier : nil
    }

    static func readSignedIdentifier(in bundle: URL = Bundle.main.bundleURL) throws -> String? {
        guard let name = try ArchiveService.metadata(at: bundle)["CFBundleExecutable"] as? String else {
            throw WorkspaceFailure("找不到 Retools 的可执行文件。")
        }
        let entitlements = try RTNative.entitlements(ofExecutable: bundle.appendingPathComponent(name).path) as? [String: Any] ?? [:]
        return identifier(in: entitlements)
    }

    static func signedIdentifier(in bundle: URL = Bundle.main.bundleURL) -> String? { try? readSignedIdentifier(in: bundle) }

    static func signingRequests(in bundle: URL, includeAppGroup: Bool) throws -> [AppleBundleRequest] {
        let info = try ArchiveService.metadata(at: bundle)
        guard let mainID = info["CFBundleIdentifier"] as? String else { throw WorkspaceFailure("Retools 缺少 Bundle ID。") }
        var requests = [AppleBundleRequest(bundleID: mainID, name: "Retools",
            entitlementKeys: includeAppGroup ? ["get-task-allow", entitlement] : ["get-task-allow"],
            appGroups: includeAppGroup ? [baseIdentifier] : [])]
        let extensions = (try? FileManager.default.contentsOfDirectory(at: bundle.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil)) ?? []
        for url in extensions.filter({ $0.pathExtension == "appex" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = try ArchiveService.metadata(at: url)["CFBundleIdentifier"] as? String else { throw WorkspaceFailure("Retools 扩展缺少 Bundle ID。") }
            requests.append(AppleBundleRequest(bundleID: id, name: "Retools 配对", entitlementKeys: ["get-task-allow"], appGroups: []))
        }
        return requests
    }

    static func validateProfile(_ data: Data, bundleID: String, teamID: String, requireAppGroup: Bool) throws {
        let profile = try ProfileRefresh.parse(data)
        guard profile.applicationIdentifier == teamID + "." + bundleID,
              profile.entitlements["com.apple.developer.team-identifier"] as? String == teamID else {
            throw WorkspaceFailure("Apple 返回的描述文件不匹配 Retools 的应用标识或所选团队。")
        }
        guard profile.entitlements["get-task-allow"] as? Bool == true else {
            throw WorkspaceFailure("Apple 返回的描述文件没有授权 get-task-allow，未生成开发签名。")
        }
        if requireAppGroup {
            guard (profile.entitlements[entitlement] as? [String])?.contains(identifier(teamID: teamID)) == true else {
                throw WorkspaceFailure("Apple 返回的描述文件没有授权 Retools 的 App Group。可以关闭「申请 App Group」后继续准备普通开发签名。")
            }
        }
    }

    struct Status: Codable, Equatable, Sendable {
        let group: String?
        let message: String
        let verified: Bool
    }

    static func inspect() -> Status {
        do {
            guard let group = try readSignedIdentifier() else {
                return Status(group: nil, message: "当前安装未配置 App Group", verified: false)
            }
            return Status(group: group, message: "签名已包含 App Group，尚未检测读写", verified: false)
        } catch {
            return Status(group: nil, message: "无法读取当前安装的 App Group：" + error.localizedDescription, verified: false)
        }
    }

    /// 只读写专用组内本次创建的临时目录，不触及业务缓存或其他应用目录。
    static func check(group: String, container: (String) -> URL? = {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
    }) -> Status {
        guard let root = container(group) else {
            return Status(group: group, message: "无法访问 App Group，请检查安装包签名和描述文件授权", verified: false)
        }
        let folder = root.appendingPathComponent(".retools-check-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("probe")
            let data = Data(UUID().uuidString.utf8)
            try data.write(to: file, options: .atomic)
            guard try Data(contentsOf: file) == data else { throw WorkspaceFailure("读回的数据不一致。") }
            try FileManager.default.removeItem(at: folder)
            return Status(group: group, message: "App Group 读写检测通过", verified: true)
        } catch {
            return Status(group: group, message: "App Group 读写失败：" + error.localizedDescription, verified: false)
        }
    }
}
