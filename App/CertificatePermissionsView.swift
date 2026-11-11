import SwiftUI

struct CertificatePermissionsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let identity: SigningIdentity
    @State private var permissions: [CertificatePermission] = []
    @State private var error: String?
    @State private var loading = true
    @State private var search = ""
    private var filtered: [CertificatePermission] {
        search.isEmpty ? permissions : permissions.filter { $0.id.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            Section {
                LabeledContent("证书", value: identity.name)
                LabeledContent("团队", value: identity.teamID)
                LabeledContent("描述文件", value: identity.profileName)
                LabeledContent("有效期", value: identity.expiresAt.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("应用签名身份", value: identity.applicationIdentifier)
                LabeledContent("证书 SHA-256") { Text(identity.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }
            Section {
                if loading { ProgressView("正在读取权限…") }
                else if let error { Text(error).foregroundStyle(.red) }
                else if filtered.isEmpty { Text(search.isEmpty ? "描述文件没有声明权限" : "没有匹配的权限").foregroundStyle(Color.secondary) }
                ForEach(filtered) { permission in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(permission.title).font(.headline)
                            Spacer()
                            if let enabled = permission.enabled { Image(systemName: enabled ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(enabled ? .green : .secondary) }
                        }
                        if permission.title != permission.id { Text(permission.id).font(.system(.caption, design: .monospaced)).foregroundStyle(Color.secondary).textSelection(.enabled) }
                        Text(permission.value).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }
            } header: { Text("授权权限 · \(permissions.count) 项") } footer: {
                Text("权限来自这份签名证书配套的描述文件。安装后的应用只能使用签名实际保留的权限；相机、相册等系统隐私授权仍需在使用时确认。")
            }
        }.scrollContentBackground(.hidden).ambientBackground().navigationTitle("证书权限").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜索权限名称或标识")
            .task {
                do { permissions = try await store.service.certificatePermissions(identity.id) }
                catch { self.error = error.localizedDescription }
                loading = false
            }
    }
}
