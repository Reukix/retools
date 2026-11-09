import SwiftUI

// ArchiveService is shared with the host without linking its runtime or signing frameworks.
typealias WorkspaceFailure = FairPlayFailure

@main
struct RetoolsDecryptApp: App {
    var body: some Scene { WindowGroup { DecryptHelperView().tint(.orange) } }
}

@MainActor
final class HelperDecryptionModel: ObservableObject {
    @Published var manifest: FairPlayManifest?
    @Published var status = "准备就绪"
    @Published var busy = false
    @Published var output: URL?
    @Published var failure: String?
    private func report(_ phase: String, error: Error? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0]
        var value: [String: Any] = ["runtime":"stream-copy-v3","phase":phase,"status":status,"busy":busy,"updatedAt":Date().timeIntervalSince1970]
        if let manifest { value["jobID"] = manifest.id.uuidString }
        if let error {
            let native = error as NSError
            value["errorDomain"] = native.domain; value["errorCode"] = native.code
            value["error"] = error.localizedDescription
            if let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError { value["underlyingDomain"] = underlying.domain; value["underlyingCode"] = underlying.code }
        }
        try? JSONSerialization.data(withJSONObject: value,options: [.sortedKeys]).write(to: documents.appendingPathComponent("RuntimeStatus.json"),options: .atomic)
    }
    init() {
        do {
            guard let url = Bundle.main.url(forResource: "RetoolsDecryption", withExtension: "json") else { throw FairPlayFailure("此助手没有嵌入目标应用，请回到 Retools 生成助手。") }
            let value = try JSONDecoder().decode(FairPlayManifest.self, from: Data(contentsOf: url))
            try value.validate(); manifest = value
        } catch { failure = error.localizedDescription }
        report("loaded")
    }
    func start() async {
        guard !busy, let manifest else { return }
        busy = true; output = nil; failure = nil
        report("starting")
        UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = documents.appendingPathComponent("Decrypted")
        let receiptURL = documents.appendingPathComponent("DecryptionResult.json")
        try? FileManager.default.removeItem(at: receiptURL)
        do {
            let source = Bundle.main.bundleURL.appendingPathComponent(FairPlayManifest.resourceDirectory+"/Target")
            let output = try await Task.detached(priority: .userInitiated) {
                try FairPlayRunner.run(manifest: manifest, source: source, outputDirectory: destination) { message in
                    Task { @MainActor in self.status = message; self.report("working") }
                }
            }.value
            let hash = try await Task.detached { try FairPlayFiles.hash(output) }.value
            let receipt = FairPlayReceipt(jobID: manifest.id, succeeded: true, outputName: output.lastPathComponent, sha256: hash, error: nil, decryptedFiles: manifest.encryptedCount)
            try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
            self.output = output; status = "砸壳完成"; report("complete")
        } catch {
            failure = error.localizedDescription; status = "砸壳未完成"; report("failed",error: error)
            let receipt = FairPlayReceipt(jobID: manifest.id, succeeded: false, outputName: nil, sha256: nil, error: error.localizedDescription, decryptedFiles: 0)
            try? JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
        }
    }
}

struct DecryptHelperView: View {
    @StateObject private var model = HelperDecryptionModel()
    @State private var exporting = false
    @State private var savedToFiles = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(model.manifest?.name ?? "解密助手", systemImage: "lock.open")
                    if let manifest = model.manifest {
                        Text(manifest.bundleID).font(.caption).foregroundStyle(.secondary)
                        Text("\(manifest.encryptedCount) 个加密二进制").foregroundStyle(.secondary)
                    }
                }
                Section {
                    if model.busy { HStack { ProgressView(); Text(model.status) } }
                    else { Text(model.status) }
                    if let failure = model.failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
                    if let output = model.output {
                        Button { exporting = true } label: { Label(savedToFiles ? "再次导出 IPA" : "导出解密 IPA", systemImage: "square.and.arrow.up") }
                        Link("返回 Retools", destination: URL(string: "retools://decryption")!)
                    } else {
                        Button("开始砸壳") { Task { await model.start() } }.disabled(model.busy || model.manifest == nil)
                            .accessibilityIdentifier("decryptHelper.start")
                    }
                } footer: {
                    Text("请保持此页面打开。设备需登录拥有该应用许可的 App Store 账号；结果需重新签名后安装。")
                }
            }.navigationTitle("Retools 解密助手")
                .onOpenURL { url in
                    guard let manifest = model.manifest, manifest.authorizesStart(url) else { return }
                    Task { await model.start() }
                }
        }
        .onChange(of: model.output) { _, output in if output != nil { savedToFiles = false; exporting = true } }
        .sheet(isPresented: $exporting) {
            if let output = model.output {
                HelperFileExporter(file: output) { saved in
                    exporting = false; savedToFiles = saved
                    if saved { model.status = "已保存到“文件”" }
                }
            }
        }
    }
}

struct HelperFileExporter: UIViewControllerRepresentable {
    let file: URL
    let completion: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Bool) -> Void
        init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(!urls.isEmpty) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(false) }
    }
}
