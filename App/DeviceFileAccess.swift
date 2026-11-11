import Foundation

struct DeviceFileRoot: Identifiable, Hashable {
    let title: String
    let path: String
    var id: String { path }
}

enum DeviceFileAccess {
    enum Mode { case device, local }

    static func localApp(for target: LocalFileTarget) -> DeviceInstalledApp {
        DeviceInstalledApp(bundleID: target.root.path, name: "容器目录", version: "", build: "", signer: "",
                           profileSigned: false, debuggable: false, fileSharing: false, bundleSize: 0, dataSize: 0,
                           dataContainerPath: target.root.path)
    }

    static func target(for app: DeviceInstalledApp, path: String, root: DeviceFileRoot? = nil) throws -> LocalFileTarget {
        guard path.hasPrefix("/") else { throw WorkspaceFailure("应用文件路径无效。") }
        guard let container = root?.path ?? app.dataContainerPath else {
            throw WorkspaceFailure("设备尚未提供这个应用的数据目录，请返回应用列表刷新后重试。")
        }
        let base = try LocalFileTarget(container)
        guard base.components.isEmpty else { throw WorkspaceFailure("设备返回的应用容器目录无效。") }
        return try LocalFileTarget(base.root.path + (path == "/" ? "" : path))
    }

    static func sharedRoots(for app: DeviceInstalledApp) -> [DeviceFileRoot] {
        var seen = Set<String>()
        return (app.groupContainerPaths ?? [:]).sorted { $0.key < $1.key }.compactMap { name, path in
            guard let target = try? LocalFileTarget(path), target.components.isEmpty, LocalFileArea.of(target) == .appGroup,
                  target.root.path != LocalFileTarget.appGroupParent,
                  seen.insert(target.root.path).inserted else { return nil }
            return DeviceFileRoot(title: name, path: target.root.path)
        }
    }

    static func item(_ entry: LocalFileEntry, in directory: String) -> DeviceFileItem {
        DeviceFileItem(path: DeviceFileItem.join(directory, entry.name), isDirectory: entry.kind == .directory, size: entry.bytes, modified: entry.modified)
    }
}
