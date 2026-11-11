import IPadnKit
import UserNotifications
import SwiftUI
import BackgroundTasks
import RetoolsNative
import IdeviceGateway

struct RenewalSettings: Codable {
    var enabled = false
    var email = ""
    var anisetteURL = AppleLoginConfiguration.defaultAnisetteURL
    var authConfigurationVersion = 2
    var teamID = ""
    var teams: [DeveloperTeam] = []
    var hostIP = "10.7.0.1"
    var remotePort: UInt16 = 49152
    var hasPairing = false
    var deviceUDID = ""
    var packageIDs: Set<UUID> = []
    var installedExpiries: [String: Date] = [:]
    var renewHost = false
    var lastAttempt: Date?
    var lastSuccess: Date?
    var lastResult = "尚未运行"
    var lastAttemptSucceeded: Bool?
    var failureCount = 0
    var pendingHostProfile: String?
    var pendingHostDate: Date?
    var pendingHostReceipt: String?
    var accounts: [RenewalAccount] = []
    var defaultAccountID = ""
    var packageAccounts: [String: String] = [:]
    var hostAccountID = ""
    /// 只更新描述文件（未重装）后的 Retools 有效期，以及当时签名证书的指纹。
    /// 应用包里内嵌的仍是旧描述文件，所以有效期以这里为准；证书变了（例如被重新安装）则不再采用。
    var refreshedHostExpiry: Date?
    /// 每个已安装应用实际使用的签名（键为应用 ID），用于判断续签时能否只更新描述文件。
    var installedSignatures: [String: InstalledSignature] = [:]
    var refreshedHostCertificate: String?
    /// 每个应用（键为应用 ID）最近一次装到设备上用的 Bundle ID，换 Bundle ID 重签时据此迁移数据。
    var installedBundleIDs: [String: String] = [:]

    /// 去掉应用库中已不存在的应用留下的续签目标、账号分配与有效期记录。返回是否有改动。
    @discardableResult
    mutating func prune(keeping packages: Set<UUID>) -> Bool {
        let before = (packageIDs.count, packageAccounts.count, installedExpiries.count + installedSignatures.count)
        packageIDs.formIntersection(packages)
        let keys = Set(packages.map(\.uuidString))
        packageAccounts = packageAccounts.filter { keys.contains($0.key) }
        installedExpiries = installedExpiries.filter { keys.contains($0.key) }
        installedSignatures = installedSignatures.filter { keys.contains($0.key) }
        installedBundleIDs = installedBundleIDs.filter { keys.contains($0.key) }
        return before != (packageIDs.count, packageAccounts.count, installedExpiries.count + installedSignatures.count)
    }
    /// 自动续签无法真正执行的原因；为 nil 表示条件齐全。
    var autoRenewBlocker: String? {
        if !accounts.contains(where: \.isReady) { return "未登录 Apple ID" }
        if !hasPairing { return "缺少设备配对" }
        if !renewHost && packageIDs.isEmpty { return "未选择续签目标" }
        return nil
    }
    /// 该应用是否在续签列表中或已经安装到设备。
    func tracks(_ packageID: UUID) -> Bool { packageIDs.contains(packageID) || installedExpiries[packageID.uuidString] != nil }
    mutating func migrateAccounts() {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if accounts.isEmpty, !normalized.isEmpty, !teams.isEmpty {
            accounts = [RenewalAccount(email: normalized, anisetteURL: anisetteURL, teamID: teamID, teams: teams)]
        }
        if !accounts.contains(where: { $0.id == defaultAccountID }) { defaultAccountID = accounts.first?.id ?? "" }
        if hostAccountID.isEmpty { hostAccountID = defaultAccountID }
        for id in packageIDs where packageAccounts[id.uuidString] == nil { packageAccounts[id.uuidString] = defaultAccountID }
    }
}

@MainActor
final class RenewalController: ObservableObject {
    static let shared = RenewalController()
    static let taskID = "dev.retools.ios.renewal"
    static let checkTaskID = "dev.retools.ios.renewal-check"
    @Published var settings = RenewalSettings()
    @Published var isWorking = false
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var errorTitle = "续签操作未完成"
    @Published var appleServiceVerified = false
    @Published var appleServiceResult = "尚未检测"
    @Published var anisetteClientInfo = ""
    @Published var anisetteUserAgent = ""
    @Published var connectionVerified = false
    /// 正在后台静默验证设备连接。
    @Published var isVerifyingConnection = false
    /// 最近一次连接验证失败（区别于「还没验证过」）。
    @Published var connectionCheckFailed = false
    /// 各页面共用的连接状态文字。
    var connectionSummary: String {
        if !settings.hasPairing { return "未配对" }
        if connectionVerified { return "已连接" }
        if isVerifyingConnection { return "验证中…" }
        return connectionCheckFailed ? "连接失败" : "待验证"
    }
    /// 有配对记录但尚未验证时，在后台静默验证一次；有其他设备操作时先等它结束，而不是直接跳过。
    func verifyConnectionIfNeeded() async {
        for _ in 0..<60 where isWorking || DevicePairingCoordinator.shared.isRunning { try? await Task.sleep(for: .milliseconds(500)) }
        guard settings.hasPairing, !connectionVerified, !isVerifyingConnection, !isWorking, !DevicePairingCoordinator.shared.isRunning else { return }
        testConnection(silent: true)
    }
    @Published var deviceConnectionStatus = "尚未检测设备连接"
    @Published var discoveredDevicePort: UInt16?
    @Published var accountProgress: [String: String] = [:]
    /// 本次续签中各账号的结果：true 全部成功，false 有失败；没有值表示仍在进行。
    @Published var accountOutcome: [String: Bool] = [:]
    /// 本次续签涉及的账号，按开始顺序排列，供进度界面逐个显示。
    @Published var activeAccounts: [String] = []
    /// 各账号本次还剩几项未完成；归零时才公布该账号的结果。
    private var accountRemaining: [String: Int] = [:]
    private var accountPartial: [String: Bool] = [:]
    @Published var developmentStatus = "尚未准备开发签名"
    @Published var developmentIPA: URL?
    @Published var backgroundStatus = "等待系统安排后台检查与续签"
    private(set) var store: WorkspaceStore?
    let account = AppleAccountService()
    private var accountServices: [String: AppleAccountService] = [:]
    let device = LocalDeviceLink()
    private let file: URL
    private var scheduleGeneration = 0
    private var activeRenewal: Task<Bool, Never>?
    private var schedulingTask: Task<Void, Never>?
    init(paths: WorkspacePaths = WorkspacePaths()) {
        file = paths.support.appendingPathComponent("renewal.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
                var defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RenewalSettings())) as! [String: Any]
                defaults.merge(stored) { _, storedValue in storedValue }
                settings = try JSONDecoder().decode(RenewalSettings.self, from: JSONSerialization.data(withJSONObject: defaults))
                if (stored["authConfigurationVersion"] as? Int ?? 0) < 2, settings.teams.isEmpty,
                   settings.anisetteURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == AppleLoginConfiguration.legacyAnisetteURL {
                    settings.anisetteURL = AppleLoginConfiguration.defaultAnisetteURL
                }
                settings.authConfigurationVersion = 2
            }
            catch { errorMessage = "无法读取续签设置：\(error.localizedDescription)" }
        }
        settings.anisetteURL = AppleLoginConfiguration.migratedAnisetteURL(settings.anisetteURL)
        settings.migrateAccounts()
    }
    func attach(_ store: WorkspaceStore) { self.store = store; reconcileHost(); pruneRemovedPackages() }
    /// 应用库读取成功后，清理已移除应用的续签记录；读取失败时不动，避免误删。
    func pruneRemovedPackages() {
        guard let store, !store.loadFailed else { return }
        if settings.prune(keeping: Set(store.state.packages.map(\.id))) { save() }
    }
    func projectSigningCredentials(identity: SigningIdentity, package: AppPackage, options: PackageSigningOptions, progress: (String) -> Void) async throws -> AppleAccountService.Credentials {
        guard !isWorking, !DevicePairingCoordinator.shared.isRunning else { throw WorkspaceFailure("请等待当前 Apple ID 或设备操作完成。") }
        syncSelectedAccount()
        let owner = try ProjectSigningAccount.resolve(identity: identity, packageID: package.id, hostIdentityID: store?.state.hostIdentityID, settings: settings)
        guard !settings.deviceUDID.isEmpty else { throw WorkspaceFailure("请先在设置中配对这台 iPhone，以获取目标应用的开发描述文件。") }
        isWorking = true
        defer { isWorking = false; status = "" }
        status = "正在为 \(package.name) 获取开发描述文件…"; progress(status)
        return try await service(for: owner.id).credentials(email: owner.email, anisetteURL: owner.anisetteURL,
            teamID: owner.teamID, udid: settings.deviceUDID, bundleID: options.identifier(for: package), appName: options.name(for: package))
    }
    /// 账号所在团队的开发证书（只读）。
    func certificates(for account: RenewalAccount) async throws -> AppleCertificateList {
        try await service(for: account.id).certificates(email: account.email, anisetteURL: account.anisetteURL, teamID: account.teamID)
    }
    /// 撤销开发证书；调用方负责事先向用户确认。
    func revokeCertificate(_ certificate: AppleCertificate, account: RenewalAccount) async throws {
        try await service(for: account.id).revokeCertificate(email: account.email, anisetteURL: account.anisetteURL, teamID: account.teamID, serialNumber: certificate.serialNumber)
        AuthDiagnostics.record(stage: "开发证书", message: "已撤销证书 \(certificate.name)（序列号 \(certificate.serialNumber)）")
    }
    /// 账号所在团队的 App ID 列表（只读）。
    func appIDs(for account: RenewalAccount) async throws -> AppleAppIDList {
        try await service(for: account.id).appIDs(email: account.email, anisetteURL: account.anisetteURL, teamID: account.teamID)
    }
    /// 主应用与扩展的描述文件（SideStore 流程）。
    func projectAppCredentials(identity: SigningIdentity, package: AppPackage, bundles: [AppleBundleRequest], progress: (String) -> Void) async throws -> AppleAppCredentials {
        guard !isWorking, !DevicePairingCoordinator.shared.isRunning else { throw WorkspaceFailure("请等待当前 Apple ID 或设备操作完成。") }
        syncSelectedAccount()
        let owner = try ProjectSigningAccount.resolve(identity: identity, packageID: package.id, hostIdentityID: store?.state.hostIdentityID, settings: settings)
        guard !settings.deviceUDID.isEmpty else { throw WorkspaceFailure("请先在设置中配对这台 iPhone，以获取目标应用的开发描述文件。") }
        isWorking = true
        defer { isWorking = false; status = "" }
        status = bundles.count > 1 ? "正在为 \(package.name) 及 \(bundles.count - 1) 个扩展注册 App ID 并获取描述文件…" : "正在为 \(package.name) 获取开发描述文件…"; progress(status)
        return try await service(for: owner.id).appCredentials(email: owner.email, anisetteURL: owner.anisetteURL, teamID: owner.teamID, udid: settings.deviceUDID, bundles: bundles)
    }
    func projectHostCredentials(plan: HostUpdatePlan, progress: (String) -> Void) async throws -> (materials: [String: AppleAccountService.Credentials], accountID: String) {
        guard !isWorking, !DevicePairingCoordinator.shared.isRunning else { throw WorkspaceFailure("请等待当前 Apple ID 或设备操作完成。") }
        syncSelectedAccount()
        guard plan.identity.teamID == RTNative.hostTeamIdentifier() else { throw WorkspaceFailure("Retools 自身更新需要选择与当前安装相同团队的 Apple ID 证书，才能保留应用数据。") }
        let owner = try ProjectSigningAccount.resolve(identity: plan.identity, packageID: plan.packageID, hostIdentityID: store?.state.hostIdentityID, settings: settings)
        guard !settings.deviceUDID.isEmpty else { throw WorkspaceFailure("请先配对这台 iPhone，以获取自身更新所需的开发描述文件。") }
        isWorking = true
        defer { isWorking = false; status = "" }
        status = "正在为新版 Retools 和配对扩展获取开发描述文件…"; progress(status)
        let materials = try await service(for: owner.id).hostCredentials(email: owner.email, anisetteURL: owner.anisetteURL,
            teamID: owner.teamID, udid: settings.deviceUDID, bundle: plan.app, includeAppGroup: plan.requiresAppGroup, provisioningSource: Bundle.main.bundleURL)
        return (materials, owner.id)
    }
    func installSignedOutput(_ package: AppPackage, paths: WorkspacePaths, hostMaterial: AppleAccountService.Credentials? = nil,
                             hostAccountID: String? = nil, progress: @escaping @MainActor (String) -> Void) async throws {
        guard !isWorking, !DevicePairingCoordinator.shared.isRunning else { throw WorkspaceFailure("续签或配对正在进行，请稍后安装。") }
        guard let file = package.signedFile, let bundleID = package.signedBundleID else { throw WorkspaceFailure("请先完成签名。") }
        guard settings.hasPairing else { throw WorkspaceFailure("请先在设置中配对这台 iPhone，并开启外部代理回环。签名输出已保留，可以先导出。") }
        guard (file as NSString).pathExtension.lowercased() == "ipa" else { throw WorkspaceFailure("当前格式请导出后交给对应安装工具。") }
        let temp = paths.staging.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        progress("正在准备安装目录…")
        let app = try ArchiveService.unpack(paths.exports.appendingPathComponent(file), to: temp.appendingPathComponent("Install"))
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path) else { throw WorkspaceFailure("当前输出没有描述文件，请导出后交给对应安装工具。") }
        isWorking = true
        defer { isWorking = false }
        progress("正在验证设备回环连接…")
        let udid = try await device.connect(host: settings.hostIP, remotePort: settings.remotePort, expectedUDID: settings.deviceUDID)
        settings.deviceUDID = udid
        if bundleID == Bundle.main.bundleIdentifier {
            guard let hostMaterial, let hostAccountID, let store,
                  let owner = settings.accounts.first(where: { $0.id == hostAccountID && $0.isReady }),
                  owner.teamID == RTNative.hostTeamIdentifier(),
                  try Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision")) == hostMaterial.profile else {
                throw WorkspaceFailure("请重新使用 Apple ID 签名这份 Retools IPA，再提交自身更新。")
            }
            let requiredGroup = try HostAppGroup.readSignedIdentifier()
            _ = try HostUpdate.validateInstall(app, teamID: owner.teamID, installedID: bundleID, requiresAppGroup: requiredGroup != nil)
            if let requiredGroup, HostAppGroup.signedIdentifier(in: app) != requiredGroup { throw WorkspaceFailure("更新包没有保留当前 App Group，未替换 Retools。") }
            progress("自身更新即将提交，应用可能退出；完成后请重新打开 Retools…")
            try await submitHostInstall(app: app, main: hostMaterial, accountID: owner.id, store: store)
            return
        }
        let key = package.id.uuidString
        progress("正在检查安装条件…")
        // 读不到设备上的应用或描述文件时只跳过对应检查，不阻止安装。
        let installed = ((try? await device.installedApps(type: "User")) ?? []).compactMap(DeviceInstalledApp.parse)
        let deviceProfiles = ((try? await device.provisioningProfiles()) ?? []).compactMap(DeviceProfile.parse)
        let newProfile = (try? Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision"))).flatMap(DeviceProfile.parse)
        let migrationSource = AppDataMigration.enabled
            ? AppDataMigration.source(newBundleID: bundleID, previous: settings.installedBundleIDs[key], original: package.bundleID, installed: installed) : nil
        if let reason = InstallPreflight.blocker(appSize: DeviceToolsStore.measure(app).bytes, migrationBytes: migrationSource?.dataSize ?? 0,
                                                 freeSpace: AppDataBackupStore.availableSpace(), newProfile: newProfile, bundleID: bundleID,
                                                 installed: installed, profiles: deviceProfiles) {
            throw WorkspaceFailure(reason)
        }
        var migration: AppDataBackup?
        if let source = migrationSource {
            progress("正在备份「\(source.name)」的数据，安装后迁移到新应用…")
            do { migration = try await backupForMigration(source) }
            catch { AuthDiagnostics.record(stage: "数据迁移", message: "备份 \(source.bundleID) 失败，跳过迁移：\(error.localizedDescription)") }
        }
        progress("设备已连接，开始安装…")
        let signature = InstalledSignature.read(app: app)
        try await device.install(app: app, bundleID: bundleID) { message in Task { @MainActor in progress(message) } }
        settings.installedSignatures[key] = signature
        settings.installedBundleIDs[key] = bundleID
        await pruneReplacedProfiles(installed: Self.embeddedProfiles(in: app))
        progress("系统安装已完成")
        if let migration, let source = migrationSource {
            progress("正在把「\(source.name)」的数据迁移到新应用…")
            do {
                try await device.containerUpload(bundleID: bundleID, from: AppDataBackupStore.container(migration.id), clearing: AppDataBackupStore.cleared,
                                                 keeping: AppDataBackupStore.excluded, control: DeviceStreamControl()) { _, _ in }
                AuthDiagnostics.record(stage: "数据迁移", message: "已把 \(source.bundleID) 的数据迁移到 \(bundleID)（\(migration.bytes.byteLabel)），原应用保留")
                progress("已迁移「\(source.name)」的数据；原应用保留未动，备份在「设备工具 → 数据备份」")
            } catch {
                AuthDiagnostics.record(stage: "数据迁移", message: "迁移到 \(bundleID) 失败：\(error.localizedDescription)")
                progress("应用已安装，但数据迁移没有完成，可以在「设备工具 → 数据备份」里手动恢复")
            }
        }
        if let expiry = package.signedExpiresAt { settings.installedExpiries[package.id.uuidString] = expiry }
        save()
    }
    func reloadAfterMigration() {
        settings = RenewalController(paths: store?.paths ?? WorkspacePaths()).settings
        errorMessage = nil; invalidateDeviceConnection()
    }
    func inspectDevelopmentPackage() {
        guard !isWorking else { return }
        let paths = store?.paths ?? WorkspacePaths()
        guard let data = try? Data(contentsOf: paths.support.appendingPathComponent("Development/manifest.json")),
              let manifest = try? JSONDecoder().decode(DevelopmentSigningManifest.self, from: data),
              let vaultData = try? Data(contentsOf: paths.support.appendingPathComponent("Migration/vault.json")),
              let vault = try? JSONDecoder().decode(SigningMigration.Envelope.self, from: vaultData),
              manifest.backupID == vault.id else { return }
        let url = paths.support.appendingPathComponent("Development/Retools-development.ipa")
        if FileManager.default.fileExists(atPath: url.path) { developmentIPA = url; developmentStatus = "开发签名包已准备，请先复制恢复码" }
    }
    func prepareDevelopmentSigning(accountID: String? = nil, includeAppGroup: Bool = false) {
        guard let store, !isWorking, !store.isWorking, !DevicePairingCoordinator.shared.isRunning else { return }
        syncSelectedAccount()
        let id = accountID ?? (settings.accounts.contains(where: { $0.id == settings.email }) ? settings.email : settings.defaultAccountID)
        errorTitle = "开发签名准备未完成"
        guard let owner = settings.accounts.first(where: { $0.id == id && $0.isReady }) else { errorMessage = "请先登录要用于开发签名的 Apple ID，并选择团队。"; return }
        guard !settings.deviceUDID.isEmpty else { errorMessage = "请先配对这台 iPhone，以取得描述文件需要的设备身份。"; return }
        developmentIPA = nil; accountProgress = [:]; isWorking = true; store.isWorking = true
        let oldIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        let udid = settings.deviceUDID, service = service(for: owner.id)
        AuthDiagnostics.record(stage: "开发签名", message: "开始准备开发签名与加密迁移备份")
        Task {
            defer { isWorking = false; store.isWorking = false; store.workLabel = ""; UIApplication.shared.isIdleTimerDisabled = oldIdle }
            do {
                let bundleID = Bundle.main.bundleIdentifier ?? "dev.retools.ios"
                developmentStatus = includeAppGroup ? "正在申请 App Group 与 Apple 开发签名…" : "正在获取 Apple 开发签名…"
                status = developmentStatus; store.workLabel = developmentStatus
                let materials = try await service.hostCredentials(email: owner.email, anisetteURL: owner.anisetteURL,
                    teamID: owner.teamID, udid: udid, bundle: Bundle.main.bundleURL, includeAppGroup: includeAppGroup)
                guard let main = materials[bundleID] else { throw WorkspaceFailure("没有取得 Retools 的开发签名。") }
                developmentStatus = "正在签名 Retools 与灵动岛扩展…"; store.workLabel = developmentStatus
                let app = try await store.service.prepareHostForRenewal(materials: materials, requiresAppGroup: includeAppGroup)
                defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
                let signedAppGroup = try HostAppGroup.readSignedIdentifier(in: app)
                let directory = store.paths.support.appendingPathComponent("Development")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let partial = directory.appendingPathComponent(UUID().uuidString + ".ipa")
                defer { try? FileManager.default.removeItem(at: partial) }
                try ArchiveService.pack(app: app, to: partial)
                store.state = try await store.service.importHostIdentity(main)
                settings.hostAccountID = owner.id; save()
                developmentStatus = "正在加密备份签名资料…"; store.workLabel = developmentStatus
                let backup = try SigningMigration.backup(state: store.state, renewal: settings, targetTeam: owner.teamID, paths: store.paths)
                let destination = directory.appendingPathComponent("Retools-development.ipa")
                if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial) }
                else { try FileManager.default.moveItem(at: partial, to: destination) }
                let manifest = DevelopmentSigningManifest(bundleID: bundleID, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", targetTeam: owner.teamID, backupID: backup.id, getTaskAllow: true,
                    appGroup: signedAppGroup)
                try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                if RTNative.hostTeamIdentifier() != owner.teamID {
                    try SigningMigrationController.shared.copyRecoveryCode()
                } else {
                    try Data("same-team".utf8).write(to: store.paths.support.appendingPathComponent("Migration/restored-\(backup.id.uuidString)"), options: .atomic)
                }
                developmentIPA = destination; developmentStatus = signedAppGroup != nil
                    ? "含 App Group 的开发签名包已准备，安装后可检测读写；换团队前请保存恢复码"
                    : "开发签名包已准备，请先复制恢复码"
                AuthDiagnostics.record(stage: "开发签名", message: "主应用与配对扩展的 get-task-allow 均已获 Apple 描述文件授权；固定 Bundle ID，已创建加密迁移备份")
            } catch {
                developmentStatus = error.localizedDescription; errorMessage = error.localizedDescription
                AuthDiagnostics.record(stage: "开发签名", message: AuthDiagnostics.detail(error), secrets: [owner.email])
            }
        }
    }
    func save() {
        do { try persistSettings() }
        catch { errorMessage = error.localizedDescription }
    }
    private func persistSettings() throws {
        syncSelectedAccount(); try JSONEncoder().encode(settings).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); schedule()
        if let store { ExpiryPublisher.publish(store: store, renewal: self) }
    }
    private func service(for email: String) -> AppleAccountService {
        if let service = accountServices[email] { return service }
        let service = AppleAccountService(); accountServices[email] = service; return service
    }
    private func syncSelectedAccount() {
        let email = settings.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !settings.teams.isEmpty, !email.isEmpty else { return }
        if let index = settings.accounts.firstIndex(where: { $0.id == email }) {
            settings.accounts[index].teamID = settings.teamID
            settings.accounts[index].teams = settings.teams
            settings.accounts[index].anisetteURL = settings.anisetteURL
        } else { settings.accounts.append(RenewalAccount(email: email, anisetteURL: settings.anisetteURL, teamID: settings.teamID, teams: settings.teams)) }
        if settings.defaultAccountID.isEmpty { settings.defaultAccountID = email }
        if settings.hostAccountID.isEmpty { settings.hostAccountID = email }
    }
    func selectAccount(_ id: String) {
        guard !isWorking else { return }
        syncSelectedAccount()
        guard let selected = settings.accounts.first(where: { $0.id == id }) else { return }
        settings.email = selected.email; settings.teams = selected.teams; settings.teamID = selected.teamID
        settings.anisetteURL = selected.anisetteURL
        appleServiceVerified = false; appleServiceResult = "尚未检测"; save()
    }
    func addAccount() {
        guard !isWorking else { return }
        syncSelectedAccount()
        settings.email = ""; settings.teams = []; settings.teamID = ""
        appleServiceVerified = false; appleServiceResult = "尚未检测"; save()
    }
    private func removeAccountMetadata(_ id: String) {
        for package in settings.packageIDs where (settings.packageAccounts[package.uuidString] ?? settings.defaultAccountID) == id {
            settings.packageAccounts[package.uuidString] = ""
        }
        settings.accounts.removeAll { $0.id == id }
        if settings.defaultAccountID == id { settings.defaultAccountID = settings.accounts.first?.id ?? "" }
        if settings.hostAccountID == id { settings.hostAccountID = "" }
        if settings.accounts.isEmpty { settings.enabled = false }
    }
    func schedule() {
        scheduleGeneration += 1
        let generation = scheduleGeneration
        guard settings.enabled, settings.renewHost || !settings.packageIDs.isEmpty else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.checkTaskID)
            schedulingTask = nil
            backgroundStatus = "后台续签未开启或没有续签目标"; return
        }
        let date = RenewalScheduling.nextRequest(settings: settings)
        schedulingTask = Task {
            let pending: [BGTaskRequest] = await withCheckedContinuation { continuation in BGTaskScheduler.shared.getPendingTaskRequests { continuation.resume(returning: $0) } }
            guard generation == scheduleGeneration, settings.enabled else { return }
            do {
                let processing = BGProcessingTaskRequest(identifier: Self.taskID)
                processing.requiresNetworkConnectivity = true; processing.requiresExternalPower = false; processing.earliestBeginDate = date
                let check = BGAppRefreshTaskRequest(identifier: Self.checkTaskID); check.earliestBeginDate = date
                for request in [processing, check] as [BGTaskRequest] {
                    if let existing = pending.first(where: { $0.identifier == request.identifier }), let earlier = existing.earliestBeginDate, earlier <= date { continue }
                    try BGTaskScheduler.shared.submit(request)
                }
                backgroundStatus = "已安排后台检查与续签，最早 \(date.formatted(date: .omitted, time: .shortened))；实际执行时间由 iOS 决定"
            } catch {
                backgroundStatus = "后台调度未成功：\(error.localizedDescription)"
                AuthDiagnostics.record(stage: "后台续签", message: backgroundStatus)
            }
        }
    }
    func finishBackgroundScheduling() async {
        schedule()
        await schedulingTask?.value
    }
    func login(password: String) {
        guard !isWorking else { return }
        let email = settings.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        errorTitle = "Apple ID 登录失败"
        guard !email.isEmpty, !password.isEmpty else { errorMessage = "请填写 Apple ID 和密码。"; return }
        settings.email = email
        isWorking = true; status = "正在检测 Anisette 与 Apple 验证服务…"; appleServiceVerified = false
        Task {
            defer { isWorking = false; status = "" }
            var phase = "验证服务"
            AuthDiagnostics.record(stage: phase, message: "开始检测 \(settings.anisetteURL)")
            do {
                settings.anisetteURL = try AppleLoginConfiguration.validatedAnisetteURL(settings.anisetteURL)
                let service = try await account.checkService(anisetteURL: settings.anisetteURL)
                anisetteClientInfo = service.clientInfo; anisetteUserAgent = service.userAgent
                appleServiceVerified = true; appleServiceResult = "Anisette 与 Apple 验证服务已连通"
                AuthDiagnostics.record(stage: phase, message: "服务已连通；客户端：\(service.clientInfo)；User-Agent：\(service.userAgent)")
                status = "正在验证 Apple ID，可能需要双重验证码…"
                phase = "账号认证"
                settings.teams = try await self.service(for: email).login(email: email, password: password, anisetteURL: settings.anisetteURL)
                guard !settings.teams.isEmpty else { throw WorkspaceFailure("这个 Apple ID 没有可用的开发者团队。") }
                if !settings.teams.contains(where: { $0.id == settings.teamID }) { settings.teamID = settings.teams[0].id }
                settings.lastResult = "Apple ID 已登录，待配置回环连接"; save()
                AuthDiagnostics.record(stage: "登录完成", message: "已获取 \(settings.teams.count) 个开发者团队")
            } catch {
                AuthDiagnostics.record(stage: phase, message: AuthDiagnostics.detail(error), secrets: [email, password])
                errorMessage = error.localizedDescription
            }
        }
    }
    func checkAppleService() {
        guard !isWorking else { return }
        isWorking = true; status = "正在检测 Anisette 与 Apple 验证服务…"; appleServiceVerified = false
        errorTitle = "Apple ID 验证服务不可用"
        Task {
            defer { isWorking = false; status = "" }
            do {
                settings.anisetteURL = try AppleLoginConfiguration.validatedAnisetteURL(settings.anisetteURL)
                let service = try await account.checkService(anisetteURL: settings.anisetteURL)
                anisetteClientInfo = service.clientInfo; anisetteUserAgent = service.userAgent
                appleServiceVerified = true; appleServiceResult = "Anisette 与 Apple 验证服务已连通"; save()
                AuthDiagnostics.record(stage: "验证服务", message: "已连通 \(settings.anisetteURL)；\(service.clientInfo)；\(service.userAgent)")
            } catch {
                AuthDiagnostics.record(stage: "验证服务", message: AuthDiagnostics.detail(error), secrets: [settings.email])
                appleServiceResult = error.localizedDescription; errorMessage = error.localizedDescription
            }
        }
    }
    func resetAnisette() {
        guard !isWorking else { return }
        isWorking = true; errorTitle = "验证数据重置失败"
        Task {
            defer { isWorking = false }
            do {
                try await account.resetAnisette(email: settings.email)
                removeAccountMetadata(settings.email.lowercased())
                settings.teams = []; settings.teamID = ""
                appleServiceVerified = false; appleServiceResult = "验证数据已重置，请重新登录"
                AuthDiagnostics.record(stage: "重置验证数据", message: "已清理 Anisette 与登录会话；保留签名私钥和设备配对记录")
                save()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func forgetAccount() {
        guard !isWorking else { return }
        Task {
            do {
                try await account.forget(email: settings.email)
                let removed = settings.email.lowercased()
                removeAccountMetadata(removed)
                settings.teams = []; settings.teamID = ""; settings.lastResult = "已退出当前 Apple ID"
                save()
                if let first = settings.accounts.first { selectAccount(first.id) }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func importPairing(_ url: URL) {
        guard !isWorking else { return }
        Task {
            do { _ = try await device.importPairing(url); settings.hasPairing = true; invalidateDeviceConnection(); deviceConnectionStatus = "配对记录已保存，等待连接验证"; save(); testConnection(silent: true) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func invalidateDeviceConnection() {
        connectionVerified = false; discoveredDevicePort = nil; connectionCheckFailed = false
        deviceConnectionStatus = settings.hasPairing ? "配对记录已保存，等待连接验证" : "请先配对这台 iPhone"
    }
    func startDevicePairing() {
        guard !isWorking else { return }
        DevicePairingCoordinator.shared.start(using: device) { [weak self] udid in
            guard let self else { return }
            settings.hasPairing = true
            if !udid.isEmpty { settings.deviceUDID = udid }
            invalidateDeviceConnection(); save(); testConnection(silent: true)
        }
    }
    func importDiscoveredPairing() async {
        guard !isWorking, !DevicePairingCoordinator.shared.isRunning else { return }
        do {
            if try await device.hasSavedPairing() {
                if !settings.hasPairing { settings.hasPairing = true; invalidateDeviceConnection(); save() }
                return
            }
            if settings.hasPairing { settings.hasPairing = false; invalidateDeviceConnection(); save() }
            if let _ = try await device.importDiscoveredPairing(in: store?.paths.documents ?? WorkspacePaths().documents) {
                settings.hasPairing = true; invalidateDeviceConnection(); save()
            }
        } catch { deviceConnectionStatus = error.localizedDescription }
    }
    func testConnection(silent: Bool = false) {
        guard !isWorking else { return }
        errorTitle = "设备连接失败"
        isWorking = true; status = "正在发现并验证本机设备服务…"; connectionVerified = false
        isVerifyingConnection = true; connectionCheckFailed = false
        deviceConnectionStatus = "正在发现服务并验证配对身份…"
        let host = settings.hostIP, port = settings.remotePort
        Task {
            defer { isWorking = false; status = ""; isVerifyingConnection = false }
            do {
                let udid = try await device.connect(host: host, remotePort: port, expectedUDID: settings.deviceUDID)
                guard settings.hostIP == host, settings.remotePort == port else { invalidateDeviceConnection(); return }
                settings.deviceUDID = udid; discoveredDevicePort = await device.activePort
                connectionVerified = true; deviceConnectionStatus = "设备身份与回环连接已验证"; save()
            } catch {
                connectionVerified = false; connectionCheckFailed = true; deviceConnectionStatus = error.localizedDescription
                if !silent { errorMessage = error.localizedDescription }
            }
        }
    }
    func prepareJITConnection() async throws {
        guard !isWorking, !DevicePairingCoordinator.shared.isRunning else { throw WorkspaceFailure("请等待当前设备操作完成。") }
        isWorking = true; status = "正在验证 JIT 设备连接…"
        defer { isWorking = false; status = "" }
        let host = settings.hostIP, port = settings.remotePort
        do {
            let udid = try await device.connect(host: host, remotePort: port, expectedUDID: settings.deviceUDID)
            try await device.checkDebuggerAvailability { message in Task { @MainActor in self.status = message } }
            discoveredDevicePort = await device.activePort; settings.deviceUDID = udid
            connectionVerified = true; deviceConnectionStatus = "设备连接与调试服务已验证"; save()
            UserDefaults.standard.set(host, forKey: "RetoolsJITHostIP")
            UserDefaults.standard.set(Int(discoveredDevicePort ?? port), forKey: "RetoolsJITRemotePort")
        } catch {
            connectionVerified = false; deviceConnectionStatus = error.localizedDescription
            throw error
        }
    }
    func enableCurrentProcessJIT() async throws {
        try await prepareJITConnection()
        guard !isWorking, !DevicePairingCoordinator.shared.isRunning else { throw WorkspaceFailure("请等待当前设备操作完成。") }
        isWorking = true; status = "正在为当前进程启用 JIT…"
        defer { isWorking = false; status = "" }
        try await device.enableCurrentProcessJIT()
    }
    nonisolated static func isDue(expiry: Date?, now: Date = Date()) -> Bool { expiry.map { $0.timeIntervalSince(now) <= 2 * 24 * 3600 } ?? true }
    /// 自动续签无法真正执行的原因；为 nil 表示条件齐全。界面据此显示状态，避免“已开启”却不会续签。
    var autoRenewBlocker: String? { settings.autoRenewBlocker }
    /// Retools 实际有效期：内嵌描述文件与「只更新描述文件」记录中较晚的一个。
    var hostExpiry: Date? {
        let embedded = hostProfile()?.expiry
        guard let refreshed = settings.refreshedHostExpiry, let certificate = settings.refreshedHostCertificate,
              certificate == ProfileRefresh.runningCertificateFingerprint else { return embedded }
        return max(embedded ?? refreshed, refreshed)
    }
    /// 已安装的描述文件在进程运行期间不会改变（重新安装会重启进程），只读取和解析一次。
    private static let installedHostProfile: (id: String, expiry: Date)? = readHostProfile()
    private func hostProfile() -> (id: String, expiry: Date)? { Self.installedHostProfile }
    private nonisolated static func readHostProfile() -> (id: String, expiry: Date)? {
        guard let data = try? Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")),
              let payload = try? RTNative.profilePayload(data),
              let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any],
              let id = plist["UUID"] as? String, let expiry = plist["ExpirationDate"] as? Date else { return nil }
        return (id, expiry)
    }
    private func reconcileHost() {
        guard let pending = settings.pendingHostProfile else { return }
        if RenewalScheduling.confirmsInstall(expectedProfile: pending, expectedReceipt: settings.pendingHostReceipt, currentProfile: hostProfile()?.id, currentReceipt: Bundle.main.object(forInfoDictionaryKey: "RetoolsRenewalReceipt") as? String) {
            settings.pendingHostProfile = nil; settings.pendingHostDate = nil; settings.pendingHostReceipt = nil
            settings.lastSuccess = Date(); settings.lastResult = "Retools 自身续签已在重启后确认"
            if let index = settings.accounts.firstIndex(where: { $0.id == settings.hostAccountID }) {
                settings.accounts[index].lastResult = "Retools 自身更新已在重启后确认"; settings.accounts[index].lastSuccess = Date()
            }
            settings.lastAttemptSucceeded = true; settings.failureCount = 0; save()
            AuthDiagnostics.record(stage: "自动续签", message: "重启后已核对本次安装凭据与描述文件，自身更新已确认")
        }
    }
    func foregroundCheck() {
        reconcileHost()
        invalidateDeviceConnection()
        // 回到前台：先导入配对记录；自动续签检查（如需会连接设备）结束后，再静默验证一次连接。
        Task {
            await importDiscoveredPairing()
            if settings.enabled { schedule(); _ = await renew(force: false) }
            await verifyConnectionIfNeeded()
        }
    }
    func renew(force: Bool, onlyPackages: Set<UUID>? = nil, includeHost: Bool = true, beforeSelfInstall: (() -> Void)? = nil) async -> Bool {
        guard activeRenewal == nil else { return false }
        let operation = Task { @MainActor in await self.performRenewal(force: force, onlyPackages: onlyPackages, includeHost: includeHost, beforeSelfInstall: beforeSelfInstall) }
        activeRenewal = operation
        // 前台和后台（例如快捷指令自动化）都申请额外运行时间，避免续签中途被系统挂起。
        let lease = UIApplication.shared.beginBackgroundTask(withName: "Retools 应用续签") { operation.cancel() }
        defer { if lease != .invalid { UIApplication.shared.endBackgroundTask(lease) }; activeRenewal = nil }
        return await withTaskCancellationHandler(operation: { await operation.value }, onCancel: { operation.cancel() })
    }
    private func performRenewal(force: Bool, onlyPackages: Set<UUID>?, includeHost: Bool, beforeSelfInstall: (() -> Void)?) async -> Bool {
        guard let store, !isWorking, !store.isWorking, !DevicePairingCoordinator.shared.isRunning else { return false }
        if force { errorTitle = "续签操作未完成" }
        if !force {
            guard settings.enabled else { return true }
            if Date() < RenewalScheduling.nextEligible(settings: settings) { return true }
        }
        syncSelectedAccount()
        let work: [RenewalAccountWork]
        var planned = settings
        if let onlyPackages { planned.packageIDs.formIntersection(onlyPackages) }
        do { work = try RenewalPlanner.make(settings: planned, packages: store.state.packages, force: force) }
        catch { if force { errorMessage = error.localizedDescription }; return false }
        let renewSelf = includeHost && settings.renewHost && (force || Self.isDue(expiry: hostExpiry))
        guard !work.isEmpty || renewSelf else {
            // 手动触发却没有任何目标时说明原因，不要静默“成功”。
            if force {
                errorTitle = "续签操作未完成"
                errorMessage = includeHost && !settings.renewHost && onlyPackages?.isEmpty != false
                    ? "没有需要续签的目标。请在「续签目标」中开启 Retools 自身或至少一个应用。"
                    : "所选应用不在应用库中，无法续签。请重新导入它的 IPA。"
                return false
            }
            return true
        }
        guard settings.hasPairing else { if force { errorMessage = "请先配对这台 iPhone。" }; return false }
        let hostOwner = settings.accounts.first { $0.id == settings.hostAccountID && $0.isReady }
        isWorking = true; store.isWorking = true; status = "正在验证回环连接…"; store.workLabel = status
        accountProgress = [:]; accountOutcome = [:]
        var involved = work.map(\.account.id)
        if renewSelf, let owner = hostOwner, !involved.contains(owner.id) { involved.append(owner.id) }
        activeAccounts = involved
        accountPartial = [:]
        accountRemaining = Dictionary(work.map { ($0.account.id, $0.packages.count) }, uniquingKeysWith: +)
        if renewSelf, let owner = hostOwner { accountRemaining[owner.id, default: 0] += 1 }
        settings.lastAttempt = Date(); settings.lastAttemptSucceeded = nil; save()
        AuthDiagnostics.record(stage: "自动续签", message: "开始续签；桌面应用 \(work.flatMap(\.packages).count) 项，自身更新 \(renewSelf ? "开启" : "关闭")")
        defer { isWorking = false; store.isWorking = false; status = ""; store.workLabel = ""; schedule() }
        var successes = 0, failures = 0
        var failureDetails: [String] = []
        do {
            let udid = try await device.connect(host: settings.hostIP, remotePort: settings.remotePort, expectedUDID: settings.deviceUDID)
            settings.deviceUDID = udid; connectionVerified = true
            deviceConnectionStatus = "设备身份与回环连接已验证"
            discoveredDevicePort = await device.activePort
            let workspace = store.service, paths = store.paths
            let installed = settings.installedSignatures, expiries = settings.installedExpiries
            await withTaskGroup(of: [RenewalPreparation].self) { group in
                for item in work {
                    let service = self.service(for: item.account.id)
                    updateAccount(item.account.id, result: "正在准备续签", attempted: true)
                    group.addTask {
                        await RenewalPreparationEngine.prepare(item, udid: udid, service: service, workspace: workspace, paths: paths,
                                                               installed: installed, installedExpiries: expiries) { message in
                            await self.setAccountProgress(item.account.id, message: message)
                        }
                    }
                }
                for await preparations in group {
                    for preparation in preparations {
                        switch preparation {
                        case .failed(let accountID, _, let name, let message):
                            failures += 1
                            failureDetails.append("\(name)：\(message)")
                            updateAccount(accountID, result: "\(name)：\(message)", outcome: false)
                        case .ready(let prepared):
                            defer { if let app = prepared.app { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) } }
                            do {
                                try Task.checkCancellation()
                                let profileOnly = try await installPrepared(prepared, workspace: workspace, paths: paths)
                                settings.installedExpiries[prepared.packageID.uuidString] = prepared.expiry
                                let extended = prepared.previousExpiry.map { previous in prepared.expiry.map { $0 > previous } ?? false } ?? true
                                let message = "\(prepared.name) " + (profileOnly ? "描述文件已更新（无需重装）" : (extended ? "续签并安装成功" : "已重装；Apple 返回的有效期未延长"))
                                successes += 1; settings.lastSuccess = Date()
                                updateAccount(prepared.accountID, result: message, succeeded: true, outcome: true)
                            } catch {
                                failures += 1; failureDetails.append("\(prepared.name)：\(error.localizedDescription)"); updateAccount(prepared.accountID, result: "\(prepared.name)：\(error.localizedDescription)", outcome: false)
                            }
                        }
                    }
                    store.state = await workspace.snapshot()
                }
            }
            if renewSelf {
                do {
                    guard let owner = hostOwner else { throw WorkspaceFailure("请为 Retools 自身续签选择已登录账号。") }
                    guard RTNative.hostTeamIdentifier() == owner.teamID else { throw WorkspaceFailure("Retools 自身续签需要与当前安装相同的开发者团队。") }
                    updateAccount(owner.id, result: "正在续签 Retools", attempted: true)
                    try await renewHost(owner: owner, udid: udid, store: store, submitted: beforeSelfInstall)
                    successes += 1; finishAccountItem(owner.id, succeeded: true)
                } catch { failures += 1; failureDetails.append("Retools：\(error.localizedDescription)"); if let owner = hostOwner { updateAccount(owner.id, result: "Retools：\(error.localizedDescription)", outcome: false) } }
            }
            settings.lastAttemptSucceeded = failures == 0; settings.failureCount = failures == 0 ? 0 : settings.failureCount + 1
            settings.lastResult = "续签完成：\(successes) 项成功，\(failures) 项失败"; save(); store.refreshStorage()
            AuthDiagnostics.record(stage: "自动续签", message: settings.lastResult + (failureDetails.isEmpty ? "" : "\n" + failureDetails.joined(separator: "\n")))
            if failures > 0, force { errorMessage = settings.lastResult + "\n" + failureDetails.prefix(3).joined(separator: "\n") }
            ExpiryNotifications.renewalFinished(successes: successes, failures: failures, details: failureDetails)
            return failures == 0
        } catch {
            connectionVerified = false; deviceConnectionStatus = error.localizedDescription
            settings.lastResult = Task.isCancelled ? "后台时间已结束，将在下次调度继续" : "续签失败：\(error.localizedDescription)"
            settings.lastAttemptSucceeded = false; settings.failureCount += 1
            AuthDiagnostics.record(stage: "自动续签", message: settings.lastResult)
            if !Task.isCancelled { ExpiryNotifications.renewalFinished(successes: 0, failures: 1, details: [settings.lastResult]) }
            save(); if force { errorMessage = settings.lastResult }; return false
        }
    }
    private func setAccountProgress(_ id: String, message: String) {
        accountProgress[id] = message
        status = "多账号续签进行中…"
    }
    /// 安装一项续签结果。只更新描述文件失败时，用同一份凭据重签并整包安装。返回是否只更新了描述文件。
    private func installPrepared(_ prepared: PreparedRenewal, workspace: WorkspaceService, paths: WorkspacePaths) async throws -> Bool {
        if !prepared.profiles.isEmpty {
            setAccountProgress(prepared.accountID, message: "正在更新 \(prepared.name) 的描述文件…")
            do {
                try await device.installProfiles(prepared.profiles.map { ($0.uuid, $0.data) })
                AuthDiagnostics.record(stage: "续签安装", message: "\(prepared.name) 只更新了 \(prepared.profiles.count) 份描述文件，未重装")
                await pruneReplacedProfiles(installed: prepared.profiles.map(\.data))
                return true
            } catch {
                AuthDiagnostics.record(stage: "续签安装", message: "\(prepared.name) 只更新描述文件失败，改为重签并重装：" + error.localizedDescription)
                guard let credentials = prepared.credentials, let package = store?.state.packages.first(where: { $0.id == prepared.packageID }) else { throw error }
                setAccountProgress(prepared.accountID, message: "正在签名 \(prepared.name)…")
                let plan = try await workspace.prepareAppleSigning(package.id, bundleID: prepared.bundleID)
                let (app, _) = try await RenewalPreparationEngine.signedApp(package, plan: plan, credentials: credentials, workspace: workspace, paths: paths)
                defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
                try await installApp(app, prepared: prepared, signature: InstalledSignature.read(app: app))
                return false
            }
        }
        guard let app = prepared.app else { throw WorkspaceFailure("没有可安装的续签内容。") }
        try await installApp(app, prepared: prepared, signature: prepared.signature)
        return false
    }
    private func installApp(_ app: URL, prepared: PreparedRenewal, signature: InstalledSignature?) async throws {
        setAccountProgress(prepared.accountID, message: "正在安装 \(prepared.name)…")
        store?.workLabel = "正在安装 \(prepared.name)…"
        // 设备安装逐个进行；其他账号的准备工作同时继续。
        try await device.install(app: app, bundleID: prepared.bundleID)
        settings.installedSignatures[prepared.packageID.uuidString] = signature
        await pruneReplacedProfiles(installed: Self.embeddedProfiles(in: app))
    }

    nonisolated static let pruneProfilesKey = "RetoolsPruneReplacedProfiles"

    /// 为迁移备份旧应用：存成一份普通的数据备份，迁移失败时也能手动恢复。
    private func backupForMigration(_ source: DeviceInstalledApp) async throws -> AppDataBackup {
        let id = UUID(), container = AppDataBackupStore.container(id)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        do {
            let access = try await device.containerDownload(bundleID: source.bundleID, to: container, excluding: AppDataBackupStore.excluded,
                                                            control: DeviceStreamControl()) { _, _ in }
            let totals = DeviceToolsStore.measure(container)
            let backup = AppDataBackup(id: id, bundleID: source.bundleID, appName: source.name, version: source.version, access: access.rawValue,
                                       createdAt: Date(), files: totals.files, bytes: totals.bytes)
            try AppDataBackupStore.commit(backup)
            DeviceToolsStore.shared.reloadBackups()
            return backup
        } catch { AppDataBackupStore.delete(id); throw error }
    }

    /// 应用包及其扩展里嵌入的描述文件。
    nonisolated static func embeddedProfiles(in app: URL) -> [Data] {
        var bundles = [app]
        let plugins = app.appendingPathComponent("PlugIns", isDirectory: true)
        bundles += ((try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "appex" }
        return bundles.compactMap { try? Data(contentsOf: $0.appendingPathComponent("embedded.mobileprovision")) }
    }

    /// 续签装上新描述文件或重装应用后，同一个 App ID 下到期更早的旧描述文件已经用不到了：
    /// 应用现在用新描述文件里的证书签名（只更新描述文件时已核对过证书没变）。删除前在「最近删除」留副本。
    /// 通配符描述文件可能被其他应用共用，不处理。失败不影响续签结果。
    func pruneReplacedProfiles(installed: [Data]) async {
        guard UserDefaults.standard.object(forKey: Self.pruneProfilesKey) as? Bool ?? true else { return }
        let fresh = installed.compactMap(DeviceProfile.parse).filter { !$0.isWildcard }
        guard !fresh.isEmpty else { return }
        do {
            let onDevice = try await device.provisioningProfiles().compactMap(DeviceProfile.parse)
            let stale = Self.replacedProfiles(onDevice: onDevice, installed: fresh)
            var removed = 0
            for profile in stale {
                do {
                    try DeviceProfileTrash.keep(profile)
                    try await device.removeProvisioningProfile(uuid: profile.uuid)
                    removed += 1
                } catch { AuthDiagnostics.record(stage: "续签清理", message: "\(profile.name) 未删除：\(error.localizedDescription)") }
            }
            if removed > 0 {
                AuthDiagnostics.record(stage: "续签清理", message: "已删除 \(removed) 份被新描述文件取代的旧描述文件，副本在「最近删除」")
                DeviceToolsStore.shared.reloadTrash()
            }
        } catch { AuthDiagnostics.record(stage: "续签清理", message: "读取设备描述文件失败，跳过清理：\(error.localizedDescription)") }
    }

    /// 与新装的某份描述文件同团队、同 App ID、到期更早的描述文件。
    nonisolated static func replacedProfiles(onDevice: [DeviceProfile], installed: [DeviceProfile]) -> [DeviceProfile] {
        onDevice.filter { old in
            !old.isWildcard && installed.contains { new in
                new.uuid != old.uuid && new.teamID == old.teamID && new.appIdentifier == old.appIdentifier
                    && (old.expires ?? .distantPast) < (new.expires ?? .distantPast)
            }
        }
    }
    private func finishAccountItem(_ id: String, succeeded: Bool) {
        accountPartial[id] = (accountPartial[id] ?? true) && succeeded
        let remaining = max(0, (accountRemaining[id] ?? 1) - 1)
        accountRemaining[id] = remaining
        if remaining == 0 { accountOutcome[id] = accountPartial[id] }
    }
    private func updateAccount(_ id: String, result: String, attempted: Bool = false, succeeded: Bool = false, outcome: Bool? = nil) {
        accountProgress[id] = result
        if let outcome { finishAccountItem(id, succeeded: outcome) }
        if let index = settings.accounts.firstIndex(where: { $0.id == id }) {
            settings.accounts[index].lastResult = result
            if attempted { settings.accounts[index].lastAttempt = Date() }
            if succeeded { settings.accounts[index].lastSuccess = Date() }
        }
        save()
    }
    /// 像 AltStore 一样只安装新描述文件，不重签、不重装，Retools 不会被结束。
    /// 返回 false 表示条件不满足（例如证书已更换），调用方继续走整包重装。
    private func refreshHostProfilesOnly(materials: [String: AppleAccountService.Credentials], bundleID: String, extensions: [URL], owner: RenewalAccount, store: WorkspaceStore) async throws -> Bool {
        var targets: [(uuid: String, data: Data, expiry: Date)] = []
        var blockers: [String] = []
        for (id, material) in materials {
            let executable: URL?
            if id == bundleID { executable = Bundle.main.executableURL }
            else { executable = extensions.first { (try? ArchiveService.metadata(at: $0)["CFBundleIdentifier"] as? String) == id }.flatMap { Bundle(url: $0)?.executableURL } }
            guard let executable else { blockers.append("\(id)：找不到可执行文件"); continue }
            do {
                let profile = try ProfileRefresh.parse(material.profile)
                if let reason = ProfileRefresh.blocker(profile: profile, executable: executable, currentExpiry: id == bundleID ? hostExpiry : nil) {
                    blockers.append("\(id)：\(reason)")
                } else { targets.append((profile.uuid, material.profile, profile.expiry)) }
            } catch { blockers.append("\(id)：\(error.localizedDescription)") }
        }
        guard blockers.isEmpty, let main = materials[bundleID], let mainProfile = try? ProfileRefresh.parse(main.profile),
              let certificate = ProfileRefresh.runningCertificateFingerprint else {
            AuthDiagnostics.record(stage: "自动续签", message: "不能只更新描述文件，改为重签并重装：" + (blockers.isEmpty ? "无法确认当前签名证书" : blockers.joined(separator: "；")))
            return false
        }
        setAccountProgress(owner.id, message: "正在安装新描述文件…")
        do { try await device.installProfiles(targets.map { ($0.uuid, $0.data) }) }
        catch {
            AuthDiagnostics.record(stage: "自动续签", message: "只更新描述文件失败，改为重签并重装：" + error.localizedDescription)
            return false
        }
        await pruneReplacedProfiles(installed: targets.map(\.data))
        settings.refreshedHostExpiry = mainProfile.expiry; settings.refreshedHostCertificate = certificate
        // 新证书凭据仍要保存，容器签名会用到；证书本身没变，已签名的容器无需重签。
        store.state = try await store.service.importHostIdentity(main)
        settings.lastSuccess = Date(); settings.lastResult = "Retools 描述文件已更新，无需重装"
        updateAccount(owner.id, result: "Retools 描述文件已更新（无需重装）", succeeded: true)
        save()
        AuthDiagnostics.record(stage: "自动续签", message: "只更新了 \(targets.count) 份描述文件，未重装 Retools；新到期时间 " + mainProfile.expiry.formatted(date: .abbreviated, time: .shortened))
        return true
    }
    private func renewHost(owner: RenewalAccount, udid: String, store: WorkspaceStore, submitted: (() -> Void)?) async throws {
        if settings.pendingHostProfile != nil, let date = settings.pendingHostDate, Date().timeIntervalSince(date) < 600 {
            throw WorkspaceFailure("上次自身安装仍待确认，请稍后重新打开 Retools。")
        }
        let service = service(for: owner.id)
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.retools.ios"
        setAccountProgress(owner.id, message: "正在为 Retools 获取新描述文件…")
        let plugins = Bundle.main.bundleURL.appendingPathComponent("PlugIns")
        let extensions = (try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
        // 只为已经通过用户开发签名启用的安装保留组；普通安装不在后台申请新组。
        let includeAppGroup = try HostAppGroup.readSignedIdentifier() != nil
        let materials = try await service.hostCredentials(email: owner.email, anisetteURL: owner.anisetteURL,
            teamID: owner.teamID, udid: udid, bundle: Bundle.main.bundleURL, includeAppGroup: includeAppGroup)
        guard let main = materials[bundleID], let info = try PropertyListSerialization.propertyList(from: RTNative.profilePayload(main.profile), format: nil) as? [String: Any] else { throw WorkspaceFailure("无法确认新的自身描述文件。") }
        guard (info["Entitlements"] as? [String: Any])?["get-task-allow"] as? Bool == true else { throw WorkspaceFailure("Apple 返回的描述文件未授权容器所需的调试权限，未更新 Retools。") }
        if try await refreshHostProfilesOnly(materials: materials, bundleID: bundleID, extensions: extensions, owner: owner, store: store) { return }
        let receipt = UUID().uuidString
        let app = try await store.service.prepareHostForRenewal(materials: materials, renewalReceipt: receipt, requiresAppGroup: includeAppGroup)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try await submitHostInstall(app: app, main: main, accountID: owner.id, store: store, submitted: submitted)
    }
    /// 安装会终止当前进程；先落盘凭据与回执，下一次启动才确认自身更新成功。
    private func submitHostInstall(app: URL, main: AppleAccountService.Credentials, accountID: String, store: WorkspaceStore, submitted: (() -> Void)? = nil) async throws {
        if settings.pendingHostProfile != nil, let date = settings.pendingHostDate, Date().timeIntervalSince(date) < 600 {
            throw WorkspaceFailure("上次自身安装仍待确认，请稍后重新打开 Retools。")
        }
        let info = try ArchiveService.metadata(at: app)
        guard let bundleID = info["CFBundleIdentifier"] as? String, bundleID == Bundle.main.bundleIdentifier,
              let receipt = info["RetoolsRenewalReceipt"] as? String else { throw WorkspaceFailure("自身更新包缺少安装回执。") }
        let profileID = try ProfileRefresh.parse(main.profile).uuid
        try Task.checkCancellation()
        let previousHost = store.state.hostIdentityID
        let previousAccount = settings.hostAccountID
        var imported = false
        do {
            store.state = try await store.service.importHostIdentity(main); imported = true
            settings.hostAccountID = accountID
            settings.pendingHostProfile = profileID; settings.pendingHostDate = Date(); settings.pendingHostReceipt = receipt
            settings.lastResult = "自身更新已提交，等待下次启动确认"; try persistSettings()
            submitted?()
            try await device.install(app: app, bundleID: bundleID)
        }
        catch {
            // A renewed revision can replace the old, equivalent record. Keep
            // its valid replacement if installation failed after that commit.
            if imported {
                let fallback = previousHost.flatMap { old in store.state.identities.contains { $0.id == old } ? old : store.state.hostIdentityID }
                do { store.state = try await store.service.selectHostIdentity(fallback) }
                catch { AuthDiagnostics.record(stage: "自身更新", message: "恢复原宿主证书选择失败：" + error.localizedDescription) }
            }
            settings.hostAccountID = previousAccount
            settings.pendingHostProfile = nil; settings.pendingHostDate = nil; settings.pendingHostReceipt = nil
            settings.lastResult = "自身更新未完成：" + error.localizedDescription; save()
            throw error
        }
    }

}

final class RetoolsAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// 前台时也显示到期提醒；点按通知打开对应页面。
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let link = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: link) else { return }
        await MainActor.run { WorkspaceStore.shared.handleURL(url) }
    }
    /// AI 图像请求在后台完成时，系统唤醒应用并交来这个回调：先加载对话再接收结果，写回后才通知系统挂起。
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == StoreBrowserRuntime.backgroundSessionIdentifier {
            Task { @MainActor in StoreBrowserRuntime.handleBackgroundEvents(completion: completionHandler) }
            return
        }
        guard identifier == AIBackgroundImageTransfer.identifier else { completionHandler(); return }
        Task { @MainActor in
            _ = AIChatStore.shared
            AIBackgroundImageTransfer.shared.handleEvents(completion: completionHandler)
        }
    }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 重新连上系统中仍在进行的 AI 图像后台任务。
        AIBackgroundImageTransfer.shared.reconnect()
        StoreBrowserRuntime.registerBackgroundChecks()
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: RenewalController.taskID, using: .main) { task in
            let operation = Task { @MainActor in
                let renewal = RenewalController.shared
                renewal.attach(.shared)
                let success = await renewal.renew(force: false)
                await renewal.finishBackgroundScheduling()
                task.setTaskCompleted(success: success)
            }
            task.expirationHandler = { operation.cancel() }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: RenewalController.checkTaskID, using: .main) { task in
            let operation = Task { @MainActor in
                let renewal = RenewalController.shared; renewal.attach(.shared); await renewal.finishBackgroundScheduling()
                AuthDiagnostics.record(stage: "后台续签", message: "后台检查已执行，处理任务已安排")
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { operation.cancel() }
        }
        return true
    }
}
