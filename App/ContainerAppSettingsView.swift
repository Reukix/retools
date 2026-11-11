import SwiftUI
import LocalAuthentication

struct ContainerAppSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let appID: UUID
    @State private var options = ContainerRuntimeOptions()
    @State private var languages: [String] = []
    @State private var tweakFolders: [String] = []
    @State private var ready = false
    @State private var issue: String?
    private var app: ContainerApp? { store.state.containerApps.first { $0.id == appID } }
    var body: some View {
        Form {
            if ready {
                Section("应用") {
                    TextField("备注", text: $options.remark, axis: .vertical)
                    Picker("运行方式", selection: $options.launchMode) { ForEach(ContainerLaunchMode.allCases) { Text($0.title).tag($0) } }
                    Picker("应用语言", selection: $options.language) {
                        Text("跟随系统").tag("")
                        ForEach(Array(Set(languages + (options.language.isEmpty ? [] : [options.language]))).sorted(), id: \.self) { language in
                            Text(Locale.current.localizedString(forIdentifier: language) ?? language).tag(language)
                        }
                    }.accessibilityIdentifier("container.options.language")
                }
                Section {
                    Toggle("锁定应用", isOn: $options.isLocked)
                    if options.isLocked { Toggle("从常规列表隐藏", isOn: $options.isHidden) }
                } header: { Text("隐私") } footer: { Text("锁定后每次启动需要 Face ID、Touch ID 或设备密码。") }
                Section {
                    Toggle("修复文件选择器", isOn: $options.fixFilePicker)
                    Toggle("修复本地通知", isOn: $options.fixLocalNotification)
                    Toggle("使用 Retools 的 Bundle ID", isOn: $options.useHostBundleID)
                } header: { Text("系统兼容") } footer: { Text("使用宿主标识可帮助部分系统服务识别应用，也可能影响应用自身的标识检查。") }
                Section {
                    Picker("方向锁定", selection: $options.orientation) { ForEach(ContainerOrientation.allCases) { Text($0.title).tag($0) } }
                    Toggle("经典显示模式", isOn: $options.classicMode)
                } header: { Text("显示") } footer: { Text("方向锁定沿用 LC 的 iPhone 兼容处理；经典显示模式可用于部分旧应用和分辨率异常。") }
                Section {
                    Toggle("客体 SDK 兼容", isOn: $options.spoofSDKVersion).accessibilityIdentifier("container.options.sdk")
                    Toggle("从 Dyld 查询中隐藏宿主", isOn: $options.hideLiveContainer).accessibilityIdentifier("container.options.hideHost")
                    Picker("TweakLoader", selection: $options.loaderMode) { ForEach(ContainerLoaderMode.allCases) { Text($0.title).tag($0) } }.accessibilityIdentifier("container.options.loader")
                    Picker("额外插件文件夹", selection: $options.tweakFolder) {
                        Text("无").tag("")
                        ForEach(Array(Set(tweakFolders + (options.tweakFolder.isEmpty ? [] : [options.tweakFolder]))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                } header: { Text("运行兼容与插件") } footer: {
                    Text("正常注入会在应用初始化时加载所选插件。延后模式仅加载修复组件；关闭加载器后不会主动加载所选插件。IPA 内原有的注入仍由应用自身加载。额外插件文件夹位于 Retools 文稿的 Tweaks 目录。")
                }
                Section {
                    Toggle("旧版文件选择器修复", isOn: $options.legacyFilePicker)
                } footer: { Text("通过复制文件到 Inbox 兼容旧应用，选择文件夹时可能不适用。") }
                Section {
                    Button("下次启动强制重新签名") {
                        store.run("正在更新签名状态…", success: "下次启动将重新签名") { try await store.service.forceContainerSign(appID) }
                    }.accessibilityIdentifier("container.options.forceSign")
                    NavigationLink { EmbeddedLibrariesView(target: .container(appID)) } label: { Label("查看应用已有动态库", systemImage: "puzzlepiece.extension") }
                    if let app {
                        LabeledContent("导入时间", value: app.installedAt.formatted(date: .abbreviated, time: .shortened))
                        if let last = app.lastLaunched { LabeledContent("上次启动", value: last.formatted(date: .abbreviated, time: .shortened)) }
                    }
                }
            } else if issue == nil { ProgressView("正在读取应用设置…") }
            if let issue { Section { Text(issue).foregroundStyle(.red) } }
        }.toolListStyle().navigationTitle("应用兼容设置").navigationBarTitleDisplayMode(.inline)
            .disabled(store.isWorking)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("保存") { save() }.disabled(!ready || store.isWorking).accessibilityIdentifier("container.options.save") } }
            .task {
                guard !ready, let app else { return }
                do {
                    if app.runtimeOptions?.isLocked == true {
                        guard try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "查看「\(app.name)」的容器设置") else { dismiss(); return }
                    }
                    options = app.runtimeOptions ?? ContainerRuntimeOptions()
                    let choices = try await store.service.containerSettingChoices(appID)
                    languages = choices.languages; tweakFolders = choices.tweakFolders; ready = true
                } catch { issue = error.localizedDescription }
            }
    }
    private func save() {
        if !options.isLocked { options.isHidden = false }
        let value = options
        store.run("正在保存容器设置…", success: "兼容设置将在下次启动时生效", onError: { issue = $0.localizedDescription }) {
            let result = try await store.service.setContainerRuntimeOptions(appID, options: value)
            await MainActor.run { dismiss() }
            return result
        }
    }
}

struct ContainerDataSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let appID: UUID
    let container: DataContainer
    @State private var name = ""
    @State private var options = ContainerDataOptions()
    @State private var identifier = ""
    @State private var issue: String?
    var body: some View {
        Form {
            Section("数据空间") {
                TextField("名称", text: $name)
                LabeledContent("空间 ID", value: container.id.uuidString).font(.caption)
                Toggle("隔离 App Group 数据", isOn: $options.isolateAppGroup)
            }
            Section {
                Toggle("自定义设备供应商标识（IDFV）", isOn: $options.spoofIdentifierForVendor)
                if options.spoofIdentifierForVendor {
                    TextField("留空使用此空间的默认标识", text: $identifier).font(.caption.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("生成新标识") { identifier = UUID().uuidString }
                }
            } header: { Text("应用设备标识") } footer: { Text("App Group 隔离和 IDFV 选项会在下次启动此空间时生效。") }
            if let issue { Section { Text(issue).foregroundStyle(.red) } }
        }.toolListStyle().navigationTitle("空间设置").navigationBarTitleDisplayMode(.inline)
            .onAppear { name = container.name; options = container.options ?? ContainerDataOptions(); identifier = options.identifierForVendor?.uuidString ?? "" }
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("保存") { save() }.disabled(store.isWorking) } }
    }
    private func save() {
        let text = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, UUID(uuidString: text) == nil { issue = "IDFV 必须是有效的 UUID。"; return }
        options.identifierForVendor = UUID(uuidString: text)
        let value = options, title = name
        store.run("正在保存空间设置…", success: "空间设置已保存", onError: { issue = $0.localizedDescription }) {
            let result = try await store.service.setContainerDataOptions(appID, containerID: container.id, name: title, options: value)
            await MainActor.run { dismiss() }
            return result
        }
    }
}
