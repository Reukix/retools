import Foundation
import RetoolsNative

struct HostUpdatePlan: Sendable {
    let packageID: UUID
    let options: PackageSigningOptions
    let temp: URL
    let app: URL
    let identity: SigningIdentity
    let requiresAppGroup: Bool
}

enum HostUpdate {
    static func isCandidate(_ identifier: String, installedID: String? = Bundle.main.bundleIdentifier) -> Bool {
        identifier == installedID || identifier == "dev.retools.ios" || identifier.hasPrefix("dev.retools.ios.")
    }

    /// 只修改待安装副本；同一 Bundle ID 和团队才能覆盖原安装并保留私有沙盒。
    static func normalize(_ app: URL, installed: URL = Bundle.main.bundleURL) throws {
        var info = try ArchiveService.metadata(at: app)
        let current = try ArchiveService.metadata(at: installed)
        guard info["RetoolsPrivateSandbox"] as? Bool == true,
              info[HostAppGroup.metadataKey] as? String == HostAppGroup.baseIdentifier,
              info["CFBundleExecutable"] as? String == current["CFBundleExecutable"] as? String,
              let originalID = info["CFBundleIdentifier"] as? String,
              let installedID = current["CFBundleIdentifier"] as? String else {
            throw WorkspaceFailure("这个 IPA 不是完整的 Retools 更新包。")
        }
        try SigningProjectService.renameExtensions(in: app, from: originalID, to: installedID)
        let plugins = app.appendingPathComponent("PlugIns")
        let existing = installed.appendingPathComponent("PlugIns")
        let pairing = "RetoolsPairingWidget.appex"
        if FileManager.default.fileExists(atPath: existing.appendingPathComponent(pairing).path),
           !FileManager.default.fileExists(atPath: plugins.appendingPathComponent(pairing).path) {
            throw WorkspaceFailure("更新包缺少 Retools 配对扩展，请使用完整 IPA。")
        }
        for item in (try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? [] where item.pathExtension == "appex" {
            var metadata = try ArchiveService.metadata(at: item)
            if let old = try? ArchiveService.metadata(at: existing.appendingPathComponent(item.lastPathComponent)),
               old["CFBundleExecutable"] as? String == metadata["CFBundleExecutable"] as? String,
               let id = old["CFBundleIdentifier"] as? String, id.hasPrefix(installedID + ".") {
                metadata["CFBundleIdentifier"] = id
                try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0).write(to: item.appendingPathComponent("Info.plist"), options: .atomic)
            }
            guard let id = metadata["CFBundleIdentifier"] as? String, id.hasPrefix(installedID + ".") else {
                throw WorkspaceFailure("Retools 更新包中的扩展标识不匹配。")
            }
        }
        info["CFBundleIdentifier"] = installedID
        // 后台任务沿用更新包的声明，不套用普通应用的团队后缀改写。
        info["RetoolsRenewalReceipt"] = UUID().uuidString
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: app.appendingPathComponent("Info.plist"), options: .atomic)
    }

    static func validateInstall(_ app: URL, teamID: String, installedID: String, requiresAppGroup: Bool) throws -> (profile: String, receipt: String) {
        let info = try ArchiveService.metadata(at: app)
        guard info["CFBundleIdentifier"] as? String == installedID,
              info["RetoolsPrivateSandbox"] as? Bool == true,
              let receipt = info["RetoolsRenewalReceipt"] as? String, !receipt.isEmpty else {
            throw WorkspaceFailure("请重新签名这份 Retools IPA，以准备可确认结果的自身更新。")
        }
        for (index, request) in try HostAppGroup.signingRequests(in: app, includeAppGroup: requiresAppGroup).enumerated() {
            let bundle: URL
            if index == 0 { bundle = app }
            else {
                let items = try FileManager.default.contentsOfDirectory(at: app.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil)
                guard let found = items.first(where: { (try? ArchiveService.metadata(at: $0)["CFBundleIdentifier"] as? String) == request.bundleID }) else { throw WorkspaceFailure("找不到 Retools 扩展。") }
                bundle = found
            }
            let data = try Data(contentsOf: bundle.appendingPathComponent("embedded.mobileprovision"))
            try HostAppGroup.validateProfile(data, bundleID: request.bundleID, teamID: teamID, requireAppGroup: !request.appGroups.isEmpty)
            let metadata = try ArchiveService.metadata(at: bundle)
            guard let executable = metadata["CFBundleExecutable"] as? String,
                  ProfileRefresh.blocker(profile: try ProfileRefresh.parse(data), executable: bundle.appendingPathComponent(executable), currentExpiry: nil) == nil else {
                throw WorkspaceFailure("Retools 或扩展的签名与描述文件不匹配，未提交更新。")
            }
        }
        if requiresAppGroup, HostAppGroup.signedIdentifier(in: app) == nil { throw WorkspaceFailure("更新包没有保留当前 App Group。") }
        return (try ProfileRefresh.parse(Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision"))).uuid, receipt)
    }
}

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
            let metadata = try ArchiveService.metadata(at: url)
            guard let id = metadata["CFBundleIdentifier"] as? String else { throw WorkspaceFailure("Retools 扩展缺少 Bundle ID。") }
            let needsGroup = includeAppGroup && metadata["RetoolsRequiresSharedAppGroup"] as? Bool == true
            requests.append(AppleBundleRequest(bundleID: id,
                name: metadata["CFBundleDisplayName"] as? String ?? "Retools 扩展",
                entitlementKeys: needsGroup ? ["get-task-allow", entitlement] : ["get-task-allow"],
                appGroups: needsGroup ? [baseIdentifier] : []))
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
