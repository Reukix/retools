import SwiftUI

private func pluginSize(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

struct PluginManagerView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var showImporter = false
    @State private var deleteTarget: PluginRecord?
    @State private var query = ""
    private var filtered: [PluginRecord] { store.state.plugins.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.sourceFileName.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        List {
            ToolPageIntro(tool: .plugins, title: "签名插件库", detail: "导入动态库与资源，在应用详情中选择注入和调整顺序。")
            Section {
                ToolMetrics(items: [("插件", "\(store.state.plugins.count)"), ("动态库", "\(store.state.plugins.reduce(0) { $0 + $1.executablePaths.count })"), ("占用空间", pluginSize(store.state.plugins.reduce(0) { $0 + $1.byteCount }))])
                Button { showImporter = true } label: { ToolActionLabel(title: "导入插件", symbol: "plus.circle.fill") }.accessibilityIdentifier("plugins.import")
            } footer: { Text("支持 .deb 与 .dylib。导入后可检查依赖与包内文件。") }
            Section {
                ForEach(filtered) { plugin in
                    NavigationLink { PluginDetailView(plugin: plugin) } label: {
                        HStack(spacing: 12) {
                            ToolGlyph(symbol: "puzzlepiece.extension.fill", color: WorkspaceTool.plugins.color, size: 42)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(plugin.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                                Text("\(plugin.kind.rawValue.uppercased()) · \(plugin.executablePaths.count) 个动态库 · \(pluginSize(plugin.byteCount))").font(.caption).foregroundStyle(Color.secondary)
                                if let count = plugin.resourceCount { Text("\(count) 个资源文件").font(.caption2).foregroundStyle(Color.secondary) }
                            }
                        }.padding(.vertical, 3)
                    }.swipeActions { Button("移除", role: .destructive) { deleteTarget = plugin } }
                }
                if filtered.isEmpty { ContentUnavailableView(query.isEmpty ? "还没有插件" : "没有匹配的插件", systemImage: "puzzlepiece.extension", description: Text("导入后，在应用详情中配置注入。")) }
            } header: { Text("插件库 · \(store.state.plugins.count)") }
            pluginProgress
        }
        .toolListStyle().navigationTitle("插件管理").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索插件或文件名")
        .disabled(store.isWorking)
        .sheet(isPresented: $showImporter) { importer }
        .confirmationDialog("移除插件？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("移除插件文件", role: .destructive) { if let plugin = deleteTarget { store.deletePlugin(plugin) }; deleteTarget = nil }
        } message: { Text("正在被应用使用的插件需要先取消选择。") }
    }
    @ViewBuilder private var pluginProgress: some View {
        if let error = store.pluginIssue { Section { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("plugins.error") } }
        if store.isWorking { Section { HStack { ProgressView(); Text(store.workLabel).font(.footnote) } } }
    }
    private var importer: some View {
        DocumentImportPicker(isPresented: $showImporter) { result in
            switch result { case .success(let url): store.importPlugin(url); case .failure(let error): store.pluginIssue = error.localizedDescription }
        }
    }
}

struct PluginDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let plugin: PluginRecord
    @State private var details: PluginRecord?
    @State private var files: [String] = []
    @State private var issue: String?
    private var record: PluginRecord { details ?? plugin }
    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    ToolGlyph(symbol: WorkspaceTool.plugins.symbol, color: WorkspaceTool.plugins.color, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.name).font(.headline).foregroundStyle(Color.primary)
                        Text("\(record.executablePaths.count) 个动态库 · " + pluginSize(record.byteCount)).font(.caption).foregroundStyle(Color.secondary)
                    }
                }.padding(.vertical, 5)
                LabeledContent("原文件", value: record.sourceFileName)
                LabeledContent("格式", value: record.kind.rawValue.uppercased())
                LabeledContent("解包大小", value: pluginSize(record.byteCount))
                LabeledContent("导入时间") { Text(record.importedAt, style: .date) }
                LabeledContent("资源文件", value: "\(record.resourceCount ?? 0) 个")
            }
            Section("动态库 · \(record.executablePaths.count)") {
                ForEach(record.binaries ?? []) { binary in
                    NavigationLink { PluginBinaryInformation(binary: binary) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text((binary.path as NSString).lastPathComponent).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary)
                            Text("arm64 · \(pluginSize(binary.byteCount)) · \(binary.dependencies.count) 项依赖").font(.caption).foregroundStyle(Color.secondary)
                        }.padding(.vertical, 3)
                    }
                }
            }
            Section {
                NavigationLink { PluginFileList(files: files, executables: Set(record.executablePaths)) } label: { Label("浏览包内文件（\(files.count)）", systemImage: "folder") }
                DisclosureGroup("SHA-256") { Text(record.fingerprint).font(.caption.monospaced()).textSelection(.enabled) }
            } footer: { Text("动态库和资源会一起复制到目标应用。Debian 包的安装脚本不会执行。") }
            if let issue { Section { Text(issue).foregroundStyle(.red) } }
        }.scrollContentBackground(.hidden).ambientBackground().navigationTitle("插件详情").navigationBarTitleDisplayMode(.inline)
            .task { do { let result = try await store.service.pluginDetails(plugin.id); details = result.0; files = result.1 } catch { issue = error.localizedDescription } }
    }
}

private struct PluginFileList: View {
    let files: [String]
    let executables: Set<String>
    @State private var query = ""
    var body: some View {
        List(files.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { path in
            Label(path, systemImage: executables.contains(path) ? "shippingbox" : "doc").font(.caption.monospaced()).textSelection(.enabled).padding(.vertical, 3)
        }.navigationTitle("包内文件").searchable(text: $query, prompt: "搜索路径")
    }
}

struct PluginBinaryInformation: View {
    let binary: PluginBinary
    var body: some View {
        List { PluginBinarySections(binary: binary) }
            .navigationTitle((binary.path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
    }
}
private struct PluginBinarySections: View {
    let binary: PluginBinary
    var body: some View {
        Section("动态库信息") {
            LabeledContent("架构", value: "arm64")
            LabeledContent("大小", value: pluginSize(binary.byteCount))
            if let os = binary.minimumOS { LabeledContent("最低系统", value: "iOS \(os)") }
            detail("包内路径", binary.path)
            if let name = binary.installName { detail("安装名称", name) }
        }
        if !binary.bundleFilters.isEmpty || !binary.executableFilters.isEmpty {
            Section {
                ForEach(binary.bundleFilters, id: \.self) { detail("应用标识", $0) }
                ForEach(binary.executableFilters, id: \.self) { detail("进程名称", $0) }
            } header: { Text("插件声明的匹配规则") } footer: { Text("用于判断插件原本面向的应用；是否注入由你的选择决定。") }
        }
        Section {
            ForEach(binary.dependencies) { dependency in
                VStack(alignment: .leading, spacing: 5) {
                    Text(dependency.path).font(.caption.monospaced()).textSelection(.enabled)
                    Text(dependency.isWeak ? "可选依赖" : "必需依赖").font(.caption2).foregroundStyle(Color.secondary)
                    if dependency.path.localizedCaseInsensitiveContains("substrate") || dependency.path.hasPrefix("/var/jb/") {
                        Label("需要插件提供相应运行库或适配路径", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    }
                }.padding(.vertical, 3)
            }
            if binary.dependencies.isEmpty { Text("没有动态库依赖").foregroundStyle(Color.secondary) }
        } header: { Text("动态库依赖 · \(binary.dependencies.count)") }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(Color.secondary); Text(value).font(.caption.monospaced()).textSelection(.enabled) }.padding(.vertical, 3)
    }
}

struct PluginSelectionView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let target: PluginTarget
    var defaultSigningTarget: PluginSigningTarget = .executable
    var projectNewPluginsFirst: Bool?
    @State private var entries: [PluginInjection] = []
    @State private var loaded = false
    @State private var knownIDs = Set<UUID>()
    @State private var showImporter = false
    @State private var query = ""
    @State private var inspected: [UUID: PluginRecord] = [:]
    @State private var embedded: [EmbeddedLibrary]?
    @State private var embeddedIssue: String?
    @AppStorage("RetoolsNewPluginsFirst") private var newFirst = false
    @AppStorage("RetoolsDefaultPluginWeak") private var defaultWeak = false
    private var isContainer: Bool { if case .container = target { return true }; return false }
    private var targetName: String {
        switch target { case .package(let id): return store.state.packages.first { $0.id == id }?.name ?? "应用"; case .container(let id): return store.state.containerApps.first { $0.id == id }?.name ?? "容器应用" }
    }
    private var bundleID: String {
        switch target { case .package(let id): return store.state.packages.first { $0.id == id }?.bundleID ?? ""; case .container(let id): return store.state.containerApps.first { $0.id == id }?.bundleID ?? "" }
    }
    private var records: [PluginRecord] { store.state.plugins.map { inspected[$0.id] ?? $0 } }
    private var filtered: [PluginRecord] { records.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.executablePaths.contains { $0.localizedCaseInsensitiveContains(query) } } }
    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: isContainer ? "shippingbox.fill" : "app.fill").font(.title).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 5) { Text(targetName).font(.headline); Text(bundleID).font(.caption).foregroundStyle(Color.secondary).textSelection(.enabled) }
                }.padding(.vertical, 5)
                LabeledContent("注入方式", value: isContainer ? "容器启动时加载" : "逐库选择主程序或加载器")
                LabeledContent("待注入", value: "\(entries.count) 个动态库 · \(Set(entries.map(\.pluginID)).count) 份插件")
            } footer: { Text(isContainer ? "保存后，下次启动应用生效。" : "重新签名后生效；原始 IPA 保留。") }
            Section {
                if let embedded {
                    ForEach(embedded.filter { $0.isInjectedPlugin && (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query)) }) { library in
                        NavigationLink { EmbeddedLibraryDetail(library: library) } label: { EmbeddedLibraryRow(library: library) }
                    }
                    if !embedded.contains(where: \.isInjectedPlugin) { Text("未识别到已有注入插件").foregroundStyle(Color.secondary) }
                } else if let embeddedIssue { Text(embeddedIssue).foregroundStyle(.red) }
                else { ProgressView("正在读取包内动态库…") }
            } header: { Text("IPA 已注入插件" + (embedded.map { " · \($0.filter(\.isInjectedPlugin).count)" } ?? "")) }
              footer: { Text("仅显示后期注入的插件；应用自带框架与加载支持组件不计入。下方配置额外注入项。") }
            Section {
                Button("添加插件", systemImage: "plus.circle.fill") { showImporter = true }.accessibilityIdentifier("plugins.add")
                NavigationLink { PluginManagerView() } label: { Label("从插件库管理", systemImage: "puzzlepiece.extension") }
                NavigationLink { EmbeddedLibrariesView(target: target) } label: { Label("全部动态库与依赖", systemImage: "shippingbox") }
            }
            if !entries.isEmpty {
                Section {
                    ForEach(entries) { entry in
                        if let record = records.first(where: { $0.id == entry.pluginID }) {
                            NavigationLink { options(entry.path, record: record) } label: {
                                HStack(spacing: 10) {
                                    Text("\((entries.firstIndex(where: { $0.id == entry.id }) ?? 0) + 1)").font(.caption.monospacedDigit()).foregroundStyle(Color.secondary).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text((entry.path as NSString).lastPathComponent).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary)
                                        Text("\(record.name) · \(entry.loadKind.title)").font(.caption).foregroundStyle(Color.secondary)
                                    }
                                }.padding(.vertical, 3)
                            }.accessibilityIdentifier("plugins.order." + entry.id)
                        }
                    }.onMove { from, to in entries.move(fromOffsets: from, toOffset: to) }.onDelete { entries.remove(atOffsets: $0) }
                } header: { Text("加载顺序 · \(entries.count)") } footer: { Text("点进动态库设置加载方式；点「编辑」拖动排序或移除注入。") }
            }
            Section {
                ForEach(filtered) { record in
                    DisclosureGroup {
                        ForEach(record.executablePaths, id: \.self) { path in
                            HStack(spacing: 10) {
                                Button { toggle(path, record: record) } label: { Image(systemName: contains(path, record) ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(contains(path, record) ? Color.accentColor : Color.secondary) }
                                    .buttonStyle(.borderless).accessibilityLabel("选择 \((path as NSString).lastPathComponent)").accessibilityIdentifier("plugins.select.\((path as NSString).lastPathComponent)")
                                NavigationLink { options(path, record: record) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text((path as NSString).lastPathComponent).font(.subheadline).foregroundStyle(Color.primary)
                                        if let binary = record.binaries?.first(where: { $0.path == path }) { Text("arm64 · \(pluginSize(binary.byteCount)) · \(binary.dependencies.count) 项依赖").font(.caption2).foregroundStyle(Color.secondary) }
                                    }.padding(.vertical, 4)
                                }
                            }
                        }
                        NavigationLink { PluginDetailView(plugin: record) } label: { Label("插件信息与包内文件", systemImage: "info.circle").font(.subheadline) }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                            Text("\(record.kind.rawValue.uppercased()) · 已选 \(entries.filter { $0.pluginID == record.id }.count)/\(record.executablePaths.count) · \(pluginSize(record.byteCount))").font(.caption).foregroundStyle(Color.secondary)
                        }.padding(.vertical, 4)
                    }
                }
                if filtered.isEmpty { Text(records.isEmpty ? "添加 .deb 或 .dylib 后，逐个选择需要注入的动态库。" : "没有匹配的动态库").font(.subheadline).foregroundStyle(Color.secondary) }
            } header: { Text("可用插件") }
            Section {
                Toggle("新插件放在最前", isOn: $newFirst)
                Toggle("新添加项使用弱链接", isOn: $defaultWeak)
                Button("选择全部动态库") { for record in records { for path in record.executablePaths where !contains(path, record) { add(path, record) } } }
                Button("清空本应用的注入", role: .destructive) { entries = [] }.disabled(entries.isEmpty)
            } header: { Text("添加选项") } footer: { Text("只影响之后添加的项；现有顺序和加载方式保留。插件资源会随包复制。") }
            if let error = store.pluginIssue { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
        }
        .navigationTitle(isContainer ? "动态注入插件" : "签名注入插件").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索插件或动态库")
        .toolbar { ToolbarItem(placement: .primaryAction) { EditButton() } }
        .safeAreaInset(edge: .bottom) {
            Button { Task { if await store.saveInjections(entries, target: target) { dismiss() } } } label: {
                HStack { if store.isWorking { ProgressView().tint(.white) }; Text(store.isWorking ? store.workLabel : "保存注入配置（\(entries.count)）").fontWeight(.semibold) }.frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).controlSize(.large).padding().bottomBarBackground().accessibilityIdentifier("plugins.save")
        }
        .disabled(store.isWorking)
        .sheet(isPresented: $showImporter) {
            DocumentImportPicker(isPresented: $showImporter) { result in
                switch result { case .success(let url): store.importPlugin(url); case .failure(let error): store.pluginIssue = error.localizedDescription }
            }
        }
        .onAppear {
            guard !loaded else { return }; loaded = true; store.pluginIssue = nil; knownIDs = Set(store.state.plugins.map(\.id))
            do {
                switch target {
                case .package(let id): if let app = store.state.packages.first(where: { $0.id == id }) { entries = try PluginService.configuration(app.pluginInjections, legacy: app.pluginIDs ?? [], plugins: store.state.plugins) }
                case .container(let id): if let app = store.state.containerApps.first(where: { $0.id == id }) { entries = try PluginService.configuration(app.pluginInjections, legacy: app.pluginIDs ?? [], plugins: store.state.plugins) }
                }
            } catch { store.pluginIssue = error.localizedDescription }
        }
        .onChange(of: store.state.plugins.map(\.id)) { _, ids in
            let current = Set(ids); entries.removeAll { !current.contains($0.pluginID) }
            for record in store.state.plugins where !knownIDs.contains(record.id) { for path in record.executablePaths { add(path, record) } }
            knownIDs = current
        }
        .task(id: store.state.plugins.map(\.id)) {
            for record in store.state.plugins where inspected[record.id] == nil {
                do { inspected[record.id] = try await store.service.pluginDetails(record.id).0 } catch { store.pluginIssue = error.localizedDescription }
            }
        }
        .task(id: target) {
            do { embedded = try await store.service.embeddedLibraries(for: target) }
            catch { embeddedIssue = error.localizedDescription }
        }
    }
    private func contains(_ path: String, _ record: PluginRecord) -> Bool { entries.contains { $0.pluginID == record.id && $0.path == path } }
    private func add(_ path: String, _ record: PluginRecord) { let entry = PluginInjection(pluginID: record.id, path: path, loadKind: defaultWeak ? .optional : .required, signingTarget: isContainer ? nil : defaultSigningTarget); if projectNewPluginsFirst ?? newFirst { entries.insert(entry, at: 0) } else { entries.append(entry) } }
    private func toggle(_ path: String, record: PluginRecord) { if contains(path, record) { entries.removeAll { $0.pluginID == record.id && $0.path == path } } else { add(path, record) } }
    private func options(_ path: String, record: PluginRecord) -> some View {
        PluginInjectionOptions(record: record, binary: record.binaries?.first { $0.path == path }, path: path,
            enabled: Binding(get: { contains(path, record) }, set: { if $0 != contains(path, record) { toggle(path, record: record) } }),
            kind: Binding(get: { entries.first { $0.pluginID == record.id && $0.path == path }?.loadKind ?? .required }, set: { value in if let index = entries.firstIndex(where: { $0.pluginID == record.id && $0.path == path }) { entries[index].loadKind = value } }),
            signingTarget: isContainer ? nil : Binding(get: { entries.first { $0.pluginID == record.id && $0.path == path }?.signingTarget ?? .executable }, set: { value in if let index = entries.firstIndex(where: { $0.pluginID == record.id && $0.path == path }) { entries[index].signingTarget = value } }))
    }
}

private struct PluginInjectionOptions: View {
    let record: PluginRecord
    let binary: PluginBinary?
    let path: String
    @Binding var enabled: Bool
    @Binding var kind: PluginLoadKind
    var signingTarget: Binding<PluginSigningTarget>?
    var body: some View {
        List {
            Section {
                Toggle("注入此动态库", isOn: $enabled).accessibilityIdentifier("plugins.entry.enabled")
                Picker("加载方式", selection: $kind) { ForEach(PluginLoadKind.allCases) { Text($0.title).tag($0) } }.disabled(!enabled).accessibilityIdentifier("plugins.entry.kind")
                if let signingTarget { Picker("注入位置", selection: signingTarget) { ForEach(PluginSigningTarget.allCases) { Text($0.title).tag($0) } }.disabled(!enabled) }
            } footer: { Text("必须加载：加载失败时停止启动。可选加载：加载器无法加载时允许继续启动，插件功能可能不可用。") }
            if let binary { PluginBinarySections(binary: binary) }
            Section { NavigationLink { PluginDetailView(plugin: record) } label: { Label("查看插件包与资源", systemImage: "folder") } }
        }.navigationTitle((path as NSString).lastPathComponent).navigationBarTitleDisplayMode(.inline)
    }
}
