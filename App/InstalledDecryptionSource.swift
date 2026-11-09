import Foundation
import RetoolsNative
import Darwin

/// First verify that a specific installed bundle is readable. This probe never
/// modifies the installed app, reads application data or runs the target binary.
enum InstalledDecryptionSource {
    static func probe(app: DeviceInstalledApp, group: String) throws -> [String: Any] {
        guard let path = app.path else { throw WorkspaceFailure("设备服务没有返回应用安装位置。") }
        let normalized = path.hasPrefix("/var/") ? "/private" + path : path
        let prefix = "/private/var/containers/Bundle/Application/"
        guard normalized.hasPrefix(prefix) else { throw WorkspaceFailure("仅支持具体的已安装用户应用。") }
        let parts = String(normalized.dropFirst(prefix.count)).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, UUID(uuidString: parts[0]) != nil, parts[1].hasSuffix(".app"), parts[1] != ".", parts[1] != ".." else {
            throw WorkspaceFailure("设备服务返回的应用安装目录无效。")
        }
        let handle = try RTNative.acquireLocalFileAccess(normalized, group: group).int64Value
        let root = URL(fileURLWithPath: normalized, isDirectory: true)
        let result: Result<[String: Any], Error> = Result {
            let bytes = try LocalFileReader.read(root: root, components: ["Info.plist"], maximumBytes: 1_000_000)
            guard let info = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == app.bundleID,
                  let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
                  executable == (executable as NSString).lastPathComponent, executable != ".", executable != ".." else {
                throw WorkspaceFailure("安装包身份与所选应用不一致。")
            }
            let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw WorkspaceFailure("无法读取应用安装目录。") }
            defer { Darwin.close(directory) }
            let binary = executable.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            guard binary >= 0 else { throw WorkspaceFailure("无法读取所选应用的可执行文件。") }
            defer { Darwin.close(binary) }
            var header = [UInt8](repeating: 0, count: 4)
            guard Darwin.read(binary, &header, 4) == 4 else { throw WorkspaceFailure("无法读取 Mach-O 头。") }
            let licenses = (try? LocalFileReader.entries(root: root, components: ["SC_Info"])) ?? []
            return ["bundleID": app.bundleID, "version": info["CFBundleShortVersionString"] as? String ?? "",
                    "bundleReadable": true, "binaryHeader": header.map { String(format: "%02x", $0) }.joined(),
                    "hasSINF": licenses.contains { $0.name.hasSuffix(".sinf") },
                    "hasSUPF": licenses.contains { $0.name.hasSuffix(".supf") }]
        }
        guard RTNative.releaseLocalFileAccess(handle) else { throw WorkspaceFailure("安装包读取权限未能释放，请完全退出 Retools 后重新打开。") }
        return try result.get()
    }

    @MainActor
    static func checkX(renewal: RenewalController, reportURL: URL) async {
        var report: [String: Any] = ["checkedAt": Date().timeIntervalSince1970, "target": "com.atebits.Tweetie2", "installedAppModified": false]
        func save() { try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: reportURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        report["phase"] = "connecting"; save()
        do {
            let link = LocalDeviceLink()
            _ = try await link.connect(host: renewal.settings.hostIP, remotePort: renewal.settings.remotePort, expectedUDID: renewal.settings.deviceUDID)
            report["phase"] = "listing"; save()
            let apps = try await link.installedApps(type: "User").compactMap(DeviceInstalledApp.parse)
            guard let app = apps.first(where: { $0.bundleID == "com.atebits.Tweetie2" }) else { throw WorkspaceFailure("设备服务未找到已安装的 X。") }
            guard let group = HostAppGroup.signedIdentifier() else { throw WorkspaceFailure("当前签名没有文件工具专用 App Group。") }
            report["phase"] = "reading-installed-bundle"; save()
            let result = try await Task.detached { try probe(app: app, group: group) }.value
            report.merge(result) { _, new in new }; report["phase"] = "complete"
        } catch { report["phase"] = "failed"; report["error"] = error.localizedDescription }
        save()
    }
}
