//
//  IdeviceGateway+DeveloperServices.swift
//  Retools
//
//  Local additions: developer (DVT) services that need the developer disk image mounted:
//  location simulation (kept open as a session), running processes with CPU / memory usage,
//  killing processes, lifting memory limits and launching apps. Remote Pairing (RSD) only.
//

import Foundation
import Darwin
import IDevice
import MinimuxerCommon

public struct DeviceProcessInfo: Sendable, Hashable {
    public var pid: UInt32
    public var name: String
    public var appName: String
    public var isApplication: Bool
    /// Percent of one core; nil when usage sampling was not available.
    public var cpu: Double?
    /// Physical footprint in bytes.
    public var memory: Int64?

    public init(pid: UInt32, name: String, appName: String, isApplication: Bool, cpu: Double?, memory: Int64?) {
        self.pid = pid; self.name = name; self.appName = appName; self.isApplication = isApplication; self.cpu = cpu; self.memory = memory
    }

    /// CoreDevice returns a file URL, while the existing browser/naming code uses a path.
    public init(pid: UInt32, executableURL: String?) {
        let raw = executableURL ?? ""
        let path = URL(string: raw).flatMap { $0.isFileURL ? $0.path : nil } ?? (raw.hasPrefix("/") ? raw : "")
        self.init(pid: pid, name: path.isEmpty ? "进程 \(pid)" : (path as NSString).lastPathComponent,
                  appName: path, isApplication: path.split(separator: "/").contains { $0.hasSuffix(".app") }, cpu: nil, memory: nil)
    }
}

public struct DeviceProcessUsage: Sendable, Hashable {
    public var cpu: Double?
    public var memory: Int64?
    public init(cpu: Double?, memory: Int64?) { self.cpu = cpu; self.memory = memory }
}

/// Keeps one developer-tools connection open for location simulation. The simulated
/// location only lasts while this connection stays open.
public final class DeviceLocationSession: @unchecked Sendable {
    private let gateway: IdeviceGateway
    private var server: OpaquePointer?
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "dev.retools.location-session")

    fileprivate init(gateway: IdeviceGateway, server: OpaquePointer, handle: OpaquePointer) {
        self.gateway = gateway; self.server = server; self.handle = handle
    }

    deinit { release() }

    private func release() {
        if let handle { location_simulation_free(handle) }
        if let server { remote_server_free(server) }
        handle = nil; server = nil
    }

    private func run(_ action: String, _ body: @escaping @Sendable (OpaquePointer) -> UnsafeMutablePointer<IdeviceFfiError>?) async throws {
        try await withFFIDispatch(on: queue) { [self] in
            guard let handle else { throw IdeviceGatewayError(.serviceError, reason: "定位连接已关闭") }
            if let err = body(handle) {
                let message = err.pointee.message.map { String(cString: $0) } ?? "错误代码 \(err.pointee.code)"
                idevice_error_free(err)
                throw IdeviceGatewayError(.serviceError, reason: "\(action)：\(message)")
            }
        }
    }

    public func set(latitude: Double, longitude: Double) async throws {
        try await run("设置位置失败") { location_simulation_set($0, latitude, longitude) }
    }

    public func clear() async throws {
        try await run("恢复真实位置失败") { location_simulation_clear($0) }
    }

    /// Closing the connection also ends the simulation on the device.
    public func close() async {
        _ = try? await withFFIDispatch(on: queue) { [self] in release() }
    }
}

extension IdeviceGateway {
    private func requireRemotePairing() throws {
        try verifyInitialized()
        guard pairingFileType == .rppairing else {
            throw IdeviceGatewayError(.serviceError, reason: "开发者工具服务需要 Remote Pairing 配对（iOS 17 及以上）")
        }
    }

    private func dvtFailure(_ action: String, _ err: UnsafeMutablePointer<IdeviceFfiError>) -> IdeviceGatewayError {
        let msg = getErrorMessage(from: err)
        safeFreeError(err)
        return IdeviceGatewayError(.serviceError, reason: "\(action)：\(msg)")
    }

    /// Runs `body` with a fresh developer-tools (DVT) remote server connection.
    private func withRemoteServer<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try requireRemotePairing()
        return try performWithService(connect: remote_server_connect_rsd, cleanup: remote_server_free, serviceName: "remote server", action: body)
    }

    // MARK: Location simulation

    private func syncOpenLocationSession() throws -> DeviceLocationSession {
        try requireRemotePairing()
        try ensureRPConnection()
        var server: OpaquePointer? = nil
        var err = remote_server_connect_rsd(adapter, handshake, &server)
        if let first = err {
            safeFreeError(first)
            invalidateConnection()
            try ensureRPConnection()
            err = remote_server_connect_rsd(adapter, handshake, &server)
        }
        if let err { throw dvtFailure("连接开发者工具失败（请确认开发者镜像已挂载）", err) }
        guard let server else { throw IdeviceGatewayError(.serviceError, reason: "开发者工具连接不可用") }
        var handle: OpaquePointer? = nil
        if let err = location_simulation_new(server, &handle) {
            remote_server_free(server)
            throw dvtFailure("打开定位模拟失败", err)
        }
        guard let handle else { remote_server_free(server); throw IdeviceGatewayError(.serviceError, reason: "定位模拟不可用") }
        return DeviceLocationSession(gateway: self, server: server, handle: handle)
    }

    public func openLocationSession() async throws -> DeviceLocationSession {
        try await withFFIDispatch { try self.syncOpenLocationSession() }
    }

    // MARK: Processes

    /// Attribute names the device supports for sysmontap, in the device's own order.
    private func sysmonAttributes(_ server: OpaquePointer) throws -> (process: [String], system: [String]) {
        var info: OpaquePointer? = nil
        if let err = device_info_new(server, &info) { throw dvtFailure("读取取样字段失败", err) }
        guard let info else { return ([], []) }
        defer { device_info_free(info) }
        func read(_ call: (UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>, UnsafeMutablePointer<UInt>) -> UnsafeMutablePointer<IdeviceFfiError>?) throws -> [String] {
            var list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
            var count: UInt = 0
            if let err = call(&list, &count) { throw dvtFailure("读取取样字段失败", err) }
            guard let list else { return [] }
            defer { device_info_string_array_free(list, count) }
            return (0..<Int(count)).compactMap { list[$0].map { String(cString: $0) } }
        }
        return (try read { device_info_sysmon_process_attributes(info, $0, $1) }, try read { device_info_sysmon_system_attributes(info, $0, $1) })
    }

    /// Numeric value of a plist node (integer or real); nil for other types.
    private static func number(_ node: plist_t?) -> Double? {
        guard let node else { return nil }
        switch plist_get_node_type(node) {
        case PLIST_INT:
            var signed: Int64 = 0
            plist_get_int_val(node, &signed)
            if signed != 0 { return Double(signed) }
            var unsigned: UInt64 = 0
            plist_get_uint_val(node, &unsigned)
            return Double(unsigned)
        case PLIST_REAL:
            var value: Double = 0
            plist_get_real_val(node, &value)
            return value.isFinite ? value : nil
        default: return nil
        }
    }

    /// Walks the `Processes` dictionary (PID string → value array in attribute order) with the
    /// node accessors only, so no conversion of the whole sample is needed.
    static func readUsage(_ processes: plist_t, pidIndex: Int, cpuIndex: Int?, memoryIndex: Int?) -> [UInt32: (cpu: Double?, memory: Int64?)] {
        guard plist_get_node_type(processes) == PLIST_DICT else { return [:] }
        var result: [UInt32: (cpu: Double?, memory: Int64?)] = [:]
        var iterator: plist_dict_iter? = nil
        plist_dict_new_iter(processes, &iterator)
        defer { if let iterator { plist_free(iterator) } }
        guard let iterator else { return [:] }
        for _ in 0..<Int(plist_dict_get_size(processes)) {
            var key: UnsafeMutablePointer<CChar>? = nil
            var value: plist_t? = nil
            plist_dict_next_item(processes, iterator, &key, &value)
            let keyText = key.map { String(cString: $0) }
            if let key { plist_mem_free(key) }
            guard let value, plist_get_node_type(value) == PLIST_ARRAY else { continue }
            let size = Int(plist_array_get_size(value))
            func field(_ index: Int?) -> Double? {
                guard let index, index < size else { return nil }
                return number(plist_array_get_item(value, UInt32(index)))
            }
            guard let pid = field(pidIndex).map({ UInt32(clamping: Int64($0)) }) ?? keyText.flatMap({ UInt32($0) }) else { continue }
            result[pid] = (field(cpuIndex), field(memoryIndex).map { Int64($0) })
        }
        return result
    }

    /// Testing hook: parses a serialized `Processes` dictionary with the library and reads it like a live sample.
    public static func readUsageForTesting(_ data: Data, pidIndex: Int, cpuIndex: Int?, memoryIndex: Int?) -> [UInt32: DeviceProcessUsage] {
        var node: plist_t? = nil
        let status = data.withUnsafeBytes { buffer in
            plist_from_memory(buffer.baseAddress?.assumingMemoryBound(to: CChar.self), UInt32(data.count), &node, nil)
        }
        guard status == PLIST_ERR_SUCCESS, let node else { return [:] }
        defer { plist_free(node) }
        return readUsage(node, pidIndex: pidIndex, cpuIndex: cpuIndex, memoryIndex: memoryIndex).mapValues { DeviceProcessUsage(cpu: $0.cpu, memory: $0.memory) }
    }

    /// CPU / memory per PID from sysmontap, configured the same way as pymobiledevice3
    /// (the device's full attribute lists; values come back in that order).
    /// Returns the usage and, when nothing usable arrived, a note explaining why.
    private func sampleUsage(_ server: OpaquePointer) -> (usage: [UInt32: (cpu: Double?, memory: Int64?)], note: String?) {
        let attributes: (process: [String], system: [String])
        do { attributes = try sysmonAttributes(server) } catch { return ([:], error.localizedDescription) }
        guard let pidIndex = attributes.process.firstIndex(of: "pid") else { return ([:], "设备没有提供 pid 字段（共 \(attributes.process.count) 个字段）") }
        let cpuIndex = attributes.process.firstIndex(of: "cpuUsage"), memoryIndex = attributes.process.firstIndex(of: "physFootprint")
        var tap: OpaquePointer? = nil
        if let err = sysmontap_new(server, &tap) { return ([:], dvtFailure("打开取样失败", err).localizedDescription) }
        guard let tap else { return ([:], "取样通道不可用") }
        defer { sysmontap_free(tap) }
        let processNames = attributes.process.map { strdup($0) }, systemNames = attributes.system.map { strdup($0) }
        defer { (processNames + systemNames).forEach { free($0) } }
        var processPointers = processNames.map { UnsafePointer($0) }, systemPointers = systemNames.map { UnsafePointer($0) }
        let configured: UnsafeMutablePointer<IdeviceFfiError>? = processPointers.withUnsafeMutableBufferPointer { process in
            systemPointers.withUnsafeMutableBufferPointer { system in
                var config = IdeviceSysmontapConfig(interval_ms: 500, process_attributes: process.baseAddress, process_attributes_count: UInt(process.count),
                                                    system_attributes: system.baseAddress, system_attributes_count: UInt(system.count))
                return sysmontap_set_config(tap, &config)
            }
        }
        if let configured { return ([:], dvtFailure("设置取样失败", configured).localizedDescription) }
        if let err = sysmontap_start(tap) { return ([:], dvtFailure("开始取样失败", err).localizedDescription) }
        defer { if let err = sysmontap_stop(tap) { safeFreeError(err) } }
        var result: [UInt32: (cpu: Double?, memory: Int64?)] = [:]
        var rowsWithoutProcesses = 0, lastError: String?
        for _ in 0..<10 {
            var processes: plist_t? = nil
            if let err = sysmontap_next_sample(tap, &processes, nil, nil) { lastError = dvtFailure("读取取样失败", err).localizedDescription; break }
            guard let processes else { rowsWithoutProcesses += 1; continue }
            defer { plist_free(processes) }
            // 逐个读取需要的字段，不把整份数据转换成 plist 文本：取样里有些值无法转换，转换函数会直接让 App 崩溃。
            let sample = Self.readUsage(processes, pidIndex: pidIndex, cpuIndex: cpuIndex, memoryIndex: memoryIndex)
            result = sample
            // 第一批的 CPU 可能还是空的，拿到 CPU 数据就停。
            if sample.values.contains(where: { $0.cpu != nil }) { break }
        }
        if result.isEmpty {
            return ([:], lastError ?? "读了 10 批取样，\(rowsWithoutProcesses) 批没有进程数据；字段数 \(attributes.process.count)/\(attributes.system.count)")
        }
        return (result, nil)
    }

    private func syncRunningProcesses(withUsage: Bool) throws -> [DeviceProcessInfo] {
        try requireRemotePairing()
        let listed: [DeviceProcessInfo] = try performWithService(connect: app_service_connect_rsd, cleanup: app_service_free, serviceName: "app service") { service in
            var processes: UnsafeMutablePointer<ProcessTokenC>?
            var count: UInt = 0
            if let err = app_service_list_processes(service, &processes, &count) { throw dvtFailure("读取进程失败", err) }
            guard let processes else {
                guard count == 0 else { throw IdeviceGatewayError(.serviceError, reason: "设备返回的进程列表不完整") }
                return []
            }
            defer { app_service_free_process_list(processes, count) }
            return (0..<Int(count)).map { index in
                let entry = processes[index]
                return DeviceProcessInfo(pid: entry.pid, executableURL: entry.executable_url.map { String(cString: $0) })
            }
        }
        guard withUsage else { return listed }
        let sampled: (usage: [UInt32: (cpu: Double?, memory: Int64?)], note: String?)
        do { sampled = try withRemoteServer { sampleUsage($0) } } catch { sampled = ([:], error.localizedDescription) }
        return listed.map { var process = $0; process.cpu = sampled.usage[$0.pid]?.cpu; process.memory = sampled.usage[$0.pid]?.memory; return process }
    }

    /// CPU / memory of the given processes (all when `pids` is nil) from one sysmontap sample.
    /// A PID missing from the result is no longer running.
    public func processUsage(pids: Set<UInt32>?) async throws -> [UInt32: DeviceProcessUsage] {
        try await withFFIDispatch {
            let sampled = try self.withRemoteServer { self.sampleUsage($0) }
            if let note = sampled.note, sampled.usage.isEmpty { throw IdeviceGatewayError(.serviceError, reason: "读取 CPU / 内存失败：\(note)") }
            var result: [UInt32: DeviceProcessUsage] = [:]
            for (pid, value) in sampled.usage where pids?.contains(pid) ?? true { result[pid] = DeviceProcessUsage(cpu: value.cpu, memory: value.memory) }
            return result
        }
    }

    public func runningProcesses(withUsage: Bool) async throws -> [DeviceProcessInfo] {
        try await withFFIDispatch { try self.syncRunningProcesses(withUsage: withUsage) }
    }

    private func withProcessControl<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try withRemoteServer { server in
            var control: OpaquePointer? = nil
            if let err = process_control_new(server, &control) { throw dvtFailure("打开进程控制失败", err) }
            guard let control else { throw IdeviceGatewayError(.serviceError, reason: "进程控制不可用") }
            defer { process_control_free(control) }
            return try body(control)
        }
    }

    public func killProcess(pid: UInt32) async throws {
        try await sendProcessSignal(pid: pid, signal: UInt32(SIGKILL))
    }

    /// Signal zero checks whether the device service permits signalling this process.
    /// It neither terminates nor suspends the target.
    public func checkProcessSignalPermission(pid: UInt32) async throws {
        try await sendProcessSignal(pid: pid, signal: 0)
    }

    private func sendProcessSignal(pid: UInt32, signal: UInt32) async throws {
        try await withFFIDispatch {
            let action = signal == 0 ? "检查进程控制权限失败" : "结束进程失败"
            try self.requireRemotePairing()
            guard pid > 0 else { throw IdeviceGatewayError(.serviceError, reason: "进程 PID 无效") }
            // DVT killPid: has no reply; closing its channel can discard the request.
            // CoreDevice's signal API waits for a response before releasing the service.
            try self.performWithService(connect: app_service_connect_rsd, cleanup: app_service_free, serviceName: "app service") { service in
                var response: UnsafeMutablePointer<SignalResponseC>?
                if let err = app_service_send_signal(service, pid, signal, &response) {
                    if let response { app_service_free_signal_response(response) }
                    throw self.dvtFailure(action, err)
                }
                guard let response else { throw IdeviceGatewayError(.serviceError, reason: "设备没有确认进程控制请求") }
                defer { app_service_free_signal_response(response) }
                guard response.pointee.pid == pid, response.pointee.signal == signal else {
                    throw IdeviceGatewayError(.serviceError, reason: "设备返回的进程或信号不匹配，无法确认结束结果")
                }
            }
        }
    }

    public func disableMemoryLimit(pid: UInt32) async throws {
        try await withFFIDispatch {
            try self.withProcessControl { control in
                if let err = process_control_disable_memory_limit(control, UInt64(pid)) { throw self.dvtFailure("解除内存上限失败", err) }
            }
        }
    }

    /// Launches an installed app and returns its PID.
    public func launchApp(bundleId: String, killExisting: Bool) async throws -> UInt32 {
        try await withFFIDispatch {
            try self.withProcessControl { control in
                var pid: UInt64 = 0
                let err = bundleId.withCString { process_control_launch_app(control, $0, nil, 0, nil, 0, false, killExisting, &pid) }
                if let err { throw self.dvtFailure("启动应用失败", err) }
                return UInt32(pid)
            }
        }
    }
}
