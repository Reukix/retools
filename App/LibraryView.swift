import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var showImporter = false
    @State private var search = ""
    @State private var onlySigned = false
    @State private var selectedPackage: AppPackage?
    @State private var detailsPackage: AppPackage?
    @State private var deletingPackage: AppPackage?
    @State private var showDelete = false
    @State private var showExpiry = false
    @State private var showSources = false
    @ObservedObject private var renewal = RenewalController.shared
    @ObservedObject private var sources = AppSourceStore.shared
    /// 只在使用 Apple ID 签名时展示「我的应用」卡片。
    private var showsSignedApps: Bool {
        !renewal.settings.accounts.isEmpty || renewal.hostExpiry != nil || !renewal.settings.installedExpiries.isEmpty
    }
    private var filtered: [AppPackage] {
        store.state.packages.filter { (!onlySigned || $0.signedFile != nil) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.state.packages.isEmpty {
                        // 应用库为空时 Retools 自身仍可能是 Apple ID 签名，照样显示它的有效期。
                        if showsSignedApps { SignedAppsSection(title: "Apple ID 签名", limit: 3, onShowAll: { showExpiry = true }) }
                        EmptyState(symbol: "square.stack.3d.up.fill", title: "导入第一个应用", detail: "从「文件」导入 IPA，或在其他应用中用 Retools 打开。导入后可签名、注入插件或放入容器运行。") {
                            Button { showImporter = true } label: { Label("导入 IPA", systemImage: "square.and.arrow.down") }
                                .buttonStyle(GradientCapsuleButtonStyle())
                            Button { showSources = true } label: { Label("从软件源下载", systemImage: "globe") }
                                .accessibilityIdentifier("library.sources.empty")
                        }.padding(.top, showsSignedApps ? 12 : 60).accessibilityElement(children: .contain).accessibilityIdentifier("library.empty")
                    } else {
                        if showsSignedApps, search.isEmpty {
                            SignedAppsSection(title: "Apple ID 签名", limit: 3, onShowAll: { showExpiry = true }).padding(.bottom, 8)
                        }
                        if search.isEmpty, !onlySigned { SourceUpdatesSection().padding(.bottom, 8) }
                        SectionHeading(title: onlySigned ? "已签名应用" : "全部应用", trailing: "\(filtered.count) 个").padding(.horizontal, 4)
                        if filtered.isEmpty { ContentUnavailableView.search(text: search) }
                        else {
                            LazyVStack(spacing: 12) {
                                ForEach(filtered) { package in
                                    Button { selectedPackage = package } label: { PackageRow(package: package) }.buttonStyle(.plain)
                                        .accessibilityIdentifier("library.package." + package.id.uuidString)
                                        .accessibilityHint("打开应用签名配置，长按查看更多操作")
                                        .contextMenu {
                                            Button("应用详情", systemImage: "info.circle") { detailsPackage = package }
                                            if let update = sources.update(for: package) {
                                                Button("更新到 v\(update.version.version)", systemImage: "arrow.down.circle") { sources.update(update, into: store) }
                                                    .disabled(sources.isDownloading(update.version))
                                            }
                                            Button("导入到容器", systemImage: "shippingbox") { store.install(package) }.disabled(package.isEncrypted || store.isWorking)
                                            if let output = store.exportURL(package) { ShareLink(item: output) { Label("导出签名结果", systemImage: "square.and.arrow.up") } }
                                            Button("从应用库移除", systemImage: "trash", role: .destructive) { deletingPackage = package; showDelete = true }.disabled(store.isWorking)
                                        }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: 700).frame(maxWidth: .infinity)
            }.ambientBackground().navigationTitle("应用库")
                // 下拉刷新软件源，检查应用库里的应用有没有新版本。
                .refreshable { await sources.refreshAll() }
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索名称或 Bundle ID")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !store.state.packages.isEmpty {
                            Menu {
                                Picker("筛选", selection: $onlySigned) {
                                    Label("全部应用", systemImage: "square.grid.2x2").tag(false)
                                    Label("已签名", systemImage: "checkmark.seal").tag(true)
                                }
                            } label: { Image(systemName: onlySigned ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                                .accessibilityLabel("筛选应用").accessibilityValue(onlySigned ? "已签名" : "全部应用")
                        }
                        Button { showSources = true } label: { Label("软件源", systemImage: "globe") }.accessibilityIdentifier("library.sources")
                        Button { showImporter = true } label: { Label("导入", systemImage: "plus") }.accessibilityIdentifier("library.import")
                    }
                }
                .sheet(isPresented: $showImporter) {
                    DocumentImportPicker(isPresented: $showImporter) { result in
                        switch result { case .success(let url): store.importIPA(url); case .failure(let error): store.errorMessage = error.localizedDescription }
                    }
                }
                .navigationDestination(item: $selectedPackage) { PackageSigningView(packageID: $0.id) }
                .navigationDestination(isPresented: $showSources) { SourcesView() }
                .onChange(of: store.pendingSourceInput) { _, value in if value != nil { showSources = true } }
                .onAppear { if store.pendingSourceInput != nil { showSources = true } }
                .sheet(item: $detailsPackage) { PackageDetailSheet(packageID: $0.id) }
                .onChange(of: store.showExpiryList, initial: true) { _, value in if value { showExpiry = true; store.showExpiryList = false } }
                .sheet(isPresented: $showExpiry) { NavigationStack { AppExpiryView(showsDone: true) }.tint(Palette.accent) }
                .alert("从应用库移除？", isPresented: $showDelete, presenting: deletingPackage) { package in
                    Button("移除 IPA 和签名输出", role: .destructive) { Task { _ = await store.deletePackage(package) } }
                    Button("取消", role: .cancel) {}
                } message: { package in
                    Text("将移除「\(package.name)」的原始 IPA 和签名输出。已导入的容器及其数据会保留。" + (renewal.settings.tracks(package.id) ? "\n\n它已安装或在自动续签中，移除后无法再续签，到期后将无法打开。" : ""))
                }
        }
    }
}

struct PackageRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var renewal = RenewalController.shared
    @ObservedObject private var sources = AppSourceStore.shared
    let package: AppPackage
    var body: some View {
        HStack(spacing: 13) {
            AppIcon(name: package.name, url: store.iconURL(package.iconFile), size: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(package.name).font(.headline).foregroundStyle(Color.primary).lineLimit(1)
                Text(package.bundleID).font(.caption.monospaced()).foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle)
                Text("v\(package.version) · \(package.sizeLabel)").font(.caption).foregroundStyle(Palette.tertiaryText)
            }
            Spacer(minLength: 5)
            if package.isEncrypted { StatusPill(title: "已加密", color: .secondary) }
            else if let update = sources.update(for: package) { StatusPill(title: "可更新 v" + update.version.version) }
            else if let expiry = renewal.settings.installedExpiries[package.id.uuidString] { ExpiryBadge(expiry: expiry) }
            else if package.signedFile != nil { StatusPill(title: "已签名", color: .green) }
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Palette.tertiaryText)
        }.contentShape(Rectangle()).workspaceCard(padding: 15)
    }
}

/// 软件源里有新版本的应用（与 AltStore 的「更新」相同）：逐个或全部更新，更新会替换应用库中的原项并保留签名配置。
struct SourceUpdatesSection: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var sources = AppSourceStore.shared
    @ObservedObject private var renewal = RenewalController.shared
    var body: some View {
        let updates = sources.updates(for: store.state.packages)
        if !updates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeading(title: "可更新", trailing: "\(updates.count) 个")
                    if updates.count > 1, updates.contains(where: { !sources.isDownloading($0.version) }) {
                        Button("全部更新") { for update in updates where !sources.isDownloading(update.version) { sources.update(update, into: store) } }
                            .font(.subheadline.weight(.semibold)).accessibilityIdentifier("library.updates.all")
                    }
                }.padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(Array(updates.enumerated()), id: \.element.id) { index, update in
                        SourceUpdateRow(update: update, reinstalls: renewal.settings.packageIDs.contains(update.package.id) && renewal.settings.installedExpiries[update.package.id.uuidString] != nil)
                        if index < updates.count - 1 { Divider().padding(.leading, 64) }
                    }
                }.workspaceCard(padding: 12)
            }.accessibilityElement(children: .contain).accessibilityIdentifier("library.updates")
        }
    }
}

private struct SourceUpdateRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var sources = AppSourceStore.shared
    let update: SourceUpdate
    /// 更新后会自动重签并重装（在 Apple ID 续签列表里且已安装）。
    let reinstalls: Bool
    var body: some View {
        HStack(spacing: 12) {
            AppIcon(name: update.package.name, url: store.iconURL(update.package.iconFile), size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(update.package.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("v\(update.package.version) → v\(update.version.version)").font(.caption.monospacedDigit()).foregroundStyle(Color.secondary)
                if let item = sources.downloads[update.version.id] {
                    ProgressView(value: item.fraction ?? 0).tint(Palette.accent)
                    Text([item.fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }, item.sizeLabel, item.retry].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2.monospacedDigit()).foregroundStyle(Color.secondary).lineLimit(1)
                } else {
                    Text([update.sourceName, reinstalls ? "更新后自动重签并安装" : "更新后需重新签名"].joined(separator: " · "))
                        .font(.caption2).foregroundStyle(Palette.tertiaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if sources.isDownloading(update.version) {
                Button { sources.cancelDownload(update.version) } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.borderless).foregroundStyle(Color.secondary).accessibilityLabel("取消更新 \(update.package.name)")
            } else {
                Button("更新") { sources.update(update, into: store) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
                    .accessibilityIdentifier("library.update." + update.package.id.uuidString)
            }
        }.padding(.vertical, 6)
    }
}
