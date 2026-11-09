#if targetEnvironment(simulator)
import Foundation
import CoreLocation
import UIKit
import IdeviceGateway

/// 模拟器没有回环设备服务；用一组示例数据让界面和测试可以运行。数据格式与真机服务返回的一致。
actor SampleDeviceToolsBackend: DeviceToolsBackend {
    nonisolated var isSample: Bool { true }
    private var profiles: [String: Data]
    private var apps: [String: [String: Any]]
    private var files: [String: (isDirectory: Bool, data: Data)]
    enum TerminationBehavior { case exit, reject, ignore, delayed, verificationFails, desktopRestart }
    private let terminationBehavior: TerminationBehavior
    private(set) var terminationRequests: [UInt32] = []
    private(set) var signalPermissionChecks: [UInt32] = []
    private var pendingTermination: (pid: UInt32, polls: Int)?
    enum ProcessReadingBehavior { case normal, heldUsage, delayedUsage, failedUsage, sparseUsage }
    private let processReadingBehavior: ProcessReadingBehavior
    private var heldUsage: CheckedContinuation<Void, Never>?
    private var failProcessReads = false
    private(set) var usageStarted = false

    init(now: Date = Date(), terminationBehavior: TerminationBehavior = .exit, processReadingBehavior: ProcessReadingBehavior = .normal) {
        #if DEBUG
        self.terminationBehavior = ProcessInfo.processInfo.arguments.contains("--process-review-deny-termination") ? .reject : terminationBehavior
        self.processReadingBehavior = ProcessInfo.processInfo.arguments.contains("--process-review-slow-usage") ? .delayedUsage : processReadingBehavior
        #else
        self.terminationBehavior = terminationBehavior
        self.processReadingBehavior = processReadingBehavior
        #endif
        func profile(_ uuid: String, _ name: String, app: String, team: String = "TESTTEAM01", days: Double, debug: Bool = true) -> Data {
            let plist: [String: Any] = ["UUID": uuid, "Name": name, "AppIDName": name, "TeamName": "示例团队", "TeamIdentifier": [team],
                                        "CreationDate": now.addingTimeInterval((days - 7) * 86_400), "ExpirationDate": now.addingTimeInterval(days * 86_400),
                                        "Entitlements": ["application-identifier": team + "." + app, "get-task-allow": debug],
                                        "ProvisionedDevices": ["00000000-0000000000000001"]]
            let xml = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
            return Data([0x30, 0x82, 0x01]) + xml + Data([0xA0, 0x00])
        }
        profiles = [
            "A1": profile("A1", "Retools", app: "com.reukix.retools", days: 5.2),
            "B2": profile("B2", "UTM", app: "com.utmapp.UTM", days: 3.1),
            "B1": profile("B1", "UTM", app: "com.utmapp.UTM", days: 0.6),
            "C1": profile("C1", "旧版游戏", app: "com.example.game", days: -2),
            "D1": profile("D1", "已卸载的工具", app: "com.example.tool", days: 4),
        ]
        apps = [
            "com.reukix.retools": ["CFBundleIdentifier": "com.reukix.retools", "CFBundleDisplayName": "Retools", "Path": "/private/var/containers/Bundle/Application/R1/Retools.app", "CFBundleShortVersionString": "0.1.0",
                                   "CFBundleVersion": "39", "SignerIdentity": "Apple Development: 示例", "ProfileValidated": true,
                                   "Entitlements": ["get-task-allow": true], "StaticDiskUsage": 182_000_000, "DynamicDiskUsage": 64_000_000],
            "com.utmapp.UTM": ["CFBundleIdentifier": "com.utmapp.UTM", "CFBundleDisplayName": "UTM", "CFBundleExecutable": "UTM", "Path": "/private/var/containers/Bundle/Application/A1/UTM.app", "CFBundleShortVersionString": "5.0.8",
                               "CFBundleVersion": "121", "SignerIdentity": "Apple Development: 示例", "ProfileValidated": true,
                               "Entitlements": ["get-task-allow": true], "UIFileSharingEnabled": true, "StaticDiskUsage": 412_000_000, "DynamicDiskUsage": 2_300_000_000],
            "com.nssurge.inc.surge-ios": ["CFBundleIdentifier": "com.nssurge.inc.surge-ios", "CFBundleDisplayName": "Surge", "CFBundleShortVersionString": "5.20",
                                          "SignerIdentity": "TestFlight Beta Distribution", "ProfileValidated": true, "StaticDiskUsage": 88_000_000],
            "com.apple.store.Jolly": ["CFBundleIdentifier": "com.apple.store.Jolly", "CFBundleDisplayName": "Apple Store", "CFBundleShortVersionString": "5.30",
                                      "SignerIdentity": "Apple iPhone OS Application Signing", "StaticDiskUsage": 98_000_000,
                                      "UIFileSharingEnabled": true, "ApplicationType": "User"],
        ]
        files = [
            "com.utmapp.UTM|/Documents": (true, Data()),
            "com.utmapp.UTM|/Documents/Windows 11.utm": (true, Data()),
            "com.utmapp.UTM|/Documents/Windows 11.utm/config.plist": (false, Data("<plist></plist>".utf8)),
            "com.utmapp.UTM|/Documents/说明.txt": (false, Data("这是模拟器示例文件。".utf8)),
            "com.utmapp.UTM|/Library": (true, Data()),
            "com.utmapp.UTM|/Library/Preferences": (true, Data()),
            "com.utmapp.UTM|/tmp": (true, Data()),
        ]
    }

    func reset() {}
    private var developerImageMounted = false
    func isDeveloperImageMounted() async throws -> Bool { developerImageMounted }
    func mountDeveloperImage(_ files: DeveloperDiskImage.Files) async throws { developerImageMounted = true }

    private var sampleProcesses: [DeviceProcessInfo] = [
        DeviceProcessInfo(pid: 101, name: "UTM", appName: "/var/containers/Bundle/Application/A1/UTM.app/UTM", isApplication: true, cpu: 42.5, memory: 1_850_000_000),
        DeviceProcessInfo(pid: 102, name: "Retools", appName: "/var/containers/Bundle/Application/R1/Retools.app/Retools", isApplication: true, cpu: 3.1, memory: 96_000_000),
        DeviceProcessInfo(pid: 103, name: "RetoolsPairing", appName: "/var/containers/Bundle/Application/R1/Retools.app/PlugIns/RetoolsPairing.appex/RetoolsPairing",
                          isApplication: true, cpu: 0, memory: 12_000_000),
        DeviceProcessInfo(pid: 55, name: "SpringBoard", appName: "/System/Library/CoreServices/SpringBoard.app/SpringBoard", isApplication: false, cpu: 1.2, memory: 210_000_000),
        DeviceProcessInfo(pid: 66, name: "backboardd", appName: "/usr/libexec/backboardd", isApplication: false, cpu: 0.4, memory: 48_000_000),
    ]
    private(set) var liftedLimits: Set<UInt32> = []
    func runningProcesses(withUsage: Bool) async throws -> [DeviceProcessInfo] {
        if failProcessReads { throw WorkspaceFailure("进程服务读取失败") }
        if !terminationRequests.isEmpty, terminationBehavior == .verificationFails { throw WorkspaceFailure("无法查询进程列表") }
        if let pending = pendingTermination {
            if pending.polls == 0 {
                sampleProcesses.removeAll { $0.pid == pending.pid }; pendingTermination = nil
            } else { pendingTermination = (pending.pid, pending.polls - 1) }
        }
        return sampleProcesses
    }
    func killProcess(pid: UInt32) async throws {
        terminationRequests.append(pid)
        switch terminationBehavior {
        case .exit, .verificationFails: sampleProcesses.removeAll { $0.pid == pid }
        case .reject: throw WorkspaceFailure("设备拒绝结束这个进程")
        case .ignore: break
        case .delayed: pendingTermination = (pid, 2)
        case .desktopRestart:
            if var process = sampleProcesses.first(where: { $0.pid == pid }) {
                sampleProcesses.removeAll { $0.pid == pid }; process.pid += 100; sampleProcesses.append(process)
            }
        }
    }
    func checkProcessSignalPermission(pid: UInt32) async throws {
        signalPermissionChecks.append(pid)
        if terminationBehavior == .reject { throw WorkspaceFailure("设备拒绝控制桌面进程") }
    }
    private var usageTicks = 0
    func releaseUsage() { heldUsage?.resume(); heldUsage = nil }
    func setProcessReadFailure(_ value: Bool) { failProcessReads = value }
    /// 内存每次取样增长 50 MB，模拟正在吃内存的应用。
    func processUsage(pids: Set<UInt32>?) async throws -> [UInt32: DeviceProcessUsage] {
        usageStarted = true
        if processReadingBehavior == .heldUsage, pids == nil { await withCheckedContinuation { heldUsage = $0 } }
        if processReadingBehavior == .delayedUsage, pids == nil { try await Task.sleep(for: .seconds(6)) }
        if processReadingBehavior == .failedUsage { throw WorkspaceFailure("取样服务没有响应") }
        usageTicks += 1
        var result: [UInt32: DeviceProcessUsage] = [:]
        for process in sampleProcesses where pids?.contains(process.pid) ?? true {
            if processReadingBehavior == .sparseUsage, process.pid == 101 { continue }
            result[process.pid] = DeviceProcessUsage(cpu: process.cpu, memory: (process.memory ?? 0) + Int64(usageTicks) * 50_000_000)
        }
        return result
    }
    func disableMemoryLimit(pid: UInt32) async throws { liftedLimits.insert(pid) }
    func launchApp(bundleID: String) async throws -> UInt32 {
        guard developerImageMounted else { throw WorkspaceFailure("开发者镜像未挂载") }
        let pid = UInt32(200 + sampleProcesses.count)
        sampleProcesses.append(DeviceProcessInfo(pid: pid, name: bundleID, appName: bundleID, isApplication: true, cpu: 0, memory: 20_000_000))
        return pid
    }
    let location = SampleLocationChannel()
    nonisolated func openLocationChannel(host: String, port: UInt16, udid: String) async throws -> DeviceLocationChannel {
        await location.reopen()
        return location
    }
    func connect(host: String, port: UInt16, udid: String) async throws {}
    func appSizes(type: String) async throws -> [Data] {
        apps.values.compactMap { app -> Data? in
            let sizes: [String: Any] = ["CFBundleIdentifier": app["CFBundleIdentifier"] ?? "", "StaticDiskUsage": app["StaticDiskUsage"] ?? 0,
                                        "DynamicDiskUsage": app["DynamicDiskUsage"] ?? 0]
            return try? PropertyListSerialization.data(fromPropertyList: sizes, format: .xml, options: 0)
        }
    }
    func installedApps(type: String) async throws -> [Data] {
        let system: [[String: Any]] = [
            ["CFBundleIdentifier": "com.apple.mobilesafari", "CFBundleDisplayName": "Safari 浏览器", "ApplicationType": "System", "CFBundleShortVersionString": "27.0"],
            ["CFBundleIdentifier": "com.apple.weather", "CFBundleDisplayName": "天气", "ApplicationType": "System", "CFBundleShortVersionString": "27.0"],
        ]
        let source = type == "System" ? system : Array(apps.values)
        return source.compactMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0) }
    }
    func provisioningProfiles() async throws -> [Data] { Array(profiles.values) }
    func removeProfile(uuid: String) async throws { profiles[uuid] = nil }
    func installProfile(_ data: Data) async throws {
        guard let profile = DeviceProfile.parse(data) else { throw WorkspaceFailure("描述文件无效。") }
        profiles[profile.uuid] = data
    }
    func uninstall(bundleID: String) async throws { apps[bundleID] = nil }
    func lockdownValues(domain: String?) async throws -> Data {
        let values: [String: Any]
        switch domain {
        case "com.apple.disk_usage": values = ["TotalDiskCapacity": 256_000_000_000 as Int64, "AmountDataAvailable": 61_400_000_000 as Int64, "TotalDataAvailable": 73_900_000_000 as Int64]
        case "com.apple.mobile.battery": values = ["BatteryCurrentCapacity": 78, "BatteryIsCharging": true, "ExternalConnected": true]
        default: values = ["DeviceName": "示例 iPhone", "ProductType": "iPhone17,1", "ProductVersion": "27.0", "BuildVersion": "24A5300a",
                           "HardwareModel": "D93AP", "SerialNumber": "SAMPLE0000", "UniqueDeviceID": "00000000-0000000000000001",
                           "WiFiAddress": "aa:bb:cc:dd:ee:ff", "ActivationState": "Activated"]
        }
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    private func key(_ bundleID: String, _ path: String) -> String { bundleID + "|" + path }
    private func access(_ bundleID: String) throws -> DeviceContainerAccess {
        guard let app = apps[bundleID] else { throw WorkspaceFailure("应用未安装。") }
        if (app["Entitlements"] as? [String: Any])?["get-task-allow"] as? Bool == true { return .container }
        if app["UIFileSharingEnabled"] as? Bool == true { return .documents }
        throw WorkspaceFailure("这个应用不允许访问文件。")
    }

    func containerEntries(bundleID: String, path: String) async throws -> (access: DeviceContainerAccess, entries: [DeviceFileItem]) {
        let mode = try access(bundleID)
        let root = mode == .documents && path == "/" ? "/Documents" : path
        let prefix = key(bundleID, root == "/" ? "" : root) + "/"
        let items = files.compactMap { (key, value) -> DeviceFileItem? in
            guard key.hasPrefix(prefix), !key.dropFirst(prefix.count).contains("/") else { return nil }
            return DeviceFileItem(path: String(key.split(separator: "|", maxSplits: 1)[1]), isDirectory: value.isDirectory,
                                  size: Int64(value.data.count), modified: Date().addingTimeInterval(-3600))
        }
        return (mode, items)
    }
    func containerRead(bundleID: String, path: String) async throws -> Data {
        guard let file = files[key(bundleID, path)], !file.isDirectory else { throw WorkspaceFailure("文件不存在。") }
        return file.data
    }
    func containerWrite(bundleID: String, path: String, data: Data) async throws { _ = try access(bundleID); files[key(bundleID, path)] = (false, data) }
    func containerMakeDirectory(bundleID: String, path: String) async throws { _ = try access(bundleID); files[key(bundleID, path)] = (true, Data()) }
    // MARK: 诊断

    private var crashes: [String: Data] = SampleDeviceToolsBackend.sampleCrashes()

    private static func sampleCrashes() -> [String: Data] {
        let header = #"{"app_name":"UTM","app_version":"5.0.8","build_version":"121","bundleID":"com.utmapp.UTM","os_version":"iPhone OS 27.0 (24A5300a)","bug_type":"309","name":"UTM"}"#
        let body = #"{"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x0000000000000010"},"termination":{"namespace":"SIGNAL","indicator":"Segmentation fault: 11"},"faultingThread":0,"threads":[{"frames":[{"imageIndex":1,"symbol":"qemu_ram_alloc","imageOffset":4096},{"imageIndex":0,"symbol":"main","imageOffset":512}]}],"usedImages":[{"name":"UTM"},{"name":"qemu-aarch64-softmmu"}]}"#
        return [
            "/UTM-2026-11-08-101112.ips": Data((header + "\n" + body).utf8),
            "/Retired/UTM-2026-11-01-080000.ips": Data((header + "\n" + body).utf8),
            "/JetsamEvent-2026-11-07-220000.ips": Data(#"{"bug_type":"298"}"#.utf8),
        ]
    }

    func crashReports() async throws -> [DeviceFileItem] {
        crashes.map { DeviceFileItem(path: $0.key, isDirectory: false, size: Int64($0.value.count), modified: nil) }
    }
    func crashReport(path: String) async throws -> Data {
        guard let data = crashes[path] else { throw WorkspaceFailure("报告不存在。") }
        return data
    }
    func removeCrashReports(paths: [String]) async throws { for path in paths { crashes[path] = nil } }
    func batteryRegistry() async throws -> Data {
        let values: [String: Any] = ["IORegistry": ["CycleCount": 312, "DesignCapacity": 3_561, "AppleRawMaxCapacity": 3_204,
                                                    "Temperature": 3_120, "Voltage": 4_012, "MaxCapacity": 100]]
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }
    nonisolated func streamLogs(host: String, port: UInt16, udid: String, control: DeviceStreamControl,
                                onRecord: @escaping @Sendable (DeviceLogRecord) -> Void) async throws {
        let samples: [(String, UInt8, String, String)] = [
            ("/Applications/UTM.app/UTM", 0, "com.utmapp.UTM", "虚拟机已启动"),
            ("/usr/libexec/installd", 1, "com.apple.installd", "Install of com.utmapp.UTM complete"),
            ("/Applications/UTM.app/UTM", 10, "com.utmapp.UTM", "JIT 未启用，切换到解释执行"),
            ("/System/Library/CoreServices/SpringBoard.app/SpringBoard", 2, "com.apple.springboard", "Scene update"),
        ]
        var index = 0
        while !control.isStopped {
            let sample = samples[index % samples.count]
            onRecord(DeviceLogRecord(pid: UInt32(100 + index % samples.count), timestampRaw: Int64(Date().timeIntervalSince1970), level: sample.1,
                                     imageName: sample.0, processPath: sample.0, subsystem: sample.2, category: "sample", message: sample.3))
            index += 1
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    nonisolated func appIcons(bundleIDs: [String]) async throws -> [String: Data] {
        // 用 Bundle ID 生成一个有颜色的方块，模拟真机返回的 PNG 图标。
        await MainActor.run {
            var result: [String: Data] = [:]
            for id in bundleIDs {
                let hue = CGFloat(abs(id.hashValue % 360)) / 360
                let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60)).image { context in
                    UIColor(hue: hue, saturation: 0.55, brightness: 0.9, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
                    let letter = NSAttributedString(string: String(id.split(separator: ".").last?.prefix(1) ?? "?").uppercased(),
                                                    attributes: [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.white])
                    letter.draw(at: CGPoint(x: 30 - letter.size().width / 2, y: 30 - letter.size().height / 2))
                }
                result[id] = image.pngData()
            }
            return result
        }
    }

    func containerDownload(bundleID: String, to local: URL, excluding: Set<String>, control: DeviceStreamControl,
                           progress: @escaping @Sendable (Int, Int64) -> Void) async throws -> DeviceContainerAccess {
        let mode = try access(bundleID)
        var files = 0, bytes: Int64 = 0
        for (key, value) in files_(of: bundleID) {
            let path = key
            if excluding.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            if mode == .documents, !path.hasPrefix("/Documents") { continue }
            let target = local.appendingPathComponent(String(path.dropFirst()))
            if value.isDirectory { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true); continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try value.data.write(to: target)
            files += 1; bytes += Int64(value.data.count); progress(files, bytes)
        }
        return mode
    }

    func containerUpload(bundleID: String, from local: URL, clearing: [String], keeping: Set<String>, control: DeviceStreamControl,
                         progress: @escaping @Sendable (Int, Int64) -> Void) async throws {
        let mode = try access(bundleID)
        for directory in clearing where mode == .container || directory == "/Documents" {
            files = files.filter { key, _ in
                guard key.hasPrefix(bundleID + "|" + directory + "/") else { return true }
                let path = String(key.dropFirst(bundleID.count + 1))
                return keeping.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
        }
        var count = 0, bytes: Int64 = 0
        let root = mode == .documents ? local.appendingPathComponent("Documents") : local
        let base = mode == .documents ? "/Documents" : ""
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let item = enumerator?.nextObject() as? URL {
            let relative = String(item.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count))
            let path = base + relative
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let data = isDirectory ? Data() : try Data(contentsOf: item)
            files[key(bundleID, path)] = (isDirectory, data)
            if !isDirectory { count += 1; bytes += Int64(data.count); progress(count, bytes) }
        }
    }

    private func files_(of bundleID: String) -> [(String, (isDirectory: Bool, data: Data))] {
        files.compactMap { key, value in key.hasPrefix(bundleID + "|") ? (String(key.dropFirst(bundleID.count + 1)), value) : nil }
    }

    func containerRemove(bundleID: String, path: String) async throws {
        let target = key(bundleID, path)
        files = files.filter { $0.key != target && !$0.key.hasPrefix(target + "/") }
    }
}
/// 记录设置过的位置，模拟器里代替真实的定位连接。
actor SampleLocationChannel: DeviceLocationChannel {
    private(set) var history: [CLLocationCoordinate2D] = []
    private(set) var cleared = false
    private(set) var opened = 0
    var failNextSet = false
    func reopen() { opened += 1 }
    func set(_ coordinate: CLLocationCoordinate2D) async throws {
        if failNextSet { failNextSet = false; throw WorkspaceFailure("模拟断线") }
        history.append(coordinate); cleared = false
    }
    func clear() async throws { cleared = true }
    func close() async {}
    func failOnce() { failNextSet = true }
}
#endif
