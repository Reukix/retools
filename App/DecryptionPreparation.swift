import Foundation

struct PreparedDecryption: Codable, Sendable {
    let manifest: FairPlayManifest
    var signedBundleID: String?
    var installed = false
    var startedAutomatically: Bool? = nil
}

enum DecryptionPreparation {
    static func refreshTemplate(_ job: PreparedDecryption, template: URL, root: URL) throws {
        let fm = FileManager.default, folder = root.appendingPathComponent(job.manifest.id.uuidString)
        let hash = try FairPlayFiles.hash(template), marker = folder.appendingPathComponent("HelperTemplate.sha256")
        if (try? String(contentsOf: marker,encoding: .utf8)) == hash { return }
        let current = folder.appendingPathComponent("Helper/Payload/RetoolsDecryptHelper.app")
        let target = current.appendingPathComponent(FairPlayManifest.resourceDirectory+"/Target")
        try FairPlayFiles.verifyOriginals(job.manifest,in: target)
        let staging = folder.appendingPathComponent("TemplateUpdate-"+UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        let fresh = try ArchiveService.unpack(template,to: staging)
        let info = try ArchiveService.metadata(at: fresh)
        guard info["RetoolsDecryptHelper"] as? Bool == true, info["CFBundleExecutable"] as? String == "RetoolsDecryptHelper" else { throw FairPlayFailure("更新的解密助手模板不匹配。") }
        let freshPayload = fresh.appendingPathComponent(FairPlayManifest.resourceDirectory)
        if fm.fileExists(atPath: freshPayload.path) { try fm.removeItem(at: freshPayload) }
        try fm.copyItem(at: current.appendingPathComponent(FairPlayManifest.resourceDirectory),to: freshPayload)
        try JSONEncoder().encode(job.manifest).write(to: fresh.appendingPathComponent(FairPlayManifest.fileName),options: .atomic)
        try FairPlayFiles.verifyOriginals(job.manifest,in: fresh.appendingPathComponent(FairPlayManifest.resourceDirectory+"/Target"))
        let backup = current.deletingLastPathComponent().appendingPathComponent("HelperPrevious-"+UUID().uuidString)
        try fm.moveItem(at: current,to: backup)
        do { try fm.moveItem(at: fresh,to: current) }
        catch { try? fm.moveItem(at: backup,to: current); throw error }
        try? fm.removeItem(at: backup)
        for name in ["DecryptHelper.ipa","DecryptHelper-signed.ipa"] { try? fm.removeItem(at: folder.appendingPathComponent(name)) }
        try hash.write(to: marker,atomically: true,encoding: .utf8)
    }
    static func templateURL() throws -> URL {
        guard let url = Bundle(for: WorkspaceStore.self).url(forResource: "DecryptHelperTemplate", withExtension: "ipa") else {
            throw FairPlayFailure("此版本缺少解密助手模板，请重新安装完整的 Retools。")
        }
        return url
    }
    static func prepare(source: URL, template: URL, root: URL) throws -> PreparedDecryption {
        let fm = FileManager.default, id = UUID()
        let folder = root.appendingPathComponent(id.uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let snapshot = folder.appendingPathComponent("Source.ipa")
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            var copyError: Error?, coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { url in
                do { try fm.copyItem(at: url, to: snapshot) } catch { copyError = error }
            }
            if let error = copyError ?? coordinationError { throw error }
            let app = try ArchiveService.unpack(snapshot, to: folder.appendingPathComponent("Input"))
            let info = try ArchiveService.metadata(at: app)
            // Watch binaries have a different platform and cannot be processed on iPhone.
            if fm.fileExists(atPath: app.appendingPathComponent("Watch").path) { try fm.removeItem(at: app.appendingPathComponent("Watch")) }
            try replicateLicenses(in: app)
            let records = try FairPlayFiles.binaryRecords(in: app)
            guard records.contains(where: { $0.encryptedSlices > 0 }) else { throw FairPlayFailure("这个 IPA 没有发现加密二进制，可以直接在应用库签名。") }
            // Each encrypted binary needs a neighboring SINF; a missing license cannot be fixed by re-signing.
            for record in records where record.encryptedSlices > 0 {
                let file = app.appendingPathComponent(record.path)
                let license = file.deletingLastPathComponent().appendingPathComponent("SC_Info/"+file.lastPathComponent+".sinf")
                guard fm.fileExists(atPath: license.path) else { throw FairPlayFailure("\((record.path as NSString).lastPathComponent) 缺少 SC_Info 许可文件，请使用保留商店许可的加密 IPA。") }
            }
            var manifest = FairPlayManifest(schemaVersion: 1, id: id,
                name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent,
                bundleID: info["CFBundleIdentifier"] as! String, appFileName: app.lastPathComponent, binaries: records)
            manifest.startAuthorization = UUID()
            try manifest.validate()
            let helper = try ArchiveService.unpack(template, to: folder.appendingPathComponent("Helper"))
            let helperInfo = try ArchiveService.metadata(at: helper)
            guard helperInfo["RetoolsDecryptHelper"] as? Bool == true,
                  helperInfo["CFBundleExecutable"] as? String == "RetoolsDecryptHelper" else { throw FairPlayFailure("解密助手模板不匹配。") }
            let resources = helper.appendingPathComponent(FairPlayManifest.resourceDirectory)
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            let embedded = resources.appendingPathComponent("Target")
            try fm.moveItem(at: app, to: embedded)
            try JSONEncoder().encode(manifest).write(to: helper.appendingPathComponent(FairPlayManifest.fileName), options: .atomic)
            try FairPlayFiles.verifyOriginals(manifest, in: embedded)
            try ArchiveService.pack(app: helper, to: folder.appendingPathComponent("DecryptHelper.ipa"))
            let job = PreparedDecryption(manifest: manifest)
            try JSONEncoder().encode(job).write(to: folder.appendingPathComponent("Job.json"), options: .atomic)
            try FairPlayFiles.hash(template).write(to: folder.appendingPathComponent("HelperTemplate.sha256"),atomically: true,encoding: .utf8)
            try manifest.id.uuidString.write(to: root.appendingPathComponent("Current"), atomically: true, encoding: .utf8)
            try fm.removeItem(at: snapshot)
            try fm.removeItem(at: folder.appendingPathComponent("Input"))
            return job
        } catch { try? fm.removeItem(at: folder); throw error }
    }
    static func replicateLicenses(in app: URL) throws {
        let fm = FileManager.default, file = app.appendingPathComponent("SC_Info/Manifest.plist")
        guard fm.fileExists(atPath: file.path) else { return }
        guard let manifest = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] else { throw FairPlayFailure("SC_Info 许可清单无效。") }
        let sources = manifest["SinfPaths"] as? [String] ?? []
        let copies = manifest["SinfReplicationPaths"] as? [String] ?? []
        guard sources.count <= 10000, copies.count <= 10000 else { throw FairPlayFailure("SC_Info 清单过大。") }
        for path in sources+copies { try FairPlayFiles.validate(relative: path) }
        guard let first = sources.first else {
            if !copies.isEmpty { throw FairPlayFailure("SC_Info 缺少原始许可路径。") }; return
        }
        let original = app.appendingPathComponent(first)
        guard first.hasSuffix(".sinf"), fm.fileExists(atPath: original.path) else { throw FairPlayFailure("加密 IPA 缺少原始商店许可。") }
        for path in copies where !path.hasPrefix("Watch/") {
            guard path.hasSuffix(".sinf"), path.split(separator: "/").contains("SC_Info") else { throw FairPlayFailure("SC_Info 复制路径无效。") }
            let output = app.appendingPathComponent(path)
            if !fm.fileExists(atPath: output.path) {
                try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: original, to: output)
            }
        }
    }
}
