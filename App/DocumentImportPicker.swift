import SwiftUI
import UniformTypeIdentifiers

/// Import a local copy instead of relying on provider-specific IPA type tags.
struct DocumentImportPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onSelection: (Result<URL, Error>) -> Void

    /// 启动时清掉上次运行留下的所选文件副本。
    static func discardPicked() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Picked", isDirectory: true))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--picker-test-documents") {
            picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        }
        #endif
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DocumentImportPicker
        init(_ parent: DocumentImportPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.isPresented = false
            guard let url = urls.first else {
                parent.onSelection(.failure(WorkspaceFailure("未能取得所选文件，请重新选择。")))
                return
            }
            // 系统给的副本放在共享的临时收件箱里，下次打开选择器时会被清掉
            //（例如先选 P12、再选描述文件，P12 的副本就没了），所以立刻复制到 Retools 自己的目录。
            do { parent.onSelection(.success(try Self.keep(url))) }
            catch { parent.onSelection(.failure(WorkspaceFailure("未能读取所选文件：\(error.localizedDescription)"))) }
        }
        static func keep(_ url: URL) throws -> URL {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Picked", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // 同一卷上移动是瞬时的，大体积 IPA 也不会多占一份空间；跨卷时退回复制。
            do { try FileManager.default.moveItem(at: url, to: destination) }
            catch { try FileManager.default.copyItem(at: url, to: destination) }
            return destination
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}
