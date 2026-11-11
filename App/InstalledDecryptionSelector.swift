import SwiftUI
import RetoolsNative

/// 选择已安装的用户应用。列表发现不挂载镜像，也不提前获取文件权限。
struct InstalledDecryptionSelector: View {
    @EnvironmentObject private var renewal: RenewalController
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tools = DeviceToolsStore.shared
    let onSelect: (DeviceInstalledApp) -> Void
    @State private var apps: [DeviceInstalledApp] = []
    @State private var query = ""
    @State private var loading = false
    @State private var issue: String?
    private var visible: [DeviceInstalledApp] {
        apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List {
                ToolPageIntro(tool: .decryption, title: "选择手机上的应用", detail: "尝试读取所选应用的安装包。系统不允许读取时，可按该应用从商店获取原始包。")
                if loading { Section { HStack { ProgressView(); Text("读取应用列表…") } } }
                Section("用户应用 · \(visible.count)") {
                    ForEach(visible) { app in
                        Button { onSelect(app); dismiss() } label: {
                            HStack(spacing: 12) {
                                DeviceAppIcon(bundleID: app.bundleID, size: 40)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name).font(.body.weight(.medium)).foregroundStyle(Color.primary)
                                    Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(Color.secondary).lineLimit(1)
                                    if !app.version.isEmpty { Text("已安装 v" + app.version).font(.caption).foregroundStyle(Color.secondary) }
                                }
                            }.padding(.vertical, 3)
                        }.accessibilityIdentifier("decryption.installed.app." + app.bundleID)
                    }
                }
                if !loading, visible.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "未发现可选择的应用" : "没有匹配的应用", systemImage: "app.dashed", description: Text("可通过设备连接补充应用列表。"))
                }
                Section {
                    if let issue { Text(issue).font(.footnote).foregroundStyle(.orange).textSelection(.enabled) }
                    Button("通过设备连接读取完整列表", systemImage: "network") { Task { await readDeviceList() } }.disabled(loading)
                    NavigationLink("配置配对与连接") { DeviceConnectionView() }
                } footer: { Text("这里的设备连接只读取应用列表，不挂载开发者镜像。") }
            }.toolListStyle()
            .searchable(text: $query, prompt: "应用名称或 Bundle ID")
            .navigationTitle("本机已安装").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await readLocalList() }
        }.tint(Palette.accent)
    }
    private func merge(_ values: [DeviceInstalledApp]) {
        var combined = Dictionary(apps.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        for app in values { combined[app.bundleID] = app }
        apps = combined.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func readLocalList() async {
        loading = true; defer { loading = false }
        merge(tools.apps)
        do {
            let values = try await Task.detached { try RTNative.localInstalledApplications().compactMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }.compactMap(DeviceInstalledApp.parse) }.value
            merge(values)
        } catch { issue = error.localizedDescription }
        #if targetEnvironment(simulator)
        await tools.loadApps(renewal: renewal); merge(tools.apps)
        issue = "模拟器显示示例列表，安装包读取需要真机。"
        #endif
    }
    private func readDeviceList() async {
        loading = true; defer { loading = false }
        await tools.loadApps(renewal: renewal)
        merge(tools.apps)
        if case .failed(let message) = tools.appsPhase { issue = message } else { issue = nil }
    }
}
