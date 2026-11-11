import IPadnKit
import SwiftUI
import QuickLook
import IdeviceGateway

/// 设备工具：通过回环读取这台 iPhone 上的描述文件、侧载应用、应用文件与设备信息。
struct DeviceToolsView: View {
    @EnvironmentObject private var renewal: RenewalController
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var tools = DeviceToolsStore.shared
    @State private var confirmCleanup = false
    @State private var confirmRespring = false
    @State private var showRespring = false
    @State private var respringOwnsWorkspace = false

    var body: some View {
        List {
            if tools.backend.isSample {
                Section { Label("模拟器没有设备服务，以下为示例数据。", systemImage: "info.circle").font(.footnote).foregroundStyle(Color.secondary) }
            }
            ToolPageIntro(tool: .overview, title: tools.info?.name.isEmpty == false ? tools.info!.name : "这台 iPhone", detail: "应用与数据、设备诊断和系统操作。各功能可独立读取。")
            Section {
                header
                NavigationLink { DeviceConnectionView() } label: { LabeledContent("配对与连接", value: renewal.connectionSummary) }
            }
            if case .failed(let message) = tools.phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                    NavigationLink("检查设备配对与连接") { DeviceConnectionView() }
                }
            }
            if !tools.cleanupCandidates.isEmpty {
                Section {
                    Button { confirmCleanup = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles").foregroundStyle(Palette.accent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("清理 \(tools.cleanupCandidates.count) 份无用的描述文件").font(.body.weight(.semibold))
                                Text("已过期，或已被证书相同的新描述文件取代").font(.footnote).foregroundStyle(Color.secondary)
                            }
                        }
                    }.disabled(tools.busy != nil).accessibilityIdentifier("deviceTools.cleanup")
                } footer: { Text("删除前会在 Retools 里留一份副本，可以在「描述文件 → 最近删除」里装回去。") }
            }
            Section("应用与数据") {
                NavigationLink { DeviceProfilesView() } label: {
                    toolRow("描述文件", symbol: "doc.badge.gearshape", value: "\(tools.profiles.count)")
                }.accessibilityIdentifier("deviceTools.profiles")
                NavigationLink { DeviceAppsView() } label: {
                    toolRow("应用", symbol: "square.grid.2x2", value: "\(tools.apps.count)")
                }.accessibilityIdentifier("deviceTools.apps")
                NavigationLink { AppDataBackupsView() } label: {
                    toolRow("数据备份", symbol: "externaldrive.badge.timemachine", value: tools.backups.isEmpty ? "" : "\(tools.backups.count)")
                }.accessibilityIdentifier("deviceTools.backups")
            }
            Section("诊断与信息") {
                NavigationLink { DeviceCrashReportsView() } label: {
                    toolRow("崩溃日志", symbol: "exclamationmark.octagon", value: "")
                }.accessibilityIdentifier("deviceTools.crashes")
                NavigationLink { DeviceLogConsoleView() } label: {
                    toolRow("实时日志", symbol: "text.alignleft", value: DeviceLogStore.shared.isRunning ? "接收中" : "")
                }.accessibilityIdentifier("deviceTools.logs")
                NavigationLink { DeviceInfoView() } label: {
                    toolRow("设备信息", symbol: "info.circle", value: tools.info?.systemVersion.isEmpty == false ? "iOS " + (tools.info?.systemVersion ?? "") : "")
                }.accessibilityIdentifier("deviceTools.info")
            }
            Section {
                Button(role: .destructive) { confirmRespring = true } label: {
                    Label("注销（重启桌面）", systemImage: "arrow.clockwise.circle")
                }
                .disabled(respringBlocked).accessibilityIdentifier("deviceTools.respring")
            } footer: {
                Text("通过现有配对连接请求重启桌面，请先保存其他应用中的内容。")
                if let record = tools.desktopRestartRecord {
                    Text(record.confirmedPID != nil ? "上次已确认桌面进程重新启动。" : (record.error ?? "上次请求尚未确认桌面重新启动。"))
                }
            }
            if let busy = tools.busy { Section { HStack { ProgressView(); Text(busy) } } }
        }
        .toolListStyle()
        .navigationTitle("设备工具").navigationBarTitleDisplayMode(.inline)
        .refreshable { await tools.refresh(renewal: renewal) }
        .confirmationDialog("删除 \(tools.cleanupCandidates.count) 份描述文件？", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await tools.removeProfiles(tools.cleanupCandidates, renewal: renewal) } }
        } message: { Text("只删除已过期、或已被证书相同的新描述文件取代的旧描述文件。删除前会保留副本，30 天内可以恢复。") }
        .alert(confirmRespring ? "注销并重启桌面？" : "设备工具", isPresented: Binding(
            get: { confirmRespring || tools.errorMessage != nil },
            set: { if !$0 { confirmRespring = false; tools.errorMessage = nil } }
        )) {
            if confirmRespring {
                Button("注销", role: .destructive) { presentRespring() }
                Button("取消", role: .cancel) {}
            } else { Button("好", role: .cancel) {} }
        } message: {
            Text(confirmRespring ? "将使用设备服务请求重新载入系统桌面，当前应用可能中断，未保存的内容可能丢失。" : (tools.errorMessage ?? ""))
        }
        .fullScreenCover(isPresented: $showRespring, onDismiss: {
            if respringOwnsWorkspace { store.isWorking = false; store.workLabel = ""; respringOwnsWorkspace = false }
        }) { RespringView() }
    }

    private var respringBlocked: Bool {
        store.isWorking || renewal.isWorking || tools.busy != nil || tools.transfer != nil || DevicePairingCoordinator.shared.isRunning
    }
    private func presentRespring() {
        guard !respringBlocked else { tools.errorMessage = "正在处理其他任务，请完成后再注销。"; return }
        respringOwnsWorkspace = true; store.isWorking = true; store.workLabel = ""
        showRespring = true
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("设备数据").font(.headline)
                Group {
                    if tools.phase == .loading { Text("正在" + (tools.currentStep ?? "读取") + "…" + (tools.updatedAt == nil ? "" : "（先显示上次的内容）")) }
                    else if tools.showingCache, let updated = tools.updatedAt { Text("上次读取于 " + updated.formatted(date: .abbreviated, time: .shortened) + "，刷新未成功") }
                    else if let updated = tools.updatedAt { Text("更新于 " + updated.formatted(date: .omitted, time: .shortened)) }
                    else { Text("通过回环读取设备服务") }
                }.font(.footnote).foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 0)
            Button { Task { await tools.refresh(renewal: renewal) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(tools.phase == .loading || tools.busy != nil).accessibilityIdentifier("deviceTools.refresh")
        }.padding(.vertical, 4)
    }

    private func toolRow(_ title: String, symbol: String, value: String) -> some View {
        HStack {
            ToolGlyph(symbol: symbol, color: Palette.accent, size: 32)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(Color.secondary).monospacedDigit()
        }
    }
}

// MARK: - 描述文件

struct DeviceProfilesView: View {
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var tools = DeviceToolsStore.shared
    @State private var pending: DeviceProfile?
    @State private var query = ""
    private func matches(_ profile: DeviceProfile) -> Bool {
        query.isEmpty || [profile.name, profile.appIdentifier, profile.teamName, profile.teamID].contains { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            ToolPageIntro(tool: .profiles, title: "签名与有效期", detail: "按使用状态查看描述文件。删除前保留副本，30 天内可恢复。")
            Section { ToolMetrics(items: [("设备文件", "\(tools.profiles.count)"), ("可清理", "\(tools.cleanupCandidates.count)"), ("最近删除", "\(tools.trash.count)")]) }
            DeviceServiceStatus(phase: tools.profilesPhase) { await tools.loadProfiles(renewal: renewal) }
            let groups: [(String, String?, [DeviceProfile])] = [
                ("使用中", nil, tools.profiles.filter { if case .inUse = tools.usage[$0.uuid] { return true }; return tools.usage[$0.uuid] == nil }),
                ("可能未使用", "这些描述文件没有和已安装应用直接对应上，但应用扩展、其他工具安装的应用或用旧证书签名的应用仍可能依赖它们。不确定时请保留。",
                 tools.uncertainProfiles),
                ("可以清理", "已过期，或同一个 App ID 已有包含相同签名证书、到期更晚的描述文件。Retools 每次续签都会装一份新的，旧的会留在这里。", tools.cleanupCandidates)]
            ForEach(groups.map { ($0.0, $0.1, $0.2.filter(matches)) }.filter { !$0.2.isEmpty }, id: \.0) { title, footer, items in
                Section {
                    ForEach(items) { profile in DeviceProfileRow(profile: profile, usage: tools.usage[profile.uuid]) { pending = profile } }
                } header: { Text(title) } footer: { if let footer { Text(footer) } }
            }
            if tools.profilesPhase == .ready, tools.profiles.filter(matches).isEmpty {
                ContentUnavailableView(query.isEmpty ? "没有描述文件" : "没有匹配的描述文件", systemImage: "doc.badge.gearshape")
            }
            if !tools.trash.isEmpty {
                Section {
                    ForEach(tools.trash) { entry in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name).lineLimit(1)
                                Text(entry.appIdentifier).font(.caption.monospaced()).foregroundStyle(Color.secondary).lineLimit(1)
                                Text("删除于 " + entry.deletedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Color.secondary)
                            }
                            Spacer(minLength: 6)
                            Button("恢复") { Task { await tools.restoreProfiles([entry], renewal: renewal) } }
                                .buttonStyle(.bordered).disabled(tools.busy != nil)
                        }
                        .swipeActions { Button("移除副本", role: .destructive) { tools.discardTrash([entry]) } }
                    }
                    if tools.trash.count > 1 {
                        Button("全部恢复（\(tools.trash.count) 份）") { Task { await tools.restoreProfiles(tools.trash, renewal: renewal) } }
                            .disabled(tools.busy != nil).accessibilityIdentifier("deviceTools.trash.restoreAll")
                    }
                } header: { Text("最近删除") } footer: { Text("删除的描述文件会保留副本 30 天。装回去后，依赖它的应用就能重新打开。") }
            }
            if let busy = tools.busy { Section { HStack { ProgressView(); Text(busy) } } }
        }
        .toolListStyle()
        .searchable(text: $query, prompt: "名称、应用标识或团队")
        .navigationTitle("描述文件").navigationBarTitleDisplayMode(.inline)
        .refreshable { await tools.loadApps(renewal: renewal); await tools.loadProfiles(renewal: renewal) }
        .task { await tools.loadApps(renewal: renewal); await tools.loadProfiles(renewal: renewal) }
        .alert("描述文件", isPresented: Binding(get: { tools.errorMessage != nil }, set: { if !$0 { tools.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(tools.errorMessage ?? "") }
        .confirmationDialog(pendingTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible, presenting: pending) { profile in
            Button("删除", role: .destructive) { Task { await tools.removeProfiles([profile], renewal: renewal) } }
        } message: { profile in
            if case .inUse(let apps) = tools.usage[profile.uuid] {
                Text("「\(apps.joined(separator: "、"))」正在使用它。删除后这些应用将无法打开，直到重新签名安装。")
            } else if tools.usage[profile.uuid] == .expired {
                Text("已过期的描述文件不再起作用。删除前会保留副本。")
            } else {
                Text("没能确认有应用在用它，但应用扩展、其他工具安装的应用或用旧证书签名的应用仍可能依赖它。删除前会保留副本，30 天内可以恢复。")
            }
        }
    }

    private var pendingTitle: String { pending.map { "删除「\($0.name)」？" } ?? "" }
}

private struct DeviceProfileRow: View {
    let profile: DeviceProfile
    let usage: DeviceProfileUsage?
    let onDelete: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.body.weight(.semibold)).lineLimit(1)
                    if profile.debuggable { Text("开发").font(.caption2.weight(.semibold)).foregroundStyle(Color.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                }
                Text(profile.appIdentifier).font(.caption.monospaced()).foregroundStyle(Color.secondary).lineLimit(1).textSelection(.enabled)
                Text([profile.teamName, profile.teamID].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Color.secondary).lineLimit(1)
                if let usage { Text(usage.title).font(.caption).foregroundStyle(usage.cleanable ? .orange : .secondary).lineLimit(2) }
            }
            Spacer(minLength: 6)
            ExpiryBadge(expiry: profile.expires)
        }
        .padding(.vertical, 2)
        .swipeActions { Button("删除", role: .destructive, action: onDelete) }
        .contextMenu {
            Button { UIPasteboard.general.string = profile.uuid } label: { Label("复制 UUID", systemImage: "doc.on.doc") }
            Button(role: .destructive, action: onDelete) { Label("删除描述文件", systemImage: "trash") }
        }
    }
}

// MARK: - 侧载应用

private func deviceAppSizeLabel(_ value: Int64?, phase: DeviceToolsStore.Phase) -> String {
    if let value { return value.byteLabel }
    switch phase {
    case .idle: return "待读取"
    case .loading: return "读取中"
    case .ready: return "未提供"
    case .failed: return "读取失败"
    }
}

private struct DeviceAppSizeStatus: View {
    @ObservedObject private var tools = DeviceToolsStore.shared
    @EnvironmentObject private var renewal: RenewalController
    var body: some View {
        if tools.loadingSizes {
            Section { HStack { ProgressView(); Text("正在读取应用和数据大小…").font(.footnote) } }
        } else if case .failed(let message) = tools.sizesPhase {
            Section {
                Text("未能读取应用大小：" + message).font(.footnote).foregroundStyle(.orange)
                Button("重新读取大小") { Task { await tools.loadAppSizes(renewal: renewal, force: true) } }
                    .accessibilityIdentifier("deviceTools.apps.retrySizes")
            }
        }
    }
}

struct DeviceAppsView: View {
    @EnvironmentObject private var renewal: RenewalController
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var tools = DeviceToolsStore.shared
    @State private var query = ""
    @State private var kind: DeviceInstalledApp.Kind = .sideloaded

    private var managed: Set<String> {
        Set(store.state.packages.flatMap { [$0.bundleID, $0.signedBundleID].compactMap { $0 } } + [Bundle.main.bundleIdentifier].compactMap { $0 })
    }

    var body: some View {
        let items = tools.apps(of: kind).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query) }
        List {
            ToolPageIntro(tool: .apps, title: "已安装的应用", detail: "查看签名与存储，管理应用文件和数据备份。")
            if kind != .system {
                DeviceServiceStatus(phase: tools.appsPhase) { await tools.loadApps(renewal: renewal) }
            }
            Section {
                ToolMetrics(items: [("当前分类", "\(tools.apps(of: kind).count) 个"), ("筛选结果", "\(items.count) 个")])
                Picker("类别", selection: $kind) {
                    ForEach(DeviceInstalledApp.Kind.allCases) { kind in
                        Text(kind == .system || tools.apps(of: kind).isEmpty ? kind.title : "\(kind.title) \(tools.apps(of: kind).count)").tag(kind)
                    }
                }.pickerStyle(.segmented)
                    .accessibilityIdentifier("deviceTools.apps.kind")
            }
            if kind == .system, tools.systemPhase == .loading, tools.systemApps.isEmpty {
                HStack { ProgressView(); Text("正在读取系统应用…").foregroundStyle(Color.secondary) }
            } else if kind == .system, case .failed(let message) = tools.systemPhase {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
            DeviceAppSizeStatus()
            Section {
                ForEach(items) { app in
                    NavigationLink { DeviceAppDetailView(app: app) } label: {
                        HStack(spacing: 12) {
                            DeviceAppIcon(bundleID: app.bundleID)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(app.name).font(.body.weight(.semibold)).lineLimit(1)
                                    if managed.contains(app.bundleID) { StatusPill(title: "Retools") }
                                }
                                if !app.version.isEmpty { Text("v" + app.version).font(.caption).foregroundStyle(Color.secondary) }
                                Text("应用 \(deviceAppSizeLabel(app.reportedBundleSize, phase: tools.sizesPhase)) · 数据 \(deviceAppSizeLabel(app.reportedDataSize, phase: tools.sizesPhase))")
                                    .font(.caption).foregroundStyle(Color.secondary)
                                    .accessibilityIdentifier("deviceTools.app.storage.\(app.bundleID)")
                            }
                            Spacer(minLength: 6)
                            if app.kind == .sideloaded || app.kind == .testFlight { ExpiryBadge(expiry: tools.activeProfile(for: app)?.expires) }
                        }
                    }.accessibilityIdentifier("deviceTools.app.\(app.bundleID)")
                }
            } footer: {
                if !items.isEmpty {
                    let known = items.reduce(Int64(0)) { $0 + ($1.reportedBundleSize ?? 0) + ($1.reportedDataSize ?? 0) }
                    Text(known > 0 ? "共 \(items.count) 个，已读取占用 \(known.byteLabel)" : "共 \(items.count) 个")
                }
            }
            if items.isEmpty, (kind == .system ? tools.systemPhase : tools.appsPhase) == .ready {
                ContentUnavailableView(query.isEmpty ? "没有\(kind.title)应用" : "没有匹配的应用", systemImage: "app.dashed")
            }
        }
        .searchable(text: $query, prompt: "名称或 Bundle ID")
        .toolListStyle()
        .navigationTitle("应用").navigationBarTitleDisplayMode(.inline)
        .refreshable {
            if kind == .system { await tools.loadSystemApps(renewal: renewal) } else { await tools.loadApps(renewal: renewal) }
            await tools.loadAppSizes(renewal: renewal, force: true)
        }
        .onChange(of: kind) { _, kind in
            Task {
                if kind == .system, tools.systemApps.isEmpty { await tools.loadSystemApps(renewal: renewal) }
                async let icons: Void = tools.loadIcons(for: tools.apps(of: kind), renewal: renewal)
                await tools.loadAppSizes(renewal: renewal)
                await icons
            }
        }
        .task {
            await tools.loadApps(renewal: renewal)
            if tools.appsPhase == .ready {
                async let icons: Void = tools.loadIcons(for: tools.apps(of: kind), renewal: renewal)
                await tools.loadAppSizes(renewal: renewal)
                await icons
            }
        }
    }
}

struct DeviceAppDetailView: View {
    let app: DeviceInstalledApp
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var tools = DeviceToolsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUninstall = false
    @State private var showStoreVersions = false
    @State private var restoring: AppDataBackup?
    private var latestApp: DeviceInstalledApp {
        tools.apps.first { $0.bundleID == app.bundleID } ?? tools.systemApps.first { $0.bundleID == app.bundleID } ?? app
    }

    var body: some View {
        let app = latestApp
        List {
            Section {
                HStack(spacing: 14) {
                    DeviceAppIcon(bundleID: app.bundleID, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.headline)
                        Text(app.kind.title + (app.version.isEmpty ? "" : " · v" + app.version)).font(.subheadline).foregroundStyle(Color.secondary)
                    }
                }.padding(.vertical, 4)
                LabeledContent("Bundle ID") { Text(app.bundleID).font(.footnote.monospaced()).textSelection(.enabled) }
                if !app.version.isEmpty { LabeledContent("版本", value: app.build.isEmpty ? app.version : "\(app.version)（\(app.build)）") }
                if !app.signer.isEmpty { LabeledContent("签名") { Text(app.signer).font(.footnote).multilineTextAlignment(.trailing) } }
                LabeledContent("应用大小", value: deviceAppSizeLabel(app.reportedBundleSize, phase: tools.sizesPhase))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("deviceTools.app.bundleSize")
                LabeledContent("数据大小", value: deviceAppSizeLabel(app.reportedDataSize, phase: tools.sizesPhase))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("deviceTools.app.dataSize")
            }
            DeviceAppSizeStatus()
            if app.kind == .sideloaded || app.kind == .testFlight {
            Section("描述文件") {
                let profiles = tools.profiles(for: app)
                if profiles.isEmpty { Text("设备上没有找到对应的描述文件。").foregroundStyle(Color.secondary) }
                ForEach(profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).lineLimit(1)
                            Text(profile.uuid == tools.activeProfile(for: app)?.uuid ? "当前使用" : (tools.usage[profile.uuid]?.title ?? ""))
                                .font(.caption).foregroundStyle(Color.secondary)
                        }
                        Spacer()
                        ExpiryBadge(expiry: profile.expires)
                    }
                }
            }
            }
            Section {
                NavigationLink { DeviceContainerBrowser(app: app, path: "/") } label: { Label("浏览应用文件", systemImage: "folder") }
                    .disabled(!app.filesAccessible).accessibilityIdentifier("deviceTools.files")
            } footer: {
                Text(app.debuggable ? "开发签名的应用可以访问整个沙盒。" : (app.fileSharing ? "这个应用开启了文件共享，可以访问「文稿」文件夹。" : "系统只允许读取开发签名、或开启了文件共享的应用的文件。"))
            }
            if app.dataContainerPath != nil {
                Section {
                    NavigationLink { DeviceContainerBrowser(app: app, path: "/", mode: .local) } label: {
                        Label("本机文件管理", systemImage: "iphone")
                    }.accessibilityIdentifier("deviceTools.files.local")
                } footer: { Text("使用本机文件权限读取，需兼容系统与 App Group 授权。") }
            }
            if !app.isSystem, app.bundleID != Bundle.main.bundleIdentifier {
                Section {
                    Button { showStoreVersions = true } label: { Label("下载历史版本 / 降级", systemImage: "clock.arrow.circlepath") }
                        .accessibilityIdentifier("deviceTools.storeVersions")
                } footer: { Text("登录拥有这个应用的商店账号，选择历史版本下载后安装。") }
            }
            Section {
                Button { Task { await tools.launch(app, renewal: renewal) } } label: { Label("启动应用", systemImage: "play.circle") }
                    .disabled(tools.busy != nil).accessibilityIdentifier("deviceTools.launch")
            } footer: { Text("通过开发者工具直接启动，需要开发者镜像（没挂载时会自动挂载）。") }
            if app.filesAccessible {
                Section {
                    Button { Task { await tools.backup(app, renewal: renewal) } } label: {
                        Label("备份应用数据" + (app.dataSize > 0 ? "（约 \(app.dataSize.byteLabel)）" : ""), systemImage: "externaldrive.badge.plus")
                    }.disabled(tools.transfer != nil || tools.busy != nil).accessibilityIdentifier("deviceTools.backup")
                    ForEach(tools.backups(for: app)) { backup in AppDataBackupRow(backup: backup) { restoring = backup } }
                } header: { Text("数据备份") } footer: {
                    Text(app.debuggable ? "备份整个沙盒（存档、登录状态、设置），不含缓存和临时文件。重签换了 Bundle ID 后，也可以把备份恢复到新的应用。"
                                        : "这个应用只开放了「文稿」文件夹，只能备份其中的内容。")
                }
                DeviceTransferSection()
            }
            if app.bundleID != Bundle.main.bundleIdentifier, app.kind != .system {
                Section {
                    Button("卸载应用", role: .destructive) { confirmUninstall = true }.disabled(tools.busy != nil).accessibilityIdentifier("deviceTools.uninstall")
                }
            }
            if let busy = tools.busy { Section { HStack { ProgressView(); Text(busy) } } }
        }
        .toolListStyle()
        .navigationTitle(app.name).navigationBarTitleDisplayMode(.inline)
        .task {
            async let icons: Void = tools.loadIcons(for: [app], renewal: renewal)
            await tools.loadAppSizes(renewal: renewal)
            await icons
        }
        .sheet(item: $restoring) { AppDataRestoreSheet(backup: $0) }
        .alert("设备工具", isPresented: Binding(get: { tools.errorMessage != nil }, set: { if !$0 { tools.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(tools.errorMessage ?? "") }
        .navigationDestination(isPresented: $showStoreVersions) {
            StoreBrowserHostView(initialSearch: app.name)
        }
        .confirmationDialog("卸载「\(app.name)」？", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("卸载", role: .destructive) { Task { await tools.uninstall(app, renewal: renewal); dismiss() } }
        } message: {
            Text("应用和它的全部数据（\(app.dataSize.byteLabel)）都会从这台 iPhone 上删除，无法恢复。" + (app.kind == .appStore ? "之后可以从 App Store 重新下载。" : (app.kind == .testFlight ? "之后可以从 TestFlight 重新安装。" : "应用库里的安装包不受影响。")))
        }
    }
}

// MARK: - 应用文件

@MainActor
struct DeviceContainerBrowser: View {
    let app: DeviceInstalledApp
    let path: String
    var root: DeviceFileRoot? = nil
    var mode: DeviceFileAccess.Mode = .device
    private var localFileAccess: Bool { mode == .local }
    @EnvironmentObject private var renewal: RenewalController
    @EnvironmentObject private var workspace: WorkspaceStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var tools = DeviceToolsStore.shared
    @State private var items: [DeviceFileItem] = []
    @State private var localKinds: [String: LocalFileEntry.Kind] = [:]
    @State private var localVersions: [String: LocalFileVersion] = [:]
    @State private var editing: LocalEditableDocument?
    @State private var access: DeviceContainerAccess?
    @State private var loading = false
    @State private var failure: String?
    @State private var working: String?
    @State private var preview: URL?
    @State private var share: SigningProjectShare?
    @State private var pendingDelete: DeviceFileItem?
    @State private var showImporter = false
    @State private var filePrompt: DeviceFilePrompt?
    @State private var renameName = ""
    @State private var pendingOverwrite: LocalFileImport?
    @State private var folderName = ""
    @State private var fileTask: Task<Void, Never>?
    @State private var query = ""
    private var visibleItems: [DeviceFileItem] { items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }

    private var title: String { path == "/" ? (root?.title ?? app.name) : (path as NSString).lastPathComponent }
    private var latestApp: DeviceInstalledApp { tools.apps.first { $0.bundleID == app.bundleID } ?? app }
    private var sharedRoots: [DeviceFileRoot] { localFileAccess && root == nil && path == "/" ? DeviceFileAccess.sharedRoots(for: latestApp) : [] }
    private var reloadID: String { localFileAccess ? "local-\(scenePhase == .active)" : "device" }
    private var canWrite: Bool { localFileAccess || root == nil }
    private var mutationsReady: Bool { !loading && working == nil && (localFileAccess ? failure == nil : access != nil) }
    /// 只能访问文稿时，根目录实际列出的是 /Documents。
    private var directory: String { access == .documents && path == "/" ? "/Documents" : path }

    var body: some View {
        List {
            if localFileAccess {
                Section {
                    Label("本机访问 · 读写", systemImage: "iphone").font(.footnote).foregroundStyle(Color.secondary)
                    Text("实际写入仍受文件所有者和系统权限限制。").font(.caption).foregroundStyle(Color.secondary)
                    if let target = try? DeviceFileAccess.target(for: latestApp, path: path, root: root) {
                        Text(target.path).font(.caption.monospaced()).foregroundStyle(Color.secondary).textSelection(.enabled)
                    }
                }
                    .accessibilityIdentifier("deviceTools.files.localMode")
            } else if path == "/", access == .documents {
                Section { Label("只能访问「文稿」文件夹。", systemImage: "lock").font(.footnote).foregroundStyle(Color.secondary) }
            }
            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                        .accessibilityIdentifier("deviceTools.files.failure")
                    if localFileAccess, HostAppGroup.signedIdentifier() == nil {
                        NavigationLink("配置 App Group 开发签名") { DevelopmentSigningView() }
                    }
                }
            }
            Section {
            ForEach(visibleItems) { item in
                Group {
                    if item.isDirectory {
                        NavigationLink { DeviceContainerBrowser(app: app, path: item.path, root: root, mode: mode) } label: { DeviceFileRow(item: item) }
                    } else if !readable(item) {
                        DeviceFileRow(item: item, note: localKinds[item.path] == .symbolicLink ? "符号链接" : "不可读取")
                            .foregroundStyle(Color.secondary)
                    } else {
                        Button { openFile(item) } label: { DeviceFileRow(item: item) }.tint(.primary)
                    }
                }
                .disabled(working != nil || loading)
                .swipeActions { if canWrite, mutable(item) { Button("删除", role: .destructive) { pendingDelete = item } } }
                .contextMenu {
                    if !item.isDirectory, readable(item) {
                        Button { open(item, sharing: false) } label: { Label("预览", systemImage: "eye") }
                        Button { open(item, sharing: true) } label: { Label("导出", systemImage: "square.and.arrow.up") }
                        if localFileAccess {
                            Button { edit(item) } label: { Label("编辑文本或属性列表", systemImage: "square.and.pencil") }
                        }
                    }
                    if localFileAccess, mutable(item) {
                        Button { renameName = item.name; filePrompt = .rename(item) } label: { Label("重命名", systemImage: "pencil") }
                    }
                    if canWrite, mutable(item) { Button(role: .destructive) { pendingDelete = item } label: { Label("删除", systemImage: "trash") } }
                }
            }
            } header: { Text("目录内容 · \(visibleItems.count)") }
            if !items.isEmpty, visibleItems.isEmpty { ContentUnavailableView.search(text: query) }
            if !sharedRoots.isEmpty {
                Section("共享数据") {
                    ForEach(sharedRoots) { shared in
                        NavigationLink { DeviceContainerBrowser(app: app, path: "/", root: shared, mode: .local) } label: { Label(shared.title, systemImage: "folder.fill") }
                    }
                }
            }
            if !loading, failure == nil, items.isEmpty, sharedRoots.isEmpty { ContentUnavailableView("空文件夹", systemImage: "folder") }
            if let working { Section { HStack { ProgressView(); Text(working) } } }
        }
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .toolListStyle()
        .searchable(text: $query, prompt: "搜索当前文件夹")
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canWrite { ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showImporter = true } label: { Label(localFileAccess ? "导入文件" : "上传文件", systemImage: "square.and.arrow.down") }
                    Button { folderName = ""; filePrompt = .folder } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                    if localFileAccess {
                        Button { folderName = "未命名.txt"; filePrompt = .textFile } label: { Label("新建文本文件", systemImage: "doc.badge.plus") }
                    }
                } label: { Image(systemName: "plus") }.disabled(!mutationsReady).accessibilityIdentifier("deviceTools.files.add")
            } }
            if localFileAccess { ToolbarItem(placement: .secondaryAction) {
                NavigationLink { LocalFileBackupsView() } label: { Label("文件备份", systemImage: "clock.arrow.circlepath") }
            } }
        }
        .refreshable { await load() }
        .task(id: reloadID) { if !localFileAccess || scenePhase == .active { await load() } }
        .onDisappear { fileTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in if localFileAccess && phase != .active { fileTask?.cancel() } }
        .sheet(isPresented: $showImporter) {
            DocumentImportPicker(isPresented: $showImporter) { result in
                switch result {
                case .success(let url): upload(url)
                case .failure(let error): filePrompt = .error(error.localizedDescription)
                }
            }
        }
        .sheet(item: Binding(get: { preview.map(PreviewFile.init) }, set: { if $0 == nil { preview = nil } })) { file in
            NavigationStack {
                DeviceQuickLook(file: file.url).ignoresSafeArea(edges: .bottom)
                    .navigationTitle(file.url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("完成") { preview = nil } }
                        ToolbarItem(placement: .topBarLeading) { ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up") } }
                    }
            }
        }
        .sheet(item: $share) { SigningProjectShareSheet(urls: $0.urls) }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { document in
            LocalFileEditor(document: document) { data in
                try await locally(message: "正在保存文件…") { group in
                    try await LocalFileAccessService.shared.save(path: document.path, data: data, expected: document.snapshot.version, group: group)
                }
                workspace.toast = "已保存，原文件已备份"
            }
        }
        .confirmationDialog(pendingDelete.map { "删除「\($0.name)」？" } ?? "", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { item in
            Button("删除", role: .destructive) { remove(item) }
        } message: { item in
            Text(localFileAccess ? (item.isDirectory ? "仅删除空文件夹；有内容的文件夹会保留。" : "删除前会在 Retools 中备份原文件，可从「文件备份」导出恢复。")
                 : (item.isDirectory ? "文件夹及其中所有内容都会从「\(app.name)」里删除，无法恢复。" : "文件会从「\(app.name)」里删除，无法恢复。"))
        }
        .alert(filePrompt?.title ?? "文件操作", isPresented: Binding(get: { filePrompt != nil }, set: { if !$0 { filePrompt = nil } }), presenting: filePrompt) { prompt in
            switch prompt {
            case .folder:
                TextField("名称", text: $folderName)
                Button("取消", role: .cancel) {}
                Button("新建") { makeFolder() }
            case .textFile:
                TextField("文件名", text: $folderName)
                Button("取消", role: .cancel) {}
                Button("新建") { makeTextFile() }
            case .rename(let item):
                TextField("名称", text: $renameName)
                Button("取消", role: .cancel) {}
                Button("保存名称") { rename(item) }
            case .error:
                Button("好", role: .cancel) {}
            }
        } message: { prompt in if case .error(let message) = prompt { Text(message) } }
        .confirmationDialog("替换已有文件？", isPresented: Binding(get: { pendingOverwrite != nil }, set: { if !$0 { pendingOverwrite = nil } }), titleVisibility: .visible, presenting: pendingOverwrite) { request in
            Button("备份并替换", role: .destructive) { importLocal(request) }
            Button("取消", role: .cancel) { discardImport(request.url) }
        } message: { request in Text("「\(request.name)」已存在，替换前会备份原文件。文件夹和特殊文件不会被覆盖。") }
    }

    private func load() async {
        loading = true; defer { loading = false }
        let local = localFileAccess
        do {
            if local {
                access = nil
                let listed = try await locally { group in
                    let target = try DeviceFileAccess.target(for: latestApp, path: path, root: root)
                    return try await LocalFileAccessService.shared.entries(path: target.path, group: group)
                }
                try Task.checkCancellation()
                guard localFileAccess else { return }
                items = DeviceFileItem.sorted(listed.map { DeviceFileAccess.item($0, in: path) })
                localKinds = Dictionary(uniqueKeysWithValues: listed.map { (DeviceFileItem.join(path, $0.name), $0.kind) })
                localVersions = Dictionary(uniqueKeysWithValues: listed.compactMap { entry in
                    entry.version.map { (DeviceFileItem.join(path, entry.name), $0) }
                })
            } else {
                guard root == nil else { throw WorkspaceFailure("本机文件访问已关闭，请返回应用详情。") }
                let result = try await tools.entries(of: app, path: path, renewal: renewal)
                try Task.checkCancellation()
                guard !localFileAccess else { return }
                access = result.access; items = result.entries; localKinds = [:]; localVersions = [:]
            }
            failure = nil
        } catch is CancellationError { }
        catch { items = []; localKinds = [:]; localVersions = [:]; failure = "无法读取：\(error.localizedDescription)" }
    }

    private func readable(_ item: DeviceFileItem) -> Bool {
        !localFileAccess || localKinds[item.path] == .file || localKinds[item.path] == .directory
    }

    private func mutable(_ item: DeviceFileItem) -> Bool {
        !localFileAccess || localVersions[item.path].map { $0.isFile || $0.isDirectory } == true
    }

    private func locally<T>(message: String = "正在读取本机文件…", _ operation: (String) async throws -> T) async throws -> T {
        guard localFileAccess, scenePhase == .active else { throw CancellationError() }
        if let reason = LocalFileAccessService.unavailableReason { throw WorkspaceFailure(reason) }
        guard let group = try HostAppGroup.readSignedIdentifier() else { throw WorkspaceFailure("请先安装带 App Group 授权的开发签名包。") }
        guard !workspace.isWorking, !renewal.isWorking else { throw WorkspaceFailure("正在处理其他任务，请稍后重试。") }
        workspace.isWorking = true; workspace.workLabel = message
        defer { workspace.isWorking = false; workspace.workLabel = "" }
        return try await operation(group)
    }

    private func openFile(_ item: DeviceFileItem) {
        if localFileAccess, ["txt", "json", "plist", "xml", "md", "yaml", "yml", "log", "conf", "ini", "strings", "entitlements", "mobileconfig", "csv"].contains((item.name as NSString).pathExtension.lowercased()) {
            edit(item)
        } else { open(item, sharing: false) }
    }

    private func edit(_ item: DeviceFileItem) {
        guard localFileAccess, readable(item), !item.isDirectory else { return }
        run("正在打开编辑器…") {
            let target = try DeviceFileAccess.target(for: latestApp, path: item.path, root: root)
            let snapshot = try await locally { try await LocalFileAccessService.shared.snapshot(path: target.path, group: $0) }
            editing = try LocalEditableDocument(path: target.path, snapshot: snapshot)
        }
    }

    private func run(_ message: String, _ body: @escaping () async throws -> Void) {
        guard working == nil else { return }
        working = message
        fileTask = Task { @MainActor in
            defer { working = nil; fileTask = nil }
            do { try await body() }
            catch is CancellationError { }
            catch { if localFileAccess { filePrompt = .error(error.localizedDescription) } else { tools.errorMessage = error.localizedDescription } }
        }
    }

    private func open(_ item: DeviceFileItem, sharing: Bool) {
        guard readable(item) else { return }
        let local = localFileAccess
        run("正在读取「\(item.name)」…") {
            let url: URL
            if local {
                url = try await locally { group in
                    let target = try DeviceFileAccess.target(for: latestApp, path: item.path, root: root)
                    return try await LocalFileAccessService.shared.export(path: target.path, group: group)
                }
            } else { url = try await tools.download(item, of: app, renewal: renewal) }
            do { try Task.checkCancellation() }
            catch { if local { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }; throw error }
            if sharing { share = SigningProjectShare(urls: [url]) } else { preview = url }
        }
    }

    private func upload(_ url: URL) {
        guard canWrite else { return }
        if localFileAccess {
            let name = url.lastPathComponent
            let version = localVersions[DeviceFileItem.join(path, name)]
            let request = LocalFileImport(url: url, name: name, version: version)
            if items.contains(where: { $0.name == name }) { pendingOverwrite = request }
            else { importLocal(request) }
            return
        }
        run("正在上传…") {
            _ = try await tools.upload(url, to: directory, existing: Set(items.map(\.name)), of: app, renewal: renewal)
            try? FileManager.default.removeItem(at: url)
            await load()
        }
    }

    private func makeFolder() {
        guard canWrite else { return }
        let name = folderName
        run("正在新建文件夹…") {
            if localFileAccess {
                let target = try DeviceFileAccess.target(for: latestApp, path: path, root: root)
                try await locally(message: "正在新建文件夹…") { try await LocalFileAccessService.shared.makeDirectory(directory: target.path, name: name, group: $0) }
            } else { try await tools.makeDirectory(name, in: directory, of: app, renewal: renewal) }
            await load()
        }
    }

    private func remove(_ item: DeviceFileItem) {
        guard canWrite else { return }
        run("正在删除…") {
            if localFileAccess {
                let target = try DeviceFileAccess.target(for: latestApp, path: item.path, root: root)
                guard let expected = localVersions[item.path] else { throw WorkspaceFailure("文件状态已失效，请刷新后重试。") }
                try await locally(message: "正在删除文件…") { try await LocalFileAccessService.shared.remove(path: target.path, expected: expected, group: $0) }
            } else { try await tools.remove(item, of: app, renewal: renewal) }
            await load()
        }
    }

    private func makeTextFile() {
        let name = folderName
        run("正在新建文件…") {
            let target = try DeviceFileAccess.target(for: latestApp, path: path, root: root)
            try await locally(message: "正在新建文件…") { try await LocalFileAccessService.shared.createTextFile(directory: target.path, name: name, group: $0) }
            await load()
        }
    }

    private func rename(_ item: DeviceFileItem) {
        let name = renameName
        run("正在重命名…") {
            let target = try DeviceFileAccess.target(for: latestApp, path: item.path, root: root)
            guard let expected = localVersions[item.path] else { throw WorkspaceFailure("文件状态已失效，请刷新后重试。") }
            try await locally(message: "正在重命名…") { try await LocalFileAccessService.shared.rename(path: target.path, name: name, expected: expected, group: $0) }
            await load()
        }
    }

    private func importLocal(_ request: LocalFileImport) {
        run("正在导入文件…") {
            defer { discardImport(request.url) }
            let target = try DeviceFileAccess.target(for: latestApp, path: path, root: root)
            try await locally(message: "正在导入文件…") {
                try await LocalFileAccessService.shared.importFile(request.url, directory: target.path, name: request.name, replacing: request.version, group: $0)
            }
            await load()
        }
    }
    private func discardImport(_ url: URL) {
        if url.path.hasPrefix(FileManager.default.temporaryDirectory.appendingPathComponent("Picked").path + "/") {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }
}

private enum DeviceFilePrompt {
    case folder, textFile, rename(DeviceFileItem), error(String)
    var title: String {
        switch self {
        case .folder: "新建文件夹"
        case .textFile: "新建文本文件"
        case .rename: "重命名"
        case .error: "文件操作未完成"
        }
    }
}

private struct LocalFileImport { let url: URL; let name: String; let version: LocalFileVersion? }

private struct PreviewFile: Identifiable { let url: URL; var id: URL { url } }

private struct DeviceFileRow: View {
    let item: DeviceFileItem
    var note: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc").foregroundStyle(item.isDirectory ? Palette.accent : .secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                let detail = [note, item.isDirectory || note != nil ? nil : item.size.byteLabel, item.modified?.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }
                if !detail.isEmpty { Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(Color.secondary) }
            }
        }
    }
}

private struct DeviceQuickLook: UIViewControllerRepresentable {
    let file: URL
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let file: URL
        init(file: URL) { self.file = file }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { file as NSURL }
    }
    func makeCoordinator() -> Coordinator { Coordinator(file: file) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
}

// MARK: - 设备信息

struct DeviceInfoView: View {
    @EnvironmentObject private var renewal: RenewalController
    @ObservedObject private var tools = DeviceToolsStore.shared
    @State private var revealIdentifiers = false

    var body: some View {
        List {
            ToolPageIntro(tool: .deviceInfo, title: tools.info?.name.isEmpty == false ? tools.info!.name : "设备状态", detail: "系统、存储与电池信息。设备标识默认隐藏。")
            DeviceServiceStatus(phase: tools.infoPhase) { await tools.loadDeviceInfo(renewal: renewal) }
            if let info = tools.info {
                Section {
                    ToolMetrics(items: [("系统", "iOS " + info.systemVersion), ("电量", info.batteryLevel.map { "\($0)%" } ?? "—"), ("可用空间", info.dataAvailable?.byteLabel ?? "—")])
                }
                Section("设备") {
                    row("名称", info.name)
                    row("机型标识", info.productType)
                    row("主板型号", info.hardwareModel)
                    row("激活状态", info.activation == "Activated" ? "已激活" : info.activation)
                }
                Section("系统") {
                    row("iOS 版本", info.systemVersion)
                    row("内部版本", info.build)
                }
                if let total = info.totalCapacity, let free = info.dataAvailable, total > 0 {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: Double(min(total, max(0, total - free))), total: Double(total)).tint(Double(free) / Double(total) < 0.1 ? .red : Palette.accent)
                            HStack {
                                Text("已用 \(max(0, total - free).byteLabel)")
                                Spacer()
                                Text("可用 \(free.byteLabel) / 共 \(total.byteLabel)").foregroundStyle(Color.secondary)
                            }.font(.footnote.monospacedDigit())
                        }.padding(.vertical, 4)
                    } header: { Text("存储空间") } footer: {
                        if let purgeable = info.purgeable, purgeable > 1_000_000_000 {
                            Text("另有约 \(purgeable.byteLabel) 是系统可以按需释放的空间（如缓存、可重新下载的内容），没有算进可用。")
                        }
                    }
                }
                if let level = info.batteryLevel {
                    Section {
                        HStack {
                            Label("\(level)%", systemImage: batterySymbol(level, charging: info.charging == true)).font(.body.monospacedDigit())
                            Spacer()
                            Text(info.charging == true ? "正在充电" : (info.externalPower == true ? "已接通电源" : "使用电池")).foregroundStyle(Color.secondary)
                        }
                    } header: { Text("电池") }
                }
                if let health = info.batteryHealth {
                    Section {
                        if let percent = health.healthPercent {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("\(percent)%").font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
                                    Text("最大容量").foregroundStyle(Color.secondary)
                                }
                                ProgressView(value: Double(percent), total: 100).tint(percent < 80 ? .orange : .green)
                            }.padding(.vertical, 4)
                        }
                        if let cycles = health.cycleCount { LabeledContent("循环次数", value: "\(cycles)") }
                        if let design = health.designCapacity { LabeledContent("设计容量", value: "\(design) mAh") }
                        if let max = health.maxCapacity { LabeledContent("当前满电容量", value: "\(max) mAh") }
                        if let temperature = health.temperature { LabeledContent("温度", value: String(format: "%.1f ℃", temperature)) }
                        if let voltage = health.voltage { LabeledContent("电压", value: String(format: "%.2f V", Double(voltage) / 1000)) }
                        if health.charger != nil || health.chargerWatts != nil {
                            LabeledContent("充电器", value: [health.charger, health.chargerWatts.map { "\($0) W" }].compactMap { $0 }.joined(separator: " · "))
                        }
                    } header: { Text("电池健康") } footer: {
                        Text("最大容量按电池控制器报告的满电容量与设计容量计算，可能与「设置」里显示的略有差别。")
                    }
                }
                Section {
                    row("序列号", revealIdentifiers ? info.serial : mask(info.serial))
                    row("UDID", revealIdentifiers ? info.udid : mask(info.udid))
                    row("Wi-Fi 地址", revealIdentifiers ? info.wifiAddress : mask(info.wifiAddress))
                    Button(revealIdentifiers ? "隐藏标识" : "显示完整标识") { revealIdentifiers.toggle() }
                } header: { Text("标识") } footer: { Text("长按数值可以复制。截图分享前请先隐藏。") }
            } else {
                ContentUnavailableView("还没有读取设备信息", systemImage: "iphone")
            }
        }
        .toolListStyle()
        .navigationTitle("设备信息").navigationBarTitleDisplayMode(.inline)
        .refreshable { await tools.loadDeviceInfo(renewal: renewal) }
        .task { await tools.loadDeviceInfo(renewal: renewal) }
    }

    @ViewBuilder private func row(_ title: String, _ value: String) -> some View {
        if !value.isEmpty { LabeledContent(title) { Text(value).monospacedDigit().textSelection(.enabled) } }
    }
    private func mask(_ value: String) -> String { value.count > 6 ? String(value.prefix(4)) + "••••" + String(value.suffix(2)) : value }
    private func batterySymbol(_ level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level { case ..<13: return "battery.0percent"; case ..<38: return "battery.25percent"; case ..<63: return "battery.50percent"; case ..<88: return "battery.75percent"; default: return "battery.100percent" }
    }
}
