import SwiftUI

struct LocalEditableDocument: Identifiable {
    enum Format { case utf8(bom: Bool), utf16(littleEndian: Bool), plist(binary: Bool) }
    let id = UUID()
    let path: String
    let snapshot: LocalFileSnapshot
    let text: String
    let format: Format
    var name: String { (path as NSString).lastPathComponent }
    var isPlist: Bool { if case .plist = format { return true }; return false }

    init(path: String, snapshot: LocalFileSnapshot) throws {
        self.path = path; self.snapshot = snapshot
        let data = snapshot.data
        let plist = data.starts(with: Data("bplist".utf8)) || ["plist", "mobileconfig", "entitlements"].contains((path as NSString).pathExtension.lowercased())
        if plist {
            var original = PropertyListSerialization.PropertyListFormat.xml
            let value = try PropertyListSerialization.propertyList(from: data, options: [], format: &original)
            let xml = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            guard let string = String(data: xml, encoding: .utf8) else { throw WorkspaceFailure("无法将属性列表转换为可编辑文本。") }
            text = string; format = .plist(binary: original == .binary); return
        }
        let decoded: String?
        if data.starts(with: [0xff, 0xfe]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16LittleEndian); format = .utf16(littleEndian: true)
        } else if data.starts(with: [0xfe, 0xff]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16BigEndian); format = .utf16(littleEndian: false)
        } else {
            let bom = data.starts(with: [0xef, 0xbb, 0xbf])
            decoded = String(data: bom ? Data(data.dropFirst(3)) : data, encoding: .utf8); format = .utf8(bom: bom)
        }
        guard let decoded, decoded.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || ["\n", "\r", "\t"].contains(String($0)) }) else {
            throw WorkspaceFailure("这个文件不是支持的文本或属性列表。可以预览，或导入修改后的文件进行覆盖。")
        }
        text = decoded
    }

    func encoded(_ text: String) throws -> Data {
        switch format {
        case .utf8(let bom): return (bom ? Data([0xef, 0xbb, 0xbf]) : Data()) + Data(text.utf8)
        case .utf16(let little):
            guard let data = text.data(using: little ? .utf16LittleEndian : .utf16BigEndian, allowLossyConversion: false) else { throw WorkspaceFailure("无法保留原文件的文本编码。") }
            return Data(little ? [0xff, 0xfe] : [0xfe, 0xff]) + data
        case .plist(let binary):
            let value = try PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil)
            return try PropertyListSerialization.data(fromPropertyList: value, format: binary ? .binary : .xml, options: 0)
        }
    }
}

struct LocalFileEditor: View {
    let document: LocalEditableDocument
    let onSave: (Data) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDiscard = false

    init(document: LocalEditableDocument, onSave: @escaping (Data) async throws -> Void) {
        self.document = document; self.onSave = onSave; _text = State(initialValue: document.text)
    }
    private var changed: Bool { text != document.text }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(document.path).font(.caption.monospaced()).foregroundStyle(Color.secondary).lineLimit(3).textSelection(.enabled)
                if document.isPlist {
                    Text("以 XML 编辑；保存时保留原文件的二进制或 XML 格式。").font(.footnote).foregroundStyle(Color.secondary)
                }
                TextEditor(text: $text).font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(saving)
                    .accessibilityIdentifier("localFiles.editor.text")
                Text("保存前会备份原文件。若文件已被其他应用修改，将保留你的编辑并提示重新核对。")
                    .font(.caption).foregroundStyle(Color.secondary)
            }.padding(16).ambientBackground()
            .navigationTitle(document.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if changed { confirmDiscard = true } else { dismiss() } }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else {
                        Button("保存") { save() }.disabled(!changed).accessibilityIdentifier("localFiles.editor.save")
                    }
                }
            }
        }
        .interactiveDismissDisabled(changed || saving)
        .alert("未能保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("继续编辑", role: .cancel) {}
        } message: { Text(error ?? "") }
        .confirmationDialog("放弃未保存的更改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃更改", role: .destructive) { dismiss() }
        }
    }
    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do { try await onSave(document.encoded(text)); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct LocalFileBackupsView: View {
    @State private var records: [LocalFileBackup] = []
    @State private var query = ""
    private var visible: [LocalFileBackup] { records.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.originalPath.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        List {
            ToolPageIntro(tool: .fileBackups, title: "修改前的原文件", detail: "覆盖和删除文件前自动保存，可导出后回到原目录恢复。")
            Section { ToolMetrics(items: [("备份数量", "\(records.count)"), ("占用空间", records.reduce(Int64(0)) { $0 + $1.bytes }.byteLabel)]) }
            if records.isEmpty {
                ContentUnavailableView("还没有文件备份", systemImage: "clock.arrow.circlepath", description: Text("使用本机文件工具修改或删除文件后，原文件会保存在这里。"))
            } else if visible.isEmpty { ContentUnavailableView.search(text: query) }
            ForEach(visible) { record in
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.name).font(.headline)
                        Text(record.originalPath).font(.caption.monospaced()).foregroundStyle(Color.secondary).textSelection(.enabled)
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened) + " · " + record.bytes.byteLabel)
                            .font(.caption).foregroundStyle(Color.secondary)
                    }
                    ShareLink(item: record.file()) { Label("导出原文件备份", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .toolListStyle()
        .searchable(text: $query, prompt: "文件名或原始路径")
        .navigationTitle("文件备份").navigationBarTitleDisplayMode(.inline)
        .task { records = LocalFileBackupStore.list() }
        .refreshable { records = LocalFileBackupStore.list() }
        .safeAreaInset(edge: .bottom) {
            Text("可先导出备份，再回到原目录导入恢复。备份也保存在「文件 → Retools → Retools → FileBackups」。")
                .font(.caption).foregroundStyle(Color.secondary).padding().bottomBarBackground()
        }
    }
}
