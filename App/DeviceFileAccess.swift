import Foundation

struct DeviceFileRoot: Identifiable, Hashable {
    let title: String
    let path: String
    var id: String { path }
}

enum DeviceFileAccess {
    static let enabledKey = "RetoolsLocalFileAccessEnabled"

    static func canBrowse(_ app: DeviceInstalledApp, locally: Bool) -> Bool { locally || app.filesAccessible }

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
            guard let target = try? LocalFileTarget(path), target.components.isEmpty,
                  seen.insert(target.root.path).inserted else { return nil }
            return DeviceFileRoot(title: name, path: target.root.path)
        }
    }

    static func item(_ entry: LocalFileEntry, in directory: String) -> DeviceFileItem {
        DeviceFileItem(path: DeviceFileItem.join(directory, entry.name), isDirectory: entry.kind == .directory, size: entry.bytes, modified: entry.modified)
    }
}
