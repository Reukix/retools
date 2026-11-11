import SwiftUI
import ZIPFoundation
import IdeviceGateway

struct StoreArchiveRequest: Identifiable {
    let id = UUID()
    let file: URL
}

struct StoreArchiveInfo: Equatable, Sendable {
    let name: String
    let bundleID: String
    let version: String
    let build: String

    static func inspect(_ file: URL) throws -> Self {
        let archive = try Archive(url: file, accessMode: .read)
        let infos = archive.filter {
            let parts = $0.path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }
        guard infos.count == 1, let entry = infos.first, entry.type == .file, entry.uncompressedSize <= 2_000_000 else {
            throw WorkspaceFailure("安装包必须包含一个有效的 iOS 应用。")
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            guard data.count + chunk.count <= 2_000_000 else { throw WorkspaceFailure("安装包信息过大。") }
            data.append(chunk)
        }
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw WorkspaceFailure("无法读取安装包信息。")
        }
        let executable = info["CFBundleExecutable"] as? String ?? ""
        let folder = String(entry.path.dropLast("Info.plist".count))
        guard !executable.isEmpty, executable == (executable as NSString).lastPathComponent,
              executable != ".", executable != "..", let binary = archive[folder + executable], binary.type == .file, binary.uncompressedSize > 0 else {
            throw WorkspaceFailure("安装包缺少主程序，已停止安装。")
        }
        let id = info["CFBundleIdentifier"] as? String ?? ""
        guard !id.isEmpty, id.utf8.count < 256,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              id != Bundle.main.bundleIdentifier else { throw WorkspaceFailure("不能在这里安装或降级 Retools 自身。") }
        let platforms = info["CFBundleSupportedPlatforms"] as? [String] ?? []
        let families = info["UIDeviceFamily"] as? [Int] ?? []
        guard platforms.isEmpty || platforms.contains("iPhoneOS"), families.isEmpty || families.contains(1) || families.contains(2) else {
            throw WorkspaceFailure("这个安装包不适用于 iPhone 或 iPad，可在商店下载中导出到对应设备。")
        }
        return Self(name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? id,
                    bundleID: id, version: info["CFBundleShortVersionString"] as? String ?? "", build: info["CFBundleVersion"] as? String ?? "")
    }
    func isOlder(than app: DeviceInstalledApp) -> Bool {
        let versionOrder = version.compare(app.version, options: .numeric)
        if !version.isEmpty, !app.version.isEmpty, versionOrder != .orderedSame { return versionOrder == .orderedAscending }
        return !build.isEmpty && !app.build.isEmpty && build.compare(app.build, options: .numeric) == .orderedAscending
    }
}

@MainActor
enum StoreVersionInstallation {
    /// No fallback removal: a failed Upgrade always returns directly to the caller.
    static func run(reinstall: Bool, installed: Bool, canBackUp: Bool,
                    backup: () async throws -> Void, uninstall: () async throws -> Void,
                    install: (Bool) async throws -> Void) async throws {
        if reinstall && installed {
            if canBackUp { try await backup() }
            try await uninstall()
        }
        try await install(installed && !reinstall)
    }
}

@MainActor
private final class StoreInstallationBackgroundTime {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Store version installation") { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid
    }
}

struct StoreArchiveInstallView: View {
    let request: StoreArchiveRequest
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var renewal: RenewalController
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tools = DeviceToolsStore.shared
    @State private var info: StoreArchiveInfo?
    @State private var status = "正在读取安装包…"
    @State private var issue: String?
    @State private var working = false
    @State private var installFailed = false
    @State private var confirmReinstall = false
    @State private var confirmRestore = false
    @State private var backup: AppDataBackup?
    @State private var currentApp: DeviceInstalledApp?
    @State private var checkingDevice = false
    @State private var uploadProgress: Double?
    @State private var succeeded = false
    @State private var attemptID = UUID()
    private var installed: DeviceInstalledApp? { currentApp }

    var body: some View {
        NavigationStack {
            Form {
                if let info {
                    Section {
                        HStack(spacing: 14) {
                            Image(systemName: "arrow.down.app.fill").font(.system(size: 25, weight: .semibold))
                                .foregroundStyle(.white).frame(width: 56, height: 56)
                                .background(Palette.accentGradient, in: RoundedRectangle(cornerRadius: 15))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(info.name).font(.headline).foregroundStyle(Color.primary)
                                Text("版本 " + info.version + (info.build.isEmpty ? "" : "（\(info.build)）"))
                                    .font(.subheadline).foregroundStyle(Color.secondary)
                            }
                        }.padding(.vertical, 8)
                        if let app = installed { InfoRow(title: "当前版本", value: app.version) }
                        Text(info.bundleID).font(.caption.monospaced()).foregroundStyle(Color.secondary)
                    }
                    Section {
                        if succeeded {
                            Button("完成") { dismiss() }.frame(maxWidth: .infinity).buttonStyle(.borderedProminent)
                        } else if !renewal.settings.hasPairing {
                            NavigationLink { DeviceConnectionView() } label: { Label("设置设备连接", systemImage: "point.3.connected.trianglepath.dotted") }
                                .accessibilityIdentifier("storeInstall.connection")
                        } else {
                            Button { install(reinstall: false) } label: {
                                HStack(spacing: 8) {
                                    if working || checkingDevice { ProgressView().tint(.white) }
                                    Text(working ? "正在安装…" : checkingDevice ? "正在检查设备…" : installed.map { info.isOlder(than: $0) } == true ? "保留数据降级" : "安装到本机")
                                        .fontWeight(.semibold)
                                }.frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 14))
                            .disabled(working || checkingDevice || tools.busy != nil || store.isWorking || renewal.isWorking)
                            .accessibilityIdentifier("storeInstall.install")
                        }
                        if working {
                            Group {
                                if let uploadProgress { ProgressView(value: uploadProgress) }
                                else { ProgressView().progressViewStyle(.linear) }
                            }.tint(Palette.accent).accessibilityIdentifier("storeInstall.progress")
                        }
                        HStack(spacing: 8) {
                            if succeeded { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            Text(status).font(.subheadline).foregroundStyle(Color.secondary)
                                .accessibilityIdentifier("storeInstall.status")
                        }
                        if let issue { Text(issue).font(.footnote).foregroundStyle(Color.primary).textSelection(.enabled) }
                        if installFailed, installed != nil {
                            Button("卸载后重新安装", role: .destructive) { confirmReinstall = true }
                                .disabled(working || tools.busy != nil || store.isWorking || renewal.isWorking)
                                .accessibilityIdentifier("storeInstall.reinstall")
                        }
                    } footer: {
                        Text(installed.map { info.isOlder(than: $0) } == true
                             ? "先尝试覆盖安装并保留数据。旧版可能无法读取新版数据；如果系统拒绝降级，原应用保持不变。"
                             : "使用 Retools 已保存的设备连接安装，保留商店许可与已有应用数据。")
                    }
                    if let app = installed {
                        Section {
                            DisclosureGroup("数据备份与恢复") {
                                Button("备份当前应用数据") { makeBackup(app) }
                                    .disabled(working || !app.filesAccessible || tools.busy != nil)
                                if let backup {
                                    Text("已保存 " + backup.createdAt.formatted(date: .numeric, time: .shortened)).font(.footnote).foregroundStyle(Color.secondary)
                                    Button("恢复这份数据备份") { confirmRestore = true }.disabled(working)
                                }
                                Text(app.filesAccessible ? "备份保存在「工具 → 应用数据备份」。" : "这个应用未开放数据访问，无法备份其数据。")
                                    .font(.footnote).foregroundStyle(Color.secondary)
                            }
                        }
                    }
                } else {
                    Section { HStack { if checkingDevice { ProgressView() }; Text(status).foregroundStyle(Color.secondary) } }
                    if let issue { Section { Text(issue).foregroundStyle(Color.primary) } }
                }
            }
            .scrollContentBackground(.hidden).ambientBackground()
            .navigationTitle("安装到本机").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(working) } }
            .interactiveDismissDisabled(working)
            .task { await loadState() }
            .confirmationDialog("卸载后安装此版本？", isPresented: $confirmReinstall, titleVisibility: .visible) {
                Button("确认卸载并安装", role: .destructive) { install(reinstall: true) }
            } message: {
                Text(installed?.filesAccessible == true
                     ? "会先备份可访问的数据，备份成功后才卸载。卸载会删除应用数据；备份可随后恢复，钥匙串和共享数据不包含在备份中。"
                     : "无法备份这个应用的数据。卸载会删除应用数据，安装失败也无法自动恢复原应用。")
            }
            .confirmationDialog("恢复数据备份？", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("恢复", role: .destructive) {
                    guard let backup, let app = installed else { return }
                    working = true
                    Task { await tools.restore(backup, to: app, renewal: renewal); working = false }
                }
            } message: { Text("会替换目标应用中可访问的数据，旧版可能不兼容新版的数据格式。") }
        }.tint(Palette.accent)
    }

    @MainActor
    private func loadState() async {
        checkingDevice = true
        defer { checkingDevice = false }
        do {
            info = try await Task.detached { try StoreArchiveInfo.inspect(request.file) }.value
            guard renewal.settings.hasPairing else { status = "连接设备后即可安装"; return }
            guard !store.isSimulator else { status = "请连接要安装的设备"; return }
            status = "正在检查设备上的版本…"
            let link = LocalDeviceLink()
            _ = try await link.connect(host: renewal.settings.hostIP, remotePort: renewal.settings.remotePort, expectedUDID: renewal.settings.deviceUDID)
            currentApp = try await link.installedAppsQuick(type: "User").compactMap(DeviceInstalledApp.parse).first { $0.bundleID == info?.bundleID }
            status = "安装包已准备好"
        } catch { issue = error.localizedDescription; status = info == nil ? "无法读取安装包" : "连接未完成，可重试安装" }
    }

    private func makeBackup(_ app: DeviceInstalledApp) {
        working = true
        Task {
            defer { working = false }
            let previous = Set(tools.backups.map(\.id))
            await tools.backup(app, renewal: renewal)
            backup = tools.backups.first { $0.bundleID == app.bundleID && !previous.contains($0.id) }
            status = backup == nil ? "备份未完成" : "数据备份已保存"
            if backup == nil { issue = tools.errorMessage }
        }
    }
    private func install(reinstall: Bool) {
        guard let info, !working, !store.isWorking, !renewal.isWorking else { return }
        working = true; store.isWorking = true; issue = nil; installFailed = false
        succeeded = false; uploadProgress = nil
        let currentAttempt = UUID(); attemptID = currentAttempt
        status = "正在校验安装包并连接设备…"
        Task {
            let background = StoreInstallationBackgroundTime()
            defer { background.end() }
            let staging = store.paths.staging.appendingPathComponent("StoreInstall-" + UUID().uuidString)
            defer {
                try? FileManager.default.removeItem(at: staging)
                working = false; store.isWorking = false; store.workLabel = ""
            }
            do {
                let file = staging.appendingPathComponent("Package.ipa")
                try await Task.detached {
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: request.file, to: file)
                    guard try StoreArchiveInfo.inspect(file) == info else { throw WorkspaceFailure("安装包发生变化，请重新选择。") }
                }.value
                let link = LocalDeviceLink()
                _ = try await link.connect(host: renewal.settings.hostIP, remotePort: renewal.settings.remotePort, expectedUDID: renewal.settings.deviceUDID)
                let current = try await link.installedAppsQuick(type: "User").compactMap(DeviceInstalledApp.parse).first { $0.bundleID == info.bundleID }
                try await StoreVersionInstallation.run(reinstall: reinstall, installed: current != nil, canBackUp: current?.filesAccessible == true, backup: {
                    guard let current else { return }
                    status = "正在备份，备份成功后才会卸载…"
                    let previous = Set(tools.backups.map(\.id))
                    await tools.backup(current, renewal: renewal)
                    guard let saved = tools.backups.first(where: { $0.bundleID == info.bundleID && !previous.contains($0.id) }) else {
                        throw WorkspaceFailure("备份未完成，已停止卸载。" + (tools.errorMessage ?? ""))
                    }
                    backup = saved
                }, uninstall: {
                    // Stop if another installer changed the app after the backup.
                    let fresh = try await link.installedAppsQuick(type: "User").compactMap(DeviceInstalledApp.parse).first { $0.bundleID == info.bundleID }
                    guard fresh?.version == current?.version, fresh?.build == current?.build else {
                        throw WorkspaceFailure("设备上的版本发生变化，已停止卸载，请重新检查。")
                    }
                    status = "正在卸载原版本…"
                    try await link.uninstall(bundleID: info.bundleID)
                }, install: { replacing in
                    status = "正在上传安装包并等待系统安装…"; store.workLabel = status
                    try await link.installStoreArchive(file, bundleID: info.bundleID, replacing: replacing) { progress in
                        Task { @MainActor in
                            guard working, attemptID == currentAttempt else { return }
                            switch progress {
                            case .uploading(let completed, let total):
                                let fraction = total > 0 ? min(1, Double(completed) / Double(total)) : 0
                                uploadProgress = fraction
                                status = "正在传输安装包 \(Int(fraction * 100))%"
                            case .installing:
                                uploadProgress = nil; status = "系统正在安装，请稍候…"
                            }
                        }
                    }
                })
                let after = try await link.installedAppsQuick(type: "User").compactMap(DeviceInstalledApp.parse).first { $0.bundleID == info.bundleID }
                guard let after, after.version == info.version, info.build.isEmpty || after.build == info.build else {
                    throw WorkspaceFailure("系统返回成功，但未确认设备上的版本已匹配。请查看设备应用列表。")
                }
                currentApp = after; succeeded = true
                status = reinstall && backup != nil ? "所选版本已安装，可按需恢复数据备份" : current != nil && !reinstall ? "所选版本已安装，原有数据保留" : "所选版本已安装"
            } catch {
                installFailed = true; status = "安装未完成"
                issue = error.localizedDescription
            }
        }
    }
}
