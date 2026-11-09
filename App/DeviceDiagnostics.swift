import Foundation
import IdeviceGateway

// MARK: - 崩溃日志

/// 设备崩溃日志目录里的一份报告。文件名形如 `UTM-2026-11-08-101112.ips`。
struct DeviceCrashEntry: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case crash, memory, resource, other }
    var id: String { path }
    var path: String
    var name: String
    var process: String
    var date: Date?
    var size: Int64
    var kind: Kind

    var kindTitle: String {
        switch kind { case .crash: "崩溃"; case .memory: "内存不足被终止"; case .resource: "资源占用超限"; case .other: "诊断报告" }
    }

    init?(_ item: DeviceFileItem) {
        guard !item.isDirectory else { return nil }
        let base = (item.name as NSString).deletingPathExtension
        let ext = (item.name as NSString).pathExtension.lowercased()
        guard ["ips", "crash", "synced", "panic", "log"].contains(ext) || item.name.contains(".ips") else { return nil }
        path = item.path; name = item.name; size = item.size
        var process = base
        if let match = base.range(of: #"-\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) {
            process = String(base[..<match.lowerBound])
            let stamp = String(base[match]).dropFirst()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            date = formatter.date(from: String(stamp)) ?? item.modified
        } else { date = item.modified }
        // 资源类报告的文件名前缀带类型：ExcResource_UTM-…、ExcUserFault_UTM-…
        if let underscore = process.firstIndex(of: "_"), process.hasPrefix("Exc") {
            kind = .resource; process = String(process[process.index(after: underscore)...])
        } else if process.hasPrefix("JetsamEvent") {
            kind = .memory; process = "系统"
        } else if ["Stacks", "LowBatteryLog", "WiFi", "SiriSearchFeedback", "Bluetooth"].contains(where: process.hasPrefix) {
            kind = .other
        } else { kind = .crash }
        if process.contains(".") { process = String(process.split(separator: ".").first ?? Substring(process)) }
        self.process = process
    }
}

/// 解析后的崩溃详情。新格式 .ips 是一行 JSON 头加一段 JSON 正文；旧格式为纯文本。
struct DeviceCrashDetail: Sendable {
    var appName = ""
    var bundleID = ""
    var version = ""
    var osVersion = ""
    var exception = ""
    var termination = ""
    var crashedThread: Int?
    var frames: [String] = []
    var text = ""

    static func parse(_ data: Data) -> DeviceCrashDetail {
        var detail = DeviceCrashDetail()
        let text = String(decoding: data, as: UTF8.self)
        detail.text = text
        guard let newline = text.firstIndex(of: "\n"),
              let header = try? JSONSerialization.jsonObject(with: Data(text[..<newline].utf8)) as? [String: Any] else {
            return parseLegacy(text, into: detail)
        }
        detail.appName = header["app_name"] as? String ?? header["name"] as? String ?? ""
        detail.bundleID = header["bundleID"] as? String ?? ""
        detail.version = [header["app_version"] as? String, (header["build_version"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        detail.osVersion = header["os_version"] as? String ?? ""
        guard let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8)) as? [String: Any] else { return detail }
        if let exception = body["exception"] as? [String: Any] {
            detail.exception = [exception["type"] as? String, exception["signal"] as? String, exception["subtype"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if let termination = body["termination"] as? [String: Any] {
            detail.termination = [termination["namespace"] as? String, termination["indicator"] as? String,
                                  (termination["reasons"] as? [String])?.joined(separator: "；")]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if let index = body["faultingThread"] as? Int, let threads = body["threads"] as? [[String: Any]], threads.indices.contains(index) {
            detail.crashedThread = index
            let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
            detail.frames = (threads[index]["frames"] as? [[String: Any]] ?? []).prefix(12).enumerated().map { offset, frame in
                let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?"
                let symbol = frame["symbol"] as? String ?? (frame["imageOffset"] as? Int).map { "+0x" + String($0, radix: 16) } ?? ""
                return "\(offset)  \(image)  \(symbol)"
            }
        }
        return detail
    }

    private static func parseLegacy(_ text: String, into detail: DeviceCrashDetail) -> DeviceCrashDetail {
        var detail = detail
        for line in text.split(separator: "\n").prefix(80) {
            func value(_ key: String) -> String? { line.hasPrefix(key) ? line.dropFirst(key.count).trimmingCharacters(in: .whitespaces) : nil }
            if let v = value("Process:") { detail.appName = v.components(separatedBy: " [").first ?? v }
            if let v = value("Identifier:") { detail.bundleID = v }
            if let v = value("Version:") { detail.version = v }
            if let v = value("OS Version:") { detail.osVersion = v }
            if let v = value("Exception Type:") { detail.exception = v }
            if let v = value("Termination Reason:") { detail.termination = v }
        }
        return detail
    }
}

// MARK: - 电池健康

struct DeviceBatteryHealth: Equatable, Sendable, Codable {
    var cycleCount: Int?
    var designCapacity: Int?
    var maxCapacity: Int?
    /// 摄氏度。
    var temperature: Double?
    /// 毫伏。
    var voltage: Int?

    var healthPercent: Int? {
        guard let design = designCapacity, design > 0, let max = maxCapacity, max > 0 else { return nil }
        return min(100, Int((Double(max) / Double(design) * 100).rounded()))
    }

    /// 充电器描述与功率（瓦），接通电源时才有。
    var charger: String?
    var chargerWatts: Int?

    /// 诊断服务返回 IOPMPowerSource 的注册表项（在 `IORegistry` 下）。新系统把容量放在 `BatteryData` 子字典里，
    /// 旧系统在顶层，两处都看。
    static func parse(_ data: Data) -> DeviceBatteryHealth? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let values = root["IORegistry"] as? [String: Any] ?? root
        let battery = values["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { ((battery[key] ?? values[key]) as? NSNumber)?.intValue }
        // MaxCapacity 在新系统上是百分比（≤100），只有 mAh 数值才能用来算健康度。
        // 「设置」里的最大容量对应 NominalChargeCapacity（AppleRawMaxCapacity 是旧系统的同义字段）。
        let raw = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? int("FullChargeCapacity") ?? int("MaxCapacity").flatMap { $0 > 100 ? $0 : nil }
        let adapter = values["AdapterDetails"] as? [String: Any] ?? [:]
        let connected = values["ExternalConnected"] as? Bool ?? false
        var health = DeviceBatteryHealth(cycleCount: int("CycleCount"), designCapacity: int("DesignCapacity"), maxCapacity: raw,
                                         temperature: (int("Temperature") ?? int("VirtualTemperature")).map { Double($0) / 100 },
                                         voltage: int("Voltage") ?? int("AppleRawBatteryVoltage"))
        if connected {
            health.charger = (adapter["Description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            health.chargerWatts = (adapter["Watts"] as? NSNumber)?.intValue
        }
        return health.cycleCount == nil && health.designCapacity == nil ? nil : health
    }
}

// MARK: - 实时日志

struct DeviceLogLine: Identifiable, Sendable, Equatable {
    var id: Int
    var date: Date
    var level: UInt8
    var process: String
    var pid: UInt32
    var subsystem: String
    var category: String
    var message: String

    var isError: Bool { level >= 10 }
    var levelTitle: String {
        switch level { case 0: "默认"; case 1: "信息"; case 2: "调试"; case 10: "错误"; case 11: "故障"; default: "\(level)" }
    }

    init(id: Int, record: DeviceLogRecord, received: Date = Date()) {
        self.id = id
        date = DeviceFileItem.date(fromRaw: record.timestampRaw) ?? received
        level = record.level
        let path = record.processPath.isEmpty ? record.imageName : record.processPath
        process = (path as NSString).lastPathComponent
        pid = record.pid; subsystem = record.subsystem; category = record.category
        message = record.message
    }

    func matches(query: String) -> Bool {
        query.isEmpty || message.localizedCaseInsensitiveContains(query) || process.localizedCaseInsensitiveContains(query)
            || subsystem.localizedCaseInsensitiveContains(query)
    }

    var exportLine: String {
        let time = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        let label = [subsystem, category].filter { !$0.isEmpty }.joined(separator: ":")
        return "\(time) \(process)[\(pid)] <\(levelTitle)>\(label.isEmpty ? "" : " (\(label))") \(message)"
    }
}

/// 后台线程收到的日志先放进这里，主线程定时取走，避免每条日志刷新一次界面。
final class DeviceLogInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [DeviceLogRecord] = []
    private var dropped = 0
    func push(_ record: DeviceLogRecord) {
        lock.lock(); defer { lock.unlock() }
        if pending.count >= 5_000 { pending.removeFirst(1_000); dropped += 1_000 }
        pending.append(record)
    }
    func drain() -> (records: [DeviceLogRecord], dropped: Int) {
        lock.lock(); defer { lock.unlock() }
        let result = (pending, dropped); pending = []; dropped = 0
        return result
    }
}

@MainActor
final class DeviceLogStore: ObservableObject {
    static let shared = DeviceLogStore()
    static let capacity = 3_000

    @Published private(set) var lines: [DeviceLogLine] = []
    @Published private(set) var isRunning = false
    @Published var paused = false
    @Published var query = ""
    @Published var process: String?
    @Published var errorsOnly = false
    @Published private(set) var failure: String?
    @Published private(set) var dropped = 0

    private var control: DeviceStreamControl?
    private var nextID = 0
    private var pump: Task<Void, Never>?
    private let inbox = DeviceLogInbox()
    let backend: DeviceToolsBackend

    init(backend: DeviceToolsBackend? = nil) { self.backend = backend ?? DeviceToolsStore.shared.backend }

    var visible: [DeviceLogLine] {
        lines.filter { (!errorsOnly || $0.isError) && (process == nil || $0.process == process) && $0.matches(query: query) }
    }
    /// 已出现过的进程，按出现次数排序，供筛选。
    var processes: [String] {
        Dictionary(grouping: lines, by: \.process).sorted { $0.value.count > $1.value.count }.map(\.key).filter { !$0.isEmpty }
    }

    func start(renewal: RenewalController) {
        guard !isRunning else { return }
        guard backend.isSample || renewal.settings.hasPairing else { failure = "请先在「设备配对与连接」里配对这台 iPhone，并打开回环代理。"; return }
        let control = DeviceStreamControl()
        self.control = control
        isRunning = true; failure = nil
        let inbox = inbox, backend = backend
        let (host, port, udid) = (renewal.settings.hostIP, renewal.settings.remotePort, renewal.settings.deviceUDID)
        Task.detached {
            do { try await backend.streamLogs(host: host, port: port, udid: udid, control: control) { inbox.push($0) } }
            catch { await MainActor.run { if !control.isStopped { self.failure = error.localizedDescription } } }
            await MainActor.run { if self.control === control { self.isRunning = false; self.control = nil } }
        }
        pump?.cancel()
        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                self?.drain()
            }
        }
    }

    func stop() {
        control?.stop(); control = nil
        isRunning = false
        pump?.cancel(); pump = nil
        drain()
    }

    func clear() { lines = []; dropped = 0 }

    /// 退到后台后系统会挂起连接，日志流不会再有新内容；停止并提示重新开始。
    func appDidEnterBackground() {
        guard isRunning else { return }
        stop()
        failure = "Retools 退到后台时已停止接收。点右上角重新开始。"
    }

    private func drain() {
        // 暂停时先留在收件箱里（最多 5000 条），继续后一起显示。
        guard !paused else { return }
        let batch = inbox.drain()
        guard !batch.records.isEmpty || batch.dropped > 0 else { return }
        dropped += batch.dropped
        let now = Date()
        let new = batch.records.map { record -> DeviceLogLine in nextID += 1; return DeviceLogLine(id: nextID, record: record, received: now) }
        lines.append(contentsOf: new)
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
    }

    /// 导出当前筛选结果为文本文件。
    func export() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceFiles/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Retools-日志-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))).txt")
        try visible.map(\.exportLine).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
