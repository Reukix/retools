import SwiftUI
import UserNotifications
import RetoolsNative

struct SettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var renewal: RenewalController
    @State private var showNotices = false
    @AppStorage("RetoolsAIEnabled") private var aiEnabled = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        BrandMark(size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Retools").font(.title2.weight(.bold))
                            Text("签名 · 容器 · 续签工作台").font(.subheadline).foregroundStyle(Color.secondary)
                            HStack(spacing: 6) {
                                StatusPill(title: "v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")")
                            }.padding(.top, 2)
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 6).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                        .accessibilityElement(children: .combine)
                }
                Section {
                    NavigationLink { CertificateManagerView() } label: {
                        row("证书管理", symbol: "checkmark.seal") { value(store.state.identities.isEmpty ? "未导入" : "\(store.state.identities.count)") }
                    }.accessibilityIdentifier("settings.certificates")
                    NavigationLink { RenewalView() } label: {
                        row("Apple ID 与自动续签", symbol: "arrow.triangle.2.circlepath") {
                            if renewal.settings.accounts.isEmpty { value("未登录") }
                            else if let expiry = renewal.hostExpiry { ExpiryBadge(expiry: expiry) }
                            else if !renewal.settings.enabled { value("已关闭") }
                            else if renewal.autoRenewBlocker != nil { Text("已暂停").foregroundStyle(.orange) }
                            else { value("已开启", highlight: true) }
                        }
                    }.accessibilityIdentifier("settings.renewal")
                    NavigationLink { DeviceConnectionView() } label: {
                        row("设备配对与连接", symbol: "iphone.radiowaves.left.and.right") {
                            connectionValue
                        }
                    }.accessibilityIdentifier("settings.deviceConnection")
                    NavigationLink { DevelopmentSigningView() } label: {
                        row("Apple ID 开发签名", symbol: "person.crop.circle.badge.checkmark") {
                            value(RTNative.hostAllowsDebugging() ? "已启用" : "未配置", highlight: RTNative.hostAllowsDebugging())
                        }
                    }.accessibilityIdentifier("settings.developmentSigning")
                } header: { Text("账号与设备") }
                Section {
                    NavigationLink { DecryptionCacheView() } label: {
                        row("缓存清理", symbol: "trash") { EmptyView() }
                    }.accessibilityIdentifier("settings.cache")
                    NavigationLink { ContainerRuntimeSettingsView() } label: {
                        row("容器运行", symbol: "shippingbox") { value(store.containerMode.title) }
                    }.accessibilityIdentifier("settings.runtime")
                    NavigationLink { FloatingDockSettingsView() } label: {
                        row("悬浮切换侧栏", symbol: "sidebar.right") { EmptyView() }
                    }.accessibilityIdentifier("settings.dock")
                    NavigationLink { ShortcutsSettingsView() } label: {
                        row("快捷指令", symbol: "square.stack.3d.up") { EmptyView() }
                    }.accessibilityIdentifier("settings.shortcuts")
                } header: { Text("功能") }
                Section {
                    Toggle(isOn: $aiEnabled) { row("AI 对话", symbol: "bubble.left.and.bubble.right") { EmptyView() } }.accessibilityIdentifier("settings.aiEnabled")
                    if aiEnabled {
                        NavigationLink { AISettingsView() } label: {
                            row("AI 接口", symbol: "slider.horizontal.3") { EmptyView() }
                        }.accessibilityIdentifier("settings.ai")
                    }
                } header: { Text("实验功能") }
                Section {
                    NavigationLink { AuthDiagnosticView() } label: {
                        row("运行诊断记录", symbol: "doc.text.magnifyingglass") { EmptyView() }
                    }.accessibilityIdentifier("settings.runtimeDiagnostics")
                    LabeledContent("已用空间", value: ByteCountFormatter.string(fromByteCount: store.storageBytes, countStyle: .file))
                    LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
                    DisclosureGroup("应用信息") {
                        InfoRow(title: "安装标识", value: Bundle.main.bundleIdentifier ?? "dev.retools.ios")
                        InfoRow(title: "数据模式", value: RTNative.usesPrivateSandbox() ? "独立沙盒" : "共享容器")
                        Link("Retools 源码", destination: URL(string: "https://github.com/Reukix/retools")!)
                        Link("LiveContainer 源码", destination: URL(string: "https://github.com/LiveContainer/LiveContainer/tree/9108ae624ea001f7d7696d48407f890b48fa2653")!)
                    }
                    Button("开源许可与致谢") { showNotices = true }
                } header: { Text("关于") } footer: {
                    Text("IPA 和签名输出在「文件 → 我的 iPhone → Retools」。")
                }
            }
            .scrollContentBackground(.hidden).ambientBackground()
            .navigationTitle("设置")
            .navigationDestination(isPresented: $store.showDevelopmentSigning) { DevelopmentSigningView() }
            .navigationDestination(isPresented: $store.showDeviceConnection) { DeviceConnectionView() }
            .sheet(isPresented: $showNotices) { NoticesView() }
            .task { await renewal.verifyConnectionIfNeeded() }
        }
    }
    private func row<Trailing: View>(_ title: String, symbol: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Palette.accent).frame(width: 28).accessibilityHidden(true)
            Text(title).foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            trailing()
        }.padding(.vertical, 3)
    }
    @ViewBuilder private var connectionValue: some View {
        if renewal.isVerifyingConnection { HStack(spacing: 6) { ProgressView().controlSize(.mini); value(renewal.connectionSummary) } }
        else if renewal.connectionCheckFailed { Text(renewal.connectionSummary).foregroundStyle(.orange) }
        else { value(renewal.connectionSummary, highlight: renewal.connectionVerified) }
    }
    private func value(_ text: String, highlight: Bool = false) -> some View {
        Text(text).foregroundStyle(highlight ? Color.green : Color.secondary).monospacedDigit()
    }
}

struct ShortcutsSettingsView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var renewal: RenewalController
    @State private var notificationsAllowed: Bool?
    var body: some View {
        Form {
            Section {
                Label("续签全部应用", systemImage: "arrow.triangle.2.circlepath")
                Text("在后台运行，不会打开 Retools；锁屏时也能执行。各应用使用自己绑定的账号与团队。").font(.footnote).foregroundStyle(Color.secondary)
            }
            Section {
                Label("安装 IPA", systemImage: "square.and.arrow.down")
                Text("传入 IPA 文件，选择签名账号后签名并安装。会打开 Retools。").font(.footnote).foregroundStyle(Color.secondary)
            }
            Section {
                HelpStep(number: "1", title: "新建个人自动化", detail: "快捷指令 → 自动化 → 新建 → 特定时间，例如每天 0:00。")
                HelpStep(number: "2", title: "选择「立即运行」", detail: "关闭运行前询问，这样无需点击确认。")
                HelpStep(number: "3", title: "添加「续签全部应用」", detail: "搜索 Retools，添加这个动作即可。")
                Button("打开快捷指令") { openURL(URL(string: "shortcuts://")!) }
            } header: { Text("每天自动续签") }
            Section {
                requirement("已登录 Apple ID 并选择续签目标", ok: renewal.settings.accounts.contains(where: \.isReady) && (renewal.settings.renewHost || !renewal.settings.packageIDs.isEmpty))
                requirement("已配对这台 iPhone", ok: renewal.settings.hasPairing)
                requirement("续签结果通知", ok: notificationsAllowed == true)
                if notificationsAllowed != true {
                    Button("允许续签结果通知") { Task { notificationsAllowed = await RenewalNotice.requestAuthorization() } }
                        .accessibilityIdentifier("shortcuts.notifications")
                }
            } header: { Text("运行条件") } footer: {
                Text("运行时外部代理的回环（10.7.0.1）需要保持开启；设备重启后需先解锁一次。Retools 正在运行容器应用时无法在后台续签。")
            }
        }
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle("快捷指令").navigationBarTitleDisplayMode(.inline)
        .task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            notificationsAllowed = [.authorized, .provisional, .ephemeral].contains(status)
        }
    }
    private func requirement(_ title: String, ok: Bool) -> some View {
        Label { Text(title) } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Color.green : Color.secondary)
        }
    }
}

struct NoticesView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }.navigationTitle("开源许可").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
    private var text: String {
        guard let url = Bundle(for: ResourceAnchor.self).url(forResource: "OpenSourceNotices", withExtension: "txt"), let content = try? String(contentsOf: url, encoding: .utf8) else { return "Retools includes LiveContainer (AGPL-3.0), litehook (MIT), zsign (MIT), ZIPFoundation (MIT), and OpenSSL (Apache-2.0). Source: https://github.com/Reukix/retools" }
        return content
    }
}
private final class ResourceAnchor: NSObject {}
