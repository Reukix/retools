//
//  IdeviceGateway+DeviceTools.swift
//  Retools
//
//  Local additions: device tools (installed apps, provisioning profiles, crash reports,
//  device information, battery, os_trace log stream, app container files) built directly
//  on the idevice FFI. None of these require a mounted developer disk image.
//

import Foundation
import IDevice
import MinimuxerCommon

public struct DeviceFileEntry: Sendable, Hashable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    /// Raw AFC timestamp; the unit depends on the FFI build, normalize before display.
    public var modifiedRaw: Int64
}

public struct DeviceLogRecord: Sendable {
    public var pid: UInt32
    /// Raw timestamp from the relay; normalize before display.
    public var timestampRaw: Int64
    /// os_log level: 0 notice, 1 info, 2 debug, 10 error, 11 fault.
    public var level: UInt8
    public var imageName: String
    public var processPath: String
    public var subsystem: String
    public var category: String
    public var message: String

    public init(pid: UInt32, timestampRaw: Int64, level: UInt8, imageName: String, processPath: String, subsystem: String, category: String, message: String) {
        self.pid = pid; self.timestampRaw = timestampRaw; self.level = level; self.imageName = imageName
        self.processPath = processPath; self.subsystem = subsystem; self.category = category; self.message = message
    }
}

public enum DeviceContainerAccess: String, Sendable {
    /// Whole sandbox container (development-signed apps).
    case container
    /// Documents folder only (apps that enable file sharing).
    case documents
}

public enum DevicePowerAction: Sendable { case restart, shutdown, sleep }

/// Thread-safe stop flag for long-running streams.
public final class DeviceStreamControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func stop() { lock.lock(); stopped = true; lock.unlock() }
    public var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

extension IdeviceGateway {
    private func toolFailure(_ action: String, _ err: UnsafeMutablePointer<IdeviceFfiError>) -> IdeviceGatewayError {
        let msg = getErrorMessage(from: err)
        safeFreeError(err)
        return IdeviceGatewayError(.serviceError, reason: "\(action)：\(msg)")
    }

    private func check(_ action: String, _ err: UnsafeMutablePointer<IdeviceFfiError>?) throws {
        if let err { throw toolFailure(action, err) }
    }

    // MARK: Installed apps (installation_proxy)

    /// 只请求界面用到的字段；完整返回每个应用会带上全部 Info.plist 与权限，几十个应用就有约 1 MB。
    public static let installedAppAttributes = ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleExecutable",
                                                "CFBundleShortVersionString", "CFBundleVersion", "SignerIdentity", "ProfileValidated",
                                                "UIFileSharingEnabled", "StaticDiskUsage", "DynamicDiskUsage", "Entitlements", "ApplicationType", "Path", "Container", "GroupContainers"]

    /// 不含大小的字段：读取很快。StaticDiskUsage / DynamicDiskUsage 需要设备逐个计算容器占用，几十个应用要十几秒。
    public static let installedAppQuickAttributes = installedAppAttributes.filter { !$0.hasSuffix("DiskUsage") }

    private func syncInstalledApps(type: String?, attributes: [String]) throws -> [Data] {
        try verifyInitialized()
        return try performWithEitherService(connectRP: installation_proxy_connect_rsd, connectLockdown: installation_proxy_connect,
                                            cleanup: installation_proxy_client_free, serviceName: "instproxy") { client in
            let options = plist_new_dict()
            defer { plist_free(options) }
            if let type { plist_dict_set_item(options, "ApplicationType", plist_new_string(type)) }
            let returned = plist_new_array()
            for key in attributes { plist_array_append_item(returned, plist_new_string(key)) }
            plist_dict_set_item(options, "ReturnAttributes", returned)
            var result: UnsafeMutablePointer<plist_t?>? = nil
            var count = 0
            try self.check("读取已安装应用失败", installation_proxy_browse(client, options, &result, &count))
            guard let result, count > 0 else { return [] }
            defer { idevice_plist_array_free(result, UInt(count)); idevice_outer_slice_free(result, UInt(count)) }
            return (0..<count).compactMap { result[$0].flatMap(self.plistNodeToData) }
        }
    }

    public func installedApps(type: String? = "User", attributes: [String] = IdeviceGateway.installedAppAttributes) async throws -> [Data] {
        try await withFFIDispatch { try self.syncInstalledApps(type: type, attributes: attributes) }
    }

    // MARK: Provisioning profiles (misagent)

    private func syncProvisioningProfiles() throws -> [Data] {
        try verifyInitialized()
        return try performWithEitherService(connectRP: misagent_connect_rsd, connectLockdown: misagent_connect,
                                            cleanup: misagent_client_free, serviceName: "misagent") { client in
            var profiles: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>? = nil
            var lengths: UnsafeMutablePointer<Int>? = nil
            var count = 0
            try self.check("读取设备描述文件失败", misagent_copy_all(client, &profiles, &lengths, &count))
            guard let profiles, let lengths, count > 0 else { return [] }
            defer { misagent_free_profiles(profiles, lengths, count) }
            return (0..<count).compactMap { index in profiles[index].map { Data(bytes: $0, count: lengths[index]) } }
        }
    }

    public func provisioningProfiles() async throws -> [Data] {
        try await withFFIDispatch { try self.syncProvisioningProfiles() }
    }

    // MARK: AFC helpers

    private func afcEntries(client: OpaquePointer, path: String, depth: Int, limit: Int) -> [DeviceFileEntry] {
        guard let names = try? afcListDirectory(client: client, path: path) else { return [] }
        var entries: [DeviceFileEntry] = []
        for name in names where name != "." && name != ".." {
            guard entries.count < limit else { break }
            let child = path == "/" ? "/" + name : path + "/" + name
            var info = AfcFileInfo()
            let err = child.withCString { afc_get_file_info(client, $0, &info) }
            if let err { safeFreeError(err); continue }
            let isDirectory = info.st_ifmt != nil && String(cString: info.st_ifmt).contains("S_IFDIR")
            let entry = DeviceFileEntry(path: child, name: name, isDirectory: isDirectory, size: Int64(info.size), modifiedRaw: info.modified)
            afc_file_info_free(&info)
            if isDirectory, depth > 0 {
                entries += afcEntries(client: client, path: child, depth: depth - 1, limit: limit - entries.count)
            } else {
                entries.append(entry)
            }
        }
        return entries
    }

    private func afcWrite(client: OpaquePointer, path: String, data: Data) throws {
        var handle: OpaquePointer? = nil
        try check("无法创建文件 \(path)", path.withCString { afc_file_open(client, $0, AfcWr, &handle) })
        defer { _ = afc_file_close(handle) }
        let chunk = 1 << 20
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while offset < data.count {
                let length = min(chunk, data.count - offset)
                try check("写入文件失败", afc_file_write(handle, base + offset, length))
                offset += length
            }
        }
    }

    // MARK: Crash reports (crashreportcopymobile)

    private func withCrashAFC<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try verifyInitialized()
        var afc: OpaquePointer? = nil
        try performWithEitherService(connectRP: crash_report_client_connect_rsd, connectLockdown: crash_report_client_connect,
                                     cleanup: { _ in }, serviceName: "crashreportcopymobile") { client in
            // Converting consumes the crash report client.
            try self.check("打开崩溃日志目录失败", crash_report_client_to_afc(client, &afc))
        }
        guard let afc else { throw IdeviceGatewayError(.serviceError, reason: "崩溃日志目录不可用") }
        defer { afc_client_free(afc) }
        return try body(afc)
    }

    public func crashReports() async throws -> [DeviceFileEntry] {
        try await withFFIDispatch { try self.withCrashAFC { self.afcEntries(client: $0, path: "/", depth: 2, limit: 2_000) } }
    }

    public func crashReport(path: String) async throws -> Data {
        try await withFFIDispatch { try self.withCrashAFC { try self.afcReadFile(client: $0, path: path) } }
    }

    public func removeCrashReports(paths: [String]) async throws {
        try await withFFIDispatch {
            try self.withCrashAFC { client in
                for path in paths { try self.check("删除崩溃日志失败", path.withCString { afc_remove_path(client, $0) }) }
            }
        }
    }

    // MARK: Device values (lockdownd) and diagnostics

    private func syncLockdownValues(domain: String?) throws -> Data {
        try verifyInitialized()
        return try performWithEitherService(connectRP: lockdownd_connect_rsd, connectLockdown: lockdownd_connect,
                                            cleanup: lockdownd_client_free, serviceName: "lockdownd") { client in
            if self.pairingFileType == .lockdown, let pairingData = self.pairingFileData {
                var pairing: OpaquePointer? = nil
                try self.check("配对文件无效", pairingData.withUnsafeBytes {
                    idevice_pairing_file_from_bytes($0.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt(pairingData.count), &pairing)
                })
                if let pairing {
                    defer { idevice_pairing_file_free(pairing) }
                    try self.check("建立设备会话失败", lockdownd_start_session(client, pairing))
                }
            }
            var value: plist_t? = nil
            let err = { () -> UnsafeMutablePointer<IdeviceFfiError>? in
                if let domain { return domain.withCString { lockdownd_get_value(client, nil, $0, &value) } }
                return lockdownd_get_value(client, nil, nil, &value)
            }()
            try self.check("读取设备信息失败", err)
            guard let value else { return Data() }
            defer { self.safeFreePlist(value) }
            return self.plistNodeToData(value) ?? Data()
        }
    }

    public func lockdownValues(domain: String? = nil) async throws -> Data {
        try await withFFIDispatch { try self.syncLockdownValues(domain: domain) }
    }

    private func withDiagnostics<T>(_ body: @escaping (OpaquePointer) throws -> T) throws -> T {
        try verifyInitialized()
        return try performWithEitherService(connectRP: diagnostics_relay_client_connect_rsd, connectLockdown: diagnostics_relay_client_connect,
                                            cleanup: diagnostics_relay_client_free, serviceName: "diagnostics_relay", action: body)
    }

    /// IORegistry entry of the battery (IOPMPowerSource / AppleSmartBattery).
    public func batteryRegistry() async throws -> Data {
        try await withFFIDispatch {
            try self.withDiagnostics { client in
                var result: plist_t? = nil
                try self.check("读取电池信息失败", "IOPMPowerSource".withCString { diagnostics_relay_client_ioregistry(client, nil, nil, $0, &result) })
                guard let result else { return Data() }
                defer { self.safeFreePlist(result) }
                return self.plistNodeToData(result) ?? Data()
            }
        }
    }

    public func power(_ action: DevicePowerAction) async throws {
        try await withFFIDispatch {
            try self.withDiagnostics { client in
                switch action {
                case .restart: try self.check("重启失败", diagnostics_relay_client_restart(client))
                case .shutdown: try self.check("关机失败", diagnostics_relay_client_shutdown(client))
                case .sleep: try self.check("睡眠失败", diagnostics_relay_client_sleep(client))
                }
            }
        }
    }

    // MARK: Live logs (os_trace_relay)

    private func syncStreamLogs(pid: UInt32?, control: DeviceStreamControl, onRecord: @escaping @Sendable (DeviceLogRecord) -> Void) throws {
        try verifyInitialized()
        var receiver: OpaquePointer? = nil
        try performWithEitherService(connectRP: os_trace_relay_connect_rsd, connectLockdown: os_trace_relay_connect,
                                     cleanup: { _ in }, serviceName: "os_trace_relay") { client in
            // start_trace consumes the relay client.
            let err: UnsafeMutablePointer<IdeviceFfiError>?
            if var pid { err = os_trace_relay_start_trace(client, &receiver, &pid) }
            else { err = os_trace_relay_start_trace(client, &receiver, nil) }
            try self.check("无法开始读取日志", err)
        }
        guard let receiver else { throw IdeviceGatewayError(.serviceError, reason: "日志通道不可用") }
        defer { os_trace_relay_receiver_free(receiver) }
        func text(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }
        while !control.isStopped {
            var log: UnsafeMutablePointer<OsTraceLog>? = nil
            try check("日志连接已中断", os_trace_relay_next(receiver, &log))
            guard let log else { continue }
            let entry = log.pointee
            let record = DeviceLogRecord(pid: entry.pid, timestampRaw: entry.timestamp, level: entry.level,
                                         imageName: text(entry.image_name), processPath: text(entry.filename),
                                         subsystem: text(entry.label?.pointee.subsystem), category: text(entry.label?.pointee.category),
                                         message: text(entry.message))
            os_trace_relay_free_log(log)
            onRecord(record)
        }
    }

    /// Streams os_log entries until `control.stop()` is called. Runs on its own thread because each read blocks.
    public func streamLogs(pid: UInt32? = nil, control: DeviceStreamControl, onRecord: @escaping @Sendable (DeviceLogRecord) -> Void) async throws {
        try await withFFIDispatch(on: DispatchQueue(label: "dev.retools.device-logs")) {
            try self.syncStreamLogs(pid: pid, control: control, onRecord: onRecord)
        }
    }

    // MARK: App containers (house_arrest)

    private func openContainer(bundleId: String) throws -> (OpaquePointer, DeviceContainerAccess) {
        try verifyInitialized()
        var lastError: Error?
        for access in [DeviceContainerAccess.container, .documents] {
            var afc: OpaquePointer? = nil
            do {
                try performWithEitherService(connectRP: house_arrest_client_connect_rsd, connectLockdown: house_arrest_client_connect,
                                             cleanup: { _ in }, serviceName: "house_arrest") { client in
                    // Vending consumes the house_arrest client.
                    let err = bundleId.withCString { id in
                        access == .container ? house_arrest_vend_container(client, id, &afc) : house_arrest_vend_documents(client, id, &afc)
                    }
                    try self.check("无法打开应用文件", err)
                }
                if let afc { return (afc, access) }
            } catch { lastError = error }
        }
        throw lastError ?? IdeviceGatewayError(.serviceError, reason: "无法打开应用文件")
    }

    private func withContainer<T>(_ bundleId: String, _ body: (OpaquePointer, DeviceContainerAccess) throws -> T) throws -> T {
        let (afc, access) = try openContainer(bundleId: bundleId)
        defer { afc_client_free(afc) }
        return try body(afc, access)
    }

    public func containerEntries(bundleId: String, path: String) async throws -> (access: DeviceContainerAccess, entries: [DeviceFileEntry]) {
        try await withFFIDispatch {
            try self.withContainer(bundleId) { client, access in
                let root = access == .documents && (path == "/" || path.isEmpty) ? "/Documents" : path
                return (access, self.afcEntries(client: client, path: root, depth: 0, limit: 5_000))
            }
        }
    }

    public func containerRead(bundleId: String, path: String) async throws -> Data {
        try await withFFIDispatch { try self.withContainer(bundleId) { client, _ in try self.afcReadFile(client: client, path: path) } }
    }

    /// Stream one regular file to an atomic local replacement, bounded to the declared size.
    public func containerDownloadFile(bundleId: String, path: String, to destination: URL) async throws {
        try await withFFIDispatch(on: DispatchQueue(label: "dev.retools.container-file-transfer")) {
            try self.withContainer(bundleId) { client, _ in
                guard !path.split(separator: "/").contains(".."),
                      let info = self.entryInfo(client, path), info.kind == .file,
                      info.size >= 0, info.size <= 8*1024*1024*1024 else {
                    throw IdeviceGatewayError(.serviceError, reason: "文件无效或超过 8 GB")
                }
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".download")
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw IdeviceGatewayError(.serviceError, reason: "无法创建下载文件") }
                let output = try FileHandle(forWritingTo: temporary); defer { try? output.close() }
                var handle: OpaquePointer? = nil
                try self.check("无法读取文件", path.withCString { afc_file_open(client, $0, AfcRdOnly, &handle) })
                defer { _ = afc_file_close(handle) }
                var received: Int64 = 0
                while received < info.size {
                    var chunk: UnsafeMutablePointer<UInt8>?, count = 0
                    try self.check("文件传输失败", afc_file_read(handle, &chunk, UInt(min(4 << 20, Int(info.size-received))), &count))
                    guard let chunk else { throw IdeviceGatewayError(.serviceError, reason: "文件传输中断") }
                    defer { afc_file_read_data_free(chunk, count) }
                    guard count > 0, Int64(count) <= info.size-received else { throw IdeviceGatewayError(.serviceError, reason: "文件长度不匹配") }
                    try output.write(contentsOf: Data(bytesNoCopy: chunk, count: count, deallocator: .none)); received += Int64(count)
                }
                try output.synchronize(); try output.close()
                if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
                else { try FileManager.default.moveItem(at: temporary, to: destination) }
            }
        }
    }

    public func containerWrite(bundleId: String, path: String, data: Data) async throws {
        try await withFFIDispatch { try self.withContainer(bundleId) { client, _ in try self.afcWrite(client: client, path: path, data: data) } }
    }

    public func containerMakeDirectory(bundleId: String, path: String) async throws {
        try await withFFIDispatch {
            try self.withContainer(bundleId) { client, _ in try self.check("新建文件夹失败", path.withCString { afc_make_directory(client, $0) }) }
        }
    }

    public func containerRemove(bundleId: String, path: String) async throws {
        try await withFFIDispatch {
            try self.withContainer(bundleId) { client, _ in try self.check("删除失败", path.withCString { afc_remove_path_and_contents(client, $0) }) }
        }
    }

    // MARK: App icons (springboardservices)

    /// 一次连接读多个图标；单个读取失败的跳过。
    private func syncAppIcons(bundleIds: [String]) throws -> [String: Data] {
        try verifyInitialized()
        return try performWithEitherService(connectRP: springboard_services_connect_rsd, connectLockdown: springboard_services_connect,
                                            cleanup: springboard_services_free, serviceName: "springboardservices") { client in
            var icons: [String: Data] = [:]
            for id in bundleIds {
                var output: UnsafeMutableRawPointer? = nil
                var length = 0
                let err = id.withCString { springboard_services_get_icon(client, $0, &output, &length) }
                if let err { self.safeFreeError(err); continue }
                guard let output, length > 0 else { continue }
                icons[id] = Data(bytes: output, count: length)
                idevice_data_free(output.assumingMemoryBound(to: UInt8.self), UInt(length))
            }
            return icons
        }
    }

    public func appIcons(bundleIds: [String]) async throws -> [String: Data] {
        try await withFFIDispatch { try self.syncAppIcons(bundleIds: bundleIds) }
    }

    // MARK: Container backup / restore (streamed)

    private enum EntryKind { case file, directory, other }

    private func entryInfo(_ client: OpaquePointer, _ path: String) -> (kind: EntryKind, size: Int64)? {
        var info = AfcFileInfo()
        let err = path.withCString { afc_get_file_info(client, $0, &info) }
        if let err { safeFreeError(err); return nil }
        defer { afc_file_info_free(&info) }
        let format = info.st_ifmt.map { String(cString: $0) } ?? ""
        return (format.contains("S_IFDIR") ? .directory : (format.contains("S_IFREG") ? .file : .other), Int64(info.size))
    }

    private static func join(_ directory: String, _ name: String) -> String { directory == "/" ? "/" + name : directory + "/" + name }

    /// 把应用沙盒下载到本地目录，目录结构与沙盒一致。`excluding` 为沙盒内的绝对路径（如 /tmp、/Library/Caches）。
    private func syncContainerDownload(bundleId: String, to localRoot: URL, excluding: Set<String>, control: DeviceStreamControl,
                                       progress: @Sendable (Int, Int64) -> Void) throws -> DeviceContainerAccess {
        try withContainer(bundleId) { client, access in
            var files = 0, bytes: Int64 = 0
            func copy(_ remote: String, to local: URL) throws {
                if control.isStopped { throw CancellationError() }
                var handle: OpaquePointer? = nil
                try check("无法读取 \(remote)", remote.withCString { afc_file_open(client, $0, AfcRdOnly, &handle) })
                defer { _ = afc_file_close(handle) }
                FileManager.default.createFile(atPath: local.path, contents: nil)
                let output = try FileHandle(forWritingTo: local)
                defer { try? output.close() }
                while true {
                    if control.isStopped { throw CancellationError() }
                    var chunk: UnsafeMutablePointer<UInt8>? = nil
                    var count = 0
                    try check("读取 \(remote) 失败", afc_file_read(handle, &chunk, 4 << 20, &count))
                    guard let chunk, count > 0 else { break }
                    defer { afc_file_read_data_free(chunk, count) }
                    try output.write(contentsOf: Data(bytesNoCopy: chunk, count: count, deallocator: .none))
                    bytes += Int64(count)
                    progress(files, bytes)
                }
                files += 1
                progress(files, bytes)
            }
            func walk(_ remote: String, _ local: URL) throws {
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                for name in try afcListDirectory(client: client, path: remote) where name != "." && name != ".." {
                    let child = Self.join(remote, name)
                    if excluding.contains(child) { continue }
                    guard let info = entryInfo(client, child) else { continue }
                    switch info.kind {
                    case .directory: try walk(child, local.appendingPathComponent(name, isDirectory: true))
                    case .file: try copy(child, to: local.appendingPathComponent(name))
                    case .other: continue
                    }
                }
            }
            if access == .documents { try walk("/Documents", localRoot.appendingPathComponent("Documents", isDirectory: true)) }
            else { try walk("/", localRoot) }
            return access
        }
    }

    public func containerDownload(bundleId: String, to localRoot: URL, excluding: Set<String>, control: DeviceStreamControl,
                                  progress: @escaping @Sendable (Int, Int64) -> Void) async throws -> DeviceContainerAccess {
        try await withFFIDispatch(on: DispatchQueue(label: "dev.retools.container-transfer")) {
            try self.syncContainerDownload(bundleId: bundleId, to: localRoot, excluding: excluding, control: control, progress: progress)
        }
    }

    /// 把本地目录写回应用沙盒。先清空 `clearing` 里列出的沙盒目录的内容（目录本身保留），再逐个上传。
    private func syncContainerUpload(bundleId: String, from localRoot: URL, clearing: [String], keeping: Set<String>, control: DeviceStreamControl,
                                     progress: @Sendable (Int, Int64) -> Void) throws {
        try withContainer(bundleId) { client, access in
            for directory in clearing where access == .container || directory == "/Documents" {
                guard let names = try? afcListDirectory(client: client, path: directory) else { continue }
                for name in names where name != "." && name != ".." {
                    let child = Self.join(directory, name)
                    if keeping.contains(child) { continue }
                    try check("清理 \(child) 失败", child.withCString { afc_remove_path_and_contents(client, $0) })
                }
            }
            var files = 0, bytes: Int64 = 0
            func upload(_ local: URL, to remote: String) throws {
                if control.isStopped { throw CancellationError() }
                var handle: OpaquePointer? = nil
                try check("无法写入 \(remote)", remote.withCString { afc_file_open(client, $0, AfcWr, &handle) })
                defer { _ = afc_file_close(handle) }
                let input = try FileHandle(forReadingFrom: local)
                defer { try? input.close() }
                while let data = try input.read(upToCount: 4 << 20), !data.isEmpty {
                    if control.isStopped { throw CancellationError() }
                    try data.withUnsafeBytes { buffer in
                        try check("写入 \(remote) 失败", afc_file_write(handle, buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count))
                    }
                    bytes += Int64(data.count)
                    progress(files, bytes)
                }
                files += 1
                progress(files, bytes)
            }
            func walk(_ local: URL, _ remote: String) throws {
                let items = try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                for item in items {
                    let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true { continue }
                    let child = Self.join(remote, item.lastPathComponent)
                    if keeping.contains(child) { continue }
                    if values.isDirectory == true {
                        let err = child.withCString { afc_make_directory(client, $0) }
                        if let err { safeFreeError(err) }
                        try walk(item, child)
                    } else { try upload(item, to: child) }
                }
            }
            // 只能访问文稿的应用，只写回 Documents。
            if access == .documents {
                let documents = localRoot.appendingPathComponent("Documents", isDirectory: true)
                if FileManager.default.fileExists(atPath: documents.path) { try walk(documents, "/Documents") }
            } else { try walk(localRoot, "/") }
        }
    }

    public func containerUpload(bundleId: String, from localRoot: URL, clearing: [String], keeping: Set<String>, control: DeviceStreamControl,
                                progress: @escaping @Sendable (Int, Int64) -> Void) async throws {
        try await withFFIDispatch(on: DispatchQueue(label: "dev.retools.container-transfer")) {
            try self.syncContainerUpload(bundleId: bundleId, from: localRoot, clearing: clearing, keeping: keeping, control: control, progress: progress)
        }
    }
}
