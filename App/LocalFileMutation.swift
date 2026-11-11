import Foundation
import Darwin

struct LocalFileVersion: Codable, Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let bytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let mode: UInt32
    let owner: UInt32
    let group: UInt32
    let links: UInt64

    init(_ info: stat) {
        device = Int64(info.st_dev); inode = UInt64(info.st_ino); bytes = Int64(info.st_size)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec); changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        mode = UInt32(info.st_mode); owner = info.st_uid; group = info.st_gid; links = UInt64(info.st_nlink)
    }
    var isDirectory: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
    var isFile: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
    func sameIdentity(as other: Self) -> Bool {
        device == other.device && inode == other.inode && mode == other.mode && owner == other.owner && group == other.group && links == other.links
    }
    static func read(_ descriptor: Int32) throws -> Self {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw LocalFileMutation.failure("无法读取文件状态") }
        return Self(info)
    }
}

struct LocalFileSnapshot: Sendable {
    let data: Data
    let version: LocalFileVersion
}

struct LocalFileBackup: Codable, Identifiable, Sendable {
    let id: UUID
    let originalPath: String
    let createdAt: Date
    let bytes: Int64
    var name: String { (originalPath as NSString).lastPathComponent }
    func file(in root: URL = LocalFileBackupStore.root) -> URL {
        root.appendingPathComponent(id.uuidString).appendingPathComponent("Files").appendingPathComponent(name)
    }
}

enum LocalFileBackupStore {
    static var root: URL { WorkspacePaths().documents.appendingPathComponent("Retools/FileBackups", isDirectory: true) }
    static func list(in root: URL = root) -> [LocalFileBackup] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        return directories.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let data = try? Data(contentsOf: folder.appendingPathComponent("Record.json")),
                  let record = try? JSONDecoder().decode(LocalFileBackup.self, from: data),
                  record.id.uuidString == folder.lastPathComponent,
                  (try? LocalFileMutation.validate(name: record.name)) != nil,
                  let properties = try? record.file(in: root).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  properties.isRegularFile == true, properties.isSymbolicLink != true else { return nil }
            return record
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static func create(descriptor: Int32, version: LocalFileVersion, originalPath: String, in root: URL) throws -> LocalFileBackup {
        let record = LocalFileBackup(id: UUID(), originalPath: originalPath, createdAt: Date(), bytes: version.bytes)
        try LocalFileMutation.validate(name: record.name)
        let folder = root.appendingPathComponent(record.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Files"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let file = record.file(in: root)
            let output = Darwin.open(file.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw LocalFileMutation.failure("无法创建原文件备份") }
            do {
                var position: Int64 = 0
                while position < version.bytes {
                    try Task.checkCancellation()
                    let bytes = try LocalFileMutation.read(descriptor, offset: position, count: Int(min(65_536, version.bytes - position)))
                    try LocalFileMutation.writeAll(output, data: bytes, offset: position)
                    position += Int64(bytes.count)
                }
                guard try LocalFileVersion.read(descriptor) == version else { throw WorkspaceFailure("备份期间文件已变化，未执行更改，请刷新后重试。") }
                guard fsync(output) == 0 else { throw LocalFileMutation.failure("无法确认备份已写入") }
                position = 0
                while position < version.bytes {
                    try Task.checkCancellation()
                    let count = Int(min(65_536, version.bytes - position))
                    guard try LocalFileMutation.read(descriptor, offset: position, count: count) == LocalFileMutation.read(output, offset: position, count: count) else { throw WorkspaceFailure("备份内容校验失败，未执行更改。") }
                    position += Int64(count)
                }
                guard try LocalFileVersion.read(descriptor) == version else { throw WorkspaceFailure("备份校验期间文件已变化，未执行更改。") }
            } catch { Darwin.close(output); throw error }
            guard Darwin.close(output) == 0 else { throw LocalFileMutation.failure("关闭备份失败，未执行更改") }
            try JSONEncoder().encode(record).write(to: folder.appendingPathComponent("Record.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return record
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}

enum LocalFileInput: Sendable { case data(Data), file(URL) }

private final class LocalFileInputReader {
    let data: Data?
    let descriptor: Int32
    let version: LocalFileVersion?
    let count: Int64
    init(_ input: LocalFileInput) throws {
        switch input {
        case .data(let data): self.data = data; descriptor = -1; version = nil; count = Int64(data.count)
        case .file(let url):
            data = nil
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw LocalFileMutation.failure("无法打开导入文件") }
            do {
                let info = try LocalFileVersion.read(fd)
                guard info.isFile, info.bytes >= 0 else { throw WorkspaceFailure("只能导入普通文件。") }
                descriptor = fd; version = info; count = info.bytes
            } catch { Darwin.close(fd); throw error }
        }
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
    func read(offset: Int64, count: Int) throws -> Data {
        if let data { return data.subdata(in: Int(offset)..<(Int(offset) + count)) }
        return try LocalFileMutation.read(descriptor, offset: offset, count: count)
    }
    func verify() throws {
        if let version, try LocalFileVersion.read(descriptor) != version { throw WorkspaceFailure("导入文件在操作期间发生变化，未能确认写入。") }
    }
}

/// 修改普通文件时持有同一个描述符，保留 inode、所有者和模式；覆盖与删除前先备份。
/// 版本校验和文件锁用于检测并发修改，不能与不遵守锁的其他应用形成原子事务。
enum LocalFileMutation {
    typealias Write = (Int32, UnsafeRawPointer, Int, off_t) -> Int
    static func failure(_ message: String) -> WorkspaceFailure {
        WorkspaceFailure(message + "：" + NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription)
    }
    static func validate(name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), name.utf8.count <= Int(NAME_MAX) else {
            throw WorkspaceFailure("名称无效：不能包含路径分隔符、路径跳转或超长文件名。")
        }
    }
    private static func protect(root: URL, components: [String], backups: URL) throws {
        guard !components.isEmpty else { throw WorkspaceFailure("不能修改容器根目录。") }
        for part in components { try validate(name: part) }
        func normalized(_ path: String) -> String { path.hasPrefix("/var/") ? "/private" + path : path }
        let target = normalized(components.reduce(root.path) { $0 + "/" + $1 })
        let protected = normalized(backups.path)
        guard target != protected, !target.hasPrefix(protected + "/"), !protected.hasPrefix(target + "/") else {
            throw WorkspaceFailure("文件备份目录及其父目录不能通过普通文件操作修改。请先导出需要保留的备份。")
        }
    }
    private static func parent(root: URL, components: [String]) throws -> Int32 {
        try LocalFileReader.open(root: root, components: Array(components.dropLast()), directory: true)
    }
    private static func checkParent(_ descriptor: Int32, root: URL, components: [String]) throws {
        let current = try parent(root: root, components: components); defer { Darwin.close(current) }
        guard try LocalFileVersion.read(current).sameIdentity(as: LocalFileVersion.read(descriptor)) else { throw WorkspaceFailure("文件所在目录已经变化，请刷新后重试。") }
    }
    private static func linked(_ descriptor: Int32, name: String) throws -> LocalFileVersion {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("文件已不存在或无法访问") }
        return LocalFileVersion(info)
    }
    private static func checkLinked(_ parent: Int32, name: String, version: LocalFileVersion, exact: Bool = true) throws {
        let current = try linked(parent, name: name)
        guard exact ? current == version : current.sameIdentity(as: version) else { throw WorkspaceFailure("文件已被修改或替换，请刷新后重新打开，未覆盖新的文件。") }
    }
    static func read(_ descriptor: Int32, offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count), done = 0
        while done < count {
            let position = done
            let result = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress!.advanced(by: position), count - position, off_t(offset + Int64(position))) }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw failure("无法完整读取文件") }
            done += result
        }
        return data
    }
    static func writeAll(_ descriptor: Int32, data: Data, offset: Int64) throws {
        var done = 0
        while done < data.count {
            let position = done
            let count = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress!.advanced(by: position), data.count - position, off_t(offset + Int64(position))) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw failure("无法完整写入文件") }
            done += count
        }
    }
    private static func copy(_ input: LocalFileInputReader, to descriptor: Int32, cancellable: Bool = false) throws {
        var position: Int64 = 0
        while position < input.count {
            if cancellable { try Task.checkCancellation() }
            let data = try input.read(offset: position, count: Int(min(65_536, input.count - position)))
            try writeAll(descriptor, data: data, offset: position)
            position += Int64(data.count)
        }
    }
    private static func matches(_ descriptor: Int32, input: LocalFileInputReader, length: Int64, offset: Int64 = 0) throws -> Bool {
        var position = offset
        while position < length {
            let count = Int(min(65_536, length - position))
            if try read(descriptor, offset: position, count: count) != input.read(offset: position, count: count) { return false }
            position += Int64(count)
        }
        return true
    }

    static func snapshot(root: URL, components: [String]) throws -> LocalFileSnapshot {
        let fd = try LocalFileReader.open(root: root, components: components, directory: false); defer { Darwin.close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw failure("文件正在被其他操作使用") }
        let before = try LocalFileVersion.read(fd)
        guard before.isFile else { throw WorkspaceFailure("只能编辑普通文件。") }
        guard before.bytes <= 2 * 1024 * 1024 else { throw WorkspaceFailure("直接编辑最多支持 2 MB；较大的文件可以通过导入文件覆盖。") }
        let bytes = try LocalFileReader.read(descriptor: fd, maximumBytes: 2 * 1024 * 1024)
        guard try LocalFileVersion.read(fd) == before else { throw WorkspaceFailure("读取期间文件已经变化，请重新打开。") }
        return LocalFileSnapshot(data: bytes, version: before)
    }

    static func export(root: URL, components: [String], to destination: URL) throws {
        let source = try LocalFileReader.open(root: root, components: components, directory: false); defer { Darwin.close(source) }
        let before = try LocalFileVersion.read(source)
        guard before.isFile, before.bytes >= 0 else { throw WorkspaceFailure("只能导出普通文件。") }
        guard flock(source, LOCK_SH | LOCK_NB) == 0 else { throw failure("文件正在被其他操作使用") }
        let output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw failure("无法创建导出副本") }; defer { Darwin.close(output) }
        var position: Int64 = 0
        while position < before.bytes {
            try Task.checkCancellation()
            let bytes = try read(source, offset: position, count: Int(min(65_536, before.bytes - position)))
            try writeAll(output, data: bytes, offset: position); position += Int64(bytes.count)
        }
        guard fsync(output) == 0, try LocalFileVersion.read(source) == before else { throw WorkspaceFailure("导出期间文件已变化，未提供不完整的副本，请重新导出。") }
    }

    static func replace(root: URL, components: [String], originalPath: String, input value: LocalFileInput,
                        expected: LocalFileVersion, backups: URL = LocalFileBackupStore.root,
                        write: Write = { pwrite($0, $1, $2, $3) }) throws {
        try protect(root: root, components: components, backups: backups)
        let directory = try parent(root: root, components: components); defer { Darwin.close(directory) }
        let name = components.last!
        let fd = openat(directory, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("无法写入文件，请检查文件权限") }; defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw failure("文件正在被其他操作使用") }
        let before = try LocalFileVersion.read(fd)
        guard before.isFile, before.links == 1, before == expected else { throw WorkspaceFailure("文件已变化，或不是可独立编辑的普通文件。请刷新后重试。") }
        let input = try LocalFileInputReader(value)
        guard input.version?.sameIdentity(as: before) != true else { throw WorkspaceFailure("导入文件与目标是同一个文件。") }
        try checkParent(directory, root: root, components: components)
        try checkLinked(directory, name: name, version: before)
        let backup = try LocalFileBackupStore.create(descriptor: fd, version: before, originalPath: originalPath, in: backups)
        try Task.checkCancellation()
        try input.verify()
        try checkLinked(directory, name: name, version: before)
        try checkParent(directory, root: root, components: components)
        var written: Int64 = 0, truncated = false
        do {
            while written < input.count {
                let data = try input.read(offset: written, count: Int(min(65_536, input.count - written)))
                var done = 0
                while done < data.count {
                    let position = done, offset = written
                    let count = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: position), data.count - position, off_t(offset)) }
                    if count < 0, errno == EINTR { continue }
                    guard count > 0, count <= data.count - done else { throw failure("写入文件失败") }
                    done += count; written += Int64(count)
                }
            }
            guard ftruncate(fd, off_t(input.count)) == 0 else { throw failure("调整文件大小失败") }
            truncated = true
            guard fsync(fd) == 0 else { throw failure("无法确认文件已保存") }
            try input.verify()
            guard try LocalFileVersion.read(fd).bytes == input.count, try matches(fd, input: input, length: input.count) else { throw WorkspaceFailure("写入内容校验失败，文件可能被其他应用同时修改。") }
            try checkParent(directory, root: root, components: components)
            try checkLinked(directory, name: name, version: before, exact: false)
        } catch {
            // Roll back only the held inode, and only if its bytes still match
            // exactly what this write produced. Keep the backup if uncertain.
            let saved = try? LocalFileInputReader(.file(backup.file(in: backups)))
            var restored = false
            if let saved,
               (try? checkParent(directory, root: root, components: components)) != nil,
               (try? checkLinked(directory, name: name, version: before, exact: false)) != nil,
               let current = try? LocalFileVersion.read(fd),
               current.bytes == (truncated ? input.count : max(before.bytes, written)),
               (try? matches(fd, input: input, length: written)) == true,
               (truncated || (try? matches(fd, input: saved, length: before.bytes, offset: written)) == true) {
                do {
                    try copy(saved, to: fd)
                    guard ftruncate(fd, off_t(before.bytes)) == 0, fsync(fd) == 0,
                          try matches(fd, input: saved, length: before.bytes) else { throw failure("恢复原内容失败") }
                    restored = true
                } catch { }
            }
            throw WorkspaceFailure((restored ? "保存失败，原文件已恢复。" : "未能确认保存结果，请从文件备份导出原内容并核对。") + "备份位于「本机文件 → 文件备份」。\n" + error.localizedDescription)
        }
    }

    static func create(root: URL, components: [String], input value: LocalFileInput, backups: URL = LocalFileBackupStore.root) throws {
        try protect(root: root, components: components, backups: backups)
        let directory = try parent(root: root, components: components); defer { Darwin.close(directory) }
        let input = try LocalFileInputReader(value), temporary = ".retools-import-" + UUID().uuidString
        let output = openat(directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw failure("无法创建文件，请检查目录权限") }
        defer { Darwin.close(output); unlinkat(directory, temporary, 0) }
        try copy(input, to: output, cancellable: true)
        try input.verify()
        guard fsync(output) == 0, try LocalFileVersion.read(output).bytes == input.count,
              try matches(output, input: input, length: input.count) else { throw failure("导入内容校验失败") }
        try Task.checkCancellation()
        try checkParent(directory, root: root, components: components)
        guard renameatx_np(directory, temporary, directory, components.last!, UInt32(RENAME_EXCL)) == 0 else { throw failure("目标已存在或无法导入，未覆盖现有文件") }
    }

    static func makeDirectory(root: URL, components: [String], backups: URL = LocalFileBackupStore.root) throws {
        try protect(root: root, components: components, backups: backups)
        let directory = try parent(root: root, components: components); defer { Darwin.close(directory) }
        try checkParent(directory, root: root, components: components)
        guard mkdirat(directory, components.last!, 0o700) == 0 else { throw failure("无法新建文件夹，请检查名称和目录权限") }
    }

    static func rename(root: URL, components: [String], name: String, expected: LocalFileVersion, backups: URL = LocalFileBackupStore.root) throws {
        try protect(root: root, components: components, backups: backups); try validate(name: name)
        try protect(root: root, components: Array(components.dropLast()) + [name], backups: backups)
        let directory = try parent(root: root, components: components); defer { Darwin.close(directory) }
        guard expected.isFile || expected.isDirectory else { throw WorkspaceFailure("不修改符号链接或特殊文件。") }
        try checkParent(directory, root: root, components: components)
        try checkLinked(directory, name: components.last!, version: expected)
        if name == components.last! { return }
        guard renameatx_np(directory, components.last!, directory, name, UInt32(RENAME_EXCL)) == 0 else { throw failure("无法重命名，目标可能已存在") }
    }

    static func remove(root: URL, components: [String], originalPath: String, expected: LocalFileVersion, backups: URL = LocalFileBackupStore.root) throws {
        try protect(root: root, components: components, backups: backups)
        guard expected.isFile || expected.isDirectory else { throw WorkspaceFailure("不删除符号链接或特殊文件。") }
        let directory = try parent(root: root, components: components); defer { Darwin.close(directory) }
        let name = components.last!
        try checkParent(directory, root: root, components: components)
        try checkLinked(directory, name: name, version: expected)
        if expected.isDirectory {
            guard try LocalFileReader.entries(root: root, components: components).isEmpty else { throw WorkspaceFailure("只能删除空文件夹，请先处理其中的内容。") }
        }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (expected.isDirectory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw failure("无法打开待删除项目") }; defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0, try LocalFileVersion.read(fd) == expected else { throw WorkspaceFailure("文件已变化或正在使用，请刷新后重试。") }
        // Move to an exclusive temporary name first. A new file subsequently
        // created at the original name must never be the one we unlink.
        let staged = ".retools-remove-" + UUID().uuidString
        guard renameatx_np(directory, name, directory, staged, UInt32(RENAME_EXCL)) == 0 else { throw failure("无法准备删除项目") }
        do {
            try checkParent(directory, root: root, components: components)
            try checkLinked(directory, name: staged, version: expected, exact: false)
            let moved = try LocalFileVersion.read(fd)
            guard moved.sameIdentity(as: expected), moved.bytes == expected.bytes,
                  moved.modifiedSeconds == expected.modifiedSeconds, moved.modifiedNanoseconds == expected.modifiedNanoseconds else { throw WorkspaceFailure("删除前文件内容已变化，请刷新后重试。") }
            if expected.isFile { _ = try LocalFileBackupStore.create(descriptor: fd, version: moved, originalPath: originalPath, in: backups) }
            try Task.checkCancellation()
            try checkLinked(directory, name: staged, version: moved)
            try checkParent(directory, root: root, components: components)
            guard unlinkat(directory, staged, expected.isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw failure("无法删除项目，原文件备份已保留") }
        } catch {
            if renameatx_np(directory, staged, directory, name, UInt32(RENAME_EXCL)) != 0 {
                throw WorkspaceFailure("删除未完成，项目保留在「\(staged)」。原名称已被占用或目录权限发生变化，请刷新后核对。\n" + error.localizedDescription)
            }
            throw error
        }
    }
}
