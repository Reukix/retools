import SwiftUI

/// 团队的 iOS 开发证书，与 SideStore 的证书管理相同：查看每张证书由谁创建、在本机签过什么，并可撤销。
/// 撤销后用这张证书签名的应用会立即无法打开，所以每次都需要确认，撤销 Retools 正在使用的证书时额外警告。
struct AppleCertificatesView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var renewal = RenewalController.shared
    let account: RenewalAccount
    @State private var list: AppleCertificateList?
    @State private var loading = false
    @State private var failure: String?
    @State private var revoking: AppleCertificate?
    @State private var working = false
    @State private var notice: String?

    var body: some View {
        List {
            if let list {
                Section {
                    LabeledContent("证书", value: list.maximum.map { "\(list.certificates.count) / \($0)" } ?? "\(list.certificates.count)")
                    Text(account.email + " · " + account.teamID).font(.caption).foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle)
                } footer: {
                    Text("开发证书数量有上限（免费账号通常为 2 张），达到上限后无法再取得新证书。撤销后，用这张证书签名的应用会立即无法打开，需要重新签名安装。")
                }
                Section {
                    if list.certificates.isEmpty { Text("没有开发证书").foregroundStyle(Color.secondary) }
                    ForEach(list.certificates) { certificate in
                        CertificateRow(certificate: certificate, usage: usage(of: certificate))
                            .swipeActions { Button("撤销", systemImage: "xmark.seal") { revoking = certificate }.tint(.red) }
                            .contextMenu {
                                Button("复制序列号", systemImage: "doc.on.doc") { UIPasteboard.general.string = certificate.serialNumber }
                                Button("撤销证书", systemImage: "xmark.seal", role: .destructive) { revoking = certificate }
                            }
                    }
                } header: { Text("开发证书 · \(list.certificates.count)") } footer: { Text("左滑或长按证书可撤销。") }
            } else if let failure {
                Section { Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            } else {
                Section { HStack { ProgressView(); Text("正在读取证书…").foregroundStyle(Color.secondary) } }
            }
        }
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle("开发证书").navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .toolbar { ToolbarItem(placement: .primaryAction) { if loading || working { ProgressView() } } }
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(revoking.map { "撤销「\($0.machineName ?? $0.name)」？" } ?? "", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
            Button("撤销证书", role: .destructive) { if let target = revoking { Task { await revoke(target) } }; revoking = nil }
        } message: { Text(revoking.map(warning(for:)) ?? "") }
        .alert("开发证书", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("好", role: .cancel) {} } message: { Text(notice ?? "") }
    }

    /// 本机用这张证书签名的内容：Retools 自身，以及已安装的续签应用。
    private func usage(of certificate: AppleCertificate) -> CertificateUsage {
        var usage = CertificateUsage()
        guard let fingerprint = certificate.fingerprint else { return usage }
        usage.runsRetools = ProfileRefresh.runningCertificateFingerprint == fingerprint
        for (key, signature) in renewal.settings.installedSignatures where ProfileRefresh.fingerprint(signature.certificate) == fingerprint {
            if let package = store.state.packages.first(where: { $0.id.uuidString == key }) { usage.apps.append(package.name) }
        }
        return usage
    }

    private func warning(for certificate: AppleCertificate) -> String {
        let usage = usage(of: certificate)
        var parts: [String] = []
        if usage.runsRetools { parts.append("这是 Retools 当前正在使用的证书。撤销后 Retools 会立即无法打开，需要在电脑上重新安装，或先换用其他证书签名 Retools。") }
        if !usage.apps.isEmpty { parts.append("以下已安装的应用会无法打开：" + usage.apps.joined(separator: "、") + "。") }
        parts.append("用这张证书签名的应用都会失效，此操作无法撤回。")
        return parts.joined(separator: "\n\n")
    }

    private func load() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do { list = try await renewal.certificates(for: account); failure = nil }
        catch { failure = error.localizedDescription }
    }

    private func revoke(_ certificate: AppleCertificate) async {
        working = true; defer { working = false }
        do {
            try await renewal.revokeCertificate(certificate, account: account)
            notice = "已撤销「\(certificate.machineName ?? certificate.name)」。下次签名或续签会自动申请新证书。"
            await load()
        } catch { notice = "撤销失败：" + error.localizedDescription }
    }
}

/// 本机用某张证书签名的内容。
private struct CertificateUsage { var runsRetools = false; var apps: [String] = [] }

private struct CertificateRow: View {
    let certificate: AppleCertificate
    let usage: CertificateUsage
    private var daysLeft: Int? { certificate.expiresAt.map { Int(ceil($0.timeIntervalSinceNow / 86_400)) } }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: usage.runsRetools ? "checkmark.seal.fill" : "seal").font(.title3)
                .foregroundStyle(usage.runsRetools ? Palette.accent : Color.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(certificate.machineName ?? certificate.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(certificate.serialNumber).font(.caption.monospaced()).foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                HStack(spacing: 6) {
                    if usage.runsRetools { StatusPill(title: "Retools 正在使用") }
                    if certificate.machineName == "Retools" && !usage.runsRetools { StatusPill(title: "Retools 创建", color: .secondary) }
                }
                if !usage.apps.isEmpty { Text("已安装：" + usage.apps.joined(separator: "、")).font(.caption).foregroundStyle(Color.secondary).lineLimit(2) }
            }
            Spacer(minLength: 6)
            if let daysLeft {
                VStack(spacing: 1) {
                    Text(daysLeft <= 0 ? "已过期" : "\(daysLeft)").font(.headline.monospacedDigit()).foregroundStyle(daysLeft <= 7 ? .orange : .primary)
                    if daysLeft > 0 { Text("天").font(.caption2).foregroundStyle(Color.secondary) }
                }.frame(minWidth: 40)
            }
        }.padding(.vertical, 2)
    }
}
