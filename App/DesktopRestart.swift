import Foundation
import IdeviceGateway

enum DesktopRestart {
    static let executable = "/System/Library/CoreServices/SpringBoard.app/SpringBoard"
    static var recordURL: URL { WorkspacePaths().support.appendingPathComponent("DesktopRestart.json") }

    struct Record: Codable, Equatable, Sendable {
        var requestedAt: Date
        var originalPID: UInt32
        var submitted = false
        var confirmedPID: UInt32?
        var error: String?
    }

    static func target(in processes: [DeviceProcessInfo]) throws -> DeviceProcessInfo {
        let matches = processes.filter { $0.pid > 1 && $0.appName == executable }
        guard matches.count == 1, let process = matches.first else {
            throw WorkspaceFailure("没有找到唯一的系统桌面进程，未执行注销。请刷新设备连接后重试。")
        }
        return process
    }

    /// Signal zero checks existence/permission only. This method never sends a terminating signal.
    static func inspect(backend: DeviceToolsBackend) async throws -> DeviceProcessInfo {
        let process = try target(in: await backend.runningProcesses(withUsage: false))
        try Task.checkCancellation()
        try await backend.checkProcessSignalPermission(pid: process.pid)
        return process
    }

    static func load(from url: URL = recordURL) -> Record? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }
    static func save(_ record: Record, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func request(backend: DeviceToolsBackend, recordURL: URL = DesktopRestart.recordURL) async throws -> Record {
        let inspected = try await inspect(backend: backend)
        let current = try target(in: await backend.runningProcesses(withUsage: false))
        guard current.pid == inspected.pid else { throw WorkspaceFailure("桌面进程已变化，未发送注销请求，请重试。") }
        try Task.checkCancellation()
        var record = Record(requestedAt: Date(), originalPID: current.pid)
        try save(record, to: recordURL)
        do {
            // One explicit request, never a retry or a fallback to another system process.
            try Task.checkCancellation()
            try await backend.killProcess(pid: current.pid)
            record.submitted = true
            try save(record, to: recordURL)
        } catch {
            record.error = error.localizedDescription
            try? save(record, to: recordURL)
            throw error
        }
        // The app/tunnel may exit during a respring. Keep the record for the next launch.
        do {
            let running = try await backend.runningProcesses(withUsage: false)
            if let new = try? target(in: running), new.pid != record.originalPID { record.confirmedPID = new.pid }
        } catch { record.error = "请求已发出，暂时无法核对桌面进程：\(error.localizedDescription)" }
        try save(record, to: recordURL)
        return record
    }

    static func verify(backend: DeviceToolsBackend, recordURL: URL = DesktopRestart.recordURL) async throws -> Record? {
        guard var record = load(from: recordURL), record.confirmedPID == nil else { return load(from: recordURL) }
        let current = try target(in: await backend.runningProcesses(withUsage: false))
        if current.pid != record.originalPID {
            record.confirmedPID = current.pid; record.error = nil
            try save(record, to: recordURL)
        }
        return record
    }
}
