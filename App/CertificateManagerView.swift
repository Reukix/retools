import SwiftUI

struct CertificateManagerView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var showImport = false
    @State private var pendingDelete: SigningIdentity?
    @State private var permissionsIdentity: SigningIdentity?
    private var certificateCount: Int { Set(store.state.identities.map { $0.teamID + ":" + $0.fingerprint.lowercased() }).count }
    var body: some View {
        List {
            if store.state.identities.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("暂无签名证书", systemImage: "checkmark.seal")
                    } description: {
                        Text("导入 P12 和匹配的描述文件，用于应用签名。")
                    } actions: {
                        Button("导入签名证书") { showImport = true }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    }
                }
            } else {
                Section {
                    LabeledContent("证书", value: "\(certificateCount) 张 · \(store.state.identities.count) 份配置")
                    if let identity = store.activeIdentity { LabeledContent("当前选择", value: identity.profileName) }
                }
                Section {
                    ForEach(store.state.identities) { identity in
                        HStack(spacing: 12) {
                            Button { store.selectIdentity(identity.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: store.state.activeIdentityID == identity.id ? "checkmark.circle.fill" : "circle").foregroundStyle(store.state.activeIdentityID == identity.id ? Palette.accent : .secondary)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(identity.profileName).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary).lineLimit(2)
                                        Text("\(identity.teamID) · \(identity.isExpired ? "已过期" : "剩余 \(identity.daysRemaining) 天")").font(.caption).foregroundStyle(Color.secondary)
                                        Text(identity.applicationIdentifier).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle)
                                        Text("指纹 \(identity.fingerprint.prefix(12).uppercased())").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.tertiaryText)
                                    }
                                    Spacer(minLength: 0)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { permissionsIdentity = identity } label: { Image(systemName: "list.bullet.rectangle").frame(width: 32, height: 44) }.buttonStyle(.plain).accessibilityLabel("查看证书权限").accessibilityIdentifier("identity.permissions")
                            Button(role: .destructive) { pendingDelete = identity } label: { Image(systemName: "trash").font(.subheadline) }.buttonStyle(.plain).accessibilityLabel("删除 \(identity.profileName)")
                        }.padding(.vertical, 5)
                    }
                } header: { Text("签名配置") } footer: { Text("选择默认签名证书；各应用仍可在签名配置中单独选择。") }
            }
        }.scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle("证书管理").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { showImport = true } label: { Image(systemName: "plus") }.accessibilityLabel("导入签名证书").accessibilityIdentifier("certificates.import") } }
            .sheet(isPresented: $showImport) { IdentityImportSheet() }
            .navigationDestination(item: $permissionsIdentity) { CertificatePermissionsView(identity: $0) }
            .confirmationDialog("移除这份证书？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("移除证书和密码", role: .destructive) { if let pendingDelete { store.deleteIdentity(pendingDelete.id) }; pendingDelete = nil }
            } message: { Text("已导出的 IPA 会保留。容器下次启动需要可用的签名证书。") }
    }
}

struct IdentityImportSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var p12: URL?
    @State private var profile: URL?
    @State private var password = ""
    @State private var importP12 = true
    @State private var showPicker = false
    @State private var pickerError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    fileButton("P12 证书", value: p12?.lastPathComponent, symbol: "key.horizontal") { importP12 = true; showPicker = true }
                    SecureField("证书密码（可以为空）", text: $password).textContentType(.password).autocorrectionDisabled().accessibilityIdentifier("identity.password")
                } header: { Text("签名证书") }
                Section {
                    fileButton("描述文件", value: profile?.lastPathComponent, symbol: "doc.badge.gearshape") { importP12 = false; showPicker = true }
                } header: { Text("Mobileprovision") } footer: { Text("将自动核对证书、团队、有效期以及描述文件中的开发者证书。") }
                Section {
                    Label("密码保存在此设备的钥匙串中", systemImage: "lock.shield").font(.system(size: 13)).foregroundStyle(Color.secondary)
                    Text("容器运行请使用为 Retools 签名的同一份证书，并在设置中完成 JIT-less 检测。").font(.system(size: 13)).foregroundStyle(Color.secondary)
                }
                Section {
                    Button("校验并保存") {
                        guard let p12, let profile else { return }
                        store.importIdentity(p12: p12, profile: profile, password: password); password = ""; dismiss()
                    }.disabled(p12 == nil || profile == nil || store.isWorking).fontWeight(.semibold).accessibilityIdentifier("identity.save")
                }
            }.scrollContentBackground(.hidden).ambientBackground()
                .navigationTitle("导入签名证书").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .sheet(isPresented: $showPicker) {
                    DocumentImportPicker(isPresented: $showPicker) { result in
                        switch result { case .success(let url): if importP12 { p12 = url } else { profile = url }; case .failure(let error): pickerError = error.localizedDescription }
                    }
                }.alert("无法读取文件", isPresented: Binding(get: { pickerError != nil }, set: { if !$0 { pickerError = nil } })) { Button("知道了", role: .cancel) {} } message: { Text(pickerError ?? "") }
        }
    }
    private func fileButton(_ title: String, value: String?, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: symbol).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(Color.primary)
                    Text(value ?? "从文件中选择").font(.system(size: 12)).foregroundStyle(Color.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: value == nil ? "plus.circle" : "checkmark.circle.fill")
            }.padding(.vertical, 5)
        }
    }
}
