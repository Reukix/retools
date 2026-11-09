import SwiftUI
import RetoolsNative

struct DecryptionView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var renewal: RenewalController
    @StateObject private var controller = DecryptionController()
    @StateObject private var commerce = StoreDownloadController()
    @ObservedObject private var broker = TwoFactorBroker.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showImporter = false
    @State private var identityID: UUID?
    @State private var loaded = false
    @State private var showStoreLogin = false
    @State private var showInstalledApps = false
    @State private var storeTerm = ""
    @State private var pendingStoreApp: StoreCatalogApp?
    @State private var pendingStoreVersion: String?
    let package: AppPackage?
    init(package: AppPackage? = nil) { self.package = package }
    private var identity: SigningIdentity? { store.state.identities.first { $0.id == identityID } }
    private var blocked: Bool { controller.busy || store.isWorking || renewal.isWorking }
    var body: some View {
        List {
            StoreDecryptionSection(controller: commerce,showLogin: $showStoreLogin,showInstalled: $showInstalledApps,term: $storeTerm,onDownload: downloadStoreApp)
            if controller.job == nil && identity == nil {
                Section("助手签名") { certificatePicker }
            }
            Section {
                if let job = controller.job {
                    Label(job.manifest.name, systemImage: "app.badge")
                    Text(job.manifest.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text("\(job.manifest.encryptedCount) 个加密二进制").foregroundStyle(.secondary)
                }
                Button { showImporter = true } label: { Label(controller.job == nil ? "选择本地加密 IPA" : "选择其他 IPA", systemImage: "folder") }
                    .disabled(blocked).accessibilityIdentifier("decryption.import")
                let encrypted = store.state.packages.filter(\.isEncrypted)
                if !encrypted.isEmpty {
                    Menu {
                        ForEach(encrypted) { value in
                            Button(value.name) { prepare(store.paths.library.appendingPathComponent(value.fileName)) }
                        }
                    } label: { Label("从应用库选择", systemImage: "square.grid.2x2") }.disabled(blocked)
                }
            } header: { Text("已有加密 IPA") } footer: {
                Text("选择保存在本机“文件”中的加密 IPA，需包含 SC_Info 许可。设备应登录拥有该应用的商店账号。输出不包含 Apple Watch 组件。")
            }
            if controller.job != nil {
                Section {
                    certificatePicker
                    Button { if let identity { Task { await controller.sign(identity: identity, install: true, store: store, renewal: renewal) } } } label: {
                        Label("签名并安装解密助手", systemImage: "arrow.down.app")
                    }.disabled(blocked || identity == nil).accessibilityIdentifier("decryption.install")
                    Button { if let identity { Task { await controller.sign(identity: identity, install: false, store: store, renewal: renewal) } } } label: {
                        Label("仅签名助手", systemImage: "checkmark.seal")
                    }.disabled(blocked || identity == nil)
                    if let helper = controller.helperIPA {
                        ShareLink(item: helper) { Label("导出助手 IPA", systemImage: "square.and.arrow.up") }.disabled(blocked)
                    }
                } header: { Text("解密助手") } footer: {
                    Text("助手独立安装。安装后打开“Retools 解密助手”，点击“开始砸壳”；也可导出助手后用其他工具签名安装。")
                }
                Section {
                    HStack {
                        if controller.busy { ProgressView() }
                        Text(controller.status).textSelection(.enabled)
                    }
                    if controller.job?.installed == true {
                        Link(destination: URL(string: "retoolsdecrypt://open")!) { Label("打开解密助手", systemImage: "arrow.up.forward.app") }.disabled(blocked)
                    }
                    Button { Task { await controller.collect(store: store, renewal: renewal) } } label: {
                        Label("取回砸壳结果", systemImage: "arrow.down.doc")
                    }.disabled(blocked || controller.job?.signedBundleID == nil)
                    if let result = controller.result {
                        ShareLink(item: result) { Label("导出解密 IPA", systemImage: "square.and.arrow.up") }
                        Button("导入应用库签名") { store.importIPA(result) }.disabled(blocked)
                    }
                } header: { Text("结果") } footer: {
                    Text("助手完成后回到此页取回结果。也可以在助手中直接保存到“文件”，再导入 Retools。")
                }
            } else if controller.busy {
                Section { HStack { ProgressView(); Text(controller.status) } }
            }
        }
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle("应用砸壳").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(controller.busy || commerce.busy)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, controller.job?.startedAutomatically == true, controller.result == nil {
                Task { await controller.collect(store: store,renewal: renewal,quietly: true) }
            }
        }
        .sheet(isPresented: $showImporter) {
            DocumentImportPicker(isPresented: $showImporter) { value in
                switch value { case .success(let file): prepare(file); case .failure(let error): controller.error = error.localizedDescription }
            }
        }
        .sheet(item: $broker.prompt) { prompt in TwoFactorSheet(prompt: prompt).interactiveDismissDisabled() }
        .sheet(isPresented: $showStoreLogin) {
            StoreLoginSheet(controller: commerce) {
                if let app = pendingStoreApp { let version = pendingStoreVersion; pendingStoreApp = nil; pendingStoreVersion = nil; downloadStoreApp(app,version) }
            }
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
            if let package { await controller.prepare(source: store.paths.library.appendingPathComponent(package.fileName), store: store, renewal: renewal) }
            else if controller.job?.startedAutomatically == true { await controller.collect(store: store,renewal: renewal,quietly: true) }
        }
    }
    private var certificatePicker: some View {
        Picker("签名证书", selection: $identityID) {
            Text("请选择").tag(nil as UUID?)
            ForEach(store.state.identities.filter { !$0.isExpired }) { item in Text(item.name).tag(Optional(item.id)) }
        }.disabled(blocked)
    }
    private func prepare(_ file: URL) { Task { await controller.prepare(source: file, store: store, renewal: renewal) } }
    private func downloadStoreApp(_ app: StoreCatalogApp,_ version: String?) {
        guard commerce.account != nil else { pendingStoreApp = app; pendingStoreVersion = version; showStoreLogin = true; return }
        Task {
            guard let identity else { controller.error = "请先选择助手签名证书，或在设置中准备 Apple ID 开发签名。"; return }
            guard let input = await commerce.download(app,version: version,store: store,renewal: renewal) else { return }
            let previous = controller.job?.manifest.id
            await controller.prepare(source: input,store: store,renewal: renewal)
            guard let job = controller.job,job.manifest.id != previous,job.manifest.bundleID == app.bundleID else { return }
            await controller.sign(identity: identity,install: true,store: store,renewal: renewal)
            if controller.job?.installed == true { await controller.startHelper() }
        }
    }
}
