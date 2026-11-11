import SwiftUI
import RetoolsNative

@MainActor
final class DecryptionController: ObservableObject {
    @Published var job: PreparedDecryption?
    @Published var busy = false
    @Published var status = "选择一个加密 IPA"
    @Published var error: String?
    @Published var sourceIssue: String?
    @Published var result: URL?
    let paths: WorkspacePaths
    var root: URL { paths.support.appendingPathComponent("Decryption") }
    var folder: URL? { job.map { root.appendingPathComponent($0.manifest.id.uuidString) } }
    var unsignedHelperIPA: URL? {
        guard let file = folder?.appendingPathComponent("DecryptHelper.ipa"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
    var helperIPA: URL? {
        guard let folder else { return nil }
        let signed = folder.appendingPathComponent("DecryptHelper-signed.ipa")
        if FileManager.default.fileExists(atPath: signed.path) { return signed }
        let prepared = folder.appendingPathComponent("DecryptHelper.ipa")
        return FileManager.default.fileExists(atPath: prepared.path) ? prepared : nil
    }
    init(paths: WorkspacePaths = WorkspacePaths()) {
        self.paths = paths
        reload()
    }
    func reload() {
        guard !busy else { return }
        job = nil; result = nil; sourceIssue = nil; status = "选择一个加密 IPA"
        if let value = try? String(contentsOf: root.appendingPathComponent("Current"), encoding: .utf8), let id = UUID(uuidString: value),
           let data = try? Data(contentsOf: root.appendingPathComponent(id.uuidString+"/Job.json")),
           let saved = try? JSONDecoder().decode(PreparedDecryption.self, from: data), saved.manifest.id == id,
           (try? saved.manifest.validate()) != nil {
            job = saved; status = saved.installed ? "助手已安装，打开助手后开始砸壳" : "助手已准备好"
            let archive = root.appendingPathComponent(id.uuidString + "/Result.ipa")
            if FileManager.default.fileExists(atPath: archive.path) { result = archive }
        }
        if job == nil { result = try? DecryptionCache.savedResults(paths: paths).first }
    }
    private func save() throws {
        guard let job, let folder else { return }
        try JSONEncoder().encode(job).write(to: folder.appendingPathComponent("Job.json"), options: .atomic)
    }
    private func begin(store: WorkspaceStore, renewal: RenewalController, message: String) throws {
        guard !busy, !store.isWorking, !renewal.isWorking, !DevicePairingCoordinator.shared.isRunning else { throw FairPlayFailure("请等待当前签名或设备操作完成。") }
        busy = true; error = nil; status = message; store.isWorking = true; store.workLabel = ""
        UIApplication.shared.isIdleTimerDisabled = true
    }
    private func end(store: WorkspaceStore) {
        busy = false; store.isWorking = false; store.workLabel = ""
        UIApplication.shared.isIdleTimerDisabled = false
    }
    func packageHelper(store: WorkspaceStore, renewal: RenewalController) async {
        guard let job, let folder else { return }
        do { try begin(store: store, renewal: renewal, message: "正在生成未签名助手…") }
        catch { self.error = error.localizedDescription; return }
        defer { end(store: store) }
        do {
            let template = try DecryptionPreparation.templateURL(), root = root
            try await Task.detached(priority: .userInitiated) {
                try DecryptionPreparation.refreshTemplate(job, template: template, root: root)
                let app = folder.appendingPathComponent("Helper/Payload/RetoolsDecryptHelper.app")
                try FairPlayFiles.verifyOriginals(job.manifest, in: app.appendingPathComponent(FairPlayManifest.resourceDirectory + "/Target"))
                try ArchiveService.pack(app: app, to: folder.appendingPathComponent("DecryptHelper.ipa"))
            }.value
            status = "未签名助手已生成，可以导出后使用其他工具安装"
        } catch { self.error = error.localizedDescription }
    }
    func prepare(source: URL, store: WorkspaceStore, renewal: RenewalController) async {
        do { try begin(store: store, renewal: renewal, message: "正在检查 IPA 和商店许可…") } catch { self.error = error.localizedDescription; return }
        sourceIssue = nil
        defer { end(store: store) }
        defer {
            let picked = FileManager.default.temporaryDirectory.appendingPathComponent("Picked").path+"/"
            if source.path.hasPrefix(picked) { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        }
        do {
            let template = try DecryptionPreparation.templateURL(), root = root
            let prepared = try await Task.detached(priority: .userInitiated) { try DecryptionPreparation.prepare(source: source, template: template, root: root) }.value
            job = prepared; result = nil; status = "助手已准备好"
        } catch { sourceIssue = error.localizedDescription; status = job == nil ? "来源检查未完成" : "保留上一次准备好的助手" }
    }

    func prepareInstalled(_ app: DeviceInstalledApp, store: WorkspaceStore, renewal: RenewalController) async {
        do { try begin(store: store, renewal: renewal, message: "正在读取「\(app.name)」的安装包…") }
        catch { self.error = error.localizedDescription; return }
        sourceIssue = nil
        defer { end(store: store) }
        let staging = paths.staging.appendingPathComponent("InstalledSource-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            guard let group = HostAppGroup.signedIdentifier() else { throw WorkspaceFailure("当前签名缺少文件工具专用 App Group，可从商店获取原始包。") }
            let source = try InstalledDecryptionSource.bundleRoot(app.path)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let snapshot = staging.appendingPathComponent(source.lastPathComponent)
            try await LocalFileAccessService.shared.snapshotInstalledApp(app, to: snapshot, group: group)
            status = "正在校验安装包与许可…"
            let archive = staging.appendingPathComponent("Installed.ipa"), root = root
            let template = try DecryptionPreparation.templateURL()
            let prepared = try await Task.detached(priority: .userInitiated) {
                try ArchiveService.pack(app: snapshot, to: archive)
                return try DecryptionPreparation.prepare(source: archive, template: template, root: root)
            }.value
            job = prepared; result = nil; status = "已从本机应用准备好助手"
        } catch {
            sourceIssue = "无法从已安装应用准备助手：" + error.localizedDescription
            status = job == nil ? "本机安装包未能读取，可从商店获取" : "保留上一次准备好的助手"
        }
    }
    func sign(identity: SigningIdentity, install: Bool, store: WorkspaceStore, renewal: RenewalController) async {
        guard let job else { return }
        do { try begin(store: store, renewal: renewal, message: "正在准备助手签名…") } catch { self.error = error.localizedDescription; return }
        defer { end(store: store) }
        do {
            self.job?.installed = false; self.job?.startedAutomatically = false; try save()
            status = "正在检查助手组件更新…"
            let template = try DecryptionPreparation.templateURL(), root = root
            try await Task.detached(priority: .userInitiated) { try DecryptionPreparation.refreshTemplate(job,template: template,root: root) }.value
            let identifier = FairPlayManifest.helperBundleID+"."+identity.teamID.lowercased()
            var fresh: AppleAccountService.Credentials?
            if let owner = try await store.service.decryptionProvisioningIdentity(identity.id, bundleID: identifier) {
                let synthetic = AppPackage(id: job.manifest.id, name: "Retools 解密助手", bundleID: identifier,
                    version: "0.1.0", build: "51", minimumOS: "17.0", fileName: "", iconFile: nil, byteCount: 0, isEncrypted: false, importedAt: Date())
                fresh = try await renewal.projectSigningCredentials(identity: owner, package: synthetic, options: PackageSigningOptions()) { self.status = $0 }
            }
            status = "正在签名并校验目标二进制…"
            let archive = try await store.service.signDecryptionHelper(job, identityID: identity.id, bundleID: identifier, fresh: fresh)
            self.job?.signedBundleID = identifier; self.job?.installed = false; try save()
            status = "签名完成，可以导出助手"
            if install {
                guard renewal.settings.hasPairing else { throw FairPlayFailure("助手已签名。请连接设备服务后安装，或先导出助手 IPA。") }
                let temp = paths.staging.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temp) }
                let app = try await Task.detached { try ArchiveService.unpack(archive, to: temp.appendingPathComponent("Install")) }.value
                status = "正在连接这台 iPhone…"
                _ = try await renewal.device.connect(host: renewal.settings.hostIP, remotePort: renewal.settings.remotePort, expectedUDID: renewal.settings.deviceUDID)
                try await renewal.device.install(app: app, bundleID: identifier) { message in Task { @MainActor in self.status = message } }
                self.job?.installed = true; try save(); status = "助手已安装，请打开助手并点击“开始砸壳”"
            }
        } catch { self.error = error.localizedDescription }
    }
    func startHelper() async {
        guard let job, job.installed, let token = job.manifest.startAuthorization else { return }
        let url = URL(string: "retoolsdecrypt://start?job=\(job.manifest.id.uuidString)&authorization=\(token.uuidString)")!
        do {
            self.job?.startedAutomatically = true; try save()
            guard await UIApplication.shared.open(url) else { throw FairPlayFailure("无法打开助手，请在桌面打开“Retools 解密助手”。") }
        } catch { self.error = error.localizedDescription }
    }
    func collect(store: WorkspaceStore, renewal: RenewalController, quietly: Bool = false) async {
        guard let job, let identifier = job.signedBundleID, let folder else { return }
        do { try begin(store: store, renewal: renewal, message: "正在检查助手结果…") } catch { if !quietly { self.error = error.localizedDescription }; return }
        defer { end(store: store) }
        do {
            _ = try await renewal.device.connect(host: renewal.settings.hostIP, remotePort: renewal.settings.remotePort, expectedUDID: renewal.settings.deviceUDID)
            let data = try await renewal.device.containerRead(bundleID: identifier, path: "Documents/DecryptionResult.json")
            let receipt = try JSONDecoder().decode(FairPlayReceipt.self, from: data)
            guard receipt.jobID == job.manifest.id else { throw FairPlayFailure("助手中的任务与当前任务不同，请安装当前助手后重试。") }
            guard receipt.succeeded, receipt.decryptedFiles == job.manifest.encryptedCount,
                  let filename = receipt.outputName, let hash = receipt.sha256, hash.count == 64, hash.allSatisfy({ $0.isHexDigit }),
                  filename == job.manifest.id.uuidString+"-decrypted.ipa" else { throw FairPlayFailure(receipt.error ?? "助手尚未完成砸壳，请打开助手查看。") }
            let archive = folder.appendingPathComponent(UUID().uuidString+"-incoming.ipa")
            defer { try? FileManager.default.removeItem(at: archive) }
            // Stream the IPA from the helper rather than loading a large archive into memory.
            try await renewal.device.downloadAppFile(bundleID: identifier, path: "Documents/Decrypted/"+filename, to: archive)
            status = "正在校验砸壳结果…"
            try await Task.detached {
                guard try FairPlayFiles.hash(archive) == hash else { throw FairPlayFailure("结果传输校验失败。") }
                let temp = folder.appendingPathComponent("ResultCheck-"+UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temp) }
                let app = try ArchiveService.unpack(archive, to: temp)
                let info = try ArchiveService.metadata(at: app)
                let binaries = try FairPlayFiles.binaryRecords(in: app)
                guard info["CFBundleIdentifier"] as? String == job.manifest.bundleID,
                      binaries.map(\.path) == job.manifest.binaries.map(\.path), binaries.allSatisfy({ $0.encryptedSlices == 0 }) else {
                    throw FairPlayFailure("结果应用或二进制完整性校验失败。")
                }
                for original in job.manifest.binaries where original.encryptedSlices == 0 {
                    guard binaries.first(where: { $0.path == original.path })?.sha256 == original.sha256 else { throw FairPlayFailure("原本未加密的二进制发生变化。") }
                }
            }.value
            let destination = folder.appendingPathComponent("Result.ipa")
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: archive) }
            else { try FileManager.default.moveItem(at: archive, to: destination) }
            result = destination; status = "已取回并校验砸壳结果，可导入应用库签名"
        } catch { if !quietly { self.error = "暂未取回结果："+error.localizedDescription } }
    }
}
