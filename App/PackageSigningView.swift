import SwiftUI
import UIKit

private let projectAccent = Palette.accent
private enum SigningProjectPanel: String, Identifiable {
    case workspace, dependencies
    var id: String { rawValue }
}

struct PackageSigningView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let packageID: UUID
    @State private var options = PackageSigningOptions()
    @AppStorage(AppDataMigration.enabledKey) private var migrateData = true
    @State private var loaded = false
    @State private var field: SigningProjectField?
    @State private var showEntitlements = false
    @State private var showIdentityImport = false
    @State private var showImporter = false
    @State private var importKind = "plugins"
    @State private var selecting = false
    @State private var selectedEntries = Set<String>()
    @State private var confirmRemove = false
    @State private var confirmReset = false
    @State private var confirmDelete = false
    @State private var localBusy = false
    @State private var sharing: SigningProjectShare?
    @State private var projectPanel: SigningProjectPanel?
    @State private var expandedOptions = false
    @State private var completed: String?
    @State private var pendingSave: Task<Void, Never>?
    private var package: AppPackage? { store.state.packages.first { $0.id == packageID } }
    private var entries: [PluginInjection] { package?.pluginInjections ?? [] }
    private var identity: SigningIdentity? { options.identityID == nil ? store.activeIdentity : options.selectedIdentity(in: store.state.identities) }
    private var busy: Bool { (store.isWorking && !store.workLabel.isEmpty) || localBusy }
    private var exportOnly: Bool { options.removeEmbedded || options.format == .tipa }
    private var canSign: Bool { identity != nil && identity?.isExpired == false && package?.isEncrypted == false }

    var body: some View {
        Group {
            if let package {
                ScrollView {
                    VStack(spacing: 22) {
                        appCard(package)
                        if package.isEncrypted {
                            NavigationLink { DecryptionView(package: package) } label: {
                                Label("砸壳后再签名", systemImage: "lock.open").frame(maxWidth: .infinity, alignment: .leading).workspaceCard(padding: 16)
                            }.accessibilityIdentifier("project.decrypt")
                        }
                        certificateCard
                        pluginsCard
                        outputCard(package)
                        configurationCard
                        dependenciesCard
                        if let completed {
                            card {
                                Label(completed, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(projectAccent)
                                if let output = store.exportURL(package) { ShareLink(item: output) { Label("导出签名结果", systemImage: "square.and.arrow.up") }.accessibilityIdentifier("project.exportResult") }
                            }
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 18).frame(maxWidth: 700).frame(maxWidth: .infinity)
                }.ambientBackground().disabled(busy)
                    .safeAreaInset(edge: .bottom) { footer(package) }
                    .onAppear { if !loaded { options = package.signingOptions ?? PackageSigningOptions(); loaded = true; store.signingIssue = nil } }
                    .onChange(of: options) { _, value in if loaded { queueOptions(value) } }
                    .onChange(of: entries.map(\.id)) { _, values in selectedEntries.formIntersection(values) }
                    .onChange(of: store.state.identities.map(\.id)) { _, _ in
                        if let selected = options.identityID, let resolved = options.selectedIdentity(in: store.state.identities), selected != resolved.id { options.selectIdentity(resolved) }
                    }
            } else { ContentUnavailableView("应用已移除", systemImage: "app.dashed") }
        }
        .navigationTitle("签名配置").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar).toolbar(.visible, for: .navigationBar).tint(projectAccent)
        .navigationBarBackButtonHidden(busy)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("仅签名并导出", systemImage: "square.and.arrow.up") { runSign(install: false) }.disabled(identity == nil || busy || package?.isEncrypted == true)
                    Button("导入签名证书", systemImage: "checkmark.seal") { showIdentityImport = true }.disabled(busy)
                    Button("重置项目配置", systemImage: "arrow.counterclockwise") { confirmReset = true }.disabled(busy)
                    Button("从应用库移除", systemImage: "trash", role: .destructive) { confirmDelete = true }.disabled(busy)
                    Button("完成", systemImage: "checkmark") { Task { await pendingSave?.value; dismiss() } }.disabled(busy)
                } label: { Image(systemName: "ellipsis").foregroundStyle(projectAccent) }.accessibilityLabel("签名操作")
            }
        }
        .interactiveDismissDisabled(busy)
        .sheet(item: $field) { field in
            SigningProjectFieldEditor(field: field, initial: field.value(options)) { value in
                guard let package else { return }
                var updated = options; field.set(value, in: &updated); try updated.validate(for: package); options = updated
            }.tint(projectAccent)
        }
        .sheet(isPresented: $showEntitlements) { SigningEntitlementsEditor(data: options.customEntitlements) { options.customEntitlements = $0 }.tint(projectAccent) }
        .sheet(isPresented: $showIdentityImport) { IdentityImportSheet() }
        .sheet(item: $sharing) { SigningProjectShareSheet(urls: $0.urls) }
        .sheet(item: $store.signingProgress) { progress in
            SigningProgressSheet(progress: progress) { store.signingProgress = nil }.tint(projectAccent)
        }
        .sheet(item: $projectPanel) { panel in
            switch panel {
            case .workspace: SigningProjectBrowser(packageID: packageID, options: options, pendingSave: pendingSave)
            case .dependencies: SigningProjectDependenciesView(packageID: packageID, entries: entries, pendingSave: pendingSave)
            }
        }
        .sheet(isPresented: $showImporter) {
            DocumentImportPicker(isPresented: $showImporter) { result in
                switch result { case .success(let url): importFile(url); case .failure(let error): store.signingIssue = error.localizedDescription }
            }
        }
        .alert("签名项目", isPresented: Binding(get: { store.signingIssue != nil }, set: { if !$0 { store.signingIssue = nil } })) { Button("好", role: .cancel) {} } message: { Text(store.signingIssue ?? "") }
        .confirmationDialog("移除项目中的插件注入？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(selecting ? "移除所选注入" : "移除全部注入", role: .destructive) {
                let removed = selecting ? selectedEntries : Set(entries.map(\.id))
                changeEntries { $0.filter { !removed.contains($0.id) } }; selecting = false; selectedEntries.removeAll()
            }
        } message: { Text("插件库中的原文件会保留。") }
        .confirmationDialog("重置项目配置？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("恢复原始应用信息与默认选项", role: .destructive) { options = PackageSigningOptions() }
        } message: { Text("已选择的插件和原始 IPA 会保留。") }
        .confirmationDialog("从应用库移除？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("移除 IPA 和签名输出", role: .destructive) {
                guard let package else { return }
                localBusy = true
                Task { @MainActor in
                    await pendingSave?.value
                    let removed = await store.deletePackage(package)
                    localBusy = false
                    if removed { dismiss() }
                }
            }
        } message: { Text("已导入的容器及其数据会保留。" + (RenewalController.shared.settings.tracks(packageID) ? "\n\n它已安装或在自动续签中，移除后无法再续签，到期后将无法打开。" : "")) }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16, content: content).frame(maxWidth: .infinity, alignment: .leading).workspaceCard(padding: 16)
    }
    private func appCard(_ package: AppPackage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Button { importKind = "icon"; showImporter = true } label: {
                    AppIcon(name: options.name(for: package), url: store.iconURL(options.iconFile ?? package.iconFile), size: 68)
                        .overlay(alignment: .bottomTrailing) { Image(systemName: "photo").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).padding(5).background(projectAccent, in: RoundedRectangle(cornerRadius: 6)).offset(x: 4, y: 4) }
                }.buttonStyle(.plain).accessibilityLabel("修改应用图标").accessibilityIdentifier("project.icon")
                    .contextMenu { Button("恢复原图标") { options.iconFile = nil; options.repairDarkIcon = true; options.repairWhiteIcon = false } }
                VStack(alignment: .leading, spacing: 7) {
                    Button { field = .name } label: { HStack(spacing: 7) { Text(options.name(for: package)).font(.title2.bold()).foregroundStyle(.primary).multilineTextAlignment(.leading); Image(systemName: "pencil").font(.caption).foregroundStyle(.tertiary) } }.buttonStyle(.plain).accessibilityIdentifier("project.name")
                    Button { field = .identifier } label: { HStack(spacing: 6) { Text(options.identifier(for: package)).font(.caption.monospaced()).lineLimit(2); Image(systemName: "square.and.pencil").font(.caption2) }.foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityIdentifier("project.bundleID")
                    Button { field = .version } label: { Text("版本 " + options.appVersion(for: package)).font(.caption).foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityIdentifier("project.version")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { field = .note } label: { Label(options.note.isEmpty ? "添加备注" : options.note, systemImage: "text.alignleft").font(.caption).foregroundStyle(.secondary).lineLimit(2) }.buttonStyle(.plain)
            if options.identifier(for: package) != package.bundleID {
                Toggle(isOn: $migrateData) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("安装时迁移原应用的数据").font(.subheadline)
                        Text("换了 Bundle ID 后，新应用默认是空的。打开后，安装前会先备份原应用的数据，装好后写进新应用；原应用不受影响。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.tint(projectAccent).accessibilityIdentifier("project.migrateData")
            }
            if package.isEncrypted { Label("此 IPA 已加密，无法重新签名。", systemImage: "lock").font(.footnote).foregroundStyle(.secondary) }
        }.padding(.horizontal, 4).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func outputCard(_ package: AppPackage) -> some View {
        card {
            Label("输出", systemImage: "shippingbox").font(.subheadline.weight(.semibold))
            Button { field = .output } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("文件名称").font(.caption).foregroundStyle(.secondary)
                        Text((try? options.fileName(for: package)) ?? "文件名无效").font(.caption.monospaced()).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "pencil").font(.subheadline)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("编辑输出文件名").accessibilityIdentifier("project.outputName")
            HStack { Text("文件格式").font(.subheadline).foregroundStyle(.secondary); Spacer(); Picker("导出格式", selection: $options.format) { ForEach(SigningExportFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) } }.pickerStyle(.segmented).frame(width: 145).accessibilityIdentifier("project.format") }
        }
    }
    private var selectionPage: some View { PluginSelectionView(target: .package(packageID), defaultSigningTarget: options.directInjection ? .executable : .loader, projectNewPluginsFirst: options.newPluginsFirst) }
    private var pluginsCard: some View {
        card {
            HStack(spacing: 13) {
                Label("插件", systemImage: "puzzlepiece.extension").font(.subheadline.weight(.semibold))
                Text("\(entries.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 5)
                NavigationLink { selectionPage } label: { Text("管理").font(.subheadline) }.accessibilityLabel("排序与详细配置").accessibilityIdentifier("package.plugins")
                Menu {
                    NavigationLink { selectionPage } label: { Label("从插件库选择", systemImage: "puzzlepiece.extension") }
                    Button("导入 .deb 或 .dylib", systemImage: "doc.badge.plus") { importKind = "plugins"; showImporter = true }
                    Divider()
                    Button(selecting ? "完成选择" : "选择多个插件", systemImage: "checkmark.circle") { selecting.toggle(); selectedEntries.removeAll() }.disabled(entries.isEmpty)
                    Button("导出插件文件", systemImage: "square.and.arrow.up") { exportPlugins() }.disabled(entries.isEmpty || (selecting && selectedEntries.isEmpty))
                    Button(selecting ? "移除所选注入" : "移除全部注入", systemImage: "trash", role: .destructive) { confirmRemove = true }.disabled(entries.isEmpty || (selecting && selectedEntries.isEmpty))
                } label: { Image(systemName: "plus.circle.fill").font(.system(size: 21)) }.accessibilityLabel("添加与管理插件").accessibilityIdentifier("project.addPlugin")
            }
            if selecting {
                HStack {
                    Text("已选择 \(selectedEntries.count) 项").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("完成选择") { selecting = false; selectedEntries.removeAll() }.font(.caption)
                }
            }
            if entries.isEmpty {
                NavigationLink { selectionPage } label: { Label("选择插件", systemImage: "plus").font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 10).background(projectAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)) }.accessibilityIdentifier("project.choosePlugins")
            }
            ForEach(entries) { entry in
                HStack(spacing: 12) {
                    if selecting {
                        Button { if selectedEntries.contains(entry.id) { selectedEntries.remove(entry.id) } else { selectedEntries.insert(entry.id) } } label: { Image(systemName: selectedEntries.contains(entry.id) ? "checkmark.circle.fill" : "circle") }
                    } else { Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(projectAccent).font(.system(size: 16)).frame(width: 34, height: 34).background(projectAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9)) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text((entry.path as NSString).lastPathComponent).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                        Menu {
                            Section("注入位置") { ForEach(PluginSigningTarget.allCases) { target in Button(target.title) { changeEntries { values in values.map { var item = $0; if item.id == entry.id { item.signingTarget = target }; return item } } } } }
                            Section("加载方式") { ForEach(PluginLoadKind.allCases) { kind in Button(kind.title) { changeEntries { values in values.map { var item = $0; if item.id == entry.id { item.loadKind = kind }; return item } } } } }
                        } label: { HStack(spacing: 4) { Text((entry.signingTarget ?? .executable).title + (entry.loadKind == .optional ? " · 弱链接" : "")); Image(systemName: "chevron.down").font(.system(size: 8)) }.font(.system(size: 11)).foregroundStyle(Color.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        NavigationLink { selectionPage } label: { Label("顺序与详细配置", systemImage: "slider.horizontal.3") }
                        Button("移除此项", systemImage: "trash", role: .destructive) { changeEntries { $0.filter { $0.id != entry.id } } }
                    } label: { Image(systemName: "ellipsis").foregroundStyle(Color.secondary).frame(width: 32, height: 34) }.accessibilityLabel("\((entry.path as NSString).lastPathComponent) 的操作")
                }.padding(.vertical, 5)
            }
            if entries.contains(where: { $0.signingTarget == .loader }) && entries.contains(where: { $0.signingTarget != .loader }) {
                Text("两种方式分别处理加载顺序；需要统一顺序时，请全部使用加载器。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var configurationCard: some View {
        card {
            Label("应用选项", systemImage: "app.badge.checkmark").font(.subheadline.weight(.semibold))
            configToggle("开启文件访问", detail: "在「文件」中可见", value: $options.fileSharing, id: "project.fileSharing")
            Divider()
            configToggle("移除应用跳转", detail: "避免占用其他应用的链接", value: $options.removeURLSchemes, id: "project.removeURLSchemes")
            Divider()
            configToggle("移除 Watch", detail: nil, value: $options.removeWatch, id: "project.removeWatch")
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expandedOptions.toggle() }
            } label: {
                HStack {
                    Label("更多选项", systemImage: "slider.horizontal.3").font(.subheadline)
                    Spacer()
                    Image(systemName: expandedOptions ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(expandedOptions ? "已展开" : "已收起").accessibilityIdentifier("project.advancedOptions")
            if expandedOptions { advancedOptions.padding(.top, 2) }
        }
    }
    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            configToggle("修复白色图标", detail: "从图片重建图标", value: Binding(get: { options.repairWhiteIcon }, set: { value in var updated = options; updated.repairWhiteIcon = value; if value { updated.repairDarkIcon = false }; options = updated }), id: "project.whiteIcon")
            Divider()
            configToggle("修复深色图标", detail: options.iconFile == nil ? "恢复深浅色图标引用" : "自定义图标时不可用", value: Binding(get: { options.repairDarkIcon }, set: { value in var updated = options; updated.repairDarkIcon = value; if value { updated.repairWhiteIcon = false }; options = updated }), id: "project.darkIcon").disabled(options.iconFile != nil)
            Divider()
            configToggle("直接注入插件", detail: "关闭则使用 Retools Loader", value: $options.directInjection, id: "project.directInjection")
            Divider()
            configToggle("移除 Embedded", detail: "输出不含描述文件", value: $options.removeEmbedded, id: "project.removeEmbedded")
            Divider()
            configToggle("新插件放在最前", detail: nil, value: $options.newPluginsFirst, id: "project.newPluginsFirst")
            Divider()
            Picker(selection: $options.gameMode) { ForEach(SigningGameMode.allCases) { Text($0.title).tag($0) } } label: { VStack(alignment: .leading, spacing: 5) { Text("游戏模式"); Text(options.gameMode.title).font(.caption).foregroundStyle(.secondary) } }.accessibilityIdentifier("project.gameMode")
            Divider()
            Button { field = .minimum } label: { HStack { VStack(alignment: .leading, spacing: 5) { Text("最低系统版本").foregroundStyle(.primary); Text(options.minimumOS.isEmpty ? "保持原始设置" : "iOS " + options.minimumOS).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) } }.accessibilityIdentifier("project.minimumOS")
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("Entitlements"); Text("受描述文件授权范围约束").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                Menu {
                    Button("导入文件") { importKind = "entitlements"; showImporter = true }
                    Button(options.customEntitlements == nil ? "新建与编辑" : "查看与编辑") { showEntitlements = true }
                    if options.customEntitlements != nil { Button("清除", role: .destructive) { options.customEntitlements = nil } }
                } label: { Text(options.customEntitlements == nil ? "导入" : "已配置").font(.subheadline); Image(systemName: "chevron.right").font(.caption) }.accessibilityIdentifier("project.entitlements")
            }
            Text("应用扩展会从签名副本中移除。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func configToggle(_ title: String, detail: String?, value: Binding<Bool>, id: String) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }.accessibilityIdentifier(id)
    }
    private var certificateCard: some View {
        card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).frame(width: 40, height: 40).background(Palette.accentGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 7) {
                    Text("签名证书").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        Picker("签名证书", selection: Binding(get: { options.identityID }, set: { id in options.selectIdentity(store.state.identities.first { $0.id == id }) })) {
                            Text("跟随当前签名证书").tag(UUID?.none)
                            if let selected = options.identityID, identity == nil { Text("所选证书已移除").tag(Optional(selected)) }
                            ForEach(store.state.identities) { identity in Text("\(identity.name) · \(identity.teamID)").tag(Optional(identity.id)) }
                        }.pickerStyle(.inline)
                    } label: {
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(identity?.name ?? (options.identityID == nil ? "请选择证书" : "所选证书已移除")).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary).multilineTextAlignment(.leading)
                                Text(identity?.teamID ?? "P12 + 描述文件").font(.caption).foregroundStyle(Color.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down").font(.caption).foregroundStyle(projectAccent)
                        }.contentShape(Rectangle())
                    }.accessibilityIdentifier("project.identity")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let identity {
                HStack { Text(identity.isExpired ? "已过期" : "剩余 \(identity.daysRemaining) 天").font(.caption).foregroundStyle(identity.isExpired ? .red : .secondary); Spacer(); NavigationLink { CertificatePermissionsView(identity: identity) } label: { Text("权限与详情").font(.caption) } }
            } else { Button("导入签名证书") { showIdentityImport = true }.font(.subheadline) }
        }
    }
    private var dependenciesCard: some View {
        card {
            Label("文件与依赖", systemImage: "folder").font(.subheadline.weight(.semibold))
            Button { projectPanel = .workspace } label: {
                fileActionRow("浏览工作区文件", detail: "查看当前配置的文件副本")
            }.buttonStyle(.plain).accessibilityIdentifier("project.browse")
            Divider()
            Button { projectPanel = .dependencies } label: {
                fileActionRow("主二进制依赖", detail: "查看应用依赖与当前注入项")
            }.buttonStyle(.plain).accessibilityIdentifier("project.dependencies")
        }
    }
    private func fileActionRow(_ title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline).foregroundStyle(Color.primary)
                Text(detail).font(.caption).foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.secondary)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
    }
    private func footer(_ package: AppPackage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(identity == nil ? "请选择签名证书" : identity?.isExpired == true ? "证书已过期，请更换" : exportOnly ? "签名后导出文件" : "签名后安装到当前设备").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(options.format.rawValue.uppercased()).font(.caption.monospaced().weight(.medium)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { runSign(install: !exportOnly) } label: {
                    HStack(spacing: 9) {
                        if busy { ProgressView().tint(.white) } else { Image(systemName: exportOnly ? "square.and.arrow.up.fill" : "arrow.down.app.fill") }
                        Text(busy ? (store.workLabel.isEmpty ? "正在准备…" : store.workLabel) : exportOnly ? "签名并导出" : "签名并安装").font(.body.weight(.semibold)).lineLimit(1)
                    }.foregroundStyle(canSign ? Color.white : Color.secondary).frame(maxWidth: .infinity, minHeight: 52).padding(.horizontal, 12)
                        .background { if canSign { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.accentGradient).shadow(color: projectAccent.opacity(0.3), radius: 10, x: 0, y: 5) } else { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .tertiarySystemFill)) } }
                }.buttonStyle(.plain).disabled(busy || !canSign).accessibilityIdentifier("package.confirmSign")
                if !exportOnly {
                    Button { runSign(install: false) } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 19, weight: .medium)).frame(width: 52, height: 52).background(projectAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous)) }.buttonStyle(.plain).disabled(busy || package.isEncrypted || identity == nil || identity?.isExpired == true).accessibilityLabel("仅签名并导出").accessibilityIdentifier("project.exportOnly")
                }
            }
        }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8).bottomBarBackground()
    }
    private func queueOptions(_ value: PackageSigningOptions) {
        let previous = pendingSave
        pendingSave = Task { @MainActor in
            await previous?.value
            while store.isWorking { try? await Task.sleep(for: .milliseconds(50)) }
            _ = await store.saveSigningOptions(value, packageID: packageID)
        }
    }
    private func changeEntries(_ transform: @escaping ([PluginInjection]) -> [PluginInjection]) {
        let previous = pendingSave
        pendingSave = Task { @MainActor in
            await previous?.value
            while store.isWorking { try? await Task.sleep(for: .milliseconds(50)) }
            _ = await store.saveInjections(transform(entries), target: .package(packageID))
        }
    }
    private func runSign(install: Bool) {
        localBusy = true; completed = nil
        Task { @MainActor in
            await pendingSave?.value
            let result = await store.signProject(packageID, options: options, install: install)
            localBusy = false
            // 进度面板会展示结果并提供分享；页面上保留一条完成记录。
            if result { completed = install ? "签名及设备安装已完成" : "签名输出已生成" }
        }
    }
    private func importFile(_ url: URL) {
        localBusy = true
        Task { @MainActor in
            defer { localBusy = false }
            await pendingSave?.value
            do {
                switch importKind {
                case "icon":
                    let icon = try await store.service.importSigningIcon(url)
                    var updated = options; updated.iconFile = icon; updated.repairWhiteIcon = false; updated.repairDarkIcon = false; options = updated
                case "entitlements": options.customEntitlements = try await store.service.importSigningEntitlements(url)
                default: _ = await store.importProjectPlugin(url, packageID: packageID, options: options)
                }
            } catch { store.signingIssue = error.localizedDescription }
        }
    }
    private func exportPlugins() {
        localBusy = true
        Task { @MainActor in
            defer { localBusy = false }
            await pendingSave?.value
            do { sharing = SigningProjectShare(urls: [try await store.service.exportProjectPlugins(packageID, entryIDs: selecting ? selectedEntries : nil)]) }
            catch { store.signingIssue = error.localizedDescription }
        }
    }
}
