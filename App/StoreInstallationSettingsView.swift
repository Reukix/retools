import SwiftUI

/// The store reads the workbench's live resources instead of maintaining its own copies.
struct StoreInstallationSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var renewal: RenewalController
    private var certificateCount: Int {
        Set(store.state.identities.map { $0.teamID + ":" + $0.fingerprint.lowercased() }).count
    }
    var body: some View {
        Form {
            Section {
                Label("Retools 设备安装", systemImage: "iphone.and.arrow.forward")
                    .font(.headline).foregroundStyle(Color.primary)
                LabeledContent("设备连接", value: renewal.connectionSummary)
                    .accessibilityIdentifier("storeSettings.connection")
                NavigationLink { DeviceConnectionView() } label: { Label("配对与连接", systemImage: "point.3.connected.trianglepath.dotted") }
                    .accessibilityIdentifier("storeSettings.pairing")
                Button { renewal.testConnection() } label: {
                    HStack {
                        Text("检查连接")
                        Spacer()
                        if renewal.isVerifyingConnection { ProgressView() }
                    }
                }
                .disabled(!renewal.settings.hasPairing || renewal.isVerifyingConnection || renewal.isWorking)
            } header: { Text("安装方式") } footer: {
                Text("直接使用 Retools 已保存的配对与设备连接安装，保留商店许可，无需另行配置本地网站或信任安装证书。")
            }
            Section {
                LabeledContent("已保存", value: "\(certificateCount) 张证书 · \(store.state.identities.count) 份配置")
                    .accessibilityIdentifier("storeSettings.certificates.count")
                ForEach(store.state.identities) { identity in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(identity.profileName).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                            Spacer(minLength: 8)
                            Text(identity.isExpired ? "已过期" : "剩余 \(identity.daysRemaining) 天")
                                .font(.caption).foregroundStyle(Color.secondary)
                        }
                        Text(identity.teamID).font(.caption.monospaced()).foregroundStyle(Color.secondary)
                        if store.state.activeIdentityID == identity.id {
                            Label("默认签名配置", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.secondary)
                        }
                    }.padding(.vertical, 3).accessibilityIdentifier("storeSettings.identity." + identity.id.uuidString)
                }
                NavigationLink { CertificateManagerView() } label: {
                    Label(store.state.identities.isEmpty ? "导入签名证书" : "管理 Retools 证书", systemImage: "checkmark.seal")
                }.accessibilityIdentifier("storeSettings.certificates.manage")
            } header: { Text("Retools 证书") } footer: {
                Text("与 Retools 的证书管理实时同步。商店原始安装包保留原签名；需要重签时，可将下载文件导入应用库并选择这里的证书。")
            }
        }
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle("安装设置").navigationBarTitleDisplayMode(.inline)
        .tint(Palette.accent)
    }
}
