import SwiftUI

struct EmbeddedLibrariesView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let target: PluginTarget
    var onlyPlugins = false
    @State private var libraries: [EmbeddedLibrary]?
    @State private var issue: String?
    @State private var query = ""
    @State private var attempt = 0
    private var visibleLibraries: [EmbeddedLibrary] { (libraries ?? []).filter { !onlyPlugins || $0.isInjectedPlugin } }
    private var filtered: [EmbeddedLibrary] { visibleLibraries.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        List {
            if let libraries {
                Section {
                    LabeledContent(onlyPlugins ? "已注入插件" : "包内动态库", value: "\(visibleLibraries.count) 个")
                } footer: {
                    Text(onlyPlugins ? "按插件加载记录与追加的加载命令识别，不将应用自带框架和加载器支持组件计为插件。" : "显示应用自带框架、注入插件与运行支持库的完整文件和链接关系。")
                }
                Section {
                    ForEach(filtered) { library in
                        NavigationLink { EmbeddedLibraryDetail(library: library) } label: { EmbeddedLibraryRow(library: library) }
                            .accessibilityIdentifier("embedded.library." + library.path)
                    }
                    if visibleLibraries.isEmpty { ContentUnavailableView(onlyPlugins ? "未识别到注入插件" : "未发现包内动态库", systemImage: "shippingbox") }
                    else if filtered.isEmpty { Text("没有匹配的动态库").foregroundStyle(Color.secondary) }
                } header: { Text(onlyPlugins ? "已注入插件" : "全部动态库") }
            } else if let issue {
                Section { Text(issue).foregroundStyle(.red); Button("重试") { self.issue = nil; attempt += 1 } }
            } else { ProgressView("正在读取包内动态库…") }
        }.toolListStyle().navigationTitle(onlyPlugins ? "已注入插件" : "全部动态库").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索 dylib 或 framework")
            .task(id: attempt) {
                do { libraries = try await store.service.embeddedLibraries(for: target) }
                catch { issue = error.localizedDescription }
            }
    }
}

struct EmbeddedLibraryRow: View {
    let library: EmbeddedLibrary
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(library.name).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary)
            Text(library.path).font(.caption.monospaced()).foregroundStyle(Color.secondary).lineLimit(2)
            HStack(spacing: 8) {
                Text(library.isPresent ? (library.isInjectedPlugin ? "已注入" : library.linkageLabel) : "未在包内定位")
                    .foregroundStyle(library.isPresent ? Color.secondary : Color.orange)
                if library.isPresent { Text(ByteCountFormatter.string(fromByteCount: library.byteCount, countStyle: .file)).foregroundStyle(Color.secondary) }
            }.font(.caption)
        }.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading).foregroundStyle(Color.primary).padding(.vertical, 3)
    }
}

struct EmbeddedLibraryDetail: View {
    let library: EmbeddedLibrary
    var body: some View {
        List {
            Section(library.isInjectedPlugin ? "已注入插件" : "动态库信息") {
                LabeledContent("文件名", value: library.name)
                LabeledContent("格式", value: library.isFramework ? "Framework" : "Dylib")
                LabeledContent("类型", value: library.isInjectedPlugin ? "注入插件" : (library.isInjectionSupport ? "加载支持组件" : "应用动态库"))
                LabeledContent("状态", value: library.isPresent ? library.linkageLabel : "未在包内定位")
                if library.isPresent { LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: library.byteCount, countStyle: .file)) }
                if let os = library.minimumOS { LabeledContent("最低系统", value: "iOS " + os) }
                Text(library.path).font(.caption.monospaced()).textSelection(.enabled)
            }
            if library.isInjectedPlugin {
                Section("插件识别依据") { ForEach(library.pluginEvidence ?? [], id: \.self) { Text($0.title).font(.footnote) } }
            }
            Section("引用此库的程序") {
                ForEach(library.linkedBy, id: \.self) { owner in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(owner).font(.caption.monospaced()).textSelection(.enabled)
                        Text(library.weakLinkedBy.contains(owner) ? "弱链接" : "必需链接").font(.caption2).foregroundStyle(Color.secondary)
                    }
                }
                if library.linkedBy.isEmpty { Text("未发现静态链接记录，可能由加载器或应用代码加载。").foregroundStyle(Color.secondary) }
            }
            Section("依赖") {
                ForEach(library.dependencies) { dependency in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dependency.path).font(.caption.monospaced()).textSelection(.enabled)
                        if dependency.isWeak { Text("弱链接").font(.caption2).foregroundStyle(Color.secondary) }
                    }
                }
            }
        }.toolListStyle().navigationTitle(library.name).navigationBarTitleDisplayMode(.inline)
    }
}
