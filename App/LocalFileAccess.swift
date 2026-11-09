import Foundation
import Darwin
import RetoolsNative

struct LocalFileTarget: Equatable, Sendable {
    let root: URL
    let components: [String]
    var path: String { components.reduce(root.path) { $0 + "/" + $1 } }

    init(_ input: String) throws {
        guard input.utf8.count < Int(PATH_MAX), !input.contains("\0") else { throw WorkspaceFailure("目录路径无效或过长。") }
        var path = input
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.hasPrefix("/var/") { path = "/private" + path }
        let prefixes = ["/private/var/mobile/Containers/Data/Application/", "/private/var/mobile/Containers/Data/PluginKitPlugin/", "/private/var/mobile/Containers/Shared/AppGroup/"]
        guard let prefix = prefixes.first(where: { path.hasPrefix($0) }) else {
            throw WorkspaceFailure("请选择应用数据、应用扩展或 App Group 中的具体容器目录。")
        }
        let parts = String(path.dropFirst(prefix.count)).components(separatedBy: "/")
        guard let uuid = parts.first, UUID(uuidString: uuid) != nil,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WorkspaceFailure("目录必须包含有效的容器 UUID，且不能包含路径跳转。")
        }
        root = URL(fileURLWithPath: prefix + uuid, isDirectory: true)
        components = Array(parts.dropFirst())
    }
}

struct LocalFileEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case directory, file, symbolicLink, unavailable }
    let name: String
    let kind: Kind
    let bytes: Int64
    var modified: Date? = nil
    var id: String { name }
}

/// 从容器文件描述符逐级 openat，禁止符号链接及特殊文件，避免路径检查与读取间的跳转。
enum LocalFileReader {
    static let maximumFileBytes = 32 * 1024 * 1024
    static let maximumEntries = 2_000

    private static func failure(_ action: String, code: Int32 = errno) -> WorkspaceFailure {
        WorkspaceFailure(action + "：" + NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription)
    }

    private static func open(root: URL, components: [String], directory: Bool) throws -> Int32 {
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") }) else {
            throw WorkspaceFailure("文件路径包含无效的目录项。")
        }
        var fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("打开容器目录失败") }
        do {
            for (index, component) in components.enumerated() {
                try Task.checkCancellation()
                let needsDirectory = directory || index < components.count - 1
                let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (needsDirectory ? O_DIRECTORY : 0)
                let next = component.withCString { openat(fd, $0, flags) }
                guard next >= 0 else { throw failure("打开文件失败（不跟随符号链接）") }
                Darwin.close(fd); fd = next
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    static func entries(root: URL, components: [String]) throws -> [LocalFileEntry] {
        let fd = try open(root: root, components: components, directory: true)
        guard let directory = fdopendir(fd) else { let error = failure("读取目录失败"); Darwin.close(fd); throw error }
        defer { closedir(directory) }
        var result: [LocalFileEntry] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw failure("读取目录失败") }
                break
            }
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingCString: $0) }
            }
            guard let name else { throw WorkspaceFailure("目录包含无法解码的文件名。") }
            if name == "." || name == ".." { continue }
            guard result.count < maximumEntries else { throw WorkspaceFailure("目录超过 \(maximumEntries) 项，请打开更具体的子目录。") }
            var info = stat()
            let readable = name.withCString { fstatat(dirfd(directory), $0, &info, AT_SYMLINK_NOFOLLOW) } == 0
            let type = info.st_mode & S_IFMT
            let kind: LocalFileEntry.Kind = !readable ? .unavailable : type == S_IFDIR ? .directory : type == S_IFREG ? .file : type == S_IFLNK ? .symbolicLink : .unavailable
            let modified = readable ? Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000) : nil
            result.append(LocalFileEntry(name: name, kind: kind, bytes: readable ? Int64(info.st_size) : 0, modified: modified))
        }
        return result.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func read(root: URL, components: [String], maximumBytes: Int = maximumFileBytes) throws -> Data {
        let fd = try open(root: root, components: components, directory: false)
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure("读取文件信息失败") }
        guard info.st_mode & S_IFMT == S_IFREG else { throw WorkspaceFailure("只支持普通文件，不读取符号链接或特殊文件。") }
        guard maximumBytes >= 0, info.st_size >= 0, info.st_size <= Int64(maximumBytes) else { throw WorkspaceFailure("单个文件最多读取 32 MB。") }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("读取文件失败")
            }
            if count == 0 { return result }
            guard count <= maximumBytes - result.count else { throw WorkspaceFailure("读取期间文件超过 32 MB，已停止。") }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}

protocol LocalFileAccessBackend: Sendable {
    func acquire(root: String, group: String) throws -> Int64
    func release(_ handle: Int64) -> Bool
}

struct NativeLocalFileAccess: LocalFileAccessBackend {
    func acquire(root: String, group: String) throws -> Int64 { try RTNative.acquireLocalFileAccess(root, group: group).int64Value }
    func release(_ handle: Int64) -> Bool { RTNative.releaseLocalFileAccess(handle) }
}

/// 同一 actor 的操作不在持有权限时 await，保证专用组缓存入口与权限释放串行。
actor LocalFileAccessService {
    static let shared = LocalFileAccessService()
    private let backend: any LocalFileAccessBackend
    private let rootForTarget: @Sendable (LocalFileTarget) -> URL
    private var releaseFailed = false

    init(backend: any LocalFileAccessBackend = NativeLocalFileAccess(), rootForTarget: @escaping @Sendable (LocalFileTarget) -> URL = { $0.root }) {
        self.backend = backend; self.rootForTarget = rootForTarget
    }

    private func withAccess<T>(_ target: LocalFileTarget, group: String, read: (URL) throws -> T) throws -> T {
        try Task.checkCancellation()
        guard !releaseFailed else { throw WorkspaceFailure("上次目录权限未能释放，请完全退出 Retools 后重新打开。") }
        let handle = try backend.acquire(root: target.root.path, group: group)
        guard handle >= 0 else { throw WorkspaceFailure("系统没有授予有效的目录访问权限。") }
        var released = false
        let result = Result {
            defer { released = backend.release(handle) }
            let value = try read(rootForTarget(target))
            try Task.checkCancellation()
            return value
        }
        guard released else {
            releaseFailed = true
            throw WorkspaceFailure("目录访问权限未能释放，请完全退出 Retools 后重新打开；已暂停进一步访问和容器启动。")
        }
        return try result.get()
    }

    func entries(path: String, group: String) throws -> [LocalFileEntry] {
        let target = try LocalFileTarget(path)
        return try withAccess(target, group: group) { try LocalFileReader.entries(root: $0, components: target.components) }
    }

    func read(path: String, group: String) throws -> Data {
        let target = try LocalFileTarget(path)
        return try withAccess(target, group: group) { try LocalFileReader.read(root: $0, components: target.components) }
    }

    func export(path: String, group: String) throws -> URL {
        let data = try read(path: path, group: group)
        // 到这里扩展权限已经释放，预览和分享仅使用自己的临时副本。
        let folder = Self.exportFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent((path as NSString).lastPathComponent)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try Task.checkCancellation()
            return file
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }

    nonisolated static var unavailableReason: String? {
        #if targetEnvironment(simulator)
        return "模拟器不运行 worse_query，请在真机上使用。"
        #else
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if os.majorVersion == 26 && (os.minorVersion < 7 || (os.minorVersion == 7 && os.patchVersion <= 2)) { return nil }
        if os.majorVersion == 27 && (os.minorVersion < 2 || (os.minorVersion == 2 && os.patchVersion == 0)) { return nil }
        return "当前系统超出 worse_query 上游标注的版本范围。"
        #endif
    }

    nonisolated static var exportFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("LocalFileExports", isDirectory: true) }
    nonisolated static func discardExports() { try? FileManager.default.removeItem(at: exportFolder) }
}
