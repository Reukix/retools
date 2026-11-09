import SwiftUI

/// 远程图标；读取失败时沿用本地占位图标的样式。
struct RemoteAppIcon: View {
    let name: String
    let url: URL?
    var size: CGFloat = 54
    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill().frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.235, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: size * 0.235, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                        .shadow(color: Palette.shadow.opacity(1.4), radius: size * 0.12, x: 0, y: size * 0.06)
                } else { AppIcon(name: name, size: size) }
            }
        } else { AppIcon(name: name, size: size) }
    }
}

/// 软件源列表：添加、编辑、刷新、删除，进入单个源或全部源浏览应用。
/// 「选择」进入多选，可全选、只选读取失败的源，批量刷新或删除，也可拖动排序。
struct SourcesView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var sources = AppSourceStore.shared
    @State private var showAdd = false
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<UUID>()
    @State private var editing: AppSource?
    @State private var pendingDelete: Set<UUID> = []
    @State private var prefill = ""
    private var selecting: Bool { editMode.isEditing }
    private func takePendingInput() {
        guard let input = store.pendingSourceInput else { return }
        store.pendingSourceInput = nil; prefill = input; showAdd = true
    }
    var body: some View {
        List(selection: $selection) {
            if sources.sources.isEmpty {
                Section {
                    EmptyState(symbol: "globe", title: "添加软件源", detail: "支持 AltStore / SideStore 格式的源和 GitHub 仓库，也可以一次粘贴多个。下载的 IPA 会加入应用库，之后照常签名或导入容器。") {
                        Button { showAdd = true } label: { Label("添加软件源", systemImage: "plus") }.buttonStyle(GradientCapsuleButtonStyle())
                    }.frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
            } else {
                if !sources.activeDownloads.isEmpty, !selecting {
                    Section("正在下载 · \(sources.activeDownloads.count)") {
                        ForEach(sources.activeDownloads) { item in DownloadRow(item: item) }
                    }
                }
                if !selecting {
                    Section {
                        NavigationLink { SourceAppsView(sourceID: nil) } label: {
                            Label { LabeledContent("全部应用", value: "\(sources.allApps.count) 个") } icon: { Image(systemName: "square.grid.2x2") }
                        }.accessibilityIdentifier("sources.all")
                    }
                }
                Section {
                    ForEach(sources.sources) { source in
                        NavigationLink { SourceAppsView(sourceID: source.id) } label: { SourceRow(source: source, refreshing: sources.refreshing.contains(source.id)) }
                            .tag(source.id)
                            .swipeActions {
                                Button("删除", systemImage: "trash") { pendingDelete = [source.id] }.tint(.red)
                                Button("编辑", systemImage: "pencil") { editing = source }.tint(.orange)
                                Button("刷新", systemImage: "arrow.clockwise") { Task { await sources.refresh(source.id) } }.tint(.blue)
                            }
                            .contextMenu {
                                Button("编辑", systemImage: "pencil") { editing = source }
                                Button("刷新", systemImage: "arrow.clockwise") { Task { await sources.refresh(source.id) } }
                                Button("复制源地址", systemImage: "doc.on.doc") { UIPasteboard.general.string = source.url.absoluteString }
                                Button("删除软件源", systemImage: "trash", role: .destructive) { pendingDelete = [source.id] }
                            }
                    }
                    .onMove { sources.move(from: $0, to: $1) }
                } header: {
                    Text(selecting ? "已选择 \(selection.count) / \(sources.sources.count)" : "软件源 · \(sources.sources.count)")
                } footer: {
                    Text(selecting ? "拖动右侧把手可调整顺序。" : "下拉刷新全部源。左滑或长按可编辑、刷新、删除；读取失败时保留上次的应用列表。")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle("软件源").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
        .refreshable { await sources.refreshAll() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !sources.sources.isEmpty {
                    Button(selecting ? "完成" : "选择") {
                        withAnimation { editMode = selecting ? .inactive : .active }
                        if !selecting { selection = [] }
                    }.accessibilityIdentifier("sources.select")
                }
                if !selecting { Button { showAdd = true } label: { Label("添加软件源", systemImage: "plus") }.accessibilityIdentifier("sources.add") }
            }
            if selecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Menu {
                        Button("全选", systemImage: "checkmark.circle") { selection = Set(sources.sources.map(\.id)) }
                        Button("选择读取失败的源", systemImage: "exclamationmark.triangle") { selection = sources.failedIDs }.disabled(sources.failedIDs.isEmpty)
                        Button("取消选择", systemImage: "circle") { selection = [] }.disabled(selection.isEmpty)
                    } label: { Text("选择") }
                    Spacer()
                    Button("编辑") { editing = sources.sources.first { selection.contains($0.id) } }.disabled(selection.count != 1)
                    Spacer()
                    Button("刷新") { let ids = selection; Task { await sources.refresh(ids) } }.disabled(selection.isEmpty)
                    Spacer()
                    Button("删除", role: .destructive) { pendingDelete = selection }.disabled(selection.isEmpty).tint(.red)
                        .accessibilityIdentifier("sources.deleteSelected")
                }
            }
        }
        .sheet(isPresented: $showAdd, onDismiss: { prefill = "" }) { AddSourcesSheet(initialText: prefill).environmentObject(store) }
        .onAppear(perform: takePendingInput)
        .onChange(of: store.pendingSourceInput) { _, _ in takePendingInput() }
        .sheet(item: $editing) { EditSourceSheet(source: $0) }
        .confirmationDialog(pendingDelete.count == 1 ? "删除这个软件源？" : "删除 \(pendingDelete.count) 个软件源？",
                            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                sources.remove(pendingDelete); selection.subtract(pendingDelete); pendingDelete = []
                if sources.sources.isEmpty { editMode = .inactive }
            }
        } message: { Text("只移除订阅和缓存的应用列表，已下载到应用库的 IPA 不受影响。") }
        // 软件源的提示（例如下载失败）由 WorkspaceRoot 统一弹出，在应用库里点「更新」失败时也能看到。
    }
}

/// 编辑显示名称和源地址；改地址会先读取新地址，失败时保持原样。
private struct EditSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sources = AppSourceStore.shared
    let source: AppSource
    @State private var name = ""
    @State private var address = ""
    @State private var saving = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(source.name, text: $name).accessibilityIdentifier("sources.edit.name")
                } header: { Text("名称") } footer: { Text("留空则使用源自己的名称「\(source.name)」。") }
                Section {
                    TextField("https://", text: $address, axis: .vertical).font(.callout.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("sources.edit.address")
                } header: { Text("源地址") } footer: { Text("修改地址会立即读取新地址，成功后替换应用列表。") }
                if let failure { Section { Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red) } }
                Section {
                    LabeledContent("应用", value: "\(source.apps.count) 个")
                    if let updated = source.updatedAt { LabeledContent("上次更新", value: updated.formatted(date: .abbreviated, time: .shortened)) }
                    if let website = source.website { Link(destination: website) { Label("打开源网站", systemImage: "safari") } }
                }
            }
            .scrollContentBackground(.hidden).ambientBackground()
            .navigationTitle("编辑软件源").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("保存") { save() }.disabled(address.trimmingCharacters(in: .whitespaces).isEmpty) }
                }
            }
            .onAppear { name = source.customName ?? ""; address = source.url.absoluteString }
            .interactiveDismissDisabled(saving)
        }.tint(Palette.accent)
    }
    private func save() {
        saving = true; failure = nil
        Task {
            do { try await sources.update(source.id, name: name, address: address); dismiss() }
            catch { failure = error.localizedDescription }
            saving = false
        }
    }
}

private struct DownloadRow: View {
    @ObservedObject private var sources = AppSourceStore.shared
    let item: SourceDownload
    var body: some View {
        HStack(spacing: 12) {
            RemoteAppIcon(name: item.appName, url: item.iconURL, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(item.appName) v\(item.version)").font(.subheadline.weight(.semibold)).lineLimit(1)
                if let fraction = item.fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                Text([item.fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }, item.sizeLabel, item.retry].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Button { sources.cancelDownload(id: item.id) } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("取消下载 \(item.appName)")
        }.padding(.vertical, 2)
    }
}

private struct SourceRow: View {
    let source: AppSource
    let refreshing: Bool
    var body: some View {
        HStack(spacing: 12) {
            RemoteAppIcon(name: source.displayName, url: source.iconURL, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.displayName).font(.headline).lineLimit(1)
                Text(source.displayHost).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let error = source.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(2)
                } else {
                    Text("\(source.apps.count) 个应用" + (source.updatedAt.map { " · " + $0.formatted(.relative(presentation: .named)) + "更新" } ?? ""))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            if refreshing { ProgressView() }
        }.padding(.vertical, 2)
    }
}

/// 一次添加一个或多个源：同时请求，每个地址单独显示进度与结果；添加中也可以关闭面板，后台继续。
private struct AddSourcesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sources = AppSourceStore.shared
    var initialText = ""
    @State private var text = ""
    @State private var rows: [Row] = []
    struct Row: Identifiable { let id = UUID(); let input: String; var state: Status }
    enum Status { case pending, success(String), failure(String) }
    private var adding: Bool { rows.contains { if case .pending = $0.state { return true }; return false } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).font(.callout.monospaced()).frame(minHeight: 120)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("每行一个地址，例如\nhttps://example.com/apps.json").font(.callout.monospaced()).foregroundStyle(.tertiary)
                                    .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                        .accessibilityIdentifier("sources.input")
                    Button { if let pasted = UIPasteboard.general.string { text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + pasted } } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                    }
                } header: { Text("源地址") } footer: {
                    Text("支持 AltStore / SideStore 源、GitHub 仓库和短链接。可以直接粘贴一段文字，会自动找出其中的链接。")
                }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { row in
                            HStack(alignment: .top, spacing: 10) {
                                switch row.state {
                                case .pending: ProgressView().frame(width: 20)
                                case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 20)
                                case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).frame(width: 20)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.input).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                    switch row.state {
                                    case .pending: Text("正在读取…").font(.caption).foregroundStyle(.secondary)
                                    case .success(let detail): Text(detail).font(.subheadline.weight(.semibold))
                                    case .failure(let reason): Text(reason).font(.caption).foregroundStyle(.red)
                                    }
                                }
                            }.textSelection(.enabled)
                        }
                    } header: {
                        let done = rows.filter { if case .pending = $0.state { return false }; return true }.count
                        let failed = rows.filter { if case .failure = $0.state { return true }; return false }.count
                        Text(adding ? "正在添加 \(done)/\(rows.count)" : "完成：\(rows.count - failed) 个成功，\(failed) 个失败")
                    } footer: {
                        if adding { Text("可以关闭此页面，添加会在后台继续。") }
                    }
                }
            }
            .scrollContentBackground(.hidden).ambientBackground()
            .navigationTitle("添加软件源").navigationBarTitleDisplayMode(.inline)
            .onAppear { if text.isEmpty { text = initialText } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(adding ? "关闭" : "完成") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { add() }.disabled(adding || AppSourceAddress.candidates(in: text).isEmpty).accessibilityIdentifier("sources.confirm")
                }
            }
        }.tint(Palette.accent)
    }
    private func add() {
        var inputs: [String] = []
        for input in AppSourceAddress.candidates(in: text) where !inputs.contains(input) { inputs.append(input) }
        rows = inputs.map { Row(input: $0, state: .pending) }
        let ids = rows.map(\.id)
        Task {
            _ = await sources.add(inputs) { index, result in
                guard let position = rows.firstIndex(where: { $0.id == ids[index] }) else { return }
                switch result {
                case .success(let detail): rows[position].state = .success(detail)
                case .failure(let error): rows[position].state = .failure(error.localizedDescription)
                }
            }
            // 成功的地址从输入框移除，只留下需要处理的。
            text = rows.filter { if case .failure = $0.state { return true }; return false }.map(\.input).joined(separator: "\n")
        }
    }
}

/// 单个源或全部源的应用列表。
struct SourceAppsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var sources = AppSourceStore.shared
    let sourceID: UUID?
    @State private var search = ""
    private var source: AppSource? { sourceID.flatMap { id in sources.sources.first { $0.id == id } } }
    private var entries: [(source: AppSource, app: SourceApp)] {
        let all = source.map { source in source.apps.map { (source, $0) } } ?? sources.allApps
        guard !search.isEmpty else { return all }
        return all.filter { $0.app.name.localizedCaseInsensitiveContains(search) || $0.app.bundleID.localizedCaseInsensitiveContains(search) || ($0.app.developer ?? "").localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            if let source {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        if let subtitle = source.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                        Text(source.url.absoluteString).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                        if let error = source.lastError { Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                    }
                }
            }
            Section {
                if entries.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "没有可下载的应用" : "无匹配结果", systemImage: "magnifyingglass",
                                           description: Text(search.isEmpty ? "该源没有包含下载地址的应用。" : "换个关键词试试。"))
                }
                ForEach(entries, id: \.app.id) { entry in
                    NavigationLink { SourceAppDetailView(app: entry.app, sourceName: entry.source.displayName) } label: {
                        SourceAppRow(app: entry.app, sourceName: sourceID == nil ? entry.source.displayName : nil)
                    }
                }
            } header: { Text("\(entries.count) 个应用") }
        }
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle(source?.displayName ?? "全部应用").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索名称、开发者或 Bundle ID")
        .refreshable { if let sourceID { await sources.refresh(sourceID) } else { await sources.refreshAll() } }
    }
}

private struct SourceAppRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    let app: SourceApp
    let sourceName: String?
    var body: some View {
        HStack(spacing: 12) {
            RemoteAppIcon(name: app.name, url: app.iconURL, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.headline).lineLimit(1)
                Text([app.latest.map { "v" + $0.version }, app.developer, sourceName].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let subtitle = app.subtitle { Text(subtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if app.beta { StatusPill(title: "Beta", color: .secondary) }
            if store.state.packages.contains(where: { $0.bundleID == app.bundleID && $0.version == app.latest?.version }) { StatusPill(title: "已在应用库", color: .green) }
        }.padding(.vertical, 2)
    }
}

/// 应用详情：版本列表与下载。
struct SourceAppDetailView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var sources = AppSourceStore.shared
    let app: SourceApp
    let sourceName: String
    @State private var showAllVersions = false
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    RemoteAppIcon(name: app.name, url: app.iconURL, size: 72)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(app.name).font(.title2.bold()).lineLimit(2)
                        Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Text([app.developer, sourceName].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }.listRowBackground(Color.clear)
                if let latest = app.latest { DownloadButton(app: app, version: latest, prominent: true) }
            }
            if let latest = app.latest {
                Section("最新版本") {
                    LabeledContent("版本", value: latest.version + (latest.build.map { " (\($0))" } ?? ""))
                    if let date = latest.dateLabel { LabeledContent("发布日期", value: date) }
                    if let size = latest.size { LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    if let minimum = latest.minimumOS { LabeledContent("最低系统", value: "iOS " + minimum) }
                    if latest.sha256 != nil { LabeledContent("校验", value: "SHA-256") }
                    if let notes = latest.notes { ReleaseNotes(markdown: notes) }
                }
            }
            if !app.screenshots.isEmpty {
                Section("截图") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(app.screenshots, id: \.self) { url in
                                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.12) }
                                    .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }.listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                }
            }
            if let summary = app.summary { Section("简介") { Text(summary).font(.callout) } }
            if app.versions.count > 1 {
                Section {
                    ForEach(app.versions.dropFirst().prefix(showAllVersions ? app.versions.count : 5)) { version in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("v" + version.version + (version.build.map { " (\($0))" } ?? ""))
                                Text([version.dateLabel, version.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            DownloadButton(app: app, version: version, prominent: false)
                        }
                    }
                    if app.versions.count > 6, !showAllVersions { Button("显示全部 \(app.versions.count - 1) 个历史版本") { showAllVersions = true } }
                } header: { Text("历史版本") }
            }
        }
        .scrollContentBackground(.hidden).ambientBackground()
        .navigationTitle(app.name).navigationBarTitleDisplayMode(.inline)
    }
}

private struct DownloadButton: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var sources = AppSourceStore.shared
    let app: SourceApp
    let version: SourceVersion
    let prominent: Bool
    @State private var confirmDuplicate = false
    var body: some View {
        if sources.isDownloading(version) {
            HStack(spacing: 10) {
                if let value = sources.progress(version) { ProgressView(value: value).frame(maxWidth: prominent ? .infinity : 80) }
                else { ProgressView() }
                if prominent, let item = sources.downloads[version.id] {
                    Text([item.fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }, item.sizeLabel, item.retry].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospacedDigit()).lineLimit(1).fixedSize()
                }
                Button { sources.cancelDownload(version) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).accessibilityLabel("取消下载")
            }
        } else if prominent {
            // 应用库正忙时也可以下载：下载完成后会排队等前一个导入结束。
            PrimaryButton(title: inLibrary ? "已在应用库 · 再次下载" : "下载到应用库", symbol: inLibrary ? "checkmark.circle.fill" : "arrow.down.circle.fill") { request() }
                .accessibilityIdentifier("sources.download")
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .confirmationDialog("应用库里已有 \(app.name) v\(version.version)", isPresented: $confirmDuplicate, titleVisibility: .visible) {
                    Button("仍然下载一份") { sources.download(app, version: version, into: store) }
                } message: { Text("再次下载会在应用库中新增一份同版本的副本。") }
        } else {
            Button { request() } label: { Image(systemName: inLibrary ? "checkmark.circle" : "arrow.down.circle") }
                .buttonStyle(.borderless).accessibilityLabel(inLibrary ? "v\(version.version) 已在应用库" : "下载 v\(version.version)")
                .confirmationDialog("应用库里已有 \(app.name) v\(version.version)", isPresented: $confirmDuplicate, titleVisibility: .visible) {
                    Button("仍然下载一份") { sources.download(app, version: version, into: store) }
                } message: { Text("再次下载会在应用库中新增一份同版本的副本。") }
        }
    }
    /// 同一应用的同一版本已经在应用库里。
    private var inLibrary: Bool { store.state.packages.contains { $0.bundleID == app.bundleID && $0.version == version.version } }
    private func request() {
        if inLibrary { confirmDuplicate = true } else { sources.download(app, version: version, into: store) }
    }
}

/// 软件源的更新说明多为 Markdown：标题转成粗体行、列表转成圆点，行内的粗体、斜体、代码和链接照常渲染。
private struct ReleaseNotes: View {
    let markdown: String
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.render(markdown)).font(.callout).foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 8).textSelection(.enabled)
            if markdown.split(separator: "\n").count > 8 || markdown.count > 400 {
                Button(expanded ? "收起" : "展开全部") { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } }.font(.caption.weight(.semibold))
            }
        }
    }
    static func render(_ text: String) -> AttributedString {
        var result = AttributedString()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            var heading = false
            if line.hasPrefix("#") { line = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces); heading = true }
            else if line.hasPrefix("* ") || line.hasPrefix("- ") || line.hasPrefix("+ ") { line = "•  " + line.dropFirst(2) }
            var piece = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
            if heading { piece.font = .callout.weight(.semibold); piece.foregroundColor = .primary }
            result += piece
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }
}
