import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var addingSource = false
    @State private var editingSourceID: UUID?
    /// Results of the last "check all sources", by source.
    @State private var sourceChecks: [UUID: SourceCheckState] = [:]
    @State private var share: SharedFile?
    @State private var resetSettings = false
    @State private var clearCache = false
    var body: some View {
        Form {
            Section {
                Stepper("同时下载：\(store.settings.maxConcurrentDownloads)", value: $store.settings.maxConcurrentDownloads, in: 1...6)
                Stepper("等待任务上限：\(store.settings.maxQueuedDownloads)", value: $store.settings.maxQueuedDownloads, in: 1...100)
                Toggle("下载完成通知", isOn: $store.settings.notifications)
                Toggle("新版本提醒", isOn: $store.settings.updateNotifications)
                    .onChange(of: store.settings.updateNotifications) { _, on in
                        if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                    }
                Toggle("兼容下载模式", isOn: $store.settings.compatibleDownloadMode)
                if store.downloads.backgroundDownloadsUnavailable && !store.settings.compatibleDownloadMode {
                    Button("重新尝试后台下载") { store.downloads.retryBackgroundDownloads(); store.infoMessage = "下一个下载任务会重新尝试后台下载" }
                }
            } header: {
                Text("下载")
            } footer: {
                if store.downloads.backgroundDownloadsUnavailable && !store.settings.compatibleDownloadMode {
                    Text("当前签名下系统后台下载无法保存文件，已自动改用应用内下载，下载时请保持 Retools 在前台。更换签名后可以点按「重新尝试后台下载」。")
                } else {
                    Text("如在企业证书重签或特定环境下遇到“无法创建文件”报错，请开启兼容下载模式（使用应用前台直接下载，下载时请保持应用在前台）。")
                }
            }
            Section {
                Toggle("关注应用提醒", isOn: $store.settings.watchNotifications)
                    .onChange(of: store.settings.watchNotifications) { _, on in
                        if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
                    }
            } header: { Text("关注") } footer: {
                Text("关注的应用有新版本、降价、限免或下架时通知你。后台检查的时间由系统决定，打开商店下载时也会检查。")
            }
            Section("搜索设置") {
                Picker("搜索结果数量", selection: $store.settings.searchLimit) {
                    ForEach([10, 30, 50, 100, 200], id: \.self) { Text("\($0)").tag($0) }
                }
                LabeledContent("外观", value: "跟随 Retools")
            }
            ForEach($store.settings.versionSources) { $source in
                Section {
                    Button { editingSourceID = source.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name).foregroundStyle(Color.primary)
                                Text(source.urlTemplate).font(.caption2).foregroundStyle(Color.secondary).lineLimit(1)
                                if let check = sourceChecks[source.id] { SourceCheckLabel(state: check) }
                            }
                            Spacer()
                            Text(source.enabled ? "已启用" : "已停用").font(.caption).foregroundStyle(Color.secondary)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color(uiColor: .tertiaryLabel))
                        }
                    }
                    .accessibilityIdentifier("settings.source." + source.name)
                    .revealDelete(id: "source." + source.id.uuidString, title: "移除") {
                        let id = source.id
                        withAnimation { store.settings.versionSources.removeAll { $0.id == id } }
                    }
                } header: { if source.id == store.settings.versionSources.first?.id { Text("历史版本来源") } }
            }
            Section {
                Button { checkSources() } label: {
                    HStack {
                        Label("检测全部来源", systemImage: "checkmark.circle")
                        Spacer()
                        if sourceChecks.values.contains(.checking) { ProgressView() }
                    }
                }
                .disabled(sourceChecks.values.contains(.checking) || store.settings.versionSources.isEmpty)
                .accessibilityIdentifier("settings.sources.check")
                Button("添加版本来源", systemImage: "plus") { addingSource = true }
            } footer: {
                Text("用于查询应用的历史版本。检测会用微信的版本记录逐个请求每个来源，显示是否可用、返回的版本数和耗时。")
            }
            Section {
                Toggle("加快重复下载", isOn: $store.settings.useSignerCache)
                Button("清除缓存") { store.signer.clearCache(); store.infoMessage = "已清除缓存" }
            } header: { Text("性能") } footer: {
                Text("缓存仅在本次运行期间保留。")
            }
            Section {
                StoreNavigationLink { InstallationSettingsView() } label: { Label("安装设置", systemImage: "arrow.down.app") }
                    .accessibilityIdentifier("settings.installation")
            }
            Section {
                Toggle("专业模式", isOn: $store.settings.proMode.animation())
                    .accessibilityIdentifier("settings.pro-mode")
                if store.settings.proMode {
                    StoreNavigationLink { CredentialsView() } label: { Label("账号与设备标识", systemImage: "key") }
                        .accessibilityIdentifier("settings.credentials")
                }
            } footer: {
                Text(store.settings.proMode ? "可以在下载任务详情中浏览安装包内容，并查看账号令牌和设备标识。"
                     : "打开后可以浏览安装包内容、查看账号令牌和修改设备标识。")
            }
            Section("维护") {
                StoreNavigationLink { StorageView() } label: { Label("存储空间", systemImage: "internaldrive") }
                    .accessibilityIdentifier("settings.storage")
                Button("清除历史版本缓存") { clearCache = true }
                Button("导出诊断信息") {
                    do { share = SharedFile(url: try store.exportDiagnostics()) } catch { store.errorMessage = error.localizedDescription }
                }
                Button("恢复默认设置", role: .destructive) { resetSettings = true }
            }
            Section("关于商店下载") {
                Text("基于 iPadn 1.9.0").font(.headline).foregroundStyle(Color.primary)
                Text("搜索、下载和管理你拥有许可的应用安装包。下载的 IPA 可导入 Retools 应用库或用于准备解密助手。")
                    .font(.footnote).foregroundStyle(Color.secondary)
                Link("iPadn 项目与源代码", destination: URL(string: "https://github.com/mengangs/ipadn")!)
                StoreNavigationLink("开源许可") {
                    ScrollView { Text((try? String(contentsOf: StoreBrowserRuntime.resourceBundle.url(forResource: "IPadnLicense", withExtension: "txt")!)) ?? "GPL-2.0-or-later")
                        .font(.caption.monospaced()).textSelection(.enabled).padding() }.navigationTitle("开源许可")
                }
            }
        }
        .toolPage().navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .storeSheet(isPresented: $addingSource) { AddVersionSourceView() }
        .storeNavigationDestination(item: $editingSourceID) { id in
            if let index = store.settings.versionSources.firstIndex(where: { $0.id == id }) {
                VersionSourceEditor(source: $store.settings.versionSources[index])
            }
        }
        .storeSheet(item: $share) { file in ShareSheet(items: [file.url]) }
        .actionConfirmation(isPresented: $resetSettings, title: "恢复默认设置？", message: "账号、已下载的安装包和已购记录不受影响。", confirmTitle: "恢复默认设置") { store.settings = ToolSettings() }
        .actionConfirmation(isPresented: $clearCache, title: "清除历史版本缓存？", confirmTitle: "清除缓存") {
            Task { do { try await store.versions.clearCache(); store.infoMessage = "已清除缓存" } catch { store.errorMessage = error.localizedDescription } }
        }
    }
}

extension SettingsView {
    /// Checks every source at once, enabled or not, and shows each result
    /// under its row as it arrives.
    private func checkSources() {
        let sources = store.settings.versionSources
        UX.feedback()
        for source in sources { sourceChecks[source.id] = .checking }
        for source in sources {
            Task {
                let result: SourceCheckState
                do {
                    let check = try await VersionService.check(source)
                    result = .available(versions: check.versions, seconds: check.seconds)
                } catch { result = .unavailable(error.localizedDescription) }
                sourceChecks[source.id] = result
            }
        }
    }
}

enum SourceCheckState: Equatable {
    case checking
    case available(versions: Int, seconds: Double)
    case unavailable(String)
}

/// One line under a version source: whether it answered, and how.
struct SourceCheckLabel: View {
    let state: SourceCheckState
    var body: some View {
        Group {
            switch state {
            case .checking:
                Label("正在检测…", systemImage: "clock").foregroundStyle(Color.secondary)
            case .available(let versions, let seconds):
                Label("可用 · \(versions) 个版本 · \(String(format: "%.1f", seconds)) 秒", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .unavailable(let reason):
                Label {
                    Text("不可用：" + reason).foregroundStyle(Color.secondary).lineLimit(2)
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
        }
        .font(.caption)
        .accessibilityIdentifier("settings.sourceCheckResult")
    }
}

struct VersionSourceEditor: View {
    @Binding var source: VersionSource
    var body: some View {
        Form {
            Section("来源设置") {
                Toggle("启用", isOn: $source.enabled)
                TextField("来源名称", text: $source.name)
                TextField("接口地址，用 {id} 或 {appId} 代表 App ID", text: $source.urlTemplate)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("列表字段名（可留空）", text: $source.containerKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("倒序显示", isOn: $source.reverse)
            }
            Section("接口格式") {
                Text("[{\"external_identifier\":\"123\",\"bundle_version\":\"1.0\"}]")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("若返回 {\"data\":[…]}，列表容器键填写 data。")
                    .font(.caption).foregroundStyle(Color.secondary)
            }
        }.toolPage().navigationTitle(source.name).navigationBarTitleDisplayMode(.inline)
    }
}

struct AddVersionSourceView: View {
    @EnvironmentObject private var store: ToolStore
    @Environment(\.dismiss) private var dismiss
    @State private var source = VersionSource(name: "新来源", urlTemplate: "https://", containerKey: "data", reverse: false)
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VersionSourceEditor(source: $source)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("添加") {
                            guard !source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  source.url(for: "123") != nil else { error = "请填写名称，以及包含 {id} 或 {appId} 的 https 接口地址"; return }
                            store.settings.versionSources.append(source); dismiss()
                        }
                    }
                }
                .alert("无法添加", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("好", role: .cancel) { error = nil }
                } message: { Text(error ?? "") }
        }
    }
}
