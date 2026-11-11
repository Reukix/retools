import SwiftUI
import RetoolsNative

struct DecryptionView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var renewal: RenewalController
    @StateObject private var controller = DecryptionController()
    @StateObject private var commerce = StoreDownloadController()
    @ObservedObject private var broker = TwoFactorBroker.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    private enum Source: String, CaseIterable { case installed = "本机已安装", store = "商店下载", local = "外部 IPA" }
    private enum Output: String { case package, certificate }
    @State private var source: Source = .installed
    @AppStorage("RetoolsDecryptionOutput") private var output: Output = .package
    @State private var showImporter = false
    @State private var identityID: UUID?
    @State private var loaded = false
    @State private var showStoreLogin = false
    @State private var showInstalledApps = false
    @State private var showLocalApps = false
    @State private var installedApp: DeviceInstalledApp?
    @State private var resolvingInstalled = false
    @State private var storeTerm = ""
    @State private var pendingStoreApp: StoreCatalogApp?
    @State private var pendingStoreVersion: String?
    @State private var showCacheCleanup = false
    let package: AppPackage?
    init(package: AppPackage? = nil) { self.package = package }
    private var identity: SigningIdentity? { store.state.identities.first { $0.id == identityID } }
    private var blocked: Bool { controller.busy || commerce.busy || store.isWorking || renewal.isWorking || resolvingInstalled }
    var body: some View {
        List {
            ToolPageIntro(tool: .decryption, title: "选择应用，准备解密助手", detail: "从本机已安装应用开始，也可搜索商店或导入已有 IPA。")
            if let job = controller.job {
                Section {
                    HStack(spacing: 14) {
                        AppIcon(name: job.manifest.name, size: 60)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job.manifest.name).font(.headline)
                            Text(job.manifest.bundleID).font(.caption.monospaced()).foregroundStyle(Color.secondary)
                            StatusPill(title: "加密 ×\(job.manifest.encryptedCount)")
                        }
                    }.padding(.vertical, 6)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { workflowSteps }
                        VStack(alignment: .leading, spacing: 10) { workflowSteps }
                    }.padding(.vertical, 4)
                    HStack(spacing: 10) {
                        if controller.busy { ProgressView() }
                        Text(controller.status).font(.subheadline).textSelection(.enabled)
                    }
                } header: { Text("当前任务") }
            }
            Section {
                Group {
                    if typeSize.isAccessibilitySize { sourcePicker.pickerStyle(.menu) }
                    else { sourcePicker.pickerStyle(.segmented) }
                }.disabled(blocked).accessibilityIdentifier("decryption.source")
            } header: { Text("1 · 选择来源") }
            if source == .installed {
                installedSource
            } else if source == .store {
                StoreDecryptionSection(controller: commerce,showLogin: $showStoreLogin,showInstalled: $showInstalledApps,term: $storeTerm,onDownload: downloadStoreApp)
            } else {
                localSource
            }
            if let issue = controller.sourceIssue, source != .installed {
                Section {
                    ToolNotice(title: "来源检查未完成", detail: issue, symbol: "exclamationmark.circle", color: .orange)
                        .accessibilityIdentifier("decryption.sourceIssue")
                }
            }
            if source == .local {
                if resolvingInstalled {
                    Section { HStack { ProgressView(); Text("正在查询应用的商店信息…") } }
                }
                if commerce.busy {
                    Section {
                        HStack { ProgressView(); Text(commerce.status.isEmpty ? "正在获取原始安装包…" : commerce.status) }
                        Button("取消下载", role: .cancel) { commerce.cancel() }.disabled(commerce.cancelling)
                    }
                }
                if let issue = commerce.error, !showStoreLogin {
                    Section { ToolNotice(title: "商店获取未完成", detail: issue, symbol: "exclamationmark.circle", color: .orange) }
                }
            }
            if controller.job == nil, controller.busy, source != .installed {
                Section { HStack { ProgressView(); Text(controller.status) } }
            }
            Section {
                Picker("输出方式", selection: $output) {
                    Text("导出助手 IPA").tag(Output.package)
                    Text("证书签名安装").tag(Output.certificate)
                }.pickerStyle(.segmented).disabled(blocked).accessibilityIdentifier("decryption.output")
            } header: { Text("2 · 选择输出") } footer: {
                Text(output == .package ? "导出包含目标应用的未签名助手，用其他签名工具安装；无需配置证书或设备连接。" : "选用 Retools 中的签名身份。签名后可以导出助手，自动安装时再连接设备。")
            }
            if controller.job != nil {
                if output == .package {
                    Section {
                        if let helper = controller.unsignedHelperIPA {
                            ShareLink(item: helper) {
                                ToolActionLabel(title: "导出未签名助手 IPA", symbol: "square.and.arrow.up")
                            }.disabled(blocked).accessibilityIdentifier("decryption.exportHelper")
                        } else {
                            Button("生成未签名助手 IPA") { Task { await controller.packageHelper(store: store, renewal: renewal) } }
                                .disabled(blocked)
                        }
                    } footer: { Text("签名安装后，打开“Retools 解密助手”开始砸壳。完成后可在助手中直接导出结果。") }
                } else {
                    Section {
                        certificatePicker
                        NavigationLink("管理签名证书") { CertificateManagerView() }
                        Button { if let identity { Task { await controller.sign(identity: identity, install: true, store: store, renewal: renewal) } } } label: {
                            ToolActionLabel(title: "签名并安装解密助手", symbol: "arrow.down.app")
                        }.font(.body.weight(.semibold)).disabled(blocked || identity == nil).accessibilityIdentifier("decryption.install")
                        Button { if let identity { Task { await controller.sign(identity: identity, install: false, store: store, renewal: renewal) } } } label: {
                            Label("仅签名助手", systemImage: "checkmark.seal")
                        }.disabled(blocked || identity == nil)
                        if let helper = controller.helperIPA {
                            ShareLink(item: helper) { Label("导出助手 IPA", systemImage: "square.and.arrow.up") }.disabled(blocked)
                        }
                    } header: { Text("助手签名") } footer: {
                        Text("使用所选签名身份，Apple ID 身份可能需要联网准备描述文件；自动安装还需要设备配对与回环连接。安装后打开助手开始砸壳。")
                    }
                }
                Section {
                    if controller.job?.installed == true {
                        Link(destination: URL(string: "retoolsdecrypt://open")!) { Label("打开解密助手", systemImage: "arrow.up.forward.app") }.disabled(blocked)
                    }
                    Button { Task { await controller.collect(store: store, renewal: renewal) } } label: {
                        Label("取回砸壳结果", systemImage: "arrow.down.doc")
                    }.disabled(blocked || controller.job?.signedBundleID == nil)
                } header: { Text("3 · 取回与导出") } footer: {
                    Text("通过配对连接取回结果；也可以在助手中直接保存到“文件”，再导入 Retools。")
                }
            }
            if let result = controller.result {
                Section("砸壳结果") {
                    ShareLink(item: result) { Label("导出解密 IPA", systemImage: "square.and.arrow.up") }.disabled(blocked)
                    Button("导入应用库签名") { store.importIPA(result) }.disabled(blocked)
                }
            }
            Section {
                Button { showCacheCleanup = true } label: { Label("清理砸壳缓存", systemImage: "trash") }
                    .disabled(blocked).accessibilityIdentifier("decryption.cache")
            } footer: { Text("砸壳完成后，可清理助手副本和下载包以释放空间。") }
        }
        .toolListStyle()
        .navigationTitle("应用砸壳").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(controller.busy || commerce.busy)
        .onAppear { controller.reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, controller.job?.startedAutomatically == true, controller.result == nil {
                Task { await controller.collect(store: store,renewal: renewal,quietly: true) }
            }
        }
        .onChange(of: store.pendingStoreDecryptionSource, initial: true) { _, file in
            guard let file else { return }
            store.pendingStoreDecryptionSource = nil
            source = .local
            prepare(file)
        }
        .sheet(isPresented: $showImporter) {
            DocumentImportPicker(isPresented: $showImporter) { value in
                switch value { case .success(let file): prepare(file); case .failure(let error): controller.error = error.localizedDescription }
            }
        }
        .sheet(isPresented: $showCacheCleanup, onDismiss: { controller.reload() }) {
            NavigationStack {
                DecryptionCacheView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showCacheCleanup = false }.disabled(store.isWorking) } }
            }.interactiveDismissDisabled(store.isWorking)
        }
        .sheet(item: $broker.prompt) { prompt in TwoFactorSheet(prompt: prompt).interactiveDismissDisabled() }
        .sheet(isPresented: $showStoreLogin) {
            StoreLoginSheet(controller: commerce) {
                if let app = pendingStoreApp { let version = pendingStoreVersion; pendingStoreApp = nil; pendingStoreVersion = nil; downloadStoreApp(app,version) }
            }
        }
        .sheet(isPresented: $showLocalApps) {
            InstalledDecryptionSelector { app in installedApp = app; controller.sourceIssue = nil }
        }
        .sheet(isPresented: $showInstalledApps) {
            StoreInstalledAppSelector { app in storeTerm = app.bundleID; commerce.search(app.bundleID,bundleID: true) }
        }
        .alert("砸壳", isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(controller.error ?? "") }
        .task {
            guard !loaded else { return }; loaded = true
            let hostTeam = RTNative.hostTeamIdentifier()
            identityID = store.state.identities.first { $0.id == store.state.validHostIdentityID && $0.teamID == hostTeam && !$0.isExpired }?.id
                ?? store.state.identities.first { $0.id == store.state.activeIdentityID && $0.teamID == hostTeam && !$0.isExpired }?.id
            if ProcessInfo.processInfo.arguments.contains("--verify-prepared-decryption"), controller.job != nil {
                if let identity {
                    await controller.sign(identity: identity, install: true, store: store, renewal: renewal)
                    if controller.job?.installed == true { await controller.startHelper() }
                } else { controller.error = "请先选择助手签名证书。" }
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--verify-x-decryption") {
                await commerce.loadAccount()
                do {
                    guard commerce.account != nil else { throw FairPlayFailure("请先登录商店账号，再运行 X 的真机验证。") }
                    let apps = try await AppStoreCatalog.search("com.atebits.Tweetie2", country: AppStoreCatalog.country(storeFront: commerce.account?.storeFront), lookup: true)
                    guard let app = apps.first(where: { $0.id == 333903271 && $0.bundleID == "com.atebits.Tweetie2" }) else { throw FairPlayFailure("当前商店未找到 X。") }
                    downloadStoreApp(app, nil)
                } catch { controller.error = error.localizedDescription }
                return
            }
            if let package { source = .local; await controller.prepare(source: store.paths.library.appendingPathComponent(package.fileName), store: store, renewal: renewal) }
            else if controller.job?.startedAutomatically == true { await controller.collect(store: store,renewal: renewal,quietly: true) }
        }
    }
    private var sourcePicker: some View {
        Picker("安装包来源", selection: $source) {
            ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
    }
    @ViewBuilder private var workflowSteps: some View {
        stage("1", title: "选择应用", complete: controller.job != nil)
        stage("2", title: "准备助手", complete: controller.job?.signedBundleID != nil)
        stage("3", title: "导出结果", complete: controller.result != nil)
    }
    private func stage(_ number: String, title: String, complete: Bool) -> some View {
        HStack(spacing: 5) {
            if complete { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            else { Text(number).font(.caption.weight(.semibold)).frame(width: 20, height: 20).background(Palette.accent.opacity(0.12), in: Circle()) }
            Text(title).font(.caption.weight(.medium)).fixedSize()
        }.accessibilityElement(children: .combine)
    }
    private var installedSource: some View {
        Section {
            if let app = installedApp {
                HStack(spacing: 12) {
                    DeviceAppIcon(bundleID: app.bundleID, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.headline)
                        Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(Color.secondary).lineLimit(2)
                        if !app.version.isEmpty { Text("已安装 v" + app.version).font(.caption).foregroundStyle(Color.secondary) }
                    }
                }.padding(.vertical, 5)
                if controller.busy {
                    HStack { ProgressView(); Text(controller.status).font(.subheadline) }
                }
                if resolvingInstalled {
                    HStack { ProgressView(); Text("正在查询应用的商店信息…").font(.subheadline) }
                }
                if commerce.busy {
                    HStack { ProgressView(); Text(commerce.status.isEmpty ? "正在获取原始安装包…" : commerce.status).font(.subheadline) }
                    Button("取消下载", role: .cancel) { commerce.cancel() }.disabled(commerce.cancelling)
                }
                if let issue = controller.sourceIssue {
                    ToolNotice(title: "来源检查未完成", detail: issue, symbol: "exclamationmark.circle", color: .orange)
                        .accessibilityIdentifier("decryption.sourceIssue")
                }
                if let issue = commerce.error, !showStoreLogin {
                    ToolNotice(title: "商店获取未完成", detail: issue, symbol: "exclamationmark.circle", color: .orange)
                }
                Button { Task { await controller.prepareInstalled(app, store: store, renewal: renewal) } } label: {
                    ToolActionLabel(title: "读取并准备助手", symbol: "lock.open")
                }.disabled(blocked).accessibilityIdentifier("decryption.installed.prepare")
                Button { downloadInstalled(app) } label: { Label(resolvingInstalled ? "正在查询商店…" : "从商店获取原始包", systemImage: "arrow.down.circle") }.disabled(blocked)
            }
            Button { showLocalApps = true } label: { ToolActionLabel(title: installedApp == nil ? "选择本机已安装应用" : "选择其他应用", symbol: "iphone.gen3") }
                .disabled(blocked).accessibilityIdentifier("decryption.installed.select")
        } header: { Text("本机应用") } footer: {
            Text("直接读取取决于安装包目录权限及商店许可。读取受限时可按所选应用从商店获取，无需手动寻找加密 IPA；商店版本可能与已安装版本不同。")
        }
    }
    private var localSource: some View {
        Section {
            Button { showImporter = true } label: {
                ToolActionLabel(title: controller.job == nil ? "导入已有的加密 IPA" : "选择其他 IPA", symbol: "folder")
            }.disabled(blocked).accessibilityIdentifier("decryption.import")
            let encrypted = store.state.packages.filter(\.isEncrypted)
            if !encrypted.isEmpty {
                Menu {
                    ForEach(encrypted) { value in
                        Button(value.name) { prepare(store.paths.library.appendingPathComponent(value.fileName)) }
                    }
                } label: { Label("从应用库选择", systemImage: "square.grid.2x2") }.disabled(blocked)
            }
        } footer: {
            Text("IPA 需包含匹配的 SC_Info 许可。设备应登录拥有该应用的商店账号。输出不包含 Apple Watch 组件。")
        }
    }
    private var certificatePicker: some View {
        Picker("签名证书", selection: $identityID) {
            Text("请选择").tag(nil as UUID?)
            ForEach(store.state.identities.filter { !$0.isExpired }) { item in Text(item.name).tag(Optional(item.id)) }
        }.disabled(blocked)
    }
    private func prepare(_ file: URL) { Task { await controller.prepare(source: file, store: store, renewal: renewal) } }
    private func downloadInstalled(_ app: DeviceInstalledApp) {
        guard !blocked else { return }
        resolvingInstalled = true; controller.sourceIssue = nil
        Task {
            await commerce.loadAccount()
            do {
                let results = try await AppStoreCatalog.search(app.bundleID, country: AppStoreCatalog.country(storeFront: commerce.account?.storeFront), lookup: true)
                guard let match = results.first(where: { $0.bundleID == app.bundleID }) else { throw FairPlayFailure("当前商店未找到这个应用。可切换商店账号或导入已有 IPA。") }
                resolvingInstalled = false
                downloadStoreApp(match, nil)
            } catch { resolvingInstalled = false; controller.sourceIssue = error.localizedDescription }
        }
    }
    private func downloadStoreApp(_ app: StoreCatalogApp,_ version: String?) {
        guard commerce.account != nil else { pendingStoreApp = app; pendingStoreVersion = version; showStoreLogin = true; return }
        Task {
            guard let input = await commerce.download(app,version: version,store: store,renewal: renewal) else { return }
            let previous = controller.job?.manifest.id
            await controller.prepare(source: input,store: store,renewal: renewal)
            guard let job = controller.job,job.manifest.id != previous,job.manifest.bundleID == app.bundleID else { return }
            // 自动真机验证保留完整流程；日常下载完成后由用户选择签名或安装。
            if ProcessInfo.processInfo.arguments.contains("--verify-x-decryption") {
                guard let identity else { controller.error = "请先选择助手签名证书。"; return }
                await controller.sign(identity: identity,install: true,store: store,renewal: renewal)
                if controller.job?.installed == true { await controller.startHelper() }
            }
        }
    }
}
