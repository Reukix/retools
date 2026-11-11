import Foundation
import UIKit
import Security
import IdeviceGateway

// MARK: - 模型与解析

/// 设备上安装的一份描述文件。
struct DeviceProfile: Identifiable, Hashable, Sendable, Codable {
    var id: String { uuid }
    var uuid: String
    var name: String
    var appIDName: String
    var teamName: String
    var teamID: String
    /// application-identifier 去掉团队前缀，可能以 `*` 结尾。
    var appIdentifier: String
    var created: Date?
    var expires: Date?
    var debuggable: Bool
    var deviceCount: Int
    var allDevices: Bool
    /// 原始描述文件，删除前存进「最近删除」，可以装回去。
    var raw = Data()
    /// 描述文件允许的签名证书名称（证书主题，如「Apple Development: 名字 (ID)」），与应用的 SignerIdentity 对应。
    var certificateNames: [String] = []

    func isExpired(now: Date = Date()) -> Bool { expires.map { $0 <= now } ?? false }
    var isWildcard: Bool { appIdentifier.hasSuffix("*") }

    /// 应用实际依赖哪份描述文件，由签名里的 application-identifier（团队 + App ID）决定，
    /// 证书签名时它可能和 Bundle ID 完全不同；没有这项权限信息时才退回比较 Bundle ID。
    func matches(app: DeviceInstalledApp) -> Bool {
        if !app.signedAppID.isEmpty {
            if !app.signedTeamID.isEmpty, !teamID.isEmpty, app.signedTeamID != teamID { return false }
            return matches(bundleID: app.signedAppID)
        }
        return matches(bundleID: app.bundleID)
    }

    /// 应用扩展的 App ID 以主应用的 App ID 加后缀命名，例如 dev.retools.ios.pairing。
    func belongsToExtension(of app: DeviceInstalledApp) -> Bool {
        guard !isWildcard else { return false }
        if !app.signedTeamID.isEmpty, !teamID.isEmpty, app.signedTeamID != teamID { return false }
        return [app.signedAppID, app.bundleID].contains { !$0.isEmpty && appIdentifier.hasPrefix($0 + ".") }
    }

    func matches(bundleID: String) -> Bool {
        if isWildcard { return bundleID.hasPrefix(String(appIdentifier.dropLast())) }
        return appIdentifier == bundleID
    }

    /// 描述文件是 CMS 签名数据，明文 plist 夹在中间。
    static func parse(_ data: Data) -> DeviceProfile? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let uuid = plist["UUID"] as? String, !uuid.isEmpty else { return nil }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let teamID = (plist["TeamIdentifier"] as? [String])?.first ?? ""
        let applicationIdentifier = entitlements["application-identifier"] as? String ?? ""
        let appIdentifier = applicationIdentifier.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? applicationIdentifier
        return DeviceProfile(uuid: uuid, name: plist["Name"] as? String ?? uuid, appIDName: plist["AppIDName"] as? String ?? "",
                             teamName: plist["TeamName"] as? String ?? "", teamID: teamID, appIdentifier: appIdentifier,
                             created: plist["CreationDate"] as? Date, expires: plist["ExpirationDate"] as? Date,
                             debuggable: entitlements["get-task-allow"] as? Bool ?? false,
                             deviceCount: (plist["ProvisionedDevices"] as? [String])?.count ?? 0,
                             allDevices: plist["ProvisionsAllDevices"] as? Bool ?? false, raw: data,
                             certificateNames: (plist["DeveloperCertificates"] as? [Data] ?? []).compactMap { der in
                                 SecCertificateCreateWithData(nil, der as CFData).flatMap { SecCertificateCopySubjectSummary($0) as String? }
                             })
    }
}

/// 设备上安装的用户应用（来自 installation_proxy）。
struct DeviceAppSizeValues: Equatable, Sendable {
    let bundle: Int64?
    let data: Int64?
    init(_ plist: [String: Any]) {
        func size(_ key: String) -> Int64? {
            guard let value = (plist[key] as? NSNumber)?.int64Value, value >= 0 else { return nil }
            return value
        }
        bundle = size("StaticDiskUsage"); data = size("DynamicDiskUsage")
    }
    var available: Bool { bundle != nil || data != nil }
}

struct DeviceInstalledApp: Identifiable, Hashable, Sendable, Codable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    var version: String
    var build: String
    var signer: String
    /// 依赖描述文件运行（开发、企业或侧载签名）；App Store 应用为 false。
    var profileSigned: Bool
    var debuggable: Bool
    var fileSharing: Bool
    var bundleSize: Int64
    var dataSize: Int64
    /// 进程名；崩溃日志和系统日志按它对应到应用。
    var executable: String = ""
    /// 签名权限里的 application-identifier 去掉团队前缀；证书签名的应用可能与 Bundle ID 不同。
    var signedAppID: String = ""
    var signedTeamID: String = ""
    var isSystem: Bool = false
    /// 安装位置（.app 目录），用来把进程对应到应用。可选：旧缓存里没有。
    var path: String?
    /// 由设备服务返回；旧缓存或部分系统可能不提供。
    var dataContainerPath: String?
    var groupContainerPaths: [String: String]?
    /// 区分设备返回的 0 与尚未读取；旧缓存通过正数推断是否已有数据。
    var bundleSizeKnown: Bool? = nil
    var dataSizeKnown: Bool? = nil
    var reportedBundleSize: Int64? { (bundleSizeKnown ?? (bundleSize > 0)) ? bundleSize : nil }
    var reportedDataSize: Int64? { (dataSizeKnown ?? (dataSize > 0)) ? dataSize : nil }

    mutating func apply(sizes: DeviceAppSizeValues) {
        if let value = sizes.bundle { bundleSize = value; bundleSizeKnown = true }
        if let value = sizes.data { dataSize = value; dataSizeKnown = true }
    }
    mutating func preserveSizes(from previous: Self) {
        if reportedBundleSize == nil { bundleSize = previous.bundleSize; bundleSizeKnown = previous.bundleSizeKnown }
        if reportedDataSize == nil { dataSize = previous.dataSize; dataSizeKnown = previous.dataSizeKnown }
    }

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case sideloaded, testFlight, appStore, system
        var id: String { rawValue }
        var title: String {
            switch self { case .sideloaded: "侧载"; case .testFlight: "TestFlight"; case .appStore: "App Store"; case .system: "系统" }
        }
    }
    var kind: Kind {
        if isSystem { return .system }
        if signer.localizedCaseInsensitiveContains("TestFlight") { return .testFlight }
        return profileSigned ? .sideloaded : .appStore
    }
    /// 只有开发签名（整个沙盒）或开启文件共享（文稿）的应用，系统才允许读取文件。
    var filesAccessible: Bool { debuggable || fileSharing }

    static func parse(_ data: Data) -> DeviceInstalledApp? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        func text(_ key: String) -> String { plist[key] as? String ?? "" }
        let sizes = DeviceAppSizeValues(plist)
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let appID = entitlements["application-identifier"] as? String ?? ""
        let display = [text("CFBundleDisplayName"), text("CFBundleName"), text("CFBundleExecutable")].first { !$0.isEmpty } ?? bundleID
        return DeviceInstalledApp(bundleID: bundleID, name: display, version: text("CFBundleShortVersionString"), build: text("CFBundleVersion"),
                                  signer: text("SignerIdentity"), profileSigned: plist["ProfileValidated"] as? Bool ?? false,
                                  debuggable: entitlements["get-task-allow"] as? Bool ?? false,
                                  fileSharing: plist["UIFileSharingEnabled"] as? Bool ?? false,
                                  bundleSize: sizes.bundle ?? 0, dataSize: sizes.data ?? 0, executable: text("CFBundleExecutable"),
                                  signedAppID: appID.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? "",
                                  signedTeamID: entitlements["com.apple.developer.team-identifier"] as? String
                                      ?? appID.split(separator: ".", maxSplits: 1).first.map(String.init) ?? "",
                                  isSystem: text("ApplicationType") == "System", path: plist["Path"] as? String,
                                  dataContainerPath: plist["Container"] as? String,
                                  groupContainerPaths: plist["GroupContainers"] as? [String: String],
                                  bundleSizeKnown: sizes.bundle != nil, dataSizeKnown: sizes.data != nil)
    }
}

/// 描述文件的使用情况，用来给出清理建议。
enum DeviceProfileUsage: Hashable, Sendable {
    case inUse(apps: [String])
    /// 同一个 App ID 有到期更晚的描述文件，而且它包含应用当前的签名证书：这份可以确定不再需要。
    case replaced
    /// 有更新的同类描述文件，但无法确认它能替代这份（证书对不上或不知道应用用哪张证书签名）。
    case superseded
    case expired
    case unused

    /// 过期的、以及确认已被新描述文件替代的可以清理。其余判断不准的只能逐个手动删除：
    /// 其他工具安装的应用、用旧证书签名的应用都可能依赖它们。
    var cleanable: Bool { self == .expired || self == .replaced }
    var uncertain: Bool { self == .superseded || self == .unused }
    var title: String {
        switch self {
        case .inUse(let apps): apps.isEmpty ? "使用中" : "用于 " + apps.joined(separator: "、")
        case .replaced: "已被更新的描述文件取代（证书相同）"
        case .superseded: "可能已被更新的同类描述文件取代"
        case .expired: "已过期"
        case .unused: "没有找到对应的应用"
        }
    }
}

enum DeviceProfileAnalysis {
    /// 每份有效的描述文件先找它服务的应用：签名 App ID 匹配的主应用，或按命名规则属于某个应用的扩展。
    /// Retools 每次续签都会装一份新的，旧的会留到过期；如果更新的那份包含这些应用当前的签名证书，旧的就确定可以删。
    static func usage(of profiles: [DeviceProfile], apps: [DeviceInstalledApp], now: Date = Date()) -> [String: DeviceProfileUsage] {
        var result: [String: DeviceProfileUsage] = [:]
        let valid = profiles.filter { !$0.isExpired(now: now) }
        for profile in profiles {
            if profile.isExpired(now: now) { result[profile.uuid] = .expired; continue }
            let direct = apps.filter { profile.matches(app: $0) }
            let extended = direct.isEmpty ? apps.filter { profile.belongsToExtension(of: $0) } : []
            let owners = direct + extended
            let newer = valid.filter { $0.uuid != profile.uuid && $0.teamID == profile.teamID && $0.appIdentifier == profile.appIdentifier
                && ($0.expires ?? .distantPast, $0.uuid) > (profile.expires ?? .distantPast, profile.uuid) }
            if !newer.isEmpty {
                let signers = Set(owners.map(\.signer))
                let covered = !owners.isEmpty && !signers.contains("") && newer.contains { Set($0.certificateNames).isSuperset(of: signers) }
                if covered { result[profile.uuid] = .replaced; continue }
                // 证书对不上时，这份旧的可能正是应用在用的那份，按使用中保留。
                if !owners.isEmpty { result[profile.uuid] = .inUse(apps: names(direct: direct, extended: extended)); continue }
                result[profile.uuid] = .superseded; continue
            }
            result[profile.uuid] = owners.isEmpty ? .unused : .inUse(apps: names(direct: direct, extended: extended))
        }
        return result
    }

    private static func names(direct: [DeviceInstalledApp], extended: [DeviceInstalledApp]) -> [String] {
        direct.map(\.name) + extended.map { "\($0.name) 的扩展" }
    }
}

/// 设备概况（lockdown 通用、存储、电池三个域）。
struct DeviceInfoSummary: Equatable, Sendable, Codable {
    var name: String
    var productType: String
    var systemVersion: String
    var build: String
    var hardwareModel: String
    var serial: String
    var udid: String
    var wifiAddress: String
    var activation: String
    var totalCapacity: Int64?
    var dataAvailable: Int64?
    /// 系统报告的可按需释放空间（缓存等），不算进可用。
    var purgeable: Int64?
    var batteryLevel: Int?
    var charging: Bool?
    var externalPower: Bool?
    var batteryHealth: DeviceBatteryHealth?

    static func parse(general: Data, disk: Data?, battery: Data?) -> DeviceInfoSummary {
        func dictionary(_ data: Data?) -> [String: Any] {
            data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        }
        let values = dictionary(general), storage = dictionary(disk), power = dictionary(battery)
        func text(_ key: String) -> String { values[key] as? String ?? "" }
        func number(_ dict: [String: Any], _ key: String) -> Int64? { (dict[key] as? NSNumber)?.int64Value }
        return DeviceInfoSummary(name: text("DeviceName"), productType: text("ProductType"), systemVersion: text("ProductVersion"),
                                 build: text("BuildVersion"), hardwareModel: text("HardwareModel"), serial: text("SerialNumber"),
                                 udid: text("UniqueDeviceID"), wifiAddress: text("WiFiAddress"), activation: text("ActivationState"),
                                 totalCapacity: number(storage, "TotalDiskCapacity") ?? number(storage, "TotalDataCapacity"),
                                 // AmountDataAvailable 是真正的剩余空间（与文件系统一致）；TotalDataAvailable 还包含系统按需才能腾出的空间。
                                 dataAvailable: number(storage, "AmountDataAvailable") ?? number(storage, "TotalDataAvailable"),
                                 purgeable: number(storage, "TotalDataAvailable").flatMap { total in number(storage, "AmountDataAvailable").map { max(0, total - $0) } },
                                 batteryLevel: number(power, "BatteryCurrentCapacity").map(Int.init),
                                 charging: power["BatteryIsCharging"] as? Bool, externalPower: power["ExternalConnected"] as? Bool)
    }
}

/// 设备沙盒里的一个文件或文件夹。
struct DeviceFileItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date?

    init(_ entry: DeviceFileEntry) {
        path = entry.path; name = entry.name; isDirectory = entry.isDirectory; size = entry.size
        modified = Self.date(fromRaw: entry.modifiedRaw)
    }
    init(path: String, isDirectory: Bool, size: Int64, modified: Date?) {
        self.path = path; name = (path as NSString).lastPathComponent; self.isDirectory = isDirectory; self.size = size; self.modified = modified
    }

    /// AFC 时间戳的单位随 FFI 版本不同（秒、毫秒或纳秒），按数量级判断。
    static func date(fromRaw raw: Int64) -> Date? {
        guard raw > 0 else { return nil }
        let value = Double(raw)
        let seconds = value > 1e17 ? value / 1e9 : (value > 1e14 ? value / 1e6 : (value > 1e11 ? value / 1e3 : value))
        guard seconds > 946_684_800, seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func sorted(_ items: [DeviceFileItem]) -> [DeviceFileItem] {
        items.filter { !$0.name.hasPrefix(".com.apple.") }
            .sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 在同一目录里给上传的文件找一个不冲突的名字：「名字 2.扩展名」。
    static func uniqueName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        for index in 2...999 {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !existing.contains(candidate) { return candidate }
        }
        return UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" || directory.isEmpty ? "/" + name : (directory.hasSuffix("/") ? directory + name : directory + "/" + name)
    }
}

extension Int64 {
    var byteLabel: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// 被删除的描述文件副本，保存在 Retools 支持目录，保留 30 天。
enum DeviceProfileTrash {
    struct Entry: Identifiable, Hashable, Sendable {
        var id: String { uuid }
        var uuid: String
        var name: String
        var appIdentifier: String
        var expires: Date?
        var deletedAt: Date
        var file: URL
    }

    static var folder: URL { WorkspacePaths().support.appendingPathComponent("DeletedProfiles", isDirectory: true) }
    private static let retention: TimeInterval = 30 * 86_400

    static func keep(_ profile: DeviceProfile, in folder: URL = folder) throws {
        guard !profile.raw.isEmpty else { throw WorkspaceFailure("没有读到这份描述文件的内容，为了能够恢复，先不删除。") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try profile.raw.write(to: folder.appendingPathComponent(profile.uuid + ".mobileprovision"), options: .atomic)
    }

    static func entries(in folder: URL = folder, now: Date = Date()) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "mobileprovision" }.compactMap { file -> Entry? in
            let deletedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            guard now.timeIntervalSince(deletedAt) < retention, let data = try? Data(contentsOf: file), let profile = DeviceProfile.parse(data) else {
                try? FileManager.default.removeItem(at: file); return nil
            }
            return Entry(uuid: profile.uuid, name: profile.name, appIdentifier: profile.appIdentifier, expires: profile.expires, deletedAt: deletedAt, file: file)
        }.sorted { $0.deletedAt > $1.deletedAt }
    }

    static func discard(_ entry: Entry) { try? FileManager.default.removeItem(at: entry.file) }
}

extension DeviceProcessInfo: Identifiable {
    public var id: UInt32 { pid }
    /// 可执行文件路径（设备有时放在 appName 里，有时放在 name 里）。
    var executablePath: String { [appName, name].first { $0.hasPrefix("/") } ?? "" }
    /// 不依赖应用列表的简短名称：取 .app / .appex 目录名，或可执行文件名。
    var displayName: String { DeviceProcessNaming.label(for: self, apps: []).title }
}

/// 进程在界面上怎么称呼：对应到已安装的应用、应用的扩展、系统应用或系统后台进程。
struct DeviceProcessLabel: Equatable {
    enum Kind: Equatable { case app, appExtension, systemApp, daemon }
    var title: String
    /// 扩展名称等补充说明。
    var detail: String?
    /// 对应到的已安装应用（用于图标）。
    var bundleID: String?
    var kind: Kind
}

enum DeviceProcessNaming {
    /// 进程路径常以 /var 开头，安装信息里的路径以 /private/var 开头。
    static func normalize(_ path: String) -> String { path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path }

    static func label(for process: DeviceProcessInfo, apps: [DeviceInstalledApp]) -> DeviceProcessLabel {
        label(path: process.executablePath, fallbackName: process.name, apps: apps)
    }

    static func label(path: String, fallbackName: String, apps: [DeviceInstalledApp]) -> DeviceProcessLabel {
        let components = normalize(path).split(separator: "/").map(String.init)
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else {
            let short = components.last ?? (fallbackName.isEmpty ? "未知进程" : (fallbackName as NSString).lastPathComponent)
            return DeviceProcessLabel(title: short, detail: nil, bundleID: nil, kind: .daemon)
        }
        let bundleDirectory = "/" + components[...appIndex].joined(separator: "/")
        let folderName = String(components[appIndex].dropLast(".app".count))
        let appex = components[(appIndex + 1)...].first { $0.hasSuffix(".appex") }.map { String($0.dropLast(".appex".count)) }
        let installed = apps.first { app in app.path.map { normalize($0) == bundleDirectory } ?? false }
        let isSystem = installed?.isSystem ?? !bundleDirectory.hasPrefix("/var/containers/")
        let title = installed?.name ?? folderName
        if let appex {
            return DeviceProcessLabel(title: title, detail: "扩展 · " + appex, bundleID: installed?.bundleID, kind: .appExtension)
        }
        return DeviceProcessLabel(title: title, detail: nil, bundleID: installed?.bundleID, kind: isSystem ? .systemApp : .app)
    }
}

/// 慢操作的独立连接正忙（上一次还没返回），这次直接跳过。
struct DeviceToolsBusy: LocalizedError {
    var errorDescription: String? { "上一次读取还没结束，请稍候。" }
}

/// 上次读到的设备内容，重新打开 Retools 时先显示，再在后台刷新。
struct DeviceToolsSnapshot: Codable {
    var profiles: [DeviceProfile]
    var apps: [DeviceInstalledApp]
    var info: DeviceInfoSummary?
    var updatedAt: Date

    static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DeviceTools/snapshot.json")
    }
    static func load(from file: URL = file) -> DeviceToolsSnapshot? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(DeviceToolsSnapshot.self, from: $0) }
    }
    func save(to file: URL = file) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}

// MARK: - 连接

/// 给不能取消的设备调用加时限。设备服务调用在独立线程上阻塞，超时后不再等它，结果到达时直接丢弃。
enum DeviceToolsTimeout {
    struct Expired: LocalizedError {
        let step: String
        var errorDescription: String? { "\(step)超时：设备没有响应。请确认回环代理已开启，然后下拉刷新重试。" }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var work: Task<Void, Never>?
        private var timer: Task<Void, Never>?
        private var cancelled = false

        func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return false }
            self.continuation = continuation
            lock.unlock()
            return true
        }
        func install(work: Task<Void, Never>, timer: Task<Void, Never>) {
            lock.lock()
            if continuation == nil { lock.unlock(); work.cancel(); timer.cancel(); return }
            self.work = work; self.timer = timer
            lock.unlock()
        }
        func resume(_ result: Result<T, Error>, cancelWork: Bool = false) {
            lock.lock()
            let pending = continuation, work = work, timer = timer
            continuation = nil; self.work = nil; self.timer = nil
            lock.unlock()
            timer?.cancel()
            if cancelWork { work?.cancel() }
            pending?.resume(with: result)
        }
        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
            resume(.failure(CancellationError()), cancelWork: true)
        }
    }

    static func run<T: Sendable>(_ step: String, seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = Once<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard once.install(continuation) else { return }
                let work = Task {
                    do { try Task.checkCancellation(); once.resume(.success(try await operation())) }
                    catch { once.resume(.failure(error)) }
                }
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    once.resume(.failure(Expired(step: step)), cancelWork: true)
                }
                once.install(work: work, timer: timer)
            }
        } onCancel: { once.cancel() }
    }
}

protocol DeviceToolsBackend: Sendable {
    var isSample: Bool { get }
    /// 丢弃当前连接，下次 connect 时建立新的隧道。卡住的旧调用留在原线程上自行结束。
    func reset() async
    func connect(host: String, port: UInt16, udid: String) async throws
    /// type："User"（App Store、TestFlight、侧载）或 "System"。
    func installedApps(type: String) async throws -> [Data]
    /// 各应用的大小（较慢，单独读取）。
    func appSizes(type: String) async throws -> [Data]
    func provisioningProfiles() async throws -> [Data]
    func removeProfile(uuid: String) async throws
    func installProfile(_ data: Data) async throws
    func uninstall(bundleID: String) async throws
    func lockdownValues(domain: String?) async throws -> Data
    func containerEntries(bundleID: String, path: String) async throws -> (access: DeviceContainerAccess, entries: [DeviceFileItem])
    func containerRead(bundleID: String, path: String) async throws -> Data
    func containerWrite(bundleID: String, path: String, data: Data) async throws
    func containerMakeDirectory(bundleID: String, path: String) async throws
    func containerRemove(bundleID: String, path: String) async throws
    func crashReports() async throws -> [DeviceFileItem]
    func crashReport(path: String) async throws -> Data
    func removeCrashReports(paths: [String]) async throws
    func batteryRegistry() async throws -> Data
    func isDeveloperImageMounted() async throws -> Bool
    func mountDeveloperImage(_ files: DeveloperDiskImage.Files) async throws
    func runningProcesses(withUsage: Bool) async throws -> [DeviceProcessInfo]
    func killProcess(pid: UInt32) async throws
    func checkProcessSignalPermission(pid: UInt32) async throws
    func processUsage(pids: Set<UInt32>?) async throws -> [UInt32: DeviceProcessUsage]
    func disableMemoryLimit(pid: UInt32) async throws
    func launchApp(bundleID: String) async throws -> UInt32
    /// 定位模拟单独建一条连接并一直保持，模拟的位置只在连接期间有效。
    func openLocationChannel(host: String, port: UInt16, udid: String) async throws -> DeviceLocationChannel
    func appIcons(bundleIDs: [String]) async throws -> [String: Data]
    func containerDownload(bundleID: String, to local: URL, excluding: Set<String>, control: DeviceStreamControl,
                           progress: @escaping @Sendable (Int, Int64) -> Void) async throws -> DeviceContainerAccess
    func containerUpload(bundleID: String, from local: URL, clearing: [String], keeping: Set<String>, control: DeviceStreamControl,
                         progress: @escaping @Sendable (Int, Int64) -> Void) async throws
    func streamLogs(host: String, port: UInt16, udid: String, control: DeviceStreamControl, onRecord: @escaping @Sendable (DeviceLogRecord) -> Void) async throws
}

/// 通过回环连接本机的设备服务。与续签使用的连接分开，互不打断。
actor LiveDeviceToolsBackend: DeviceToolsBackend {
    private var link = LocalDeviceLink()
    /// 慢操作（读取应用大小、CPU / 内存取样）走另一条连接，卡住时不影响其他操作；同一时间只跑一个。
    private var side: LocalDeviceLink?
    private var sideBusy = false
    private var target: (host: String, port: UInt16, udid: String)?
    nonisolated var isSample: Bool { false }
    func reset() { link = LocalDeviceLink(); side = nil }

    private func withSide<T: Sendable>(skipIfBusy: Bool, _ body: (LocalDeviceLink) async throws -> T) async throws -> T {
        while sideBusy {
            if skipIfBusy { throw DeviceToolsBusy() }
            try await Task.sleep(for: .milliseconds(300))
        }
        sideBusy = true
        defer { sideBusy = false }
        do {
            if side == nil {
                guard let target else { throw WorkspaceFailure("设备还没有连接。") }
                let fresh = LocalDeviceLink()
                _ = try await fresh.connect(host: target.host, remotePort: target.port, expectedUDID: target.udid)
                side = fresh
            }
            return try await body(side!)
        } catch { side = nil; throw error }
    }
    func connect(host: String, port: UInt16, udid: String) async throws {
        target = (host, port, udid)
        _ = try await link.connect(host: host, remotePort: port, expectedUDID: udid)
    }
    func installedApps(type: String) async throws -> [Data] { try await link.installedAppsQuick(type: type) }
    func appSizes(type: String) async throws -> [Data] { try await withSide(skipIfBusy: false) { try await $0.appSizes(type: type) } }
    func provisioningProfiles() async throws -> [Data] { try await link.provisioningProfiles() }
    func removeProfile(uuid: String) async throws { try await link.removeProvisioningProfile(uuid: uuid) }
    func installProfile(_ data: Data) async throws { try await link.installProvisioningProfile(data) }
    func uninstall(bundleID: String) async throws { try await link.uninstall(bundleID: bundleID) }
    func lockdownValues(domain: String?) async throws -> Data { try await link.lockdownValues(domain: domain) }
    func containerEntries(bundleID: String, path: String) async throws -> (access: DeviceContainerAccess, entries: [DeviceFileItem]) {
        let result = try await link.containerEntries(bundleID: bundleID, path: path)
        return (result.access, result.entries.map(DeviceFileItem.init))
    }
    func containerRead(bundleID: String, path: String) async throws -> Data { try await link.containerRead(bundleID: bundleID, path: path) }
    func containerWrite(bundleID: String, path: String, data: Data) async throws { try await link.containerWrite(bundleID: bundleID, path: path, data: data) }
    func containerMakeDirectory(bundleID: String, path: String) async throws { try await link.containerMakeDirectory(bundleID: bundleID, path: path) }
    func containerRemove(bundleID: String, path: String) async throws { try await link.containerRemove(bundleID: bundleID, path: path) }
    func crashReports() async throws -> [DeviceFileItem] { try await link.crashReports().map(DeviceFileItem.init) }
    func crashReport(path: String) async throws -> Data { try await link.crashReport(path: path) }
    func removeCrashReports(paths: [String]) async throws { try await link.removeCrashReports(paths: paths) }
    func batteryRegistry() async throws -> Data { try await link.batteryRegistry() }
    func isDeveloperImageMounted() async throws -> Bool { try await link.isDeveloperImageMounted() }
    func mountDeveloperImage(_ files: DeveloperDiskImage.Files) async throws { try await link.mountDeveloperImage(files) }
    /// Each process request owns its tunnel, so a stuck DVT sample or a reset cannot
    /// mutate the connection used by another in-flight request.
    private func withProcessLink<T: Sendable>(_ body: (LocalDeviceLink) async throws -> T) async throws -> T {
        guard let target else { throw WorkspaceFailure("设备还没有连接。") }
        let fresh = LocalDeviceLink()
        _ = try await fresh.connect(host: target.host, remotePort: target.port, expectedUDID: target.udid)
        try Task.checkCancellation()
        return try await body(fresh)
    }
    func runningProcesses(withUsage: Bool) async throws -> [DeviceProcessInfo] { try await withProcessLink { try await $0.runningProcesses(withUsage: false) } }
    func killProcess(pid: UInt32) async throws { try await withProcessLink { try await $0.killProcess(pid: pid) } }
    func checkProcessSignalPermission(pid: UInt32) async throws { try await withProcessLink { try await $0.checkProcessSignalPermission(pid: pid) } }
    func processUsage(pids: Set<UInt32>?) async throws -> [UInt32: DeviceProcessUsage] {
        try await withProcessLink { try await $0.processUsage(pids: pids) }
    }
    func disableMemoryLimit(pid: UInt32) async throws { try await link.disableMemoryLimit(pid: pid) }
    func launchApp(bundleID: String) async throws -> UInt32 { try await link.launchApp(bundleID: bundleID) }
    nonisolated func openLocationChannel(host: String, port: UInt16, udid: String) async throws -> DeviceLocationChannel {
        let link = LocalDeviceLink()
        _ = try await link.connect(host: host, remotePort: port, expectedUDID: udid)
        return LiveLocationChannel(link: link, session: try await link.openLocationSession())
    }
    func appIcons(bundleIDs: [String]) async throws -> [String: Data] { try await link.appIcons(bundleIDs: bundleIDs) }
    func containerDownload(bundleID: String, to local: URL, excluding: Set<String>, control: DeviceStreamControl,
                           progress: @escaping @Sendable (Int, Int64) -> Void) async throws -> DeviceContainerAccess {
        try await link.containerDownload(bundleID: bundleID, to: local, excluding: excluding, control: control, progress: progress)
    }
    func containerUpload(bundleID: String, from local: URL, clearing: [String], keeping: Set<String>, control: DeviceStreamControl,
                         progress: @escaping @Sendable (Int, Int64) -> Void) async throws {
        try await link.containerUpload(bundleID: bundleID, from: local, clearing: clearing, keeping: keeping, control: control, progress: progress)
    }
    /// 日志流会一直占着连接，所以单独建一条，不影响其他工具。
    nonisolated func streamLogs(host: String, port: UInt16, udid: String, control: DeviceStreamControl, onRecord: @escaping @Sendable (DeviceLogRecord) -> Void) async throws {
        let stream = LocalDeviceLink()
        _ = try await DeviceToolsTimeout.run("连接设备", seconds: 20) { try await stream.connect(host: host, remotePort: port, expectedUDID: udid) }
        try await stream.streamLogs(control: control, onRecord: onRecord)
    }
}

// MARK: - 状态

@MainActor
final class DeviceToolsStore: ObservableObject {
    static let shared = DeviceToolsStore()

    enum Phase: Equatable { case idle, loading, ready, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var profiles: [DeviceProfile] = []
    @Published private(set) var apps: [DeviceInstalledApp] = []
    @Published private(set) var info: DeviceInfoSummary?
    @Published private(set) var usage: [String: DeviceProfileUsage] = [:]
    @Published private(set) var busy: String?
    /// 正在进行的设备调用，加载时显示给用户。
    @Published private(set) var currentStep: String?
    @Published var errorMessage: String?
    @Published private(set) var updatedAt: Date?

    let backend: DeviceToolsBackend
    private var connected = false
    private var needsFreshLink = false

    init(backend: DeviceToolsBackend? = nil) {
        #if targetEnvironment(simulator)
        self.backend = backend ?? SampleDeviceToolsBackend()
        #else
        self.backend = backend ?? LiveDeviceToolsBackend()
        #endif
        if !self.backend.isSample, let cached = DeviceToolsSnapshot.load() {
            profiles = cached.profiles; apps = cached.apps; info = cached.info; updatedAt = cached.updatedAt
            usage = DeviceProfileAnalysis.usage(of: profiles, apps: apps)
            phase = .ready
        }
    }

    /// 内容来自上次的缓存、这次还没刷新成功。
    @Published private(set) var showingCache = false

    private func saveSnapshot() {
        guard !backend.isSample else { return }
        DeviceToolsSnapshot(profiles: profiles, apps: apps, info: info, updatedAt: updatedAt ?? Date()).save()
    }

    @Published private(set) var systemApps: [DeviceInstalledApp] = []
    @Published private(set) var systemPhase: Phase = .idle

    func apps(of kind: DeviceInstalledApp.Kind) -> [DeviceInstalledApp] {
        (kind == .system ? systemApps : apps.filter { $0.kind == kind }).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 系统应用有两百多个，切到「系统」时才读取。
    func loadSystemApps(renewal: RenewalController) async {
        guard systemPhase != .loading else { return }
        systemPhase = .loading
        do {
            let raw = try await perform("读取系统应用", renewal, timeout: 60) { backend in try await backend.installedApps(type: "System") }
            let previous = Dictionary(systemApps.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
            systemApps = raw.compactMap(DeviceInstalledApp.parse).map {
                var app = $0; app.isSystem = true
                if let old = previous[app.bundleID] { app.preserveSizes(from: old) }
                if let sizes = appSizeValues[app.bundleID] { app.apply(sizes: sizes) }
                return app
            }
            systemPhase = .ready
        } catch { systemPhase = .failed(error.localizedDescription) }
    }

    /// 依赖描述文件运行的应用（侧载与 TestFlight）。
    var sideloadedApps: [DeviceInstalledApp] { apps.filter(\.profileSigned).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var cleanupCandidates: [DeviceProfile] { profiles.filter { usage[$0.uuid]?.cleanable ?? false } }
    var uncertainProfiles: [DeviceProfile] { profiles.filter { usage[$0.uuid]?.uncertain ?? false } }
    func profiles(for app: DeviceInstalledApp) -> [DeviceProfile] { profiles.filter { $0.matches(app: app) } }
    /// 应用实际依赖的描述文件：同类中到期最晚的那份。
    func activeProfile(for app: DeviceInstalledApp) -> DeviceProfile? {
        profiles(for: app).filter { !$0.isExpired() }.max { ($0.isWildcard ? 0 : 1, $0.expires ?? .distantPast) < ($1.isWildcard ? 0 : 1, $1.expires ?? .distantPast) }
    }

    private func ensureConnected(_ renewal: RenewalController) async throws {
        guard !connected else { return }
        guard backend.isSample || renewal.settings.hasPairing else { throw WorkspaceFailure("请先在「设备配对与连接」里配对这台 iPhone，并打开回环代理。") }
        if needsFreshLink { await backend.reset(); needsFreshLink = false }
        let backend = backend
        let (host, port, udid) = (renewal.settings.hostIP, renewal.settings.remotePort, renewal.settings.deviceUDID)
        let started = Date()
        do {
            try await DeviceToolsTimeout.run("连接设备", seconds: 20) { try await backend.connect(host: host, port: port, udid: udid) }
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 4 { AuthDiagnostics.record(stage: "设备工具", message: "连接设备用时 \(String(format: "%.1f", elapsed)) 秒") }
        } catch {
            // 连接卡住时旧连接可能已经失效，下次换一条新的。
            needsFreshLink = true
            throw error
        }
        connected = true
    }

    /// 每一步都有超时：回环代理断开或 App 从后台回来时，旧的隧道可能不再响应，调用会一直等下去。
    /// 超时或出错后换一条新连接重试一次。
    private func perform<T: Sendable>(_ step: String, _ renewal: RenewalController, timeout: Double = 25, retry: Bool = true, resetsConnection: Bool = true,
                                      _ body: @escaping @Sendable (DeviceToolsBackend) async throws -> T) async throws -> T {
        let backend = backend
        let started = Date()
        defer { currentStep = nil }
        do {
            if !connected { currentStep = "连接设备" }
            try await ensureConnected(renewal)
            currentStep = step
            let started = Date()
            let result = try await DeviceToolsTimeout.run(step, seconds: timeout) { try await body(backend) }
            let elapsed = Date().timeIntervalSince(started)
            // 慢的步骤记进诊断记录，方便判断是连接还是某个服务拖慢了加载。
            if elapsed > 4 { AuthDiagnostics.record(stage: "设备工具", message: "\(step)用时 \(String(format: "%.1f", elapsed)) 秒") }
            return result
        } catch {
            guard !(error is CancellationError), !(error is DeviceToolsBusy) else { throw error }
            // 走独立连接的慢操作失败时，不必重建主连接。
            if resetsConnection { connected = false; needsFreshLink = true }
            AuthDiagnostics.record(stage: "设备工具", message: "\(step)失败（\(Int(Date().timeIntervalSince(started))) 秒）：\(error.localizedDescription)")
            guard retry else { throw error }
            try await ensureConnected(renewal)
            return try await DeviceToolsTimeout.run(step, seconds: timeout) { try await body(backend) }
        }
    }

    /// App 进入后台后系统会挂起回环连接，回来时用新连接。
    func appDidEnterBackground() {
        connected = false; needsFreshLink = true
    }

    @Published private(set) var appsPhase: Phase = .idle
    @Published private(set) var profilesPhase: Phase = .idle
    @Published private(set) var infoPhase: Phase = .idle

    /// 应用枚举只依赖安装服务，不等待描述文件、诊断或开发者镜像。
    func loadApps(renewal: RenewalController) async {
        guard appsPhase != .loading else { return }
        appsPhase = .loading
        do {
            let raw = try await perform("读取应用列表", renewal) { try await $0.installedApps(type: "User") }
            let previous = Dictionary(apps.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
            apps = raw.compactMap(DeviceInstalledApp.parse).map { app in
                var app = app
                if let old = previous[app.bundleID] { app.preserveSizes(from: old) }
                if let sizes = appSizeValues[app.bundleID] { app.apply(sizes: sizes) }
                return app
            }
            usage = DeviceProfileAnalysis.usage(of: profiles, apps: apps)
            appsPhase = .ready; saveSnapshot()
        } catch { appsPhase = .failed(error.localizedDescription) }
    }

    func loadProfiles(renewal: RenewalController) async {
        guard profilesPhase != .loading else { return }
        profilesPhase = .loading
        do {
            let raw = try await perform("读取描述文件", renewal) { try await $0.provisioningProfiles() }
            profiles = raw.compactMap(DeviceProfile.parse).sorted { ($0.expires ?? .distantFuture) > ($1.expires ?? .distantFuture) }
            usage = DeviceProfileAnalysis.usage(of: profiles, apps: apps)
            profilesPhase = .ready; saveSnapshot()
        } catch { profilesPhase = .failed(error.localizedDescription) }
    }

    func loadDeviceInfo(renewal: RenewalController) async {
        guard infoPhase != .loading else { return }
        infoPhase = .loading
        do {
            let general = try await perform("读取设备信息", renewal) { try await $0.lockdownValues(domain: nil) }
            // 基础信息先显示，附加诊断不可用时仍保留设备信息。
            info = DeviceInfoSummary.parse(general: general, disk: nil, battery: nil)
            let disk = try? await perform("读取存储空间", renewal, retry: false) { try await $0.lockdownValues(domain: "com.apple.disk_usage") }
            let battery = try? await perform("读取电量", renewal, retry: false) { try await $0.lockdownValues(domain: "com.apple.mobile.battery") }
            info = DeviceInfoSummary.parse(general: general, disk: disk, battery: battery)
            if let registry = try? await perform("读取电池健康", renewal, retry: false, { try await $0.batteryRegistry() }) {
                info?.batteryHealth = DeviceBatteryHealth.parse(registry)
            }
            infoPhase = .ready; saveSnapshot()
        } catch { infoPhase = .failed(error.localizedDescription) }
    }

    func refresh(renewal: RenewalController) async {
        guard phase != .loading else { return }
        phase = .loading
        await loadApps(renewal: renewal)
        await loadProfiles(renewal: renewal)
        await loadDeviceInfo(renewal: renewal)
        let failures = [appsPhase, profilesPhase, infoPhase].compactMap { phase -> String? in
            if case .failed(let message) = phase { return message }; return nil
        }
        showingCache = !failures.isEmpty
        if failures.isEmpty {
            updatedAt = Date(); phase = .ready; saveSnapshot()
            Task { await loadAppSizes(renewal: renewal) }
        } else { phase = .failed(failures.joined(separator: "\n")) }
    }

    @Published private(set) var sizesPhase: Phase = .idle
    var loadingSizes: Bool { sizesPhase == .loading }
    private var sizeRequest: Task<Void, Never>?
    private var appSizeValues: [String: DeviceAppSizeValues] = [:]
    private var sizesUpdatedAt: Date?

    /// 由数据服务持有请求，进入详情或返回时不取消；图标读取不阻塞大小读取。
    func loadAppSizes(renewal: RenewalController, force: Bool = false) async {
        if let request = sizeRequest { await request.value; return }
        if !force, sizesPhase == .ready, let updated = sizesUpdatedAt, Date().timeIntervalSince(updated) < 60 { return }
        sizesPhase = .loading
        let request = Task { await readAppSizes(renewal: renewal) }
        sizeRequest = request
        await request.value
    }

    private func readAppSizes(renewal: RenewalController) async {
        defer { sizeRequest = nil }
        do {
            let raw = try await perform("读取应用大小", renewal, timeout: 90, retry: false, resetsConnection: false) { backend in
                try await backend.appSizes(type: "Any")
            }
            var received: [String: DeviceAppSizeValues] = [:]
            for data in raw {
                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty else { continue }
                let values = DeviceAppSizeValues(plist)
                if values.available { received[id] = values }
            }
            guard !received.isEmpty else { throw WorkspaceFailure("设备没有返回应用与数据大小，请重试读取。") }
            appSizeValues.merge(received) { _, fresh in fresh }
            func updating(_ values: [DeviceInstalledApp]) -> [DeviceInstalledApp] {
                values.map { value in
                    var app = value
                    if let sizes = received[app.bundleID] { app.apply(sizes: sizes) }
                    return app
                }
            }
            apps = updating(apps); systemApps = updating(systemApps)
            sizesUpdatedAt = Date(); sizesPhase = .ready; saveSnapshot()
        } catch is CancellationError {
            sizesPhase = .idle
        } catch {
            sizesPhase = .failed(error.localizedDescription)
        }
    }

    func checkAppSizeReading(renewal: RenewalController, report: URL) async {
        await loadApps(renewal: renewal)
        await loadAppSizes(renewal: renewal, force: true)
        var result: [String: Any] = ["checkedAt": Date().timeIntervalSince1970, "appCount": apps.count,
                                     "bundleSizeCount": apps.filter { $0.reportedBundleSize != nil }.count,
                                     "dataSizeCount": apps.filter { $0.reportedDataSize != nil }.count]
        switch sizesPhase {
        case .ready: result["phase"] = "complete"
        case .failed(let message): result["phase"] = "failed"; result["error"] = message
        default: result["phase"] = "incomplete"
        }
        if let host = apps.first(where: { $0.bundleID == Bundle.main.bundleIdentifier }) {
            result["hostBundleSize"] = host.reportedBundleSize
            result["hostDataSize"] = host.reportedDataSize
        }
        do { try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: report, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { errorMessage = error.localizedDescription }
    }

    func removeProfiles(_ targets: [DeviceProfile], renewal: RenewalController) async {
        guard busy == nil, !targets.isEmpty else { return }
        var failures: [String] = []
        for (index, profile) in targets.enumerated() {
            busy = targets.count > 1 ? "正在删除描述文件 \(index + 1)/\(targets.count)…" : "正在删除描述文件…"
            do {
                // 先留一份副本，删错了可以在「最近删除」里装回去。
                try DeviceProfileTrash.keep(profile)
                try await perform("删除描述文件", renewal) { backend in try await backend.removeProfile(uuid: profile.uuid) }
            }
            catch { failures.append("\(profile.name)：\(error.localizedDescription)") }
        }
        busy = nil
        AuthDiagnostics.record(stage: "设备工具", message: "删除描述文件 \(targets.count - failures.count)/\(targets.count) 份，副本已保存")
        trash = DeviceProfileTrash.entries()
        if !failures.isEmpty { errorMessage = "有 \(failures.count) 份描述文件没有删除：\n" + failures.prefix(3).joined(separator: "\n") }
        await loadProfiles(renewal: renewal)
    }

    // MARK: 最近删除

    @Published private(set) var trash: [DeviceProfileTrash.Entry] = DeviceProfileTrash.entries()

    func restoreProfiles(_ entries: [DeviceProfileTrash.Entry], renewal: RenewalController) async {
        guard busy == nil, !entries.isEmpty else { return }
        var failures: [String] = []
        for (index, entry) in entries.enumerated() {
            busy = entries.count > 1 ? "正在恢复描述文件 \(index + 1)/\(entries.count)…" : "正在恢复描述文件…"
            do {
                let data = try Data(contentsOf: entry.file)
                try await perform("恢复描述文件", renewal) { backend in try await backend.installProfile(data) }
                DeviceProfileTrash.discard(entry)
            } catch { failures.append("\(entry.name)：\(error.localizedDescription)") }
        }
        busy = nil
        trash = DeviceProfileTrash.entries()
        AuthDiagnostics.record(stage: "设备工具", message: "恢复描述文件 \(entries.count - failures.count)/\(entries.count) 份")
        if !failures.isEmpty { errorMessage = "有 \(failures.count) 份描述文件没有恢复：\n" + failures.prefix(3).joined(separator: "\n") }
        await loadProfiles(renewal: renewal)
    }

    func discardTrash(_ entries: [DeviceProfileTrash.Entry]) {
        entries.forEach(DeviceProfileTrash.discard)
        trash = DeviceProfileTrash.entries()
    }

    func uninstall(_ app: DeviceInstalledApp, renewal: RenewalController) async {
        guard busy == nil else { return }
        guard app.bundleID != Bundle.main.bundleIdentifier else { errorMessage = "不能在 Retools 里卸载 Retools 自身。"; return }
        busy = "正在卸载「\(app.name)」…"
        do {
            try await perform("卸载应用", renewal, timeout: 120) { backend in try await backend.uninstall(bundleID: app.bundleID) }
            AuthDiagnostics.record(stage: "设备工具", message: "已卸载 \(app.bundleID)")
        } catch { errorMessage = "卸载失败：\(error.localizedDescription)" }
        busy = nil
        await loadApps(renewal: renewal)
    }

    // MARK: 沙盒文件

    func entries(of app: DeviceInstalledApp, path: String, renewal: RenewalController) async throws -> (access: DeviceContainerAccess, entries: [DeviceFileItem]) {
        let result = try await perform("读取文件列表", renewal) { backend in try await backend.containerEntries(bundleID: app.bundleID, path: path) }
        return (result.access, DeviceFileItem.sorted(result.entries))
    }

    /// 文件下载到临时目录，用于预览和分享。
    func download(_ item: DeviceFileItem, of app: DeviceInstalledApp, renewal: RenewalController) async throws -> URL {
        guard item.size <= 512_000_000 else { throw WorkspaceFailure("文件超过 512 MB，暂不支持直接读取。") }
        let data = try await perform("下载文件", renewal, timeout: 300) { backend in try await backend.containerRead(bundleID: app.bundleID, path: item.path) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceFiles/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(item.name)
        try data.write(to: target)
        return target
    }

    func upload(_ source: URL, to directory: String, existing: Set<String>, of app: DeviceInstalledApp, renewal: RenewalController) async throws -> String {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard values.isDirectory != true else { throw WorkspaceFailure("暂不支持上传文件夹，请先压缩成一个文件。") }
        guard (values.fileSize ?? 0) <= 512_000_000 else { throw WorkspaceFailure("文件超过 512 MB，暂不支持上传。") }
        let name = DeviceFileItem.uniqueName(source.lastPathComponent, existing: existing)
        let data = try Data(contentsOf: source)
        try await perform("上传文件", renewal, timeout: 300) { backend in try await backend.containerWrite(bundleID: app.bundleID, path: DeviceFileItem.join(directory, name), data: data) }
        return name
    }

    func makeDirectory(_ name: String, in directory: String, of app: DeviceInstalledApp, renewal: RenewalController) async throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), clean != ".", clean != ".." else { throw WorkspaceFailure("文件夹名称无效。") }
        try await perform("新建文件夹", renewal) { backend in try await backend.containerMakeDirectory(bundleID: app.bundleID, path: DeviceFileItem.join(directory, clean)) }
    }

    func remove(_ item: DeviceFileItem, of app: DeviceInstalledApp, renewal: RenewalController) async throws {
        try await perform("删除文件", renewal, timeout: 60) { backend in try await backend.containerRemove(bundleID: app.bundleID, path: item.path) }
    }

    // MARK: 崩溃日志

    @Published private(set) var crashReports: [DeviceCrashEntry] = []
    @Published private(set) var crashPhase: Phase = .idle

    func loadCrashReports(renewal: RenewalController) async {
        guard crashPhase != .loading else { return }
        crashPhase = .loading
        do {
            let items = try await perform("读取崩溃日志", renewal, timeout: 60) { backend in try await backend.crashReports() }
            crashReports = items.compactMap(DeviceCrashEntry.init).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            crashPhase = .ready
        } catch { crashPhase = .failed(error.localizedDescription) }
    }

    func crashDetail(_ entry: DeviceCrashEntry, renewal: RenewalController) async throws -> (detail: DeviceCrashDetail, file: URL) {
        guard entry.size <= 64_000_000 else { throw WorkspaceFailure("这份报告超过 64 MB，暂不支持读取。") }
        let data = try await perform("读取崩溃报告", renewal, timeout: 60) { backend in try await backend.crashReport(path: entry.path) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceFiles/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(entry.name)
        try data.write(to: file)
        return (DeviceCrashDetail.parse(data), file)
    }

    func removeCrashReports(_ entries: [DeviceCrashEntry], renewal: RenewalController) async {
        guard busy == nil, !entries.isEmpty else { return }
        busy = "正在删除 \(entries.count) 份崩溃日志…"
        do { try await perform("删除崩溃日志", renewal, timeout: 60) { backend in try await backend.removeCrashReports(paths: entries.map(\.path)) } }
        catch { errorMessage = "删除崩溃日志失败：\(error.localizedDescription)" }
        busy = nil
        await loadCrashReports(renewal: renewal)
    }

    func reloadTrash() { trash = DeviceProfileTrash.entries() }

    // MARK: 开发者镜像

    /// nil 表示还不知道（未连接或读取失败）。
    @Published private(set) var developerImageMounted: Bool?
    @Published private(set) var developerImageStep: String?

    /// 下载（首次）→ 校验 → 设备向 Apple 申请本机签名并挂载。重启手机后需要重新挂载，文件不用重新下载。
    func mountDeveloperImage(renewal: RenewalController) async {
        guard busy == nil else { return }
        await prepareDeveloperImage(renewal: renewal)
    }

    /// 开发操作可能已持有 busy；内部准备不能被自己的操作状态拦截。
    private func prepareDeveloperImage(renewal: RenewalController) async {
        guard developerImageStep == nil else { return }
        defer { developerImageStep = nil }
        let started = Date()
        do {
            developerImageStep = "正在检查挂载状态…"
            if try await perform("检查开发者镜像", renewal, retry: true, { backend in try await backend.isDeveloperImageMounted() }) {
                developerImageMounted = true; return
            }
            let files: DeveloperDiskImage.Files
            if backend.isSample {
                files = DeveloperDiskImage.Files(image: Data(), trustCache: Data(), manifest: Data())
            } else {
                if let cached = try? DeveloperDiskImage.load() { files = cached }
                else {
                    try await DeveloperDiskImage.download { message in Task { @MainActor in self.developerImageStep = message } }
                    files = try DeveloperDiskImage.load()
                }
            }
            developerImageStep = "正在向 Apple 申请本机签名并挂载…"
            try await perform("挂载开发者镜像", renewal, timeout: 180, retry: false) { backend in try await backend.mountDeveloperImage(files) }
            developerImageMounted = try await perform("检查开发者镜像", renewal, retry: false) { backend in try await backend.isDeveloperImageMounted() }
            AuthDiagnostics.record(stage: "开发者镜像", message: developerImageMounted == true
                                   ? "挂载成功，用时 \(Int(Date().timeIntervalSince(started))) 秒" : "挂载命令已完成，但设备仍报告未挂载")
            if developerImageMounted != true { errorMessage = "挂载命令已完成，但设备仍报告未挂载。可以重试一次，或重启手机后再挂载。" }
        } catch {
            AuthDiagnostics.record(stage: "开发者镜像", message: "挂载失败：\(error.localizedDescription)")
            errorMessage = Self.mountFailureMessage(error.localizedDescription)
        }
    }

    /// 常见失败原因换成能操作的说明。
    nonisolated static func mountFailureMessage(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("tss") || lower.contains("gs.apple.com") || lower.contains("network") || lower.contains("http") {
            return "向 Apple 申请镜像签名失败：\(raw)\n\n挂载需要联网访问 Apple 的签名服务器。请检查网络（代理或 VPN 规则不要拦截 gs.apple.com），然后重试。"
        }
        if lower.contains("developer mode") || lower.contains("developermode") {
            return "挂载失败：\(raw)\n\n请先在「设置 → 隐私与安全性 → 开发者模式」里打开开发者模式。"
        }
        if lower.contains("buildmanifest") || lower.contains("buildidentity") || lower.contains("identity") {
            return "挂载失败：\(raw)\n\n镜像和这台设备的系统不匹配。可以在设备工具里删除已下载的镜像，重新下载后再试。"
        }
        return "挂载开发者镜像失败：\(raw)"
    }

    func deleteDownloadedDeveloperImage() { DeveloperDiskImage.remove() }

    /// 定位模拟、进程管理等功能前调用：没挂载就自动挂载（开关关闭时直接提示）。
    func ensureDeveloperImage(renewal: RenewalController) async throws {
        if developerImageMounted == true { return }
        let mounted = try? await perform("检查开发者镜像", renewal, retry: true) { backend in try await backend.isDeveloperImageMounted() }
        if mounted == true { developerImageMounted = true; return }
        guard DeveloperDiskImage.autoMountEnabled || backend.isSample else {
            throw WorkspaceFailure("这项功能需要先挂载开发者镜像。请在「工具 → 开发者镜像」中挂载。")
        }
        let previousError = errorMessage
        await prepareDeveloperImage(renewal: renewal)
        guard developerImageMounted == true else {
            let message = errorMessage ?? "开发者镜像没有挂载成功。"
            errorMessage = previousError
            throw WorkspaceFailure(message)
        }
    }

    /// 镜像在重启后会被卸载；记住的「已挂载」状态可能过期，相关功能失败时调用它重新检查。
    func forgetDeveloperImageState() { developerImageMounted = nil }

    // MARK: 进程

    @Published private(set) var processes: [DeviceProcessInfo] = []
    @Published private(set) var processPhase: Phase = .idle
    /// 这次运行中解除过内存上限、且系统已确认的进程（PID → 时间）。进程退出后自然失效。
    @Published private(set) var liftedLimits: [UInt32: Date] = [:]
    /// 进程列表有，但取样没拿到任何 CPU / 内存数据。
    /// 没拿到 CPU / 内存时的具体原因，显示在进程列表下方。
    @Published private(set) var usageNote: String?
    @Published private(set) var loadingProcessUsage = false
    private var processReadID = UUID()
    private var processSampleTask: Task<[UInt32: DeviceProcessUsage], Error>?
    var usageUnavailable: Bool { !processes.isEmpty && processes.allSatisfy { $0.cpu == nil && $0.memory == nil } }

    /// 单个进程的 CPU / 内存；返回 nil 表示进程已经退出。
    func usage(of pid: UInt32, renewal: RenewalController) async throws -> DeviceProcessUsage? {
        let result = try await perform("读取进程占用", renewal, timeout: 30, retry: false, resetsConnection: false) { backend in try await backend.processUsage(pids: [pid]) }
        if let value = result[pid] { return value }
        // A sysmontap sample can omit a running process. Only the process list can confirm exit.
        let running = try await perform("检查进程状态", renewal, retry: false, resetsConnection: false) { backend in try await backend.runningProcesses(withUsage: false) }
        return running.contains { $0.pid == pid } ? DeviceProcessUsage(cpu: nil, memory: nil) : nil
    }

    func loadProcesses(renewal: RenewalController) async {
        guard processPhase != .loading else { return }
        processSampleTask?.cancel()
        let readID = UUID(); processReadID = readID
        processPhase = .loading
        usageNote = nil
        defer {
            if processReadID == readID {
                loadingProcessUsage = false; processSampleTask = nil
                if processPhase == .loading { processPhase = processes.isEmpty ? .idle : .ready }
            }
        }
        do {
            let listed = try await perform("读取进程", renewal, timeout: 20) { backend in try await backend.runningProcesses(withUsage: false) }
            try Task.checkCancellation()
            guard processReadID == readID else { return }
            let previous = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
            processes = listed.map {
                var process = $0
                if let old = previous[process.pid], old.name == process.name, old.appName == process.appName {
                    process.cpu = old.cpu; process.memory = old.memory
                }
                return process
            }
            let running = Set(processes.map(\.pid))
            liftedLimits = liftedLimits.filter { running.contains($0.key) }
            processPhase = .ready
            loadingProcessUsage = true
            do {
                try await ensureDeveloperImage(renewal: renewal)
                try Task.checkCancellation()
                guard processReadID == readID else { return }
                let sample = Task { try await perform("读取进程占用", renewal, timeout: 20, retry: false, resetsConnection: false) { backend in try await backend.processUsage(pids: nil) } }
                processSampleTask = sample
                let usage = try await withTaskCancellationHandler { try await sample.value } onCancel: { sample.cancel() }
                try Task.checkCancellation()
                guard processReadID == readID else { return }
                processes = processes.map { var process = $0; process.cpu = usage[$0.pid]?.cpu; process.memory = usage[$0.pid]?.memory; return process }
                usageNote = usageUnavailable ? "这次取样没有返回 CPU 或内存数值，下拉刷新可以重试。" : nil
            } catch is CancellationError { return }
            catch {
                guard processReadID == readID else { return }
                usageNote = "CPU／内存更新失败：\(error.localizedDescription)" + (usageUnavailable ? "" : "。现有占用数值是上次取样。")
                AuthDiagnostics.record(stage: "进程管理", message: usageNote ?? "取样失败")
            }
        } catch is CancellationError { }
        catch {
            guard processReadID == readID else { return }
            processPhase = .failed(error.localizedDescription)
        }
    }

    func label(for process: DeviceProcessInfo) -> DeviceProcessLabel {
        DeviceProcessNaming.label(for: process, apps: apps + systemApps)
    }

    @Published private(set) var desktopRestartRecord: DesktopRestart.Record? = DesktopRestart.load()

    func inspectDesktopRestart(renewal: RenewalController) async throws -> DeviceProcessInfo {
        try await perform("检查桌面控制权限", renewal, timeout: 30, retry: false) { backend in try await DesktopRestart.inspect(backend: backend) }
    }

    func restartDesktop(renewal: RenewalController) async throws -> DesktopRestart.Record {
        guard busy == nil, transfer == nil else { throw WorkspaceFailure("正在处理其他设备任务，请稍后再注销。") }
        busy = "正在请求重启桌面…"
        defer { busy = nil; desktopRestartRecord = DesktopRestart.load() }
        AuthDiagnostics.record(stage: "注销", message: "经用户确认，使用设备服务请求重启桌面")
        do {
            return try await perform("重启桌面", renewal, timeout: 45, retry: false) { backend in try await DesktopRestart.request(backend: backend) }
        } catch {
            AuthDiagnostics.record(stage: "注销", message: "设备服务注销未确认：\(error.localizedDescription)")
            throw error
        }
    }

    func verifyDesktopRestart(renewal: RenewalController) async {
        guard let record = desktopRestartRecord, record.confirmedPID == nil else { return }
        do { desktopRestartRecord = try await perform("核对上次注销结果", renewal, timeout: 15, retry: false) { backend in try await DesktopRestart.verify(backend: backend) } }
        catch { AuthDiagnostics.record(stage: "注销", message: "暂时无法核对上次桌面进程：\(error.localizedDescription)") }
    }

    /// Explicit local development check; records counts only, without process names or paths.
    func checkProcessReading(renewal: RenewalController, report: URL) async {
        var passes: [[String: Any]] = []
        for _ in 0..<2 {
            let started = Date()
            await loadProcesses(renewal: renewal)
            let failure: String? = if case .failed(let message) = processPhase { message } else { nil }
            passes.append(["listReady": processPhase == .ready, "processCount": processes.count,
                           "applicationCount": processes.filter(\.isApplication).count,
                           "sampledCount": processes.filter { $0.cpu != nil || $0.memory != nil }.count,
                           "elapsedSeconds": Date().timeIntervalSince(started), "error": failure ?? "", "samplingNote": usageNote ?? ""])
            let result: [String: Any] = ["checkedAt": Date().timeIntervalSince1970, "passes": passes,
                                       "verified": passes.count == 2 && passes.allSatisfy { $0["listReady"] as? Bool == true && ($0["processCount"] as? Int ?? 0) > 0 }]
            do { try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: report, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            catch { errorMessage = error.localizedDescription }
            if failure != nil { break }
        }
    }

    @discardableResult
    func kill(_ process: DeviceProcessInfo, renewal: RenewalController) async -> Bool {
        guard busy == nil else { errorMessage = "正在处理其他操作，请稍后重试。"; return false }
        processReadID = UUID(); processSampleTask?.cancel(); processSampleTask = nil; loadingProcessUsage = false
        if processPhase == .loading { processPhase = processes.isEmpty ? .idle : .ready }
        busy = "正在结束「\(label(for: process).title)」…"
        defer { busy = nil }
        do {
            let current = try await perform("检查目标进程", renewal, retry: false) { backend in try await backend.runningProcesses(withUsage: false) }
            guard !current.isEmpty else { throw WorkspaceFailure("设备返回的进程列表为空，无法确认结束结果。") }
            if let target = current.first(where: { $0.pid == process.pid }) {
                guard target.name == process.name, target.appName == process.appName else {
                    throw WorkspaceFailure("这个 PID 已被其他进程使用，请刷新进程列表。")
                }
                // Do not resend a destructive request after a timeout; the PID may have been reused.
                try await perform("结束进程", renewal, retry: false) { backend in try await backend.killProcess(pid: process.pid) }
                try await perform("确认进程退出", renewal, timeout: 12, retry: false) { backend in
                    for attempt in 0..<6 {
                        try Task.checkCancellation()
                        let running = try await backend.runningProcesses(withUsage: false)
                        guard !running.isEmpty else { throw WorkspaceFailure("设备返回的进程列表为空，无法确认结束结果。") }
                        if !running.contains(where: { $0.pid == process.pid }) { return }
                        if attempt < 5 { try await Task.sleep(for: .milliseconds(400)) }
                    }
                    throw WorkspaceFailure("设备已收到请求，但进程（PID \(process.pid)）仍在运行，请刷新后重试。")
                }
            }
            AuthDiagnostics.record(stage: "进程管理", message: "已结束 \(process.name)（\(process.pid)）")
            processes.removeAll { $0.pid == process.pid }
            liftedLimits[process.pid] = nil
            return true
        } catch {
            errorMessage = "结束「\(label(for: process).title)」失败：\(error.localizedDescription)"
            return false
        }
    }

    func liftMemoryLimit(_ process: DeviceProcessInfo, renewal: RenewalController) async -> Bool {
        guard busy == nil else { return false }
        busy = "正在解除「\(label(for: process).title)」的内存上限…"
        defer { busy = nil }
        do {
            try await perform("解除内存上限", renewal) { backend in try await backend.disableMemoryLimit(pid: process.pid) }
            AuthDiagnostics.record(stage: "进程管理", message: "已解除 \(process.name)（\(process.pid)）的内存上限，系统已确认")
            liftedLimits[process.pid] = Date()
            return true
        } catch {
            AuthDiagnostics.record(stage: "进程管理", message: "解除 \(process.name)（\(process.pid)）的内存上限失败：\(error.localizedDescription)")
            errorMessage = "解除内存上限失败：\(error.localizedDescription)"; return false
        }
    }

    func launch(_ app: DeviceInstalledApp, renewal: RenewalController) async {
        guard busy == nil else { return }
        busy = "正在启动「\(app.name)」…"
        defer { busy = nil }
        do {
            try await ensureDeveloperImage(renewal: renewal)
            let pid = try await perform("启动应用", renewal, timeout: 40) { backend in try await backend.launchApp(bundleID: app.bundleID) }
            AuthDiagnostics.record(stage: "进程管理", message: "已启动 \(app.bundleID)（\(pid)）")
        } catch {
            forgetDeveloperImageState()
            errorMessage = "启动「\(app.name)」失败：\(error.localizedDescription)"
        }
    }

    // MARK: 应用图标

    @Published private(set) var icons: [String: UIImage] = [:]
    private var iconRequests: Set<String> = []
    private static var iconFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DeviceIcons", isDirectory: true)
    }

    /// 先读本机缓存，缺的再一次性向设备要；图标不影响其他功能，读不到就显示占位图。
    func loadIcons(for apps: [DeviceInstalledApp], renewal: RenewalController) async {
        var missing: [String] = []
        for app in apps where icons[app.bundleID] == nil && !iconRequests.contains(app.bundleID) {
            let file = Self.iconFolder.appendingPathComponent(app.bundleID + ".png")
            if let image = UIImage(contentsOfFile: file.path) { icons[app.bundleID] = image } else { missing.append(app.bundleID) }
        }
        guard !missing.isEmpty, phase == .ready || appsPhase == .ready || systemPhase == .ready || backend.isSample else { return }
        iconRequests.formUnion(missing)
        defer { iconRequests.subtract(missing) }
        for batch in stride(from: 0, to: missing.count, by: 40).map({ Array(missing[$0..<min($0 + 40, missing.count)]) }) {
            guard let fetched = try? await perform("读取应用图标", renewal, timeout: 60, retry: false, { backend in try await backend.appIcons(bundleIDs: batch) }) else { return }
            try? FileManager.default.createDirectory(at: Self.iconFolder, withIntermediateDirectories: true)
            for (id, data) in fetched {
                guard let image = UIImage(data: data) else { continue }
                icons[id] = image
                try? data.write(to: Self.iconFolder.appendingPathComponent(id + ".png"), options: .atomic)
            }
        }
    }

    // MARK: 应用数据备份

    @Published private(set) var backups: [AppDataBackup] = AppDataBackupStore.list()
    @Published private(set) var transfer: DeviceTransfer?
    private var transferControl: DeviceStreamControl?

    func backups(for app: DeviceInstalledApp) -> [AppDataBackup] { backups.filter { $0.bundleID == app.bundleID } }
    func reloadBackups() { backups = AppDataBackupStore.list() }
    func cancelTransfer() { transferControl?.stop() }

    /// 传输用时按数据量估计，最少 2 分钟；按每秒 1 MB 的保守速度留余量。
    private static func transferTimeout(_ bytes: Int64) -> Double { max(120, Double(bytes) / 1_000_000 + 120) }

    private func runTransfer(_ title: String, expected: Int64?, _ body: @escaping @Sendable (DeviceStreamControl, DeviceTransferMeter) async throws -> Void,
                             step: String, renewal: RenewalController) async throws {
        guard transfer == nil, busy == nil else { throw WorkspaceFailure("已有备份或恢复正在进行。") }
        let control = DeviceStreamControl(), meter = DeviceTransferMeter()
        transferControl = control
        transfer = DeviceTransfer(title: title, expected: expected)
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                let value = meter.current
                self?.transfer?.files = value.files; self?.transfer?.bytes = value.bytes
            }
        }
        defer { ticker.cancel(); transfer = nil; transferControl = nil }
        try await perform(step, renewal, timeout: Self.transferTimeout(expected ?? 0), retry: false) { _ in try await body(control, meter) }
    }

    func backup(_ app: DeviceInstalledApp, renewal: RenewalController) async {
        guard app.filesAccessible else { errorMessage = "系统不允许读取这个应用的数据。"; return }
        let estimate = app.dataSize
        if let free = AppDataBackupStore.availableSpace(), estimate > 0, free < estimate + 500_000_000 {
            errorMessage = "本机剩余空间（\(free.byteLabel)）不够存放这份备份（约 \(estimate.byteLabel)）。"; return
        }
        let id = UUID(), container = AppDataBackupStore.container(id)
        let backend = backend
        let started = Date()
        do {
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            var access = DeviceContainerAccess.container
            var totals: (files: Int, bytes: Int64) = (0, 0)
            try await runTransfer("正在备份「\(app.name)」", expected: estimate > 0 ? estimate : nil, { control, meter in
                _ = try await backend.containerDownload(bundleID: app.bundleID, to: container, excluding: AppDataBackupStore.excluded, control: control) { files, bytes in
                    meter.update(files, bytes)
                }
            }, step: "备份应用数据", renewal: renewal)
            access = app.debuggable ? .container : .documents
            totals = Self.measure(container)
            let backup = AppDataBackup(id: id, bundleID: app.bundleID, appName: app.name, version: app.version, access: access.rawValue,
                                       createdAt: Date(), files: totals.files, bytes: totals.bytes)
            try AppDataBackupStore.commit(backup)
            AuthDiagnostics.record(stage: "数据备份", message: "\(app.name)：\(totals.files) 个文件，\(totals.bytes.byteLabel)，用时 \(Int(Date().timeIntervalSince(started))) 秒")
        } catch {
            AppDataBackupStore.delete(id)
            if !(error is CancellationError) { errorMessage = "备份「\(app.name)」失败：\(error.localizedDescription)" }
        }
        reloadBackups()
    }

    /// 恢复会先清空目标应用的 Documents 和 Library（缓存除外），再写回备份。
    func restore(_ backup: AppDataBackup, to app: DeviceInstalledApp, renewal: RenewalController) async {
        guard app.filesAccessible else { errorMessage = "系统不允许写入这个应用的数据。"; return }
        let container = AppDataBackupStore.container(backup.id)
        let backend = backend
        do {
            try await runTransfer("正在恢复到「\(app.name)」", expected: backup.bytes, { control, meter in
                try await backend.containerUpload(bundleID: app.bundleID, from: container, clearing: AppDataBackupStore.cleared,
                                                  keeping: AppDataBackupStore.excluded, control: control) { files, bytes in meter.update(files, bytes) }
            }, step: "恢复应用数据", renewal: renewal)
            AuthDiagnostics.record(stage: "数据备份", message: "已把 \(backup.appName) \(backup.createdAt.formatted(date: .numeric, time: .shortened)) 的备份恢复到 \(app.name)")
        } catch {
            errorMessage = error is CancellationError
                ? "已取消恢复。「\(app.name)」的数据可能只恢复了一部分，可以重新恢复一次。"
                : "恢复到「\(app.name)」失败：\(error.localizedDescription)。应用的数据可能只恢复了一部分，可以重试。"
        }
    }

    func deleteBackup(_ backup: AppDataBackup) { AppDataBackupStore.delete(backup.id); reloadBackups() }

    nonisolated static func measure(_ folder: URL) -> (files: Int, bytes: Int64) {
        var files = 0, bytes: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let item = enumerator?.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            files += 1; bytes += Int64(values.fileSize ?? 0)
        }
        return (files, bytes)
    }

    static func discardDownloads() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("DeviceFiles", isDirectory: true))
    }
}
