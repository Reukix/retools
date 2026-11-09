import SwiftUI
import UIKit

struct SigningProjectShare: Identifiable { let id = UUID(); let urls: [URL] }
struct SigningProjectShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum SigningProjectField: String, Identifiable {
    case name, identifier, version, note, output, minimum
    var id: String { rawValue }
    var title: String { switch self { case .name: return "应用名称"; case .identifier: return "Bundle ID"; case .version: return "应用版本"; case .note: return "工作区备注"; case .output: return "输出文件名"; case .minimum: return "最低系统版本" } }
    func value(_ options: PackageSigningOptions) -> String { switch self { case .name: return options.displayName; case .identifier: return options.bundleID; case .version: return options.version; case .note: return options.note; case .output: return options.outputName; case .minimum: return options.minimumOS } }
    func set(_ value: String, in options: inout PackageSigningOptions) { switch self { case .name: options.displayName = value; case .identifier: options.bundleID = value; case .version: options.version = value; case .note: options.note = value; case .output: options.outputName = value; case .minimum: options.minimumOS = value } }
}

struct SigningProjectFieldEditor: View {
    @Environment(\.dismiss) private var dismiss
    let field: SigningProjectField
    let initial: String
    let save: (String) throws -> Void
    @State private var text = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if field == .note { TextEditor(text: $text).frame(minHeight: 150) }
                    else { TextField(field.title, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("project.editor.value") }
                } footer: { Text(field == .minimum ? "留空保留原版本。修改声明不能使应用兼容其依赖的新系统 API。" : "留空使用原始值或自动生成的文件名。") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle(field.title).navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { do { try save(field == .note ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() } catch { self.error = error.localizedDescription } }.accessibilityIdentifier("project.editor.save") }
                }.onAppear { text = initial }
        }
    }
}

struct SigningEntitlementsEditor: View {
    @Environment(\.dismiss) private var dismiss
    let data: Data?
    let save: (Data?) -> Void
    @State private var text = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("导入的条目会覆盖描述文件中的对应权限。应用、团队身份及授权范围会在签名前校验。").font(.footnote).foregroundStyle(.secondary)
                TextEditor(text: $text).font(.system(.caption, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("project.entitlements.editor")
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }.padding().navigationTitle("Entitlements").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        do {
                            let values = try PackageSigningOptions.entitlements(Data(text.utf8))
                            save(try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)); dismiss()
                        } catch { self.error = error.localizedDescription }
                    } }
                }.onAppear {
                    let initial = data ?? (try? PropertyListSerialization.data(fromPropertyList: [String: String](), format: .xml, options: 0)) ?? Data()
                    text = String(decoding: initial, as: UTF8.self)
                }
        }
    }
}

struct SigningProjectBrowser: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let packageID: UUID
    let options: PackageSigningOptions
    let pendingSave: Task<Void, Never>?
    @State private var root: URL?
    @State private var error: String?
    @State private var attempt = 0
    var body: some View {
        NavigationStack {
            Group {
                if let root { SigningProjectDirectory(directory: root, root: root, title: "工作区文件") }
                else if let error { SigningProjectReadError(message: error) { attempt += 1 } }
                else {
                    VStack(spacing: 14) {
                        ProgressView("正在准备工作区…")
                        Text("正在解压应用并应用当前配置，可随时关闭此页面。").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("project.files.loading")
                }
            }.navigationTitle("工作区文件").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("project.files.close") } }
        }.task(id: attempt) {
                    error = nil
                    await pendingSave?.value
                    do {
                        try Task.checkCancellation()
                        AuthDiagnostics.record(stage: "签名工作区", message: "开始准备当前配置的工作副本")
                        let prepared = try await store.service.signingProjectPreview(packageID, options: options)
                        guard !Task.isCancelled else { await store.service.discardSigningPreview(prepared); return }
                        root = prepared
                        AuthDiagnostics.record(stage: "签名工作区", message: "工作副本已准备完成")
                    } catch is CancellationError { }
                    catch {
                        self.error = error.localizedDescription
                        AuthDiagnostics.record(stage: "签名工作区", message: error.localizedDescription)
                    }
                }
        .onDisappear { if let root { Task { await store.service.discardSigningPreview(root) } } }
    }
}

struct SigningProjectDependenciesView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let packageID: UUID
    let entries: [PluginInjection]
    let pendingSave: Task<Void, Never>?
    @State private var inspection: SigningProjectInspection?
    @State private var error: String?
    @State private var attempt = 0
    private var dependencies: [MachODependency] {
        var values = inspection?.dependencies ?? []
        for entry in entries {
            let path = entry.signingTarget == .loader ? "@executable_path/Frameworks/RetoolsPlugins-\(packageID.uuidString)/RetoolsPluginLoader.dylib" : "@executable_path/" + PluginService.loadPath(entry, namespace: packageID)
            if !values.contains(where: { $0.path == path }) { values.append(MachODependency(path: path, isWeak: entry.signingTarget == .loader ? false : entry.loadKind == .optional)) }
        }
        return values
    }
    var body: some View {
        NavigationStack {
            Group {
                if let inspection {
                    List {
                        Section {
                            Text(inspection.executable).font(.system(.subheadline, design: .monospaced))
                            Text("\(dependencies.count) 条依赖项").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("project.dependencies.summary")
                        } header: { Text("主程序") } footer: { Text("包括原始主程序依赖和当前配置将注入的库。") }
                        Section {
                            ForEach(dependencies) { dependency in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(dependency.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    if dependency.isWeak { Text("弱链接").font(.caption2).foregroundStyle(.secondary) }
                                }.padding(.vertical, 4)
                            }
                            if dependencies.isEmpty { Text("主程序未声明动态库依赖。").foregroundStyle(.secondary) }
                        } header: { Text("动态库") }
                    }
                } else if let error { SigningProjectReadError(message: error) { attempt += 1 } }
                else { ProgressView("正在读取主程序依赖…").frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("project.dependencies.loading") }
            }.navigationTitle("主二进制依赖").navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("project.dependencies.close") } }
        }.task(id: attempt) {
                    error = nil
                    await pendingSave?.value
                    do {
                        try Task.checkCancellation()
                        AuthDiagnostics.record(stage: "签名依赖", message: "开始读取主程序依赖")
                        let value = try await store.service.inspectSigningProject(packageID)
                        try Task.checkCancellation()
                        inspection = value
                        AuthDiagnostics.record(stage: "签名依赖", message: "主程序依赖已读取完成")
                    } catch is CancellationError { }
                    catch {
                        self.error = error.localizedDescription
                        AuthDiagnostics.record(stage: "签名依赖", message: error.localizedDescription)
                    }
                }
    }
}

private struct SigningProjectReadError: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("读取失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("重试", action: retry).buttonStyle(.borderedProminent).accessibilityIdentifier("project.read.retry")
        }
    }
}

private struct SigningProjectDirectory: View {
    let directory: URL
    let root: URL
    var title: String? = nil
    @State private var files: [URL] = []
    @State private var error: String?
    var body: some View {
        List {
            if directory == root { Section { Text("当前配置的工作副本。重新签名会从原始 IPA 生成新的副本。").font(.footnote).foregroundStyle(.secondary) } }
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(files, id: \.path) { file in
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    NavigationLink { SigningProjectDirectory(directory: file, root: root) } label: { Label(file.lastPathComponent, systemImage: "folder") }
                } else {
                    NavigationLink { SigningProjectFile(file: file) } label: { Label(file.lastPathComponent, systemImage: "doc") }
                }
            }
        }.navigationTitle(title ?? directory.lastPathComponent).navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
            .task {
                do {
                    files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).filter {
                        (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true && $0.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
                    }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                } catch { self.error = error.localizedDescription }
            }
    }
}
private struct SigningProjectFile: View {
    let file: URL
    @State private var text: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ShareLink(item: file) { Label("导出文件", systemImage: "square.and.arrow.up") }
                if let text { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                else { Text("此文件可通过共享菜单导出查看。").foregroundStyle(.secondary) }
            }.padding()
        }.navigationTitle(file.lastPathComponent).navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
            .task {
                guard ["plist", "strings", "xml", "json", "txt", "md"].contains(file.pathExtension.lowercased()),
                      let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 262144,
                      let data = try? Data(contentsOf: file) else { return }
                if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                   let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) { text = String(decoding: xml, as: UTF8.self) }
                else { text = String(data: data, encoding: .utf8) }
            }
    }
}
