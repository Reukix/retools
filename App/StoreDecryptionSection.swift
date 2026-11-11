import SwiftUI

struct StoreDecryptionSection: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject var controller: StoreDownloadController
    @Binding var showLogin: Bool
    @Binding var showInstalled: Bool
    @Binding var term: String
    let onDownload: (StoreCatalogApp, String?) -> Void
    @State private var versionApp: StoreCatalogApp?
    @State private var versionIDs: [String] = []
    @State private var showVersions = false
    @State private var didSearch = false
    private var blocked: Bool { store.isWorking || renewal.isWorking || controller.busy }

    var body: some View {
        Group {
            Section {
                if let account = controller.account {
                    HStack {
                        Label(account.email, systemImage: "person.crop.circle.badge.checkmark").lineLimit(1)
                        Spacer()
                        Menu { Button("退出商店登录", role: .destructive) { Task { await controller.signOut() } } } label: { Image(systemName: "ellipsis.circle") }.disabled(blocked)
                    }
                } else {
                    Button { showLogin = true } label: { Label("登录 App Store 账号", systemImage: "person.crop.circle") }
                        .disabled(blocked).accessibilityIdentifier("decryption.store.login")
                }
            } header: { Text("商店账号") } footer: {
                Text("登录拥有目标应用的账号，下载包含许可的加密 IPA，然后准备解密助手。")
            }
            Section {
                HStack {
                    TextField("应用名称、Bundle ID 或商店链接", text: $term).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .onSubmit { search() }.accessibilityIdentifier("decryption.store.searchField")
                    Button { search() } label: { Image(systemName: "magnifyingglass") }.disabled(controller.searching || term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("搜索应用").accessibilityIdentifier("decryption.store.search")
                }.disabled(blocked)
                Button { showInstalled = true } label: { Label("从本机已安装应用选择", systemImage: "iphone.gen3") }.disabled(blocked)
                    .accessibilityIdentifier("decryption.store.installed")
            } header: { Text("选择应用") } footer: {
                Text("选择本机应用时，会按 Bundle ID 从商店重新获取安装包。付费应用需已拥有许可；免费应用会在需要时获取免费许可。")
            }
            if controller.searching { Section { HStack { ProgressView(); Text("正在搜索 App Store…") } } }
            if !controller.apps.isEmpty {
                Section("搜索结果") {
                    ForEach(controller.apps) { app in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                if let artwork = app.artwork {
                                    AsyncImage(url: artwork) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "app").foregroundStyle(Color.secondary) }
                                        .frame(width: 44,height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
                                } else { Image(systemName: "app").font(.title).foregroundStyle(Palette.accent).frame(width: 44,height: 44) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).font(.body.weight(.medium))
                                    Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(Color.secondary).lineLimit(1)
                                    if !app.version.isEmpty { Text("v"+app.version).font(.caption).foregroundStyle(Palette.tertiaryText) }
                                }
                            }
                            HStack {
                                Button("下载并准备") { download(app,version: nil) }.buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("decryption.store.download."+app.bundleID)
                                Spacer()
                                Button("选择版本") {
                                    guard controller.account != nil else { showLogin = true; return }
                                    Task {
                                        versionApp = app; versionIDs = await controller.versions(app, store: store, renewal: renewal)
                                        if !versionIDs.isEmpty { showVersions = true }
                                    }
                                }.font(.subheadline)
                            }.disabled(blocked)
                        }.padding(.vertical,6)
                    }
                }
            } else if didSearch && !controller.searching { Section { Text("没有找到应用，请检查名称、Bundle ID 或当前商店地区。").foregroundStyle(Color.secondary) } }
            if controller.busy {
                Section {
                    HStack { ProgressView(); Text(controller.status.isEmpty ? "正在处理商店请求…" : controller.status) }
                    Button("取消当前操作",role: .cancel) { controller.cancel() }.disabled(controller.cancelling)
                }
            }
            if let error = controller.error, !showLogin {
                Section { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }
        .confirmationDialog("选择应用版本", isPresented: $showVersions, titleVisibility: .visible) {
            if let app = versionApp {
                Button("最新版本") { download(app,version: nil) }
                ForEach(versionIDs, id: \.self) { version in Button("版本 ID "+version) { download(app,version: version) } }
            }
            Button("取消", role: .cancel) {}
        }
        .task { await controller.loadAccount() }
    }
    private func search() {
        didSearch = true
        let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = text.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$",options: .regularExpression) != nil
        controller.search(text,bundleID: bundle)
    }
    private func download(_ app: StoreCatalogApp, version: String?) {
        onDownload(app,version)
    }
}

struct StoreInstalledAppSelector: View {
    let onSelect: (DeviceInstalledApp) -> Void
    var body: some View { InstalledDecryptionSelector(onSelect: onSelect) }
}
