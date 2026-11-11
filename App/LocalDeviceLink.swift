import Foundation
import UIKit
import IdeviceGateway
import MinimuxerCommon
import CryptoKit
import AppleSigningFFI

actor LocalDeviceLink {
    private let gateway = IdeviceGateway()
    private let pairingKey: String
    private(set) var activePort: UInt16?
    init(pairingKey: String = "device.pairing") { self.pairingKey = pairingKey }
    func importPairing(_ source: URL) throws -> String {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        return try importPairingData(Data(contentsOf: source))
    }
    static func validatePairing(_ raw: Data) throws -> (data: Data, mode: String) {
        guard raw.count < 2_000_000 else { throw WorkspaceFailure("配对文件体积异常。") }
        let dict = try PropertyListSerialization.propertyList(from: raw, format: nil)
        let xml = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        let text = String(decoding: xml, as: UTF8.self)
        let preferred: PairingProtocol? = (dict as? [String: Any])?["private_key"] != nil ? .rppairing : nil
        let parsed = try PairingFileParser.parse(content: text, preferred: preferred)
        if preferred == .rppairing {
            let values = dict as? [String: Any] ?? [:]
            guard let privateKey = values["private_key"] as? Data, let publicKey = values["public_key"] as? Data,
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey),
                  key.publicKey.rawRepresentation == publicKey,
                  !(values["identifier"] as? String ?? "").isEmpty else { throw WorkspaceFailure("配对文件中的公私钥或设备身份无效。") }
        }
        return (xml, parsed.mode.rawValue)
    }
    func importPairingData(_ raw: Data) throws -> String {
        let parsed = try Self.validatePairing(raw)
        try SecureStore.saveData(parsed.data, key: pairingKey)
        return parsed.mode
    }
    func importPairedIdentity(_ raw: Data, hostIRK: Data) throws {
        guard hostIRK.count == 16 else { throw WorkspaceFailure("配对主机身份无效。") }
        var values = try PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any] ?? [:]
        values["retools_host_irk"] = hostIRK
        _ = try importPairingData(PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0))
    }
    func hasSavedPairing() throws -> Bool {
        guard let data = try SecureStore.data(key: pairingKey) else { return false }
        return (try? Self.validatePairing(data)) != nil
    }
    func importDiscoveredPairing(in documents: URL) throws -> String? {
        guard try SecureStore.data(key: pairingKey) == nil else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let valid = files.prefix(100).filter { ["mobiledevicepairing", "mobilepair", "plist"].contains($0.pathExtension.lowercased()) }.compactMap { url -> Data? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 2_000_000,
                  let data = try? Data(contentsOf: url), (try? Self.validatePairing(data)) != nil else { return nil }
            return data
        }
        guard valid.count == 1 else { return nil }
        return try importPairingData(valid[0])
    }
    func connect(host: String, remotePort: UInt16, expectedUDID: String = "") async throws -> String {
        #if targetEnvironment(simulator)
        throw WorkspaceFailure("回环安装需要在真机上使用外部代理软件建立设备回环连接。")
        #else
        guard let data = try SecureStore.data(key: pairingKey) else { throw WorkspaceFailure("请先配对这台设备，或导入已有配对文件。") }
        let content = String(decoding: data, as: UTF8.self)
        gateway.setLogging(false)
        gateway.setDeviceEndpointIp(host)
        let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let discoveryStarted = Date()
        let discovered = dict?["private_key"] != nil ? await RemotePairingDiscovery.discoverPort(record: data) : nil
        let discoveryTime = Date().timeIntervalSince(discoveryStarted)
        activePort = discovered ?? remotePort
        gateway.setPort(activePort ?? remotePort, for: .rppairing)
        do {
            try await gateway.start(pairingFileContent: content, preferred: dict?["private_key"] != nil ? .rppairing : nil)
            try Task.checkCancellation()
            let tunnelStarted = Date()
            let udid = try await gateway.fetchUDID()
            let tunnelTime = Date().timeIntervalSince(tunnelStarted)
            if discoveryTime + tunnelTime > 3 {
                AuthDiagnostics.record(stage: "设备连接", message: String(format: "发现端口 %.1f 秒（%@），建立连接并读取身份 %.1f 秒", discoveryTime, discovered == nil ? "未发现，用备用端口" : "已发现", tunnelTime))
            }
            guard expectedUDID.isEmpty || udid.caseInsensitiveCompare(expectedUDID) == .orderedSame else { throw WorkspaceFailure("连接的设备身份与已配对的 iPhone 不一致，请检查外部代理的回环映射。") }
            return udid
        } catch {
            AuthDiagnostics.record(stage: "设备连接", message: "端口 \(activePort ?? remotePort)；\(error.localizedDescription)")
            if dict?["private_key"] != nil, error.localizedDescription.contains("PairVerifyFailed") {
                let pointer = data.withUnsafeBytes { bytes in host.withCString { ip in
                    rt_device_pairing_verify(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, ip, activePort ?? remotePort)
                } }
                if let pointer {
                    defer { rt_apple_string_free(pointer) }
                    let result = (try? JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8))) as? [String: Any] ?? [:]
                    let detail = result["ok"] as? Bool == true ? "独立的配对身份验证通过；设备网关握手未完成" : (result["error"] as? String ?? "配对身份验证未完成")
                    AuthDiagnostics.record(stage: "设备配对验证", message: detail)
                    if result["ok"] as? Bool != true { throw WorkspaceFailure("系统未接受已保存的配对身份。请点击「重新配对这台 iPhone」完成新配对，原记录会保留到新配对成功。") }
                }
            }
            throw error
        }
        #endif
    }
    func install(app: URL, bundleID: String, stage: (@Sendable (String) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let inBackground = await MainActor.run { UIApplication.shared.applicationState == .background }
        if inBackground { AuthDiagnostics.record(stage: "后台续签", message: "正在后台上传并安装签名应用") }
        _ = try AppBundleStagingPlan(appURL: app, bundleID: bundleID)
        AuthDiagnostics.record(stage: "续签安装", message: "本地安装目录、根 Info.plist 与目标标识已校验")
        stage?("正在上传应用文件到设备…")
        try await gateway.sendAppBundleAfc(bundleId: bundleID, appURL: app)
        try Task.checkCancellation()
        AuthDiagnostics.record(stage: "续签安装", message: "应用上传完成；远端根 Info.plist 已逐字节读回校验，开始提交系统安装")
        stage?("上传完成，等待系统安装…")
        try await gateway.installAppBundle(bundleId: bundleID, appName: app.lastPathComponent)
        AuthDiagnostics.record(stage: "续签安装", message: "系统安装已完成")
    }
    func installStoreArchive(_ file: URL, bundleID: String, replacing: Bool,
                             progress: @escaping @Sendable (StoreArchiveInstallProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        try await gateway.installStoreArchive(file: file, bundleId: bundleID, replacing: replacing, progress: progress)
    }
    /// 只安装描述文件（misagent），不动应用本身；装完从设备读回描述文件列表核对。
    func installProfiles(_ profiles: [(uuid: String, data: Data)]) async throws {
        try Task.checkCancellation()
        for profile in profiles { try await gateway.installProvisioningProfile(profile: profile.data) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("retools-profiles-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let dumped = try await gateway.dumpProfiles(docsPath: folder.path)
        let missing = profiles.filter { !FileManager.default.fileExists(atPath: (dumped as NSString).appendingPathComponent($0.uuid + ".mobileprovision")) }
        guard missing.isEmpty else { throw WorkspaceFailure("描述文件安装后未在设备上找到：" + missing.map(\.uuid).joined(separator: "、")) }
        AuthDiagnostics.record(stage: "续签安装", message: "已安装 \(profiles.count) 份描述文件，并从设备读回核对")
    }
    func checkDebuggerAvailability(progress: (@Sendable (String) -> Void)? = nil) async throws {
        guard gateway.pairingFileType == .rppairing else { throw WorkspaceFailure("回环 JIT 需要 Remote Pairing 配对记录。") }
        if try await gateway.isDDIMounted() { return }
        guard DeveloperDiskImage.autoMountEnabled else {
            throw WorkspaceFailure("设备开发者镜像尚未挂载。请先在「工具 → 开发者镜像」里挂载开发者镜像，再使用 JIT 模式。")
        }
        try await mountDeveloperImageIfNeeded(progress: progress ?? { _ in })
    }

    /// 没挂载时自动挂载：已下载的镜像直接用，否则先下载（约 16.5 MB）。
    func mountDeveloperImageIfNeeded(progress: @escaping @Sendable (String) -> Void) async throws {
        if try await gateway.isDDIMounted() { return }
        let files: DeveloperDiskImage.Files
        if let cached = try? DeveloperDiskImage.load() { files = cached }
        else {
            try await DeveloperDiskImage.download(progress: progress)
            files = try DeveloperDiskImage.load()
        }
        progress("正在向 Apple 申请本机签名并挂载开发者镜像…")
        try await gateway.mountPersonalizedDdi(image: files.image, trustcache: files.trustCache, manifest: files.manifest)
        guard try await gateway.isDDIMounted() else { throw WorkspaceFailure("挂载命令已完成，但设备仍报告开发者镜像未挂载。") }
        AuthDiagnostics.record(stage: "开发者镜像", message: "已自动挂载")
    }
    func enableCurrentProcessJIT() async throws {
        try Task.checkCancellation()
        try await gateway.debugCurrentProcess()
    }

    // MARK: 设备工具（不需要开发者镜像）
    func installedApps(type: String) async throws -> [Data] { try await gateway.installedApps(type: type) }
    /// 不含应用大小，读取快。
    func installedAppsQuick(type: String) async throws -> [Data] {
        try await gateway.installedApps(type: type, attributes: IdeviceGateway.installedAppQuickAttributes)
    }
    func appSizes(type: String) async throws -> [Data] {
        try await gateway.installedApps(type: type, attributes: ["CFBundleIdentifier", "StaticDiskUsage", "DynamicDiskUsage"])
    }
    func provisioningProfiles() async throws -> [Data] { try await gateway.provisioningProfiles() }
    func removeProvisioningProfile(uuid: String) async throws { try await gateway.removeProvisioningProfile(id: uuid) }
    func installProvisioningProfile(_ data: Data) async throws { try await gateway.installProvisioningProfile(profile: data) }
    func uninstall(bundleID: String) async throws { try await gateway.removeApp(bundleId: bundleID) }
    func lockdownValues(domain: String?) async throws -> Data { try await gateway.lockdownValues(domain: domain) }
    func containerEntries(bundleID: String, path: String) async throws -> (access: DeviceContainerAccess, entries: [DeviceFileEntry]) {
        try await gateway.containerEntries(bundleId: bundleID, path: path)
    }
    func containerRead(bundleID: String, path: String) async throws -> Data { try await gateway.containerRead(bundleId: bundleID, path: path) }
    func downloadAppFile(bundleID: String, path: String, to destination: URL) async throws {
        try await gateway.containerDownloadFile(bundleId: bundleID, path: path, to: destination)
    }
    func containerWrite(bundleID: String, path: String, data: Data) async throws { try await gateway.containerWrite(bundleId: bundleID, path: path, data: data) }
    func containerMakeDirectory(bundleID: String, path: String) async throws { try await gateway.containerMakeDirectory(bundleId: bundleID, path: path) }
    func containerRemove(bundleID: String, path: String) async throws { try await gateway.containerRemove(bundleId: bundleID, path: path) }
    func crashReports() async throws -> [DeviceFileEntry] { try await gateway.crashReports() }
    func crashReport(path: String) async throws -> Data { try await gateway.crashReport(path: path) }
    func removeCrashReports(paths: [String]) async throws { try await gateway.removeCrashReports(paths: paths) }
    func batteryRegistry() async throws -> Data { try await gateway.batteryRegistry() }
    func isDeveloperImageMounted() async throws -> Bool { try await gateway.isDDIMounted() }
    func openLocationSession() async throws -> DeviceLocationSession { try await gateway.openLocationSession() }
    func runningProcesses(withUsage: Bool) async throws -> [DeviceProcessInfo] { try await gateway.runningProcesses(withUsage: withUsage) }
    func killProcess(pid: UInt32) async throws { try await gateway.killProcess(pid: pid) }
    func checkProcessSignalPermission(pid: UInt32) async throws { try await gateway.checkProcessSignalPermission(pid: pid) }
    func processUsage(pids: Set<UInt32>?) async throws -> [UInt32: DeviceProcessUsage] { try await gateway.processUsage(pids: pids) }
    func disableMemoryLimit(pid: UInt32) async throws { try await gateway.disableMemoryLimit(pid: pid) }
    func launchApp(bundleID: String) async throws -> UInt32 { try await gateway.launchApp(bundleId: bundleID, killExisting: false) }
    func mountDeveloperImage(_ files: DeveloperDiskImage.Files) async throws {
        try await gateway.mountPersonalizedDdi(image: files.image, trustcache: files.trustCache, manifest: files.manifest)
    }
    func appIcons(bundleIDs: [String]) async throws -> [String: Data] { try await gateway.appIcons(bundleIds: bundleIDs) }
    func containerDownload(bundleID: String, to local: URL, excluding: Set<String>, control: DeviceStreamControl,
                           progress: @escaping @Sendable (Int, Int64) -> Void) async throws -> DeviceContainerAccess {
        try await gateway.containerDownload(bundleId: bundleID, to: local, excluding: excluding, control: control, progress: progress)
    }
    func containerUpload(bundleID: String, from local: URL, clearing: [String], keeping: Set<String>, control: DeviceStreamControl,
                         progress: @escaping @Sendable (Int, Int64) -> Void) async throws {
        try await gateway.containerUpload(bundleId: bundleID, from: local, clearing: clearing, keeping: keeping, control: control, progress: progress)
    }
    func streamLogs(control: DeviceStreamControl, onRecord: @escaping @Sendable (DeviceLogRecord) -> Void) async throws {
        defer { Task { try? await gateway.stop() } }
        try await gateway.streamLogs(control: control, onRecord: onRecord)
    }
}
