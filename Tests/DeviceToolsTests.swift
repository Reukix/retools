import XCTest
import CoreLocation
import CryptoKit
import IdeviceGateway
@testable import LiveContainerSwiftUI

final class DeviceToolsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func profileData(_ uuid: String, app: String, team: String = "TEAM123456", days: Double, extra: [String: Any] = [:]) throws -> Data {
        var plist: [String: Any] = ["UUID": uuid, "Name": "P-\(uuid)", "TeamName": "Team", "TeamIdentifier": [team],
                                    "ExpirationDate": now.addingTimeInterval(days * 86_400),
                                    "Entitlements": ["application-identifier": team + "." + app, "get-task-allow": true],
                                    "ProvisionedDevices": ["A", "B"]]
        plist.merge(extra) { $1 }
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        // 真实描述文件是 CMS 封装，plist 前后都有二进制数据。
        return Data([0x30, 0x82, 0x0A, 0x00]) + xml + Data([0xA0, 0x82, 0x00, 0x3C])
    }
    private func profile(_ uuid: String, app: String, team: String = "TEAM123456", days: Double) throws -> DeviceProfile {
        try XCTUnwrap(DeviceProfile.parse(profileData(uuid, app: app, team: team, days: days)))
    }
    private func app(_ bundleID: String, profileSigned: Bool = true, extra: [String: Any] = [:]) throws -> DeviceInstalledApp {
        var plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": bundleID.components(separatedBy: ".").last!, "ProfileValidated": profileSigned]
        plist.merge(extra) { $1 }
        return try XCTUnwrap(DeviceInstalledApp.parse(PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)))
    }

    func testProfileParsingStripsSignatureAndTeamPrefix() throws {
        let profile = try profile("U1", app: "com.example.app", days: 3)
        XCTAssertEqual(profile.uuid, "U1")
        XCTAssertEqual(profile.teamID, "TEAM123456")
        XCTAssertEqual(profile.appIdentifier, "com.example.app")
        XCTAssertTrue(profile.debuggable)
        XCTAssertEqual(profile.deviceCount, 2)
        XCTAssertFalse(profile.isExpired(now: now))
        XCTAssertTrue(profile.matches(bundleID: "com.example.app"))
        XCTAssertFalse(profile.matches(bundleID: "com.example.app.widget"))
        XCTAssertNil(DeviceProfile.parse(Data("not a profile".utf8)))
    }

    func testWildcardProfileMatchesPrefix() throws {
        let wildcard = try profile("W", app: "*", days: 3)
        XCTAssertTrue(wildcard.isWildcard)
        XCTAssertTrue(wildcard.matches(bundleID: "anything.at.all"))
        let scoped = try profile("S", app: "com.example.*", days: 3)
        XCTAssertTrue(scoped.matches(bundleID: "com.example.tool"))
        XCTAssertFalse(scoped.matches(bundleID: "org.other.tool"))
    }

    func testUsageKeepsNewestInUseAndFlagsTheRest() throws {
        let current = try profile("NEW", app: "com.example.app", days: 6)
        let older = try profile("OLD", app: "com.example.app", days: 1)
        let expired = try profile("EXP", app: "com.example.gone", days: -1)
        let orphan = try profile("ORP", app: "com.example.removed", days: 4)
        let otherTeam = try profile("TEAM2", app: "com.example.app", team: "OTHER00000", days: 2)
        let apps = [try app("com.example.app")]
        let usage = DeviceProfileAnalysis.usage(of: [current, older, expired, orphan, otherTeam], apps: apps, now: now)
        XCTAssertEqual(usage["NEW"], .inUse(apps: ["app"]))
        // 不知道描述文件含哪些证书时，无法确认新的能替代旧的，旧的按使用中保留。
        XCTAssertEqual(usage["OLD"], .inUse(apps: ["app"]))
        XCTAssertEqual(usage["EXP"], .expired)
        XCTAssertEqual(usage["ORP"], .unused)
        // 不同团队的同名 App ID 互不取代。
        XCTAssertEqual(usage["TEAM2"], .inUse(apps: ["app"]))
        // 只有过期的能一键清理；被取代、没找到应用的只是参考判断。
        XCTAssertTrue(usage["EXP"]!.cleanable)
        XCTAssertFalse(usage["NEW"]!.cleanable || usage["OLD"]!.cleanable || usage["ORP"]!.cleanable)
        XCTAssertTrue(usage["ORP"]!.uncertain)
    }

    /// 回归：证书签名的应用，签名里的 App ID 与 Bundle ID 不同。按 Bundle ID 匹配会把它正在用的描述文件判成没人用。
    func testCertificateSignedAppsMatchBySignedAppIdentifier() throws {
        let shared = try profile("CERT", app: "app.apricot7651.mango8575", team: "SHARED0001", days: 190)
        let otherTeam = try profile("OTHER", app: "app.apricot7651.mango8575", team: "ZZZZZZZZZZ", days: 190)
        let regram = try app("app.swiftgram.ios", extra: ["Entitlements": ["application-identifier": "SHARED0001.app.apricot7651.mango8575",
                                                                           "com.apple.developer.team-identifier": "SHARED0001"]])
        let wloc = try app("com.yu9191.wloc", extra: ["Entitlements": ["application-identifier": "SHARED0001.app.apricot7651.mango8575"]])
        XCTAssertEqual(regram.signedAppID, "app.apricot7651.mango8575")
        XCTAssertEqual(wloc.signedTeamID, "SHARED0001")
        XCTAssertTrue(shared.matches(app: regram) && shared.matches(app: wloc))
        XCTAssertFalse(otherTeam.matches(app: regram))
        let usage = DeviceProfileAnalysis.usage(of: [shared, otherTeam], apps: [regram, wloc], now: now)
        XCTAssertEqual(usage["CERT"], .inUse(apps: ["ios", "wloc"]))
        XCTAssertEqual(usage["OTHER"], .unused)
        XCTAssertFalse(usage["OTHER"]!.cleanable)
    }

    /// Retools 续签留下的旧描述文件：新的包含当前签名证书时可以清理；扩展的描述文件归到主应用名下。
    func testRenewalLeftoversAndExtensionProfiles() throws {
        let signer = "Apple Development: someone@example.com (TESTCERT01)"
        var newer = try profile("NEW", app: "dev.retools.ios", team: "TESTTEAM01", days: 7); newer.certificateNames = [signer]
        var older = try profile("OLD", app: "dev.retools.ios", team: "TESTTEAM01", days: 5); older.certificateNames = [signer]
        var widget = try profile("PAIR", app: "dev.retools.ios.pairing", team: "TESTTEAM01", days: 5); widget.certificateNames = [signer]
        let retools = try app("dev.retools.ios", extra: ["CFBundleDisplayName": "Retools", "SignerIdentity": signer,
                                                        "Entitlements": ["application-identifier": "TESTTEAM01.dev.retools.ios"]])
        let usage = DeviceProfileAnalysis.usage(of: [newer, older, widget], apps: [retools], now: now)
        XCTAssertEqual(usage["NEW"], .inUse(apps: ["Retools"]))
        XCTAssertEqual(usage["OLD"], .replaced)
        XCTAssertTrue(usage["OLD"]!.cleanable)
        XCTAssertEqual(usage["PAIR"], .inUse(apps: ["Retools 的扩展"]))

        // 新描述文件不含应用当前的签名证书：旧的那份可能正在被用，保留。
        var otherCert = newer; otherCert.certificateNames = ["Apple Development: other (ZZZ)"]
        let kept = DeviceProfileAnalysis.usage(of: [otherCert, older], apps: [retools], now: now)
        XCTAssertEqual(kept["OLD"], .inUse(apps: ["Retools"]))
        // 不知道应用用哪张证书签名时，也不清理。
        var unsigned = retools; unsigned.signer = ""
        XCTAssertEqual(DeviceProfileAnalysis.usage(of: [newer, older], apps: [unsigned], now: now)["OLD"], .inUse(apps: ["Retools"]))
        // 没有任何应用对应、但有更新的同类：只作参考，不进清理。
        let orphanOld = try profile("O1", app: "com.example.gone", days: 2), orphanNew = try profile("O2", app: "com.example.gone", days: 6)
        XCTAssertEqual(DeviceProfileAnalysis.usage(of: [orphanOld, orphanNew], apps: [retools], now: now)["O1"], .superseded)
    }

    func testDeletedProfilesAreKeptForRestore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = try profile("KEEP", app: "com.example.app", days: 3)
        try DeviceProfileTrash.keep(kept, in: folder)
        let entries = DeviceProfileTrash.entries(in: folder)
        XCTAssertEqual(entries.map(\.uuid), ["KEEP"])
        XCTAssertEqual(try Data(contentsOf: entries[0].file), kept.raw)
        // 超过 30 天的副本自动清掉。
        XCTAssertTrue(DeviceProfileTrash.entries(in: folder, now: Date().addingTimeInterval(31 * 86_400)).isEmpty)
        var empty = kept; empty.raw = Data()
        XCTAssertThrowsError(try DeviceProfileTrash.keep(empty, in: folder))
    }

    func testInstalledAppParsing() throws {
        let parsed = try app("com.utmapp.UTM", extra: ["CFBundleDisplayName": "UTM", "CFBundleShortVersionString": "5.0.8", "CFBundleVersion": "121",
                                                       "Entitlements": ["get-task-allow": true], "UIFileSharingEnabled": true,
                                                       "StaticDiskUsage": 1_000, "DynamicDiskUsage": 2_000])
        XCTAssertEqual(parsed.name, "UTM")
        XCTAssertEqual(parsed.version, "5.0.8")
        XCTAssertTrue(parsed.profileSigned && parsed.debuggable && parsed.fileSharing)
        XCTAssertEqual(parsed.bundleSize + parsed.dataSize, 3_000)
        XCTAssertFalse(try app("com.apple.store.Jolly", profileSigned: false).profileSigned)
    }

    func testDeviceInfoCombinesDomains() throws {
        func xml(_ value: [String: Any]) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) }
        let info = DeviceInfoSummary.parse(general: try xml(["DeviceName": "Phone", "ProductVersion": "27.0", "ProductType": "iPhone17,1"]),
                                           disk: try xml(["TotalDiskCapacity": 256_000, "AmountDataAvailable": 64_000]),
                                           battery: try xml(["BatteryCurrentCapacity": 81, "BatteryIsCharging": false]))
        XCTAssertEqual(info.name, "Phone")
        XCTAssertEqual(info.totalCapacity, 256_000)
        XCTAssertEqual(info.dataAvailable, 64_000)
        // 实机数据：可用以 AmountDataAvailable 为准，TotalDataAvailable 多出的部分是可释放空间。
        let real = DeviceInfoSummary.parse(general: try xml([:]), disk: try xml(["TotalDiskCapacity": 128_000_000_000 as Int64,
            "TotalDataAvailable": 77_450_223_616 as Int64, "AmountDataAvailable": 5_710_200_832 as Int64]), battery: nil)
        XCTAssertEqual(real.dataAvailable, 5_710_200_832)
        XCTAssertEqual(real.purgeable, 71_740_022_784)
        XCTAssertEqual(info.batteryLevel, 81)
        XCTAssertEqual(info.charging, false)
        XCTAssertNil(DeviceInfoSummary.parse(general: Data(), disk: nil, battery: nil).batteryLevel)
    }

    func testFileHelpers() {
        XCTAssertEqual(DeviceFileItem.uniqueName("a.txt", existing: []), "a.txt")
        XCTAssertEqual(DeviceFileItem.uniqueName("a.txt", existing: ["a.txt", "a 2.txt"]), "a 3.txt")
        XCTAssertEqual(DeviceFileItem.uniqueName("Folder", existing: ["Folder"]), "Folder 2")
        XCTAssertEqual(DeviceFileItem.join("/", "Documents"), "/Documents")
        XCTAssertEqual(DeviceFileItem.join("/Documents", "x"), "/Documents/x")
        let seconds = 1_800_000_000.0
        for raw in [Int64(seconds), Int64(seconds * 1e3), Int64(seconds * 1e6), Int64(seconds * 1e9)] {
            XCTAssertEqual(DeviceFileItem.date(fromRaw: raw)?.timeIntervalSince1970 ?? 0, seconds, accuracy: 1)
        }
        XCTAssertNil(DeviceFileItem.date(fromRaw: 0))
        let sorted = DeviceFileItem.sorted([DeviceFileItem(path: "/b.txt", isDirectory: false, size: 1, modified: nil),
                                            DeviceFileItem(path: "/Zed", isDirectory: true, size: 0, modified: nil),
                                            DeviceFileItem(path: "/a10", isDirectory: false, size: 1, modified: nil),
                                            DeviceFileItem(path: "/a9", isDirectory: false, size: 1, modified: nil),
                                            DeviceFileItem(path: "/.com.apple.mobile_container_manager.metadata.plist", isDirectory: false, size: 1, modified: nil)])
        XCTAssertEqual(sorted.map(\.name), ["Zed", "a9", "a10", "b.txt"])
    }

    @MainActor
    func testSampleStoreCleansProfilesAndManagesFiles() async throws {
        let store = DeviceToolsStore(backend: SampleDeviceToolsBackend())
        let renewal = RenewalController()
        await store.refresh(renewal: renewal)
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.cleanupCandidates.map(\.uuid), ["C1"])
        XCTAssertEqual(store.uncertainProfiles.map(\.uuid), ["D1"])
        XCTAssertEqual(store.sideloadedApps.map(\.name), ["Retools", "Surge", "UTM"])
        XCTAssertEqual(store.apps(of: .sideloaded).map(\.name), ["Retools", "UTM"])
        XCTAssertEqual(store.apps(of: .testFlight).map(\.name), ["Surge"])
        XCTAssertEqual(store.apps(of: .appStore).map(\.name), ["Apple Store"])
        XCTAssertTrue(store.apps(of: .appStore)[0].filesAccessible)
        XCTAssertTrue(store.apps(of: .system).isEmpty)
        await store.loadSystemApps(renewal: renewal)
        XCTAssertEqual(store.apps(of: .system).map(\.name), ["Safari 浏览器", "天气"].sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertTrue(store.apps(of: .system).allSatisfy { $0.kind == .system && !$0.filesAccessible })
        XCTAssertEqual(store.info?.batteryLevel, 78)

        store.discardTrash(store.trash)
        await store.removeProfiles(store.cleanupCandidates + store.uncertainProfiles, renewal: renewal)
        XCTAssertTrue(store.cleanupCandidates.isEmpty)
        XCTAssertEqual(Set(store.profiles.map(\.uuid)), ["A1", "B1", "B2"])
        // 删掉的都留了副本，可以装回去。
        XCTAssertEqual(Set(store.trash.map(\.uuid)), ["C1", "D1"])
        await store.restoreProfiles(store.trash.filter { $0.uuid == "D1" }, renewal: renewal)
        XCTAssertTrue(store.profiles.contains { $0.uuid == "D1" })
        XCTAssertEqual(store.trash.map(\.uuid), ["C1"])
        store.discardTrash(store.trash)

        let utm = try XCTUnwrap(store.sideloadedApps.first { $0.bundleID == "com.utmapp.UTM" })
        let root = try await store.entries(of: utm, path: "/", renewal: renewal)
        XCTAssertEqual(root.access, .container)
        XCTAssertEqual(root.entries.map(\.name), ["Documents", "Library", "tmp"])
        try await store.makeDirectory("存档", in: "/Documents", of: utm, renewal: renewal)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("说明.txt")
        try Data("new".utf8).write(to: source)
        let uploaded = try await store.upload(source, to: "/Documents", existing: ["说明.txt"], of: utm, renewal: renewal)
        XCTAssertEqual(uploaded, "说明 2.txt")
        let docs = try await store.entries(of: utm, path: "/Documents", renewal: renewal)
        XCTAssertEqual(docs.entries.map(\.name), ["存档", "Windows 11.utm", "说明 2.txt", "说明.txt"].sorted { a, b in
            let dirs: Set = ["存档", "Windows 11.utm"]
            return dirs.contains(a) != dirs.contains(b) ? dirs.contains(a) : a.localizedStandardCompare(b) == .orderedAscending
        })
        let file = try XCTUnwrap(docs.entries.first { $0.name == "说明 2.txt" })
        let downloaded = try await store.download(file, of: utm, renewal: renewal)
        XCTAssertEqual(try Data(contentsOf: downloaded), Data("new".utf8))
        try await store.remove(file, of: utm, renewal: renewal)
        let after = try await store.entries(of: utm, path: "/Documents", renewal: renewal)
        XCTAssertFalse(after.entries.contains { $0.name == "说明 2.txt" })
    }

    func testCrashEntryParsesProcessDateAndKind() throws {
        func entry(_ path: String) -> DeviceCrashEntry? { DeviceCrashEntry(DeviceFileItem(path: path, isDirectory: false, size: 10, modified: nil)) }
        let crash = try XCTUnwrap(entry("/UTM-2026-11-08-101112.ips"))
        XCTAssertEqual(crash.process, "UTM")
        XCTAssertEqual(crash.kind, .crash)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: try XCTUnwrap(crash.date)),
                       DateComponents(year: 2026, month: 11, day: 8, hour: 10, minute: 11, second: 12))
        XCTAssertEqual(entry("/Retired/ExcUserFault_UTM-2026-11-01-080000.ips")?.kind, .resource)
        XCTAssertEqual(entry("/Retired/ExcUserFault_UTM-2026-11-01-080000.ips")?.process, "UTM")
        XCTAssertEqual(entry("/JetsamEvent-2026-11-07-220000.ips")?.kind, .memory)
        XCTAssertEqual(entry("/My App.Extension-2026-11-07-220000.ips")?.process, "My App")
        XCTAssertNil(entry("/notes.txt"))
        XCTAssertNil(DeviceCrashEntry(DeviceFileItem(path: "/Retired", isDirectory: true, size: 0, modified: nil)))
    }

    func testCrashDetailParsesIPSAndLegacyText() {
        let ips = #"{"app_name":"UTM","app_version":"5.0.8","build_version":"121","bundleID":"com.utmapp.UTM","os_version":"iPhone OS 27.0"}"# + "\n" +
            #"{"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"termination":{"namespace":"SIGNAL","indicator":"Segmentation fault: 11"},"faultingThread":1,"threads":[{"frames":[]},{"frames":[{"imageIndex":1,"symbol":"boom"},{"imageIndex":0,"imageOffset":255}]}],"usedImages":[{"name":"UTM"},{"name":"libqemu"}]}"#
        let detail = DeviceCrashDetail.parse(Data(ips.utf8))
        XCTAssertEqual(detail.appName, "UTM")
        XCTAssertEqual(detail.bundleID, "com.utmapp.UTM")
        XCTAssertEqual(detail.version, "5.0.8 (121)")
        XCTAssertEqual(detail.exception, "EXC_BAD_ACCESS · SIGSEGV")
        XCTAssertEqual(detail.termination, "SIGNAL · Segmentation fault: 11")
        XCTAssertEqual(detail.crashedThread, 1)
        XCTAssertEqual(detail.frames, ["0  libqemu  boom", "1  UTM  +0xff"])

        let legacy = DeviceCrashDetail.parse(Data("Process: Game [123]\nIdentifier: com.example.game\nException Type: EXC_CRASH (SIGABRT)\n".utf8))
        XCTAssertEqual(legacy.appName, "Game")
        XCTAssertEqual(legacy.bundleID, "com.example.game")
        XCTAssertEqual(legacy.exception, "EXC_CRASH (SIGABRT)")
    }

    func testBatteryHealthUsesRawCapacity() throws {
        func xml(_ value: [String: Any]) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) }
        let health = try XCTUnwrap(DeviceBatteryHealth.parse(xml(["IORegistry": ["CycleCount": 312, "DesignCapacity": 3_561, "AppleRawMaxCapacity": 3_204,
                                                                                  "MaxCapacity": 100, "Temperature": 3_120, "Voltage": 4_012]])))
        XCTAssertEqual(health.cycleCount, 312)
        XCTAssertEqual(health.healthPercent, 90)
        XCTAssertEqual(health.temperature ?? 0, 31.2, accuracy: 0.01)
        // 只有百分比形式的 MaxCapacity 时不计算健康度。
        XCTAssertNil(try XCTUnwrap(DeviceBatteryHealth.parse(xml(["CycleCount": 5, "DesignCapacity": 3_000, "MaxCapacity": 100]))).healthPercent)
        XCTAssertNil(DeviceBatteryHealth.parse(try xml(["Unrelated": 1])))
        // iOS 27 实机格式：容量在 BatteryData 里，顶层只有百分比形式的 MaxCapacity。
        let modern = try XCTUnwrap(DeviceBatteryHealth.parse(xml(["IORegistry": ["CycleCount": 306, "MaxCapacity": 100, "Voltage": 4_289,
            "ExternalConnected": true, "AdapterDetails": ["Description": "pd charger", "Watts": 15],
            "BatteryData": ["DesignCapacity": 3_544, "NominalChargeCapacity": 3_366, "FullChargeCapacity": 3_443, "MaxCapacity": 100]]])))
        XCTAssertEqual(modern.designCapacity, 3_544)
        XCTAssertEqual(modern.maxCapacity, 3_366)
        XCTAssertEqual(modern.healthPercent, 95)
        XCTAssertEqual(modern.charger, "pd charger")
        XCTAssertEqual(modern.chargerWatts, 15)
    }

    func testLogLineConversionAndFiltering() {
        let record = DeviceLogRecord(pid: 42, timestampRaw: 1_800_000_000, level: 10, imageName: "/usr/lib/libfoo.dylib",
                                     processPath: "/Applications/UTM.app/UTM", subsystem: "com.utmapp.UTM", category: "vm", message: "JIT unavailable")
        let line = DeviceLogLine(id: 1, record: record)
        XCTAssertEqual(line.process, "UTM")
        XCTAssertTrue(line.isError)
        XCTAssertEqual(line.date.timeIntervalSince1970, 1_800_000_000, accuracy: 1)
        XCTAssertTrue(line.matches(query: "jit") && line.matches(query: "utmapp") && !line.matches(query: "springboard"))
        XCTAssertTrue(line.exportLine.contains("UTM[42] <错误> (com.utmapp.UTM:vm) JIT unavailable"))
    }

    @MainActor
    func testLogStoreStreamsFiltersAndStops() async throws {
        let logs = DeviceLogStore(backend: SampleDeviceToolsBackend())
        logs.start(renewal: RenewalController())
        XCTAssertTrue(logs.isRunning)
        for _ in 0..<40 where logs.lines.count < 4 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertGreaterThanOrEqual(logs.lines.count, 4)
        logs.errorsOnly = true
        XCTAssertTrue(logs.visible.allSatisfy(\.isError))
        XCTAssertFalse(logs.visible.isEmpty)
        logs.errorsOnly = false; logs.process = "installd"
        XCTAssertTrue(logs.visible.allSatisfy { $0.process == "installd" })
        let exported = try logs.export()
        XCTAssertTrue(try String(contentsOf: exported, encoding: .utf8).contains("installd"))
        logs.stop()
        XCTAssertFalse(logs.isRunning)
        let count = logs.lines.count
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(logs.lines.count, count)
    }

    @MainActor
    func testSampleCrashReportsAndBatteryHealth() async throws {
        let store = DeviceToolsStore(backend: SampleDeviceToolsBackend())
        let renewal = RenewalController()
        await store.refresh(renewal: renewal)
        XCTAssertEqual(store.info?.batteryHealth?.healthPercent, 90)
        await store.loadCrashReports(renewal: renewal)
        XCTAssertEqual(store.crashReports.count, 3)
        XCTAssertEqual(store.crashReports.first?.name, "UTM-2026-11-08-101112.ips")
        let result = try await store.crashDetail(try XCTUnwrap(store.crashReports.first), renewal: renewal)
        XCTAssertEqual(result.detail.frames.first, "0  qemu-aarch64-softmmu  qemu_ram_alloc")
        await store.removeCrashReports(store.crashReports.filter { $0.process == "UTM" }, renewal: renewal)
        XCTAssertEqual(store.crashReports.map(\.kind), [.memory])
    }

    func testRenewalPrunesOnlySameAppIDWithEarlierExpiry() throws {
        let installed = try profile("NEW", app: "dev.retools.ios", team: "TESTTEAM01", days: 7)
        let older = try profile("OLD", app: "dev.retools.ios", team: "TESTTEAM01", days: 3)
        let laterThanNew = try profile("LATER", app: "dev.retools.ios", team: "TESTTEAM01", days: 9)
        let widget = try profile("PAIR", app: "dev.retools.ios.pairing", team: "TESTTEAM01", days: 2)
        let otherTeam = try profile("TEAM", app: "dev.retools.ios", team: "OTHER00000", days: 1)
        let wildcard = try profile("WILD", app: "*", team: "TESTTEAM01", days: 1)
        let stale = RenewalController.replacedProfiles(onDevice: [installed, older, laterThanNew, widget, otherTeam, wildcard], installed: [installed])
        XCTAssertEqual(stale.map(\.uuid), ["OLD"])
    }

    func testEmbeddedProfilesIncludeExtensions() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-\(UUID().uuidString)/Demo.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let appex = app.appendingPathComponent("PlugIns/Widget.appex")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        try Data("main".utf8).write(to: app.appendingPathComponent("embedded.mobileprovision"))
        try Data("widget".utf8).write(to: appex.appendingPathComponent("embedded.mobileprovision"))
        XCTAssertEqual(Set(RenewalController.embeddedProfiles(in: app)), [Data("main".utf8), Data("widget".utf8)])
    }

    func testIncompleteBackupFoldersAreDropped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let done = AppDataBackup(id: UUID(), bundleID: "a.b", appName: "A", version: "1", access: "container", createdAt: Date(), files: 1, bytes: 3)
        try FileManager.default.createDirectory(at: AppDataBackupStore.container(done.id, root: root), withIntermediateDirectories: true)
        try AppDataBackupStore.commit(done, root: root)
        let partial = UUID()
        try FileManager.default.createDirectory(at: AppDataBackupStore.container(partial, root: root), withIntermediateDirectories: true)
        XCTAssertEqual(AppDataBackupStore.list(root: root), [done])
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppDataBackupStore.folder(partial, root: root).path))
    }

    @MainActor
    func testBackupAndRestoreRoundTripWithIcons() async throws {
        let store = DeviceToolsStore(backend: SampleDeviceToolsBackend())
        let renewal = RenewalController()
        await store.refresh(renewal: renewal)
        let utm = try XCTUnwrap(store.apps.first { $0.bundleID == "com.utmapp.UTM" })
        await store.loadIcons(for: [utm], renewal: renewal)
        XCTAssertNotNil(store.icons[utm.bundleID])

        store.backups(for: utm).forEach(store.deleteBackup)
        await store.backup(utm, renewal: renewal)
        XCTAssertNil(store.errorMessage)
        let backup = try XCTUnwrap(store.backups(for: utm).first)
        XCTAssertEqual(backup.files, 2)
        let saved = AppDataBackupStore.container(backup.id)
        XCTAssertEqual(try String(contentsOf: saved.appendingPathComponent("Documents/说明.txt"), encoding: .utf8), "这是模拟器示例文件。")
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.appendingPathComponent("tmp").path))

        // 改动应用数据后恢复：删掉的文件回来，新增的文件被清掉。
        let docs = try await store.entries(of: utm, path: "/Documents", renewal: renewal)
        try await store.remove(try XCTUnwrap(docs.entries.first { $0.name == "说明.txt" }), of: utm, renewal: renewal)
        try await store.makeDirectory("临时", in: "/Documents", of: utm, renewal: renewal)
        await store.restore(backup, to: utm, renewal: renewal)
        XCTAssertNil(store.errorMessage)
        let restored = try await store.entries(of: utm, path: "/Documents", renewal: renewal)
        XCTAssertEqual(Set(restored.entries.map(\.name)), ["Windows 11.utm", "说明.txt"])
        let tmp = try await store.entries(of: utm, path: "/", renewal: renewal)
        XCTAssertTrue(tmp.entries.contains { $0.name == "tmp" })
        store.deleteBackup(backup)
        XCTAssertTrue(store.backups(for: utm).isEmpty)
    }

    private func freeProfile(_ uuid: String, app: String, team: String = "FREE000000", validity: Double = 7) throws -> DeviceProfile {
        var value = try profile(uuid, app: app, team: team, days: 5)
        value.created = value.expires!.addingTimeInterval(-validity * 86_400)
        return value
    }
    private func teamApp(_ bundleID: String, team: String = "FREE000000") throws -> DeviceInstalledApp {
        try app(bundleID, extra: ["Entitlements": ["application-identifier": "\(team).\(bundleID)", "get-task-allow": true]])
    }

    func testPreflightBlocksWhenSpaceIsShort() {
        XCTAssertEqual(InstallPreflight.requiredSpace(appSize: 100_000_000, migrationBytes: 50_000_000), 550_000_000)
        let reason = InstallPreflight.blocker(appSize: 100_000_000, migrationBytes: 50_000_000, freeSpace: 400_000_000, newProfile: nil,
                                              bundleID: "a.b", installed: [], profiles: [])
        XCTAssertTrue(reason?.contains("剩余空间不足") == true && reason?.contains("迁移数据") == true)
        XCTAssertNil(InstallPreflight.blocker(appSize: 100_000_000, migrationBytes: 0, freeSpace: 600_000_000, newProfile: nil, bundleID: "a.b", installed: [], profiles: []))
        // 读不到剩余空间时不阻止。
        XCTAssertNil(InstallPreflight.blocker(appSize: 100_000_000, migrationBytes: 0, freeSpace: nil, newProfile: nil, bundleID: "a.b", installed: [], profiles: []))
    }

    func testPreflightEnforcesFreeAccountAppLimit() throws {
        let installed = try ["one.app", "two.app", "three.app"].map { try teamApp($0) }
        let profiles = try installed.map { try freeProfile("P-\($0.bundleID)", app: $0.bundleID) }
        let newFree = try freeProfile("NEW", app: "four.app")
        let reason = InstallPreflight.blocker(appSize: 1, migrationBytes: 0, freeSpace: nil, newProfile: newFree, bundleID: "four.app", installed: installed, profiles: profiles)
        XCTAssertTrue(reason?.contains("最多同时安装 3 个应用") == true)
        // 替换已安装的同一个应用不增加数量。
        XCTAssertNil(InstallPreflight.blocker(appSize: 1, migrationBytes: 0, freeSpace: nil, newProfile: try freeProfile("RE", app: "one.app"),
                                              bundleID: "one.app", installed: installed, profiles: profiles))
        // 付费账号（一年有效期）不受限制。
        XCTAssertNil(InstallPreflight.blocker(appSize: 1, migrationBytes: 0, freeSpace: nil, newProfile: try freeProfile("PAID", app: "four.app", validity: 365),
                                              bundleID: "four.app", installed: installed, profiles: profiles))
        // 其他团队的应用不算。
        let others = try installed.map { try teamApp($0.bundleID, team: "OTHER00000") }
        XCTAssertNil(InstallPreflight.blocker(appSize: 1, migrationBytes: 0, freeSpace: nil, newProfile: newFree, bundleID: "four.app", installed: others, profiles: profiles))
    }

    func testMigrationSourceSelection() throws {
        let original = try teamApp("com.example.game")
        let previous = try teamApp("com.example.game.resigned")
        let locked = try app("com.example.locked")
        XCTAssertEqual(AppDataMigration.source(newBundleID: "com.example.game.v2", previous: previous.bundleID, original: original.bundleID,
                                               installed: [original, previous])?.bundleID, previous.bundleID)
        XCTAssertEqual(AppDataMigration.source(newBundleID: "com.example.game.v2", previous: nil, original: original.bundleID, installed: [original])?.bundleID,
                       original.bundleID)
        // 新应用已经装过（有自己的数据）时不迁移。
        XCTAssertNil(AppDataMigration.source(newBundleID: original.bundleID, previous: previous.bundleID, original: original.bundleID, installed: [original, previous]))
        // 系统不允许读取数据的应用不能作为来源。
        XCTAssertNil(AppDataMigration.source(newBundleID: "x.new", previous: nil, original: locked.bundleID, installed: [locked]))
    }

    private func ddiManifest(image: Data, trustCache: Data) throws -> Data {
        let identity: [String: Any] = ["Manifest": ["PersonalizedDMG": ["Digest": Data(SHA384.hash(data: image))],
                                                    "LoadableTrustCache": ["Digest": Data(SHA384.hash(data: trustCache))]]]
        let other: [String: Any] = ["Manifest": ["PersonalizedDMG": ["Digest": Data(repeating: 1, count: 48)]]]
        return try PropertyListSerialization.data(fromPropertyList: ["BuildIdentities": [other, identity]], format: .xml, options: 0)
    }

    func testDeveloperImageVerification() throws {
        let image = Data(repeating: 7, count: 1_200_000), trustCache = Data("trust".utf8)
        let manifest = try ddiManifest(image: image, trustCache: trustCache)
        XCTAssertEqual(DeveloperDiskImage.manifestDigests(manifest)["PersonalizedDMG"]?.count, 2)
        XCTAssertNoThrow(try DeveloperDiskImage.verify(.init(image: image, trustCache: trustCache, manifest: manifest)))
        var corrupted = image; corrupted[0] = 8
        XCTAssertThrowsError(try DeveloperDiskImage.verify(.init(image: corrupted, trustCache: trustCache, manifest: manifest)))
        XCTAssertThrowsError(try DeveloperDiskImage.verify(.init(image: image, trustCache: Data("x".utf8), manifest: manifest)))
        XCTAssertThrowsError(try DeveloperDiskImage.verify(.init(image: Data(count: 10), trustCache: trustCache, manifest: manifest)))
    }

    func testDeveloperImageDownloadReplacesFolderOnlyWhenValid() async throws {
        let image = Data(repeating: 3, count: 1_100_000), trustCache = Data("tc".utf8)
        let manifest = try ddiManifest(image: image, trustCache: trustCache)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ddi-\(UUID().uuidString)/DeveloperDiskImage")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DDIStubProtocol.self]
        let session = URLSession(configuration: configuration)

        DDIStubProtocol.responses = [DeveloperDiskImage.manifestName: manifest, DeveloperDiskImage.imageName: image, DeveloperDiskImage.trustCacheName: trustCache]
        try await DeveloperDiskImage.download(to: folder, session: session) { _ in }
        XCTAssertTrue(DeveloperDiskImage.isDownloaded(in: folder))
        XCTAssertEqual(try DeveloperDiskImage.load(from: folder).image, image)

        // 下载到损坏的镜像：校验失败，原来那套完好的文件不受影响，也不留临时目录。
        var broken = image; broken[10] = 9
        DDIStubProtocol.responses[DeveloperDiskImage.imageName] = broken
        do { try await DeveloperDiskImage.download(to: folder, session: session) { _ in }; XCTFail("应当校验失败") } catch {}
        XCTAssertEqual(try DeveloperDiskImage.load(from: folder).image, image)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["DeveloperDiskImage"])
    }

    func testMountFailureMessages() {
        XCTAssertTrue(DeviceToolsStore.mountFailureMessage("TSS request failed").contains("gs.apple.com"))
        XCTAssertTrue(DeviceToolsStore.mountFailureMessage("Developer Mode is disabled").contains("开发者模式"))
        XCTAssertTrue(DeviceToolsStore.mountFailureMessage("NoSuchBuildIdentity").contains("重新下载"))
    }

    @MainActor
    func testSampleDeveloperImageMount() async {
        let store = DeviceToolsStore(backend: SampleDeviceToolsBackend())
        let renewal = RenewalController()
        await store.refresh(renewal: renewal)
        XCTAssertEqual(store.developerImageMounted, false)
        await store.mountDeveloperImage(renewal: renewal)
        XCTAssertEqual(store.developerImageMounted, true)
        XCTAssertNil(store.developerImageStep)
        XCTAssertNil(store.errorMessage)
    }

    func testChinaCoordinateConversion() {
        let tiananmen = CLLocationCoordinate2D(latitude: 39.908692, longitude: 116.397477)
        let gcj = ChinaCoordinate.wgsToGcj(tiananmen)
        // GCJ-02 在北京大约偏移几百米。
        XCTAssertEqual(gcj.latitude - tiananmen.latitude, 0.0014, accuracy: 0.0005)
        XCTAssertEqual(gcj.longitude - tiananmen.longitude, 0.0062, accuracy: 0.0005)
        let back = ChinaCoordinate.gcjToWgs(gcj)
        XCTAssertEqual(back.latitude, tiananmen.latitude, accuracy: 1e-6)
        XCTAssertEqual(back.longitude, tiananmen.longitude, accuracy: 1e-6)
        let tokyo = CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671)
        XCTAssertEqual(ChinaCoordinate.wgsToGcj(tokyo).latitude, tokyo.latitude)
    }

    @MainActor
    func testLocationSimulationLifecycle() async throws {
        let backend = SampleDeviceToolsBackend()
        let tools = DeviceToolsStore(backend: backend)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "location-\(UUID().uuidString)"))
        let store = DeviceLocationStore(backend: backend, defaults: defaults, keepAlive: false)
        let renewal = RenewalController()
        let home = SavedLocation(name: "家", latitude: 31.2304, longitude: 121.4737)
        let office = SavedLocation(name: "公司", latitude: 31.2400, longitude: 121.5000)

        await store.simulate(home, renewal: renewal, tools: tools)
        XCTAssertEqual(store.active, home)
        XCTAssertEqual(tools.developerImageMounted, true)  // 没挂载时自动挂载
        await store.simulate(office, renewal: renewal, tools: tools)
        XCTAssertEqual(store.active, office)
        var history = await backend.location.history
        XCTAssertEqual(history.map(\.latitude), [31.2304, 31.2400])
        XCTAssertEqual(store.recents.map(\.name), ["公司", "家"])

        // 连接失效：换一条新连接重试，用户无感。
        await backend.location.failOnce()
        await store.simulate(home, renewal: renewal, tools: tools)
        XCTAssertEqual(store.active, home)
        let opened = await backend.location.opened
        XCTAssertEqual(opened, 2)

        await store.stop()
        XCTAssertEqual(store.state, .idle)
        let cleared = await backend.location.cleared
        XCTAssertTrue(cleared)
        history = await backend.location.history
        XCTAssertEqual(history.count, 3)

        store.toggleFavorite(home)
        XCTAssertTrue(store.isFavorite(home))
        let reloaded = DeviceLocationStore(backend: backend, defaults: defaults, keepAlive: false)
        XCTAssertEqual(reloaded.favorites.map(\.name), ["家"])
        XCTAssertEqual(reloaded.recents.count, 2)
    }

    @MainActor
    func testProcessesMountImageAndManage() async throws {
        let backend = SampleDeviceToolsBackend()
        let store = DeviceToolsStore(backend: backend)
        let renewal = RenewalController()
        await store.loadProcesses(renewal: renewal)
        XCTAssertEqual(store.processPhase, .ready)
        XCTAssertEqual(store.developerImageMounted, true)
        XCTAssertEqual(store.processes.count, 5)
        let utm = try XCTUnwrap(store.processes.first { $0.name == "UTM" })
        XCTAssertFalse(store.usageUnavailable)
        let lifted = await store.liftMemoryLimit(utm, renewal: renewal)
        XCTAssertTrue(lifted)
        XCTAssertNotNil(store.liftedLimits[utm.pid])
        // 实时监控：内存在涨，进程还在。
        let first = try await store.usage(of: utm.pid, renewal: renewal)
        let second = try await store.usage(of: utm.pid, renewal: renewal)
        XCTAssertGreaterThan(try XCTUnwrap(second?.memory), try XCTUnwrap(first?.memory))
        let limits = await backend.liftedLimits
        XCTAssertEqual(limits, [101])
        let terminated = await store.kill(utm, renewal: renewal)
        XCTAssertTrue(terminated)
        XCTAssertFalse(store.processes.contains { $0.pid == 101 })
        XCTAssertNil(store.liftedLimits[101])
        // 进程退出后读不到占用，解除记录立即清掉。
        let gone = try await store.usage(of: utm.pid, renewal: renewal)
        XCTAssertNil(gone)
        await store.refresh(renewal: renewal)
        await store.launch(try XCTUnwrap(store.apps.first { $0.bundleID == "com.utmapp.UTM" }), renewal: renewal)
        XCTAssertNil(store.errorMessage)
        await store.loadProcesses(renewal: renewal)
        XCTAssertTrue(store.processes.contains { $0.name == "com.utmapp.UTM" })
        XCTAssertNil(store.liftedLimits[101])
    }

    func testCoreDeviceProcessURLsPreserveApplicationAndExtensionNames() {
        let process = DeviceProcessInfo(pid: 101, executableURL: "file:///private/var/containers/Bundle/Application/A1/My%20App.app/PlugIns/Share.appex/Share")
        XCTAssertEqual(process.executablePath, "/private/var/containers/Bundle/Application/A1/My App.app/PlugIns/Share.appex/Share")
        XCTAssertEqual(process.name, "Share")
        XCTAssertTrue(process.isApplication)
        XCTAssertEqual(DeviceProcessNaming.label(for: process, apps: []).kind, .appExtension)
        let daemon = DeviceProcessInfo(pid: 55, executableURL: "/usr/libexec/backboardd")
        XCTAssertFalse(daemon.isApplication)
        XCTAssertEqual(daemon.name, "backboardd")
        let unnamed = DeviceProcessInfo(pid: 7, executableURL: nil)
        XCTAssertEqual(unnamed.name, "进程 7")
        XCTAssertFalse(unnamed.isApplication)
    }

    private func waitForUsage(_ backend: SampleDeviceToolsBackend) async -> Bool {
        for _ in 0..<100 {
            if await backend.usageStarted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @MainActor
    func testProcessListIsReadyBeforeSlowUsageCompletes() async throws {
        let backend = SampleDeviceToolsBackend(processReadingBehavior: .heldUsage)
        let store = DeviceToolsStore(backend: backend), renewal = RenewalController()
        let load = Task { await store.loadProcesses(renewal: renewal) }
        let started = await waitForUsage(backend)
        XCTAssertTrue(started)
        XCTAssertEqual(store.processPhase, .ready)
        XCTAssertEqual(store.processes.count, 5)
        XCTAssertTrue(store.loadingProcessUsage)
        await backend.releaseUsage()
        await load.value
        XCTAssertFalse(store.loadingProcessUsage)
        XCTAssertFalse(store.usageUnavailable)
    }

    @MainActor
    func testSamplingFailureKeepsProcessListUsable() async throws {
        let backend = SampleDeviceToolsBackend(processReadingBehavior: .failedUsage)
        let store = DeviceToolsStore(backend: backend), renewal = RenewalController()
        await store.loadProcesses(renewal: renewal)
        XCTAssertEqual(store.processPhase, .ready)
        XCTAssertEqual(store.processes.count, 5)
        XCTAssertFalse(store.loadingProcessUsage)
        XCTAssertTrue(try XCTUnwrap(store.usageNote).contains("取样服务"))
    }

    @MainActor
    func testProcessRefreshFailureKeepsListAndCanRecover() async throws {
        let backend = SampleDeviceToolsBackend()
        let store = DeviceToolsStore(backend: backend), renewal = RenewalController()
        await store.loadProcesses(renewal: renewal)
        let previous = store.processes
        await backend.setProcessReadFailure(true)
        await store.loadProcesses(renewal: renewal)
        guard case .failed = store.processPhase else { return XCTFail("Expected a process-list failure") }
        XCTAssertEqual(store.processes, previous)
        await backend.setProcessReadFailure(false)
        await store.loadProcesses(renewal: renewal)
        XCTAssertEqual(store.processPhase, .ready)
        XCTAssertEqual(store.processes.count, 5)
    }

    @MainActor
    func testLateSampleCannotRestoreTerminatedProcess() async throws {
        let backend = SampleDeviceToolsBackend(processReadingBehavior: .heldUsage)
        let store = DeviceToolsStore(backend: backend), renewal = RenewalController()
        let load = Task { await store.loadProcesses(renewal: renewal) }
        let started = await waitForUsage(backend)
        XCTAssertTrue(started)
        let target = try XCTUnwrap(store.processes.first { $0.pid == 101 })
        let killed = await store.kill(target, renewal: renewal)
        XCTAssertTrue(killed)
        await load.value
        XCTAssertFalse(store.processes.contains { $0.pid == 101 })
        await backend.releaseUsage()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(store.processes.contains { $0.pid == 101 })
        XCTAssertFalse(store.loadingProcessUsage)
    }

    @MainActor
    func testMissingUsageSampleDoesNotMeanProcessExited() async throws {
        let backend = SampleDeviceToolsBackend(processReadingBehavior: .sparseUsage)
        let store = DeviceToolsStore(backend: backend), renewal = RenewalController()
        await store.loadProcesses(renewal: renewal)
        let running = try await store.usage(of: 101, renewal: renewal)
        XCTAssertNotNil(running)
        XCTAssertNil(running?.memory)
        try await backend.killProcess(pid: 101)
        let exited = try await store.usage(of: 101, renewal: renewal)
        XCTAssertNil(exited)
    }

    func testDeviceReadCancellationReturnsBeforeBlockedOperationCompletes() async throws {
        let gate = ProcessReadingGate()
        let read = Task { try await DeviceToolsTimeout.run("读取进程", seconds: 2) { await gate.wait() } }
        for _ in 0..<100 {
            if await gate.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = Date()
        read.cancel()
        let result = await read.result
        if case .failure(let error) = result { XCTAssertTrue(error is CancellationError) }
        else { XCTFail("Cancelled read returned success") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        await gate.release()
    }

    func testDeviceReadTimeoutDiscardsLateReply() async throws {
        let gate = ProcessReadingGate()
        let read = Task { try await DeviceToolsTimeout.run("读取进程", seconds: 0.2) { await gate.wait() } }
        let result = await read.result
        if case .failure(let error) = result { XCTAssertTrue(error is DeviceToolsTimeout.Expired) }
        else { XCTFail("Blocked read should time out") }
        await gate.release()
    }

    @MainActor
    func testTerminationRequestWithoutExitKeepsProcessAndReportsFailure() async throws {
        let backend = SampleDeviceToolsBackend(terminationBehavior: .ignore)
        let store = DeviceToolsStore(backend: backend), renewal = RenewalController()
        await store.loadProcesses(renewal: renewal)
        let target = try XCTUnwrap(store.processes.first { $0.pid == 101 })
        let result = await store.kill(target, renewal: renewal)
        XCTAssertFalse(result)
        XCTAssertTrue(store.processes.contains { $0.pid == 101 })
        XCTAssertTrue(try XCTUnwrap(store.errorMessage).contains("仍在运行"))
        XCTAssertNil(store.busy)
        let requests = await backend.terminationRequests
        XCTAssertEqual(requests, [101])
    }

    @MainActor
    func testTerminationDenialKeepsProcessAndMemoryLimitState() async throws {
        let backend = SampleDeviceToolsBackend(terminationBehavior: .reject)
        let store = DeviceToolsStore(backend: backend), renewal = RenewalController()
        await store.loadProcesses(renewal: renewal)
        let target = try XCTUnwrap(store.processes.first { $0.pid == 101 })
        _ = await store.liftMemoryLimit(target, renewal: renewal)
        let result = await store.kill(target, renewal: renewal)
        XCTAssertFalse(result)
        XCTAssertTrue(store.processes.contains { $0.pid == 101 })
        XCTAssertNotNil(store.liftedLimits[101])
        XCTAssertTrue(try XCTUnwrap(store.errorMessage).contains("设备拒绝"))
        XCTAssertNil(store.busy)
        let requests = await backend.terminationRequests
        XCTAssertEqual(requests, [101], "A destructive request must not be retried automatically")
    }

    @MainActor
    func testTerminationWaitsForDelayedExit() async throws {
        let backend = SampleDeviceToolsBackend(terminationBehavior: .delayed)
        let store = DeviceToolsStore(backend: backend), renewal = RenewalController()
        await store.loadProcesses(renewal: renewal)
        let target = try XCTUnwrap(store.processes.first { $0.pid == 101 })
        let result = await store.kill(target, renewal: renewal)
        XCTAssertTrue(result)
        XCTAssertFalse(store.processes.contains { $0.pid == 101 })
        XCTAssertNil(store.errorMessage)
        let requests = await backend.terminationRequests
        XCTAssertEqual(requests, [101])
    }

    @MainActor
    func testFailedExitVerificationDoesNotClaimSuccess() async throws {
        let backend = SampleDeviceToolsBackend(terminationBehavior: .verificationFails)
        let store = DeviceToolsStore(backend: backend), renewal = RenewalController()
        await store.loadProcesses(renewal: renewal)
        let target = try XCTUnwrap(store.processes.first { $0.pid == 101 })
        let result = await store.kill(target, renewal: renewal)
        XCTAssertFalse(result)
        XCTAssertTrue(store.processes.contains { $0.pid == 101 })
        XCTAssertTrue(try XCTUnwrap(store.errorMessage).contains("无法查询进程列表"))
        XCTAssertNil(store.busy)
    }

    @MainActor
    func testAlreadyExitedProcessDoesNotReceiveAnotherKillRequest() async throws {
        let backend = SampleDeviceToolsBackend()
        let store = DeviceToolsStore(backend: backend), renewal = RenewalController()
        await store.loadProcesses(renewal: renewal)
        let target = try XCTUnwrap(store.processes.first { $0.pid == 101 })
        try await backend.killProcess(pid: target.pid)
        let result = await store.kill(target, renewal: renewal)
        XCTAssertTrue(result)
        XCTAssertFalse(store.processes.contains { $0.pid == 101 })
        let requests = await backend.terminationRequests
        XCTAssertEqual(requests, [101])
    }

    func testSnapshotRoundTrip() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var info = DeviceInfoSummary.parse(general: Data(), disk: nil, battery: nil)
        info.name = "Phone"; info.batteryHealth = DeviceBatteryHealth(cycleCount: 306, designCapacity: 3544, maxCapacity: 3366, temperature: nil, voltage: 4289)
        let snapshot = DeviceToolsSnapshot(profiles: [try profile("P", app: "com.example.app", days: 3)],
                                           apps: [try app("com.example.app", extra: ["StaticDiskUsage": 10, "DynamicDiskUsage": 20])], info: info, updatedAt: now)
        snapshot.save(to: file)
        let loaded = try XCTUnwrap(DeviceToolsSnapshot.load(from: file))
        XCTAssertEqual(loaded.profiles, snapshot.profiles)
        XCTAssertEqual(loaded.apps, snapshot.apps)
        XCTAssertEqual(loaded.info?.batteryHealth?.healthPercent, 95)
        XCTAssertEqual(loaded.updatedAt, now)
        XCTAssertNil(DeviceToolsSnapshot.load(from: file.appendingPathExtension("missing")))
    }

    /// 回归：取样里混有非数字的值（字符串、字典、空数组）时不能崩溃，数字字段按位置读取。
    func testSysmonUsageReadsFieldsByPosition() throws {
        let processes: [String: Any] = [
            "54170": [54170, "SpringBoard", 0.63, 255_463_064, ["nested": true]],
            "101": [101, "UTM", 42, 1_850_000_000],
            "7": [],
            "bad": "not an array",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: processes, format: .binary, options: 0)
        let usage = IdeviceGateway.readUsageForTesting(data, pidIndex: 0, cpuIndex: 2, memoryIndex: 3)
        XCTAssertEqual(usage[54170]?.cpu ?? 0, 0.63, accuracy: 1e-9)
        XCTAssertEqual(usage[54170]?.memory, 255_463_064)
        XCTAssertEqual(usage[101]?.cpu, 42)
        XCTAssertEqual(usage[101]?.memory, 1_850_000_000)
        // 数组为空时用键里的 PID，但没有数值。
        XCTAssertNotNil(usage[7])
        XCTAssertNil(usage[7]?.cpu)
        XCTAssertEqual(usage.count, 3)
        // 字段位置超出范围时不越界。
        XCTAssertNil(IdeviceGateway.readUsageForTesting(data, pidIndex: 0, cpuIndex: 9, memoryIndex: nil)[101]?.cpu)
    }

    func testProcessNamesMapToAppsExtensionsAndSystem() throws {
        let regram = try app("app.swiftgram.ios", extra: ["CFBundleDisplayName": "Regram", "Path": "/private/var/containers/Bundle/Application/9BB1/Regram.app"])
        func label(_ path: String, name: String = "") -> DeviceProcessLabel { DeviceProcessNaming.label(path: path, fallbackName: name, apps: [regram]) }
        XCTAssertEqual(label("/var/containers/Bundle/Application/9BB1/Regram.app/Regram"),
                       DeviceProcessLabel(title: "Regram", detail: nil, bundleID: "app.swiftgram.ios", kind: .app))
        XCTAssertEqual(label("/private/var/containers/Bundle/Application/9BB1/Regram.app/PlugIns/Share.appex/Share"),
                       DeviceProcessLabel(title: "Regram", detail: "扩展 · Share", bundleID: "app.swiftgram.ios", kind: .appExtension))
        // 应用列表里找不到时，用 .app 目录名。
        XCTAssertEqual(label("/var/containers/Bundle/Application/58FA/GrokApp.app/GrokApp").title, "GrokApp")
        XCTAssertEqual(label("/var/containers/Bundle/Application/58FA/GrokApp.app/GrokApp").kind, .app)
        XCTAssertEqual(label("/Applications/WidgetRenderer_Default.app/WidgetRenderer_Default"),
                       DeviceProcessLabel(title: "WidgetRenderer_Default", detail: nil, bundleID: nil, kind: .systemApp))
        XCTAssertEqual(label("/usr/libexec/backboardd"), DeviceProcessLabel(title: "backboardd", detail: nil, bundleID: nil, kind: .daemon))
        XCTAssertEqual(label("", name: "neagent").title, "neagent")
    }
}

/// 拦截开发者镜像下载请求，按文件名返回预设内容。
final class DDIStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: Data] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let name = request.url?.lastPathComponent ?? ""
        let data = Self.responses[name]
        let response = HTTPURLResponse(url: request.url!, statusCode: data == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor ProcessReadingGate {
    private var continuation: CheckedContinuation<Int, Never>?
    private var released = false
    private(set) var waiting = false
    func wait() async -> Int {
        if released { return 1 }
        waiting = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(returning: 1); continuation = nil
    }
}
