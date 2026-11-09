import SwiftUI
import RetoolsNative

struct ContainerRuntimeSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var renewal: RenewalController
    @AppStorage("RetoolsJITProvider") private var jitProvider = "loopback"
    @AppStorage("RetoolsFloatingControlsEnabled") private var floatingControls = true
    private var checkTitle: String {
        if store.containerMode == .jitless { return "检测免 JIT" }
        return jitProvider == "external" ? "检查外部 JIT 状态" : "启用 JIT"
    }
    /// 容器签名证书：免 JIT 必需；iOS 26 起 JIT 模式也会先用它签名应用。
    private var signingSection: some View {
        Section {
            Picker("容器签名证书", selection: Binding(get: { store.state.validHostIdentityID }, set: { store.selectHostIdentity($0) })) {
                Text("跟随当前签名证书").tag(Optional<UUID>.none)
                ForEach(store.state.identities) { identity in Text(identity.profileName).tag(Optional(identity.id)) }
            }.accessibilityIdentifier("runtime.identity")
            LabeledContent("当前证书", value: store.hostIdentity.map { $0.isExpired ? "已过期" : $0.profileName } ?? "未配置")
            NavigationLink { DevelopmentSigningView() } label: { Label("Apple ID 开发签名", systemImage: "person.crop.circle.badge.checkmark") }
        } header: { Text("签名配置") } footer: { Text("需与 Retools 同一团队（\(RTNative.hostTeamIdentifier() ?? "未检测到")）。") }
    }
    var body: some View {
        Form {
            Section {
                Picker("运行模式", selection: $store.containerMode) {
                    ForEach(ContainerExecutionMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("runtime.mode")
                if store.containerMode == .jitless {
                    Text("用证书签名后运行，无需调试器。").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(WorkspaceService.jitRequiresSignedGuest ? "为新进程启用 JIT；应用仍会先用容器证书签名。" : "每次运行容器都会为新进程启用 JIT。").font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("运行模式") }

            if store.containerMode == .jitless { signingSection }
            if store.containerMode == .jit {
                Section {
                    Picker("JIT 来源", selection: $jitProvider) {
                        Text("配对回环").tag("loopback")
                        Text("外部工具").tag("external")
                    }.pickerStyle(.segmented).accessibilityIdentifier("runtime.jitProvider")
                    if jitProvider == "loopback" {
                        NavigationLink { DeviceConnectionView() } label: {
                            LabeledContent("设备配对与连接", value: renewal.connectionSummary)
                        }.accessibilityIdentifier("runtime.connection")
                        Text(renewal.deviceConnectionStatus).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("在外部工具中启用 JIT 后回到这里检查；每次运行容器需重新启用。").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("JIT 连接") } footer: {
                    if jitProvider == "loopback" { Text("需保持外部代理回环连接。") }
                }
            }

            Section {
                LabeledContent("当前状态", value: store.runtimeStatusTitle).accessibilityIdentifier("runtime.status")
                Button(checkTitle) { store.diagnose(presentError: false) }
                    .disabled(store.isWorking || renewal.isWorking).accessibilityIdentifier("runtime.check")
                if store.isCheckingRuntime { HStack { ProgressView(); Text(store.workLabel).font(.footnote) } }
                if let issue = store.runtimeIssue {
                    Label { Text(issue).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.circle") }
                        .font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("runtime.error")
                }
                NavigationLink { AuthDiagnosticView() } label: { Label("运行诊断记录", systemImage: "doc.text.magnifyingglass") }
            } header: { Text(store.containerMode == .jitless ? "签名加载检测" : "JIT 启用") } footer: {
                Text(store.containerMode == .jitless ? "检测结果会保存；更换证书、证书过期或 Retools 重签后，运行前会自动重新检测。" : "以当前进程的实际 JIT 状态为准。")
            }
            if store.containerMode == .jit, WorkspaceService.jitRequiresSignedGuest { signingSection }

            Section {
                Toggle("悬浮切换侧栏", isOn: $floatingControls).accessibilityIdentifier("runtime.floatingControls")
                NavigationLink("侧栏外观与交互") { FloatingDockSettingsView() }.disabled(!floatingControls)
            } header: { Text("悬浮侧栏") }
            Section {
                LabeledContent("宿主开发签名", value: RTNative.hostAllowsDebugging() ? "已就绪" : "需要配置")
                if !RTNative.hostAllowsDebugging() {
                    NavigationLink("配置 Apple ID 开发签名") { DevelopmentSigningView() }
                }
                DisclosureGroup("设备与签名详情") {
                    LabeledContent("设备", value: store.isSimulator ? "iOS 模拟器" : UIDevice.current.model)
                    LabeledContent("系统版本", value: UIDevice.current.systemVersion)
                    LabeledContent("宿主团队", value: RTNative.hostTeamIdentifier() ?? "未检测到")
                    LabeledContent("调试权限", value: RTNative.hostAllowsDebugging() ? "已授权" : "未授权")
                }
            } header: { Text("宿主环境") }
        }
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle("容器运行设置").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
        .disabled(store.isWorking || renewal.isWorking)
        .onChange(of: jitProvider) { _, _ in store.invalidateRuntimeCheck() }
        .task { store.checkRuntimeIfNeeded() }
    }
}
