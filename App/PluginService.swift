import Foundation
import CryptoKit
import RetoolsNative

enum PluginService {
    static let maximumBytes = 512 * 1024 * 1024
    static func importFile(_ source: URL, paths: WorkspacePaths) throws -> PluginRecord {
        let kind: PluginRecord.Kind
        switch source.pathExtension.lowercased() {
        case "dylib": kind = .dylib
        case "deb": kind = .deb
        default: throw WorkspaceFailure("请选择 .deb 或 .dylib 插件文件。")
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= maximumBytes else { throw WorkspaceFailure("插件文件无效或体积超过 512 MB。") }
        let id = UUID(), directory = paths.plugins.appendingPathComponent(id.uuidString), payload = directory.appendingPathComponent("Payload")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: payload, withIntermediateDirectories: true)
            if kind == .deb { try RTNative.extractDeb(source.path, to: payload.path) }
            else { try fm.copyItem(at: source, to: payload.appendingPathComponent(source.lastPathComponent)) }
            let executables = try executablePaths(in: payload)
            guard !executables.isEmpty, executables.count <= 128 else { throw WorkspaceFailure("插件包没有可用的 arm64 动态库，或动态库数量过多。") }
            var bytes: Int64 = 0
            for case let file as URL in fm.enumerator(at: payload, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])! {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
            }
            let fingerprint = SHA256.hash(data: try Data(contentsOf: source, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            var protected = directory, options = URLResourceValues(); options.isExcludedFromBackup = true; try protected.setResourceValues(options)
            let binaries = try describe(executables, root: payload)
            return PluginRecord(id: id, name: source.deletingPathExtension().lastPathComponent, kind: kind, sourceFileName: source.lastPathComponent, executablePaths: executables, fingerprint: fingerprint, byteCount: bytes, importedAt: Date(), binaries: binaries, resourceCount: try files(in: payload).count - executables.count)
        } catch { try? fm.removeItem(at: directory); throw error }
    }
    static func files(in root: URL) throws -> [String] {
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw WorkspaceFailure("无法读取插件目录。") }
        var result: [String] = []
        for case let file as URL in entries {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw WorkspaceFailure("插件包含不支持的链接。") }
            if values.isRegularFile == true { result.append(String(file.path.dropFirst(root.path.count + 1))) }
        }
        return result.sorted()
    }
    static func describe(_ paths: [String], root: URL) throws -> [PluginBinary] {
        try paths.map { path in
            try ArchiveService.validate(path: path)
            let url = root.appendingPathComponent(path), info = try MachOInspector.inspect(url)
            var bundles: [String] = [], executables: [String] = []
            let filter = url.deletingPathExtension().appendingPathExtension("plist")
            if let values = try? filter.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
               values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 131072,
               let bytes = try? Data(contentsOf: filter), let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
               let rules = plist["Filter"] as? [String: Any] {
                bundles = Array((rules["Bundles"] as? [String] ?? []).prefix(256))
                executables = Array((rules["Executables"] as? [String] ?? []).prefix(256))
            }
            return PluginBinary(path: path, byteCount: Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), installName: info.installName, minimumOS: info.minimumOS, dependencies: info.dependencies, bundleFilters: bundles, executableFilters: executables)
        }
    }
    static func configuration(_ detailed: [PluginInjection]?, legacy: [UUID], plugins: [PluginRecord]) throws -> [PluginInjection] {
        let result = try detailed ?? selected(legacy, from: plugins).flatMap { record in record.executablePaths.map { PluginInjection(pluginID: record.id, path: $0) } }
        guard result.count <= 128, Set(result.map(\.id)).count == result.count else { throw WorkspaceFailure("插件加载项重复或超过 128 个。") }
        for entry in result {
            guard let record = plugins.first(where: { $0.id == entry.pluginID }), record.executablePaths.contains(entry.path) else { throw WorkspaceFailure("所选动态库已不存在，请重新选择。") }
            try ArchiveService.validate(path: entry.path)
        }
        return result
    }
    static func recordIDs(_ entries: [PluginInjection]) -> [UUID] {
        var result: [UUID] = []
        for entry in entries where !result.contains(entry.pluginID) { result.append(entry.pluginID) }
        return result
    }
    static func loadPath(_ entry: PluginInjection, namespace: UUID) -> String {
        "Frameworks/RetoolsPlugins-\(namespace.uuidString)/\(entry.pluginID.uuidString)/\(entry.path)"
    }
    private static func executablePaths(in root: URL) throws -> [String] {
        let fm = FileManager.default
        guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw WorkspaceFailure("无法读取插件内容。") }
        var candidates: [URL] = []
        for case let file as URL in entries {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw WorkspaceFailure("插件包含不支持的符号链接。") }
            if file.pathExtension == "framework" {
                let info = try ArchiveService.metadata(at: file)
                candidates.append(file.appendingPathComponent(info["CFBundleExecutable"] as! String))
            } else if values.isRegularFile == true, file.pathExtension.lowercased() == "dylib" { candidates.append(file) }
        }
        var result: [String] = []
        for file in candidates {
            let info = try MachOInspector.inspect(file)
            guard info.hasARM64, info.isDynamicLibrary, !info.isEncrypted else { throw WorkspaceFailure("\(file.lastPathComponent) 不是可用的未加密 arm64 动态库。") }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            try ArchiveService.validate(path: relative)
            if !result.contains(relative) { result.append(relative) }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return result.sorted()
    }
    static func selected(_ ids: [UUID], from plugins: [PluginRecord]) throws -> [PluginRecord] {
        guard ids.count <= 32, Set(ids).count == ids.count else { throw WorkspaceFailure("插件选择重复或数量过多。") }
        return try ids.map { id in
            guard let record = plugins.first(where: { $0.id == id }) else { throw WorkspaceFailure("所选插件已不存在，请重新选择。") }
            return record
        }
    }
    static func loadPaths(_ selected: [PluginRecord], namespace: UUID) throws -> [String] {
        let base = "Frameworks/RetoolsPlugins-\(namespace.uuidString)"
        let result = try selected.flatMap { record in
            try record.executablePaths.map { path in
                try ArchiveService.validate(path: path)
                return base + "/" + record.id.uuidString + "/" + path
            }
        }
        guard result.count <= 128 else { throw WorkspaceFailure("选定插件包含过多动态库。") }
        return result
    }
    /// Copies resources and libraries together. The source plugin library stays immutable.
    static func materialize(_ records: [PluginRecord], in app: URL, namespace: UUID, paths: WorkspacePaths) throws -> (libraries: [String], changed: Bool) {
        let fm = FileManager.default, framework = app.appendingPathComponent("Frameworks")
        let destination = framework.appendingPathComponent("RetoolsPlugins-" + namespace.uuidString)
        let marker = destination.appendingPathComponent(".retools-plugins.json")
        let libraries = try loadPaths(records, namespace: namespace)
        let manifest = try JSONSerialization.data(withJSONObject: records.map { ["id": $0.id.uuidString, "fingerprint": $0.fingerprint] }, options: .sortedKeys)
        if fm.fileExists(atPath: destination.path) {
            guard (try destination.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
                  fm.fileExists(atPath: marker.path) else { throw WorkspaceFailure("应用中已存在同名插件目录，未修改应用。") }
            if (try? Data(contentsOf: marker)) == manifest, libraries.allSatisfy({ fm.fileExists(atPath: app.appendingPathComponent($0).path) }) { return (libraries, false) }
        } else if records.isEmpty { return ([], false) }
        try fm.createDirectory(at: framework, withIntermediateDirectories: true)
        let temporary = framework.appendingPathComponent(".retools-plugins-" + UUID().uuidString)
        let backup = framework.appendingPathComponent(".retools-previous-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        for record in records {
            let source = paths.plugins.appendingPathComponent(record.id.uuidString + "/Payload")
            try fm.copyItem(at: source, to: temporary.appendingPathComponent(record.id.uuidString))
        }
        try manifest.write(to: temporary.appendingPathComponent(".retools-plugins.json"), options: .atomic)
        let existed = fm.fileExists(atPath: destination.path)
        if existed { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: temporary, to: destination) }
        catch { if existed { try? fm.moveItem(at: backup, to: destination) }; throw error }
        try? fm.removeItem(at: backup)
        return (libraries, true)
    }
}
