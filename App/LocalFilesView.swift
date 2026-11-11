import SwiftUI

/// 本机目录发现与浏览不发起设备配对、回环或镜像请求。
struct LocalFilesView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var tools = DeviceToolsStore.shared
    @StateObject private var catalog = LocalFileCatalog()
    @State private var area: LocalFileArea? = nil
    @State private var query = ""
    @State private var input = ""
    @State private var selected: LocalFileTarget?
    @State private var showDirectory = false
    @State private var error: String?

    private var filtered: [LocalFileContainer] {
        catalog.containers.filter {
            (area == nil || $0.area == area) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.identifier.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        List {
            ToolPageIntro(tool: .files, title: "文件与容器", detail: "编辑文本、导入文件与管理目录。修改前自动备份原文件。")
            Section {
                ToolMetrics(items: [("已发现容器", "\(catalog.containers.count)"), ("访问方式", "本机读写")])
                NavigationLink { LocalFileBackupsView() } label: { Label("查看文件备份", systemImage: "clock.arrow.circlepath") }
            }
            Section {
                TextField("粘贴完整目录路径", text: $input, axis: .vertical)
                    .font(.footnote.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("localFiles.path")
                Button { openDirectory() } label: { ToolActionLabel(title: "打开目录", symbol: "folder.badge.gearshape") }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("localFiles.open")
                if let error { Text(error).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("localFiles.error") }
            } header: { Text("按路径打开") } footer: {
                Text("输入具体容器路径，可附带子目录。例如 /var/mobile/Containers/Data/Application/<UUID>/Documents。兼容的 iOS 27 也可打开 App Group 总目录。")
            }
            Section {
                Picker("目录类别", selection: $area) {
                    Text("全部").tag(nil as LocalFileArea?)
                    ForEach(LocalFileArea.allCases) { Text($0.title).tag(Optional($0)) }
                }.accessibilityIdentifier("localFiles.area")
                if catalog.loading { HStack { ProgressView(); Text("正在本机发现目录…").font(.footnote) } }
                ForEach(filtered) { item in
                    if let target = try? LocalFileTarget(item.path) {
                        NavigationLink { DeviceContainerBrowser(app: localApp(target, name: item.title), path: "/", mode: .local) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).lineLimit(2)
                                Text(item.area.title).font(.caption).foregroundStyle(Color.secondary)
                                Text(item.path).font(.caption2.monospaced()).foregroundStyle(Palette.tertiaryText).lineLimit(2)
                            }
                        }
                    }
                }
                if catalog.scanning {
                    ProgressView(value: Double(min(catalog.cursor, catalog.upperBound)), total: Double(max(1, catalog.upperBound)))
                    Button("停止发现") { catalog.stopScan() }
                } else {
                    Button(catalog.cursor > 0 && !catalog.scanComplete ? "继续发现目录" : "扫描更多容器") { catalog.startScan() }
                        .disabled(catalog.loading || LocalFileAccessService.unavailableReason != nil).accessibilityIdentifier("localFiles.scan")
                }
                if let message = catalog.message { Text(message).font(.footnote).foregroundStyle(Color.secondary) }
            } header: { Text("容器目录 · \(filtered.count)") } footer: {
                Text(catalog.scanComplete ? "已扫描本次范围，系统仍可能隐藏部分目录。缓存目录在应用重装后可能失效。" : "本机接口可能只返回部分目录。扫描可补充目录，首次可能耗时较长，可随时停止；也可直接输入路径。")
            }
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                Section("iOS 27 目录入口") {
                    directoryLink("App Group 总目录", path: LocalFileTarget.appGroupParent)
                    directoryLink("系统数据", path: "/var/containers/Data/System")
                    directoryLink("系统分析与日志", path: "/var/containers/Shared/SystemGroup/systemgroup.com.apple.osanalytics")
                    directoryLink("设备配置", path: "/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles")
                }
            }
            Section {
                if let reason = LocalFileAccessService.unavailableReason {
                    Label(reason, systemImage: "info.circle").font(.footnote).foregroundStyle(Color.secondary)
                        .accessibilityIdentifier("localFiles.availability")
                }
                NavigationLink { DevelopmentSigningView() } label: { Label("文件访问授权", systemImage: "checkmark.shield") }
            } header: { Text("访问条件") } footer: {
                Text("需要系统兼容且当前安装包获得文件工具专用 App Group 授权。目录访问仍受系统权限限制。")
            }
        }
        .toolListStyle()
        .searchable(text: $query, prompt: "名称、标识或路径")
        .navigationTitle("本机文件").navigationBarTitleDisplayMode(.inline)
        .task {
            catalog.merge(tools.apps.flatMap { app -> [LocalFileContainer] in
                let data = app.dataContainerPath.flatMap { LocalFileContainer.parse(["path": $0, "name": app.name, "identifier": app.bundleID]) }
                let groups = DeviceFileAccess.sharedRoots(for: app).compactMap { LocalFileContainer.parse(["path": $0.path, "identifier": $0.title]) }
                return [data].compactMap { $0 } + groups
            })
            await catalog.discover()
        }
        .refreshable { await catalog.discover() }
        .onDisappear { catalog.stopScan() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { catalog.stopScan() } }
        .navigationDestination(isPresented: $showDirectory) {
            if let selected {
                DeviceContainerBrowser(app: DeviceFileAccess.localApp(for: selected), path: selected.components.isEmpty ? "/" : "/" + selected.components.joined(separator: "/"), mode: .local)
            }
        }
    }

    private func localApp(_ target: LocalFileTarget, name: String) -> DeviceInstalledApp {
        var app = DeviceFileAccess.localApp(for: target); app.name = name; return app
    }
    @ViewBuilder private func directoryLink(_ title: String, path: String) -> some View {
        if let target = try? LocalFileTarget(path) {
            NavigationLink(title) { DeviceContainerBrowser(app: localApp(target, name: title), path: "/", mode: .local) }
        }
    }

    private func openDirectory() {
        do {
            selected = try LocalFileTarget(input.trimmingCharacters(in: .whitespacesAndNewlines))
            error = nil; showDirectory = true
        } catch { self.error = error.localizedDescription }
    }
}
