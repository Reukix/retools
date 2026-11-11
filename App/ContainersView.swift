import SwiftUI
import RetoolsNative
import LocalAuthentication

struct ContainersView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPicker = false
    @State private var selectedApp: ContainerApp?
    @State private var showRuntimeSettings = false
    @State private var showHidden = false
    private var visibleApps: [ContainerApp] { store.state.containerApps.filter { showHidden || $0.runtimeOptions?.isHidden != true } }
    private var spaceCount: Int { store.state.containerApps.reduce(0) { $0 + $1.containers.count } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    runtimeStatus
                    if visibleApps.isEmpty {
                        EmptyState(symbol: "shippingbox.fill", title: "为应用留一个空间", detail: "从应用库选择 IPA 导入，可为同一个应用创建多个互不干扰的数据空间。") {
                            Button { addApp() } label: { Label(store.state.packages.isEmpty ? "前往应用库导入 IPA" : "添加容器应用", systemImage: "plus") }
                                .buttonStyle(GradientCapsuleButtonStyle())
                        }.padding(.top, 24).accessibilityElement(children: .contain).accessibilityIdentifier("containers.empty")
                    } else {
                        SectionHeading(title: "我的容器", trailing: "\(store.state.containerApps.count) 个应用 · \(spaceCount) 个空间").padding(.horizontal, 4).padding(.top, 6)
                        LazyVStack(spacing: 12) {
                            ForEach(visibleApps) { app in ContainerAppCard(app: app) { selectedApp = app } }
                        }
                    }
                    Label("容器应用与 Retools 同进程运行，可读取证书与登录状态，只运行可信应用。", systemImage: "exclamationmark.shield")
                        .font(.footnote).foregroundStyle(Color.secondary).lineSpacing(3).padding(.horizontal, 4).padding(.top, 6)
                }.padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: 700).frame(maxWidth: .infinity)
            }.ambientBackground().navigationTitle("容器空间")
                .task { if !store.state.containerApps.isEmpty { store.checkRuntimeIfNeeded() } }
                .onChange(of: scenePhase) { _, phase in if phase == .background { showHidden = false } }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if store.state.containerApps.contains(where: { $0.runtimeOptions?.isHidden == true }) {
                            Button {
                                if showHidden { showHidden = false }
                                else { Task { do { showHidden = try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "查看隐藏的容器应用") } catch { store.errorMessage = error.localizedDescription } } }
                            } label: { Image(systemName: showHidden ? "eye.slash" : "eye") }.accessibilityLabel(showHidden ? "隐藏私密应用" : "显示隐藏应用")
                        }
                        Button { showRuntimeSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel("容器运行设置").accessibilityIdentifier("containers.runtimeSettings")
                        Button { addApp() } label: { Label("添加容器应用", systemImage: "plus") }.accessibilityIdentifier("containers.add")
                    }
                }
                .sheet(isPresented: $showPicker) { ContainerPackagePicker() }
                .sheet(item: $selectedApp) { ContainerDetailSheet(appID: $0.id) }
                .sheet(isPresented: $showRuntimeSettings) {
                    NavigationStack {
                        ContainerRuntimeSettingsView()
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showRuntimeSettings = false }.disabled(store.isWorking) } }
                    }
                }
        }
    }
    private var runtimeStatus: some View {
        Button { showRuntimeSettings = true } label: {
            HStack(spacing: 14) {
                Image(systemName: store.containerMode == .jitless ? "checkmark.shield.fill" : "bolt.fill")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.accent)
                    .frame(width: 46, height: 46).background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("运行模式").font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                    Text(store.containerMode.title).font(.title3.weight(.bold)).foregroundStyle(.white)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(store.runtimeStatusTitle).font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(.white.opacity(0.2), in: Capsule())
                    HStack(spacing: 3) { Text("运行设置"); Image(systemName: "chevron.right") }.font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                }
            }.padding(18).frame(maxWidth: .infinity)
                .background {
                    ZStack(alignment: .topTrailing) {
                        Palette.accentGradient
                        Image(systemName: "shippingbox.fill").font(.system(size: 120)).foregroundStyle(.white.opacity(0.08)).rotationEffect(.degrees(-12)).offset(x: 30, y: -24)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Palette.accent.opacity(0.3), radius: 18, x: 0, y: 10)
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }.buttonStyle(.plain).accessibilityIdentifier("containers.runtimeStatus")
    }
    private func addApp() {
        if store.state.packages.isEmpty { store.selectedTab = .library } else { showPicker = true }
    }
}

private struct ContainerAppCard: View {
    @EnvironmentObject private var store: WorkspaceStore
    let app: ContainerApp
    var open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: open) {
                HStack(spacing: 13) {
                    AppIcon(name: app.name, url: store.iconURL(app.iconFile), size: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.headline).foregroundStyle(Color.primary).lineLimit(1)
                        Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle)
                        Text("v\(app.version) · \(app.containers.count) 个空间").font(.caption).foregroundStyle(Palette.tertiaryText)
                    }
                    Spacer(minLength: 5)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Palette.tertiaryText)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(app.name) 容器管理")
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(app.containers) { container in
                            let selected = app.selectedContainerID == container.id
                            Button { store.selectContainer(app, id: container.id) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "square.stack.3d.up")
                                    Text(container.name).lineLimit(1)
                                }.font(.caption.weight(.medium)).foregroundStyle(selected ? Palette.accent : .secondary)
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(selected ? Palette.accent.opacity(0.12) : Color.primary.opacity(0.05), in: Capsule())
                            }.buttonStyle(.plain).accessibilityValue(selected ? "已选择" : "")
                        }
                    }
                }.disabled(store.isWorking)
                Button { store.launch(app) } label: { Label("运行", systemImage: "play.fill") }
                    .buttonStyle(GradientCapsuleButtonStyle()).disabled(store.isWorking)
            }
        }.workspaceCard(padding: 16)
    }
}

struct ContainerPackagePicker: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.state.packages.filter { !$0.isEncrypted }) { package in
                    Button { store.install(package); dismiss() } label: { PackageRow(package: package) }.buttonStyle(.plain).listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if store.state.packages.allSatisfy(\.isEncrypted) { Text("应用库中没有可以导入容器的 IPA。").foregroundStyle(Color.secondary) }
                Section {} footer: {
                    Label("容器中的应用与 Retools 运行在同一进程，可以读取 Retools 保存的证书、Apple ID 登录状态和设备配对记录。只导入你信任的应用。", systemImage: "exclamationmark.shield")
                        .font(.footnote).foregroundStyle(Color.secondary)
                }
            }.navigationTitle("从应用库选择").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

struct ContainerDetailSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let appID: UUID
    @State private var showNewSpace = false
    @State private var spaceName = ""
    @State private var resetTarget: DataContainer?
    @State private var confirmDelete = false
    @State private var openFailure: String?
    private var app: ContainerApp? { store.state.containerApps.first { $0.id == appID } }
    var body: some View {
        NavigationStack {
            if let app {
                Form {
                    Section {
                        VStack(spacing: 14) {
                            HStack(spacing: 16) {
                                AppIcon(name: app.name, url: store.iconURL(app.iconFile), size: 72)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(app.name).font(.title2.bold()).lineLimit(1)
                                    Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    HStack(spacing: 6) {
                                        StatusPill(title: "v\(app.version)", color: .secondary)
                                        StatusPill(title: store.containerMode.title)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            PrimaryButton(title: "运行 · \(app.selectedContainer?.name ?? "默认空间")", symbol: "play.fill") { dismiss(); store.launch(app) }
                                .accessibilityIdentifier("container.run")
                        }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    }
                    Section {
                        ForEach(app.containers) { container in
                            let selected = app.selectedContainerID == container.id
                            Button { store.selectContainer(app, id: container.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3)
                                        .foregroundStyle(selected ? Palette.accent : Color.secondary.opacity(0.5))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(container.name).foregroundStyle(Color.primary)
                                        Text("创建于 " + container.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Color.secondary)
                                    }
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .swipeActions {
                                    Button("重置", systemImage: "arrow.counterclockwise") { resetTarget = container }.tint(.orange)
                                    Button("文件", systemImage: "folder") { openDataFolder(container) }.tint(.blue)
                                }
                                .contextMenu {
                                    NavigationLink { ContainerDataSettingsView(appID: appID, container: container) } label: { Label("空间设置", systemImage: "slider.horizontal.3") }
                                    Button("在「文件」中打开", systemImage: "folder") { openDataFolder(container) }
                                    Button("重置文件数据", systemImage: "arrow.counterclockwise", role: .destructive) { resetTarget = container }
                                }
                                .accessibilityAction(named: "在「文件」中打开 \(container.name)") { openDataFolder(container) }
                                .accessibilityAction(named: "重置 \(container.name) 的文件数据") { resetTarget = container }
                        }
                        if let container = app.selectedContainer {
                            NavigationLink { ContainerDataSettingsView(appID: appID, container: container) } label: { Label("当前空间设置", systemImage: "slider.horizontal.3") }
                        }
                        Button { spaceName = ""; showNewSpace = true } label: { Label("新建数据空间", systemImage: "plus.circle.fill") }
                    } header: { Text("数据空间 · \(app.containers.count)") } footer: { Text("左滑或长按空间，可在「文件」中打开或重置其数据。") }
                    Section {
                        NavigationLink { ContainerAppSettingsView(appID: app.id) } label: { Label("应用兼容设置", systemImage: "slider.horizontal.3") }
                            .accessibilityIdentifier("container.appSettings")
                        NavigationLink { EmbeddedLibrariesView(target: .container(app.id)) } label: { Label("应用已有动态库", systemImage: "shippingbox") }
                        NavigationLink { ContainerRuntimeSettingsView() } label: {
                            LabeledContent("运行设置", value: store.containerMode.title)
                        }
                        NavigationLink { PluginSelectionView(target: .container(app.id)) } label: {
                            LabeledContent("动态注入插件", value: (app.pluginIDs?.isEmpty ?? true) ? "未选择" : "\(app.pluginIDs?.count ?? 0) 份")
                        }.accessibilityIdentifier("container.plugins")
                    }
                    Section {
                        if let container = app.selectedContainer {
                            Button { openDataFolder(container) } label: {
                                LabeledContent {
                                    Text(container.name)
                                } label: { Label("打开数据文件夹", systemImage: "folder") }
                            }.accessibilityIdentifier("container.openData")
                        }
                        LabeledContent("导入时间", value: app.installedAt.formatted(date: .abbreviated, time: .omitted))
                        LabeledContent("容器目录", value: String(app.folder.prefix(8)) + "…")
                    } footer: { Text("运行会重启 Retools 并进入该应用，重新打开 Retools 即可返回。") }
                    Section {
                        Button("移除容器应用", role: .destructive) { confirmDelete = true }.frame(maxWidth: .infinity)
                    }
                }
                .scrollContentBackground(.hidden).ambientBackground()
                .navigationTitle("容器管理").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                    .disabled(store.isWorking)
                    .alert("新建数据空间", isPresented: $showNewSpace) {
                        TextField("空间名称", text: $spaceName)
                        Button("取消", role: .cancel) {}
                        Button("创建") { store.addContainer(app, name: spaceName) }
                    } message: { Text("新空间将使用独立的文件目录。") }
                    .confirmationDialog("重置文件数据？", isPresented: Binding(get: { resetTarget != nil }, set: { if !$0 { resetTarget = nil } }), titleVisibility: .visible) {
                        Button("重置文件数据", role: .destructive) { if let target = resetTarget { store.resetContainer(app, id: target.id) }; resetTarget = nil }
                    } message: { Text("将清空此空间的文件，钥匙串条目不会清除。此操作无法撤销。") }
                    .confirmationDialog("移除容器应用？", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("移除应用与全部空间", role: .destructive) { store.deleteApp(app); dismiss() }
                    } message: { Text("这会移除此容器的应用文件和所有数据空间，应用库中的原始 IPA 会保留。") }
                    .alert("无法打开数据文件夹", isPresented: Binding(get: { openFailure != nil }, set: { if !$0 { openFailure = nil } })) {
                        Button("好", role: .cancel) {}
                    } message: { Text(openFailure ?? "") }
            }
        }
    }
    /// 数据空间位于 Documents/Data/Application/<空间>，「文件」App 中可见；
    /// 用 shareddocuments 链接直接跳到该目录。空间尚未运行过时先建好空目录。
    private func openDataFolder(_ container: DataContainer) {
        let folder = store.paths.data.appendingPathComponent(container.folderName, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { openFailure = error.localizedDescription; return }
        guard let link = URL(string: "shareddocuments://" + folder.absoluteString.dropFirst("file://".count)) else { openFailure = "数据文件夹路径无效。"; return }
        UIApplication.shared.open(link) { opened in
            if !opened { openFailure = "「文件」App 未能打开该位置。可在「文件 → 我的 iPhone → Retools → Data → Application → \(container.folderName)」中找到。" }
        }
    }
}
