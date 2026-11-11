import SwiftUI

struct AppleVerificationSettingsView: View {
    @EnvironmentObject private var renewal: RenewalController
    @State private var showReset = false
    private var preset: Binding<String> {
        Binding(get: {
            switch renewal.settings.anisetteURL {
            case AppleLoginConfiguration.defaultAnisetteURL: return "new"
            case AppleLoginConfiguration.legacyAnisetteURL: return "legacy"
            default: return "custom"
            }
        }, set: { value in
            if value == "new" { renewal.settings.anisetteURL = AppleLoginConfiguration.defaultAnisetteURL }
            else if value == "legacy" { renewal.settings.anisetteURL = AppleLoginConfiguration.legacyAnisetteURL }
            else { renewal.settings.anisetteURL = "https://" }
            renewal.appleServiceVerified = false; renewal.appleServiceResult = "服务已更改，请同步并检测"
        })
    }
    var body: some View {
        Form {
            Section {
                Picker("验证服务器", selection: preset) {
                    Text("SideStore（新）").tag("new")
                    Text("SideStore（原）").tag("legacy")
                    Text("自定义 HTTPS 服务").tag("custom")
                }
                TextField("HTTPS 地址", text: $renewal.settings.anisetteURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("apple.anisette")
                    .onChange(of: renewal.settings.anisetteURL) { _, _ in renewal.appleServiceVerified = false }
                Button("同步客户端信息并检测") { renewal.checkAppleService() }.accessibilityIdentifier("apple.syncClient")
                Label(renewal.appleServiceResult, systemImage: renewal.appleServiceVerified ? "checkmark.circle.fill" : "network").font(.footnote).foregroundStyle(renewal.appleServiceVerified ? .green : .secondary)
            } header: { Text("Anisette 验证服务") } footer: {
                Text("固定使用你选择的服务器。更换服务器后会重新生成对应的验证数据，签名私钥与设备配对记录保留。")
            }
            if !renewal.anisetteClientInfo.isEmpty {
                Section {
                    LabeledContent("来源", value: renewal.settings.anisetteURL)
                    Text(renewal.anisetteClientInfo).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    Text(renewal.anisetteUserAgent).font(.system(.footnote, design: .monospaced)).foregroundStyle(Color.secondary).textSelection(.enabled)
                } header: { Text("服务器客户端信息") } footer: { Text("客户端信息与 User-Agent 成对从同一服务器读取，用于保持设备验证配置一致。") }
            }
            Section {
                Button("重置验证数据并重新登录", role: .destructive) { showReset = true }
            } footer: { Text("清理缓存的 Anisette 和 Apple 登录会话；保留证书私钥、IPA、容器数据及设备配对。") }
            Section {
                NavigationLink("登录诊断记录") { AuthDiagnosticView() }.accessibilityIdentifier("apple.diagnostics")
            }
            if renewal.isWorking { Section { HStack { ProgressView(); Text(renewal.status) } } }
        }
        .scrollContentBackground(.hidden).ambientBackground().navigationTitle("验证服务与诊断").navigationBarTitleDisplayMode(.inline)
        .disabled(renewal.isWorking)
        .onDisappear { renewal.save() }
        .confirmationDialog("重置验证数据？", isPresented: $showReset, titleVisibility: .visible) {
            Button("重置并重新登录", role: .destructive) { renewal.resetAnisette() }
        } message: { Text("需要再次登录 Apple ID。已有签名私钥和设备配对记录会保留。") }
    }
}

struct AuthDiagnosticView: View {
    @State private var entries = AuthDiagnostics.entries()
    var body: some View {
        List {
            if entries.isEmpty { Text("尚无登录诊断记录").foregroundStyle(Color.secondary) }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(entry.stage).font(.headline); Spacer(); Text(entry.date, style: .time).font(.caption).foregroundStyle(Color.secondary) }
                    Text(entry.message).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }.padding(.vertical, 5)
            }
        }.scrollContentBackground(.hidden).ambientBackground().navigationTitle("诊断记录").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("刷新") { entries = AuthDiagnostics.entries() } }
    }
}
