import SwiftUI
import RetoolsNative

@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()
    @Published var state: WorkspaceState
    @Published var selectedTab: WorkspaceTab = .library
    @Published var showDevelopmentSigning = false
    @Published var showDeviceConnection = false
    @Published var isWorking = false
    @Published var workLabel = ""
    @Published var errorMessage: String?
    @Published var toast: String?
    /// 从通知或小组件打开有效期列表。
    @Published var showExpiryList = false
    /// 正在进行或刚结束的证书签名任务，签名页以面板展示每一步。
    @Published var signingProgress: SigningProgressModel?
    /// 由外部链接（retools://launch）请求运行的容器应用，需用户确认后才启动。
    @Published var pendingExternalLaunch: ContainerApp?
    /// 外部链接请求添加的软件源地址，等待用户在添加面板确认。
    @Published var pendingSourceInput: String?
    @Published var showDecryption = false
    @Published var storageBytes: Int64 = 0
    @Published var diagnosticPassed = false
    @Published var runtimeIssue: String?
    @Published var pluginIssue: String?
    @Published var signingIssue: String?
    @Published var isCheckingRuntime = false
    @Published var containerMode = ContainerExecutionMode(rawValue: UserDefaults.standard.string(forKey: "RetoolsContainerMode") ?? "jitless") ?? .jitless {
        didSet { UserDefaults.standard.set(containerMode.rawValue, forKey: "RetoolsContainerMode"); invalidateRuntimeCheck() }
    }
    let paths: WorkspacePaths
    let service: WorkspaceService
    /// 工作区读取失败时为 true；此时不允许写入或清理关联数据。
    private(set) var loadFailed: Bool
    private var handlingContainerControl = false
    private var runtimeCheckTask: Task<Void, Never>?

    init(paths: WorkspacePaths = WorkspacePaths()) {
        self.paths = paths
        var initial = WorkspaceState(), failure: String?
        do {
            try paths.createDirectories()
            if FileManager.default.fileExists(atPath: paths.state.path) {
                initial = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: paths.state))
                guard initial.schemaVersion == 1 else { throw WorkspaceFailure("工作区版本不兼容，请保留文件并更新应用。") }
                let normalized = SigningIdentityCatalog.normalized(initial, paths: paths)
                if SigningIdentityCatalog.changed(initial, normalized) {
                    try JSONEncoder().encode(normalized).write(to: paths.state, options: .atomic)
                    SigningIdentityCatalog.cleanupRemoved(from: initial, keeping: normalized, paths: paths)
                    initial = normalized
                }
            }
        } catch { failure = "无法读取工作区：\(error.localizedDescription)" }
        state = initial; loadFailed = failure != nil; errorMessage = failure
        service = WorkspaceService(paths: paths, state: initial)
        if FileManager.default.fileExists(atPath: ContainerControlMailbox.location(in: paths.support).path) { selectedTab = .containers }
        if let launchError = UserDefaults.standard.string(forKey: "error") {
            errorMessage = "容器启动失败：\(launchError)"; UserDefaults.standard.removeObject(forKey: "error")
            runtimeIssue = launchError; selectedTab = .containers; JITLessCheckRecord.forget()
            AuthDiagnostics.record(stage: "容器启动", message: launchError)
        }
    }
    var activeIdentity: SigningIdentity? { state.identities.first { $0.id == state.activeIdentityID } }
    var hostIdentity: SigningIdentity? { state.identities.first { $0.id == (state.validHostIdentityID ?? state.activeIdentityID) } }
    func reloadAfterMigration() async throws { state = try await service.reload(); errorMessage = nil; refreshStorage() }
    var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    func refreshStorage() { Task { storageBytes = await service.storageUsage() } }
    @discardableResult
    func handleContainerControl() async -> Bool {
        guard !handlingContainerControl, !isWorking else { return true }
        handlingContainerControl = true
        defer { handlingContainerControl = false }
        do {
            guard let request = try ContainerControlMailbox.consume(support: paths.support) else { return false }
            selectedTab = .containers
            if request.action == .switchApp {
                guard !loadFailed, let id = request.appID, let container = request.containerID,
                      let app = state.containerApps.first(where: { $0.id == id }), app.containers.contains(where: { $0.id == container }) else {
                    throw WorkspaceFailure("目标应用或数据空间已不存在，请重新选择。")
                }
                state = try await service.selectContainer(appID: id, containerID: container)
                if let app = state.containerApps.first(where: { $0.id == id }) { launch(app) }
            }
            return true
        } catch {
            selectedTab = .containers; errorMessage = error.localizedDescription
            AuthDiagnostics.record(stage: "容器切换", message: error.localizedDescription)
            return true
        }
    }
    private func run(_ label: String, success: String? = nil, onError: ((Error) -> Void)? = nil, operation: @escaping () async throws -> WorkspaceState) {
        // 忙时不能静默忽略：例如后台续签时导入证书，面板关闭了但实际什么都没做。
        guard !isWorking else {
            let current = workLabel.trimmingCharacters(in: CharacterSet(charactersIn: "…. "))
            errorMessage = (current.isEmpty ? "正在进行其他操作" : "正在\(current.hasPrefix("正在") ? String(current.dropFirst(2)) : current)") + "，请等它完成后再试。"
            return
        }
        guard !loadFailed else { errorMessage = "工作区读取失败，为保留现有文件已暂停写入。"; return }
        isWorking = true; workLabel = label
        Task {
            defer { isWorking = false; workLabel = "" }
            do { state = try await operation(); toast = success; refreshStorage() }
            catch { if let onError { onError(error) } else { errorMessage = error.localizedDescription } }
        }
    }
    func importIPA(_ url: URL) {
        run("正在解析 IPA…", success: "已添加到应用库") {
            // 从选择器取得的副本已经复制进工作区，留着只会多占一份空间。
            defer { if url.path.hasPrefix(FileManager.default.temporaryDirectory.appendingPathComponent("Picked").path) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
            return try await self.service.importIPA(url)
        }
    }
    /// 导入从软件源下载的 IPA，完成或失败后删除下载用的临时目录。
    /// 同时下载多个应用时，后完成的会排队等前一个导入结束，而不是被丢弃。
    func importDownloadedIPA(_ url: URL) async {
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        while isWorking, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(400)) }
        guard !Task.isCancelled else { return }
        guard !loadFailed else { errorMessage = "工作区读取失败，为保留现有文件已暂停写入。"; return }
        isWorking = true; workLabel = "正在解析 IPA…"
        defer { isWorking = false; workLabel = "" }
        do { state = try await service.importIPA(url); toast = "已从软件源添加到应用库"; refreshStorage() }
        catch { errorMessage = error.localizedDescription }
    }
    /// 用软件源下载的新版本替换应用库中的原项。
    /// 在 Apple ID 自动续签列表里且已安装的应用，替换后直接走续签流程重签并重装新版本；其他应用提示重新签名。
    func replaceDownloadedIPA(_ url: URL, packageID: UUID) async {
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        while isWorking, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(400)) }
        guard !Task.isCancelled else { return }
        guard !loadFailed else { errorMessage = "工作区读取失败，为保留现有文件已暂停写入。"; return }
        let previous = state.packages.first { $0.id == packageID }
        isWorking = true; workLabel = "正在替换为新版本…"
        do {
            state = try await service.replacePackageIPA(packageID, with: url)
            refreshStorage()
        } catch {
            isWorking = false; workLabel = ""
            errorMessage = error.localizedDescription; return
        }
        isWorking = false; workLabel = ""
        guard let package = state.packages.first(where: { $0.id == packageID }) else { return }
        let renewal = RenewalController.shared
        let installed = renewal.settings.installedExpiries[packageID.uuidString] != nil
        if renewal.settings.packageIDs.contains(packageID), installed {
            toast = "\(package.name) 已更新到 v\(package.version)，正在重新签名并安装"
            _ = await renewal.renew(force: true, onlyPackages: [packageID], includeHost: false)
        } else {
            let from = previous.map { "v\($0.version) → " } ?? ""
            toast = "\(package.name) 已更新（\(from)v\(package.version)），重新签名后生效"
        }
    }
    func importPlugin(_ url: URL) {
        pluginIssue = nil
        run("正在导入插件…", success: "插件已导入", onError: { self.pluginIssue = $0.localizedDescription }) { try await self.service.importPlugin(url) }
    }
    func deletePlugin(_ plugin: PluginRecord) {
        pluginIssue = nil
        run("正在移除插件…", onError: { self.pluginIssue = $0.localizedDescription }) { try await self.service.deletePlugin(plugin.id) }
    }
    func savePlugins(_ ids: [UUID], target: PluginTarget) async -> Bool {
        do { return await saveInjections(try PluginService.configuration(nil, legacy: ids, plugins: state.plugins), target: target) }
        catch { pluginIssue = error.localizedDescription; return false }
    }
    func saveInjections(_ entries: [PluginInjection], target: PluginTarget) async -> Bool {
        guard !isWorking, !loadFailed else { return false }
        isWorking = true; workLabel = "正在保存插件选择…"; pluginIssue = nil
        defer { isWorking = false; workLabel = "" }
        do {
            switch target {
            case .package(let id): state = try await service.setPackageInjections(id, entries: entries)
            case .container(let id): state = try await service.setContainerInjections(id, entries: entries)
            }
            return true
        } catch { pluginIssue = error.localizedDescription; return false }
    }
    func importIdentity(p12: URL, profile: URL, password: String) {
        diagnosticPassed = false
        run("正在校验证书…", success: "签名证书已就绪") { try await self.service.importIdentity(p12: p12, profile: profile, password: password) }
    }
    func sign(_ package: AppPackage, bundleID: String) { run("正在签名并打包…", success: "签名完成，可导出 IPA") { try await self.service.sign(package.id, bundleID: bundleID) } }
    func saveSigningOptions(_ options: PackageSigningOptions, packageID: UUID) async -> Bool {
        guard !loadFailed, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do { state = try await service.saveSigningOptions(options, packageID: packageID); return true }
        catch { signingIssue = error.localizedDescription; return false }
    }
    func signProject(_ packageID: UUID, options: PackageSigningOptions, install: Bool) async -> Bool {
        guard !isWorking, !loadFailed else { return false }
        let name = state.packages.first(where: { $0.id == packageID }).map { options.name(for: $0) } ?? "应用"
        let progress = SigningProgressModel(appName: name, install: install)
        signingProgress = progress
        let reporter = SigningReporter { event in Task { @MainActor in progress.apply(event); self.workLabel = event.stage.title } }
        isWorking = true; workLabel = "正在签名并打包…"; signingIssue = nil
        defer { isWorking = false; workLabel = ""; refreshStorage() }
        do {
            if install, options.removeEmbedded || options.format == .tipa { throw WorkspaceFailure("TIPA 或移除 Embedded 的输出请使用「仅签名并导出」，再交给对应安装工具。") }
            progress.apply(SigningEvent(stage: .credentials, detail: "检查项目配置与证书"))
            if let identity = try await service.projectProvisioningIdentity(packageID, options: options) {
                guard let package = state.packages.first(where: { $0.id == packageID }) else { throw WorkspaceFailure("找不到应用。") }
                // 与 SideStore 一致：没有自定义 Bundle ID 时在后面加上团队 ID，避免与原作者已注册的 App ID 冲突。
                var options = options
                let resolved = AppleIDBundleIdentifier.resolve(original: package.bundleID, team: identity.teamID, custom: options.bundleID, previous: package.signedBundleID)
                if resolved != options.identifier(for: package) {
                    options.bundleID = resolved
                    progress.apply(SigningEvent(stage: .credentials, detail: "Bundle ID 使用 \(resolved)（加上团队 ID，与 SideStore 相同）"))
                }
                // SideStore 流程：先准备签名副本并列出主应用与扩展，再逐个注册 App ID、开启功能、分配 App Group 并取描述文件。
                let plan = try await service.prepareAppleSigning(packageID, bundleID: options.identifier(for: package), options: options, report: reporter)
                do {
                    let material = try await RenewalController.shared.projectAppCredentials(identity: identity, package: package, bundles: plan.bundles) { message in
                        self.workLabel = message; progress.apply(SigningEvent(stage: .credentials, detail: message))
                    }
                    if material.extensionsRemoved { progress.apply(SigningEvent(stage: .credentials, detail: "可用 App ID 不足，本次只签名主应用，扩展已移除")) }
                    state = try await service.finishAppleSigning(plan, credentials: material, expectedIdentity: identity, report: reporter)
                } catch { await service.discardAppleSigning(plan); throw error }
            } else {
                state = try await service.signProject(packageID, options: options, report: reporter)
            }
            // 让节流中的最后一条进度先送达，再进入下一阶段。
            await Task.yield()
            if let package = state.packages.first(where: { $0.id == packageID }) { progress.exportURL = exportURL(package) }
            if install, let package = state.packages.first(where: { $0.id == packageID }) {
                progress.apply(SigningEvent(stage: .install, detail: "验证设备回环连接"))
                try await RenewalController.shared.installSignedOutput(package, paths: paths) { message in
                    self.workLabel = message; progress.apply(SigningEvent(stage: .install, detail: message))
                }
            }
            progress.succeed(install ? "签名并安装完成" : "签名完成，可以分享或导出")
            return true
        } catch {
            await Task.yield()
            progress.fail(error.localizedDescription)
            return false
        }
    }
    func importProjectPlugin(_ source: URL, packageID: UUID, options: PackageSigningOptions) async -> Bool {
        guard !isWorking, !loadFailed else { return false }
        isWorking = true; workLabel = "正在导入插件…"; signingIssue = nil
        defer { isWorking = false; workLabel = "" }
        do {
            state = try await service.importPlugin(source)
            guard let record = state.plugins.last, let package = state.packages.first(where: { $0.id == packageID }) else { throw WorkspaceFailure("找不到新导入的插件。") }
            var entries = try PluginService.configuration(package.pluginInjections, legacy: package.pluginIDs ?? [], plugins: state.plugins)
            let added = record.executablePaths.map { PluginInjection(pluginID: record.id, path: $0, signingTarget: options.directInjection ? .executable : .loader) }
            if options.newPluginsFirst { entries.insert(contentsOf: added, at: 0) } else { entries.append(contentsOf: added) }
            state = try await service.setPackageInjections(packageID, entries: entries)
            return true
        } catch { signingIssue = error.localizedDescription; return false }
    }
    func install(_ package: AppPackage) { run("正在准备容器…", success: "已添加到容器") { try await self.service.installContainer(package.id) } }
    func addContainer(_ app: ContainerApp, name: String) { run("正在创建空间…", success: "数据空间已创建") { try await self.service.addContainer(to: app.id, name: name) } }
    func selectContainer(_ app: ContainerApp, id: UUID) { run("正在切换空间…") { try await self.service.selectContainer(appID: app.id, containerID: id) } }
    func resetContainer(_ app: ContainerApp, id: UUID) { run("正在重置空间…", success: "数据空间已重置") { try await self.service.resetContainer(appID: app.id, containerID: id) } }
    @discardableResult
    func deletePackage(_ package: AppPackage) async -> Bool {
        guard !isWorking, !loadFailed else { errorMessage = "请等待当前操作完成，或先恢复无法读取的工作区。"; return false }
        isWorking = true; workLabel = "正在移除 IPA…"
        defer { isWorking = false; workLabel = ""; refreshStorage() }
        do {
            state = try await service.deletePackage(package.id); toast = "已从应用库移除"
            RenewalController.shared.pruneRemovedPackages()
            return true
        }
        catch { errorMessage = error.localizedDescription; return false }
    }
    func deleteApp(_ app: ContainerApp) { run("正在移除容器…") { try await self.service.deleteContainerApp(app.id) } }
    func selectIdentity(_ id: UUID) { diagnosticPassed = false; run("正在切换证书…") { try await self.service.selectIdentity(id) } }
    func selectHostIdentity(_ id: UUID?) { invalidateRuntimeCheck(); run("正在切换容器证书…") { try await self.service.selectHostIdentity(id) } }
    func deleteIdentity(_ id: UUID) { diagnosticPassed = false; run("正在移除证书…") { try await self.service.deleteIdentity(id) } }
    var runtimeStatusTitle: String {
        if isCheckingRuntime { return containerMode == .jit ? "正在启用" : "正在检测" }
        if isSimulator { return "需真机验证" }
        if containerMode == .jit, RTNative.isJITEnabled() { return "本次已启用" }
        if diagnosticPassed || jitlessVerified { return "检测通过" }
        if runtimeIssue != nil { return containerMode == .jit ? "启用未完成" : "检测未通过" }
        if !RTNative.hostAllowsDebugging() { return "需开发签名" }
        return containerMode == .jit ? "待启用" : "待检测"
    }
    func invalidateRuntimeCheck() { diagnosticPassed = false; runtimeIssue = nil }
    /// 免 JIT 模式下，当前容器证书此前已检测通过且证书、Retools 签名都没变。
    var jitlessVerified: Bool {
        guard containerMode == .jitless, runtimeIssue == nil, !isSimulator, let identity = hostIdentity else { return false }
        return JITLessCheckRecord.isValid(for: identity)
    }
    /// 进入容器页面时调用：没有有效检测记录就在后台静默检测一次，不弹错误。
    /// JIT 模式会附加调试器，不自动执行。
    func checkRuntimeIfNeeded() {
        guard containerMode == .jitless, !isSimulator, !isWorking, runtimeIssue == nil, !diagnosticPassed,
              hostIdentity != nil, !jitlessVerified else { return }
        diagnose(presentError: false)
    }
    func diagnose(presentError: Bool = true) {
        guard !isWorking else { return }
        let mode = containerMode
        isWorking = true; isCheckingRuntime = true; workLabel = mode == .jit ? "正在启用 JIT…" : "正在检测免 JIT…"
        invalidateRuntimeCheck()
        runtimeCheckTask = Task {
            defer { isWorking = false; isCheckingRuntime = false; workLabel = ""; runtimeCheckTask = nil }
            do {
                guard !isSimulator else { throw WorkspaceFailure(mode == .jit ? "模拟器无法启用设备 JIT。请在开发签名的 iPhone 上验证配对、回环与调试服务。" : "模拟器无法验证设备签名加载。请在开发签名的 iPhone 上检测免 JIT。") }
                if mode == .jit {
                    guard RTNative.hostAllowsDebugging() else { throw WorkspaceFailure("请先使用 Apple ID 开发签名安装 Retools，再启用 JIT。") }
                    if !RTNative.isJITEnabled() {
                        guard UserDefaults.standard.string(forKey: "RetoolsJITProvider") != "external" else {
                            throw WorkspaceFailure("请先通过外部调试工具为 Retools 当前进程启用 JIT，再点击检查。重启容器后需为新进程重新启用。")
                        }
                        try await RenewalController.shared.enableCurrentProcessJIT()
                    }
                    guard RTNative.isJITEnabled() else { throw WorkspaceFailure("调试服务已返回，但当前进程尚未获得 JIT。请查看运行诊断。") }
                    toast = "当前进程 JIT 已启用"
                    AuthDiagnostics.record(stage: "容器 JIT", message: "当前进程已完成附加与分离，实际 JIT 标志已确认")
                } else {
                    try await service.diagnose(); toast = "免 JIT 检测通过"
                    AuthDiagnostics.record(stage: "容器 JIT-less 检测", message: "实际签名并加载测试动态库成功")
                }
                diagnosticPassed = true
            } catch {
                runtimeIssue = Self.containerErrorSummary(error)
                if presentError { errorMessage = runtimeIssue }
                AuthDiagnostics.record(stage: mode == .jit ? "容器 JIT" : "容器 JIT-less 检测", message: error.localizedDescription)
            }
        }
    }
    func launch(_ app: ContainerApp) {
        // 静默检测进行中时点了运行：等检测结束再启动，而不是忽略这次点击。
        if isCheckingRuntime, let pending = runtimeCheckTask {
            Task { await pending.value; launch(app) }; return
        }
        guard !isWorking else { return }
        if isSimulator { errorMessage = "容器运行需要已签名的 iPhone 或 iPad。模拟器支持导入和数据空间管理。"; return }
        isWorking = true; workLabel = "正在验证并启动…"
        let mode = containerMode
        Task {
            defer { isWorking = false; workLabel = "" }
            do {
                if mode == .jit {
                    guard RTNative.hostAllowsDebugging() else { throw WorkspaceFailure("JIT 模式需要 Apple 开发签名授权的调试权限。请先在容器运行设置中配置开发签名，再运行应用。") }
                    if UserDefaults.standard.string(forKey: "RetoolsJITProvider") != "external" {
                        workLabel = "正在验证 JIT 回环通路…"
                        try await RenewalController.shared.prepareJITConnection()
                    }
                }
                state = try await service.prepareLaunch(app.id, mode: mode)
                guard let current = state.containerApps.first(where: { $0.id == app.id }) else { return }
                try RTNative.launchGuest(current.folder, container: current.selectedContainerID.uuidString, jit: mode == .jit)
            } catch { JITLessCheckRecord.forget(); runtimeIssue = Self.containerErrorSummary(error); diagnosticPassed = false; errorMessage = runtimeIssue; AuthDiagnostics.record(stage: "容器启动", message: error.localizedDescription) }
        }
    }
    func iconURL(_ file: String?) -> URL? { file.map { paths.icons.appendingPathComponent($0) } }
    private static func containerErrorSummary(_ error: Error) -> String {
        let detail = error.localizedDescription
        if detail.contains("code signature invalid") {
            return "JIT-less 测试动态库的签名未被系统接受。详细加载原因已保存，可在设置的「运行诊断记录」查看。"
        }
        return detail.count > 600 ? String(detail.prefix(600)) + "\n完整原因已保存在运行诊断记录。" : detail
    }
    func exportURL(_ package: AppPackage) -> URL? { package.signedFile.map { paths.exports.appendingPathComponent($0) } }
    func handleURL(_ url: URL) {
        if url.isFileURL { importIPA(url); return }
        if url.scheme == "retools", url.host == "decryption" { selectedTab = .library; showDecryption = true; return }
        // 到期提醒和桌面小组件：打开应用库里的 Apple ID 签名有效期列表。
        if url.scheme == "retools", url.host == "expiry" { selectedTab = .library; showExpiryList = true; return }
        if url.scheme == "retools", url.host == "diagnose" { selectedTab = .containers; diagnose(); return }
        // retools://addsource?url=…&url=…：打开添加软件源面板并填好地址，由用户确认后才订阅。
        if url.scheme == "retools", url.host == "addsource" {
            let urls = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "url" }.compactMap(\.value) ?? []
            guard !urls.isEmpty else { errorMessage = "添加软件源的链接里没有 url 参数。"; return }
            selectedTab = .library; pendingSourceInput = urls.joined(separator: "\n"); return
        }
        if url.scheme == "retools", url.host == "pairing" { selectedTab = .settings; showDeviceConnection = true; return }
        if url.scheme == "retools", url.host == "prepare-development" {
            selectedTab = .settings; showDevelopmentSigning = true; return
        }
        guard url.scheme == "retools", url.host == "launch", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let app = state.containerApps.first(where: { $0.id.uuidString == id }) else { return }
        // 任何网页或应用都能打开这个链接，不能直接重启进入容器，先交给用户确认。
        selectedTab = .containers; pendingExternalLaunch = app
    }
}
