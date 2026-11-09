import Foundation
import CryptoKit
import RetoolsNative

actor WorkspaceService {
    let paths: WorkspacePaths
    private var state: WorkspaceState
    private let fm = FileManager.default

    init(paths: WorkspacePaths, state: WorkspaceState) { self.paths = paths; self.state = state }

    private func commit(_ next: WorkspaceState) throws -> WorkspaceState {
        let data = try JSONEncoder().encode(next)
        try data.write(to: paths.state, options: .atomic)
        state = next
        return next
    }
    private func log(_ title: String, _ detail: String, _ symbol: String, in next: inout WorkspaceState) {
        next.activities.insert(Activity(title: title, detail: detail, symbol: symbol), at: 0)
        next.activities = Array(next.activities.prefix(80))
    }
    private func coordinatedRead<T>(_ url: URL, _ read: (URL) throws -> T) throws -> T {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var result: Result<T, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            result = Result { try read(coordinatedURL) }
        }
        if let result { return try result.get() }
        throw coordinationError ?? NSError(domain: "Retools", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取所选文件，请确认文件已下载并重试。"])
    }
    private func readScoped(_ url: URL) throws -> Data {
        try coordinatedRead(url) { try Data(contentsOf: $0) }
    }
    private func readScoped(_ url: URL, maximumBytes: Int) throws -> Data {
        try coordinatedRead(url) { file in
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= maximumBytes else { throw WorkspaceFailure("所选文件不是普通文件，或超过允许的大小。") }
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else { throw WorkspaceFailure("所选文件超过允许的大小。") }
            return data
        }
    }
    private func temporaryDirectory() throws -> URL {
        let url = paths.staging.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// 解析好的 IPA：快照文件和从中读出的元数据来自同一份字节。
    private struct ParsedIPA {
        let snapshot: URL
        let name: String
        let bundleID: String
        let version: String
        let build: String
        let minimumOS: String
        let icon: Data?
        let byteCount: Int64
        let isEncrypted: Bool
    }
    private func parseIPA(_ source: URL, in temp: URL) throws -> ParsedIPA {
        // Snapshot first; metadata and stored bytes must come from the same file.
        let snapshot = temp.appendingPathComponent("import.ipa")
        try coordinatedRead(source) { try fm.copyItem(at: $0, to: snapshot) }
        let app = try ArchiveService.unpack(snapshot, to: temp.appendingPathComponent("Unpacked"))
        let info = try ArchiveService.metadata(at: app)
        let executable = info["CFBundleExecutable"] as! String
        let binary = try MachOInspector.inspect(app.appendingPathComponent(executable))
        let size = (try fm.attributesOfItem(atPath: snapshot.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ParsedIPA(snapshot: snapshot,
                         name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent,
                         bundleID: info["CFBundleIdentifier"] as! String, version: info["CFBundleShortVersionString"] as? String ?? "1.0",
                         build: info["CFBundleVersion"] as? String ?? "1", minimumOS: info["MinimumOSVersion"] as? String ?? "未知",
                         icon: ArchiveService.icon(at: app, info: info), byteCount: size, isEncrypted: binary.isEncrypted)
    }
    func importIPA(_ source: URL) throws -> WorkspaceState {
        let temp = try temporaryDirectory()
        defer { try? fm.removeItem(at: temp) }
        let parsed = try parseIPA(source, in: temp)
        let id = UUID()
        let fileName = id.uuidString + ".ipa"
        let iconFile = parsed.icon == nil ? nil : id.uuidString + ".png"
        let package = AppPackage(id: id, name: parsed.name, bundleID: parsed.bundleID, version: parsed.version, build: parsed.build, minimumOS: parsed.minimumOS,
                                 fileName: fileName, iconFile: iconFile, byteCount: parsed.byteCount, isEncrypted: parsed.isEncrypted, importedAt: Date())
        let destination = paths.library.appendingPathComponent(fileName)
        do {
            try fm.moveItem(at: parsed.snapshot, to: destination)
            if let icon = parsed.icon, let iconFile { try icon.write(to: paths.icons.appendingPathComponent(iconFile), options: .atomic) }
            var next = state; next.packages.insert(package, at: 0)
            log("已导入 \(package.name)", "v\(package.version) · \(package.sizeLabel)", "square.and.arrow.down", in: &next)
            return try commit(next)
        } catch {
            try? fm.removeItem(at: destination)
            if let iconFile { try? fm.removeItem(at: paths.icons.appendingPathComponent(iconFile)) }
            throw error
        }
    }
    /// 用新版本 IPA 替换应用库中的一项（软件源更新）。保留 ID、签名配置、插件注入和已签名的 Bundle ID，
    /// 这样续签与签名配置照常沿用；旧版本的签名输出作废并删除，扩展列表等新版本签名时重新读取。
    func replacePackageIPA(_ packageID: UUID, with source: URL) throws -> WorkspaceState {
        guard let index = state.packages.firstIndex(where: { $0.id == packageID }) else { throw WorkspaceFailure("找不到要更新的应用。") }
        let old = state.packages[index]
        let temp = try temporaryDirectory()
        defer { try? fm.removeItem(at: temp) }
        let parsed = try parseIPA(source, in: temp)
        guard parsed.bundleID == old.bundleID else {
            throw WorkspaceFailure("下载的包标识为 \(parsed.bundleID)，与应用库中的 \(old.bundleID) 不同，已取消更新。")
        }
        let token = UUID().uuidString
        let fileName = old.id.uuidString + "-" + token + ".ipa"
        let iconFile = parsed.icon == nil ? old.iconFile : old.id.uuidString + "-" + token + ".png"
        let destination = paths.library.appendingPathComponent(fileName)
        var package = old
        package.name = parsed.name; package.version = parsed.version; package.build = parsed.build; package.minimumOS = parsed.minimumOS
        package.fileName = fileName; package.iconFile = iconFile; package.byteCount = parsed.byteCount; package.isEncrypted = parsed.isEncrypted
        package.importedAt = Date()
        package.signedFile = nil; package.signedAt = nil; package.appleBundles = nil
        do {
            try fm.moveItem(at: parsed.snapshot, to: destination)
            if let icon = parsed.icon, let iconFile { try icon.write(to: paths.icons.appendingPathComponent(iconFile), options: .atomic) }
            var next = state; next.packages[index] = package
            log("已更新 \(package.name)", "v\(old.version) → v\(package.version)", "arrow.triangle.2.circlepath", in: &next)
            let result = try commit(next)
            // 提交成功后再清理旧文件；图标仍被容器或其他项引用时保留。
            try? fm.removeItem(at: paths.library.appendingPathComponent(old.fileName))
            try? fm.removeItem(at: paths.exports.appendingPathComponent(old.id.uuidString))
            if let signed = old.signedFile { try? fm.removeItem(at: paths.exports.appendingPathComponent(signed)) }
            if let icon = old.iconFile, icon != iconFile, !result.packages.contains(where: { $0.iconFile == icon }), !result.containerApps.contains(where: { $0.iconFile == icon }) {
                try? fm.removeItem(at: paths.icons.appendingPathComponent(icon))
            }
            return result
        } catch {
            try? fm.removeItem(at: destination)
            if let iconFile, iconFile != old.iconFile { try? fm.removeItem(at: paths.icons.appendingPathComponent(iconFile)) }
            throw error
        }
    }
    private func validatedIdentity(p12Data: Data, profileData: Data, password: String) throws -> SigningIdentity {
        let details = try RTNative.certificateDetails(p12Data, password: password)
        let payload = try RTNative.profilePayload(profileData)
        guard let plist = try PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any],
              let team = (plist["TeamIdentifier"] as? [String])?.first,
              let certTeam = details["teamID"] as? String, team == certTeam,
              let der = details["certificateDER"] as? Data,
              let certificates = plist["DeveloperCertificates"] as? [Data], certificates.contains(der),
              let entitlements = plist["Entitlements"] as? [String: Any],
              let applicationID = entitlements["application-identifier"] as? String,
              let expiration = plist["ExpirationDate"] as? Date,
              let certificateExpiration = details["expiresAt"] as? Date,
              let start = details["startsAt"] as? Date else {
            throw WorkspaceFailure("P12 证书与描述文件不匹配。请导入同一开发者团队、包含该证书的描述文件。")
        }
        guard expiration > Date(), certificateExpiration > Date(), start <= Date(),
              (plist["CreationDate"] as? Date ?? .distantPast) <= Date() else { throw WorkspaceFailure("证书或描述文件已过期，或尚未生效。") }
        guard applicationID.hasPrefix(team + ".") else { throw WorkspaceFailure("描述文件的应用标识与团队不一致。") }
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return SigningIdentity(id: UUID(), name: details["name"] as? String ?? "开发者证书", teamID: team,
                                       profileName: plist["Name"] as? String ?? "描述文件", applicationIdentifier: applicationID,
                                       expiresAt: expiration, certificateExpiresAt: certificateExpiration, fingerprint: fingerprint, importedAt: Date(),
                                       profileScopeFingerprint: try SigningIdentityCatalog.profileScope(plist))
    }
    func importIdentity(p12: URL, profile: URL, password: String) throws -> WorkspaceState {
        let p12Data = try readScoped(p12), profileData = try readScoped(profile)
        return try saveIdentity(p12Data: p12Data, profileData: profileData, password: password, forHost: false)
    }
    private func saveIdentity(p12Data: Data, profileData: Data, password: String, forHost: Bool) throws -> WorkspaceState {
        let identity = try validatedIdentity(p12Data: p12Data, profileData: profileData, password: password)
        let previous = state
        var next = SigningIdentityCatalog.normalized(state, paths: paths)
        let matches = next.identities.filter { SigningIdentityCatalog.equivalent($0, identity) }
        if let existing = matches.first(where: { item in
            let directory = paths.credentials.appendingPathComponent(item.id.uuidString)
            return (try? Data(contentsOf: directory.appendingPathComponent("identity.p12"))) == p12Data &&
                (try? Data(contentsOf: directory.appendingPathComponent("profile.mobileprovision"))) == profileData &&
                (try? SecureStore.password(id: item.id)) == password
        }) {
            if forHost { next.hostIdentityID = existing.id; next.activeIdentityID = next.activeIdentityID ?? existing.id }
            else { next.activeIdentityID = existing.id }
            let result = try commit(next)
            SigningIdentityCatalog.cleanupRemoved(from: previous, keeping: result, paths: paths)
            return result
        }
        let directory = paths.credentials.appendingPathComponent(identity.id.uuidString)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try p12Data.write(to: directory.appendingPathComponent("identity.p12"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try profileData.write(to: directory.appendingPathComponent("profile.mobileprovision"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var protected = directory; try protected.setResourceValues(values)
            try SecureStore.save(password: password, id: identity.id)
            let replaced = Set(matches.map(\.id))
            if let active = next.activeIdentityID, replaced.contains(active) { next.activeIdentityID = identity.id }
            if let host = next.hostIdentityID, replaced.contains(host) { next.hostIdentityID = identity.id }
            next.identities.removeAll { replaced.contains($0.id) }
            for index in next.packages.indices {
                if let selected = next.packages[index].signingOptions?.identityID, replaced.contains(selected) { next.packages[index].signingOptions?.selectIdentity(identity) }
            }
            next.identities.insert(identity, at: 0)
            if forHost { next.hostIdentityID = identity.id; next.activeIdentityID = next.activeIdentityID ?? identity.id }
            else { next.activeIdentityID = identity.id }
            log(matches.isEmpty ? "已添加签名证书" : "已更新签名配置", identity.name, "checkmark.seal", in: &next)
            let result = try commit(next)
            SigningIdentityCatalog.cleanupRemoved(from: previous, keeping: result, paths: paths)
            return result
        } catch {
            try? SecureStore.delete(id: identity.id); try? fm.removeItem(at: directory); throw error
        }
    }
    private func credentials(forHost: Bool = false, selectedID: UUID? = nil) throws -> (SigningIdentity, String, String, String) {
        let id = selectedID ?? (forHost ? (state.validHostIdentityID ?? state.activeIdentityID) : state.activeIdentityID)
        guard let identity = state.identities.first(where: { $0.id == id }) else { throw WorkspaceFailure("请先在签名页面导入 P12 和描述文件。") }
        guard !identity.isExpired else { throw WorkspaceFailure("当前证书或描述文件已过期，请更新签名凭据。") }
        let directory = paths.credentials.appendingPathComponent(identity.id.uuidString)
        return (identity, directory.appendingPathComponent("identity.p12").path, try SecureStore.password(id: identity.id), directory.appendingPathComponent("profile.mobileprovision").path)
    }
    func decryptionProvisioningIdentity(_ identityID: UUID, bundleID: String) throws -> SigningIdentity? {
        let (identity,_,_,profile) = try credentials(selectedID: identityID)
        let parsed = try ProfileRefresh.parse(Data(contentsOf: URL(fileURLWithPath: profile)))
        if parsed.entitlements["get-task-allow"] as? Bool == true,
           parsed.entitlements["application-identifier"] as? String != identity.teamID+"."+bundleID { return identity }
        return nil
    }
    func signDecryptionHelper(_ job: PreparedDecryption, identityID: UUID, bundleID: String,
                              fresh: AppleAccountService.Credentials?) throws -> URL {
        let root = paths.support.appendingPathComponent("Decryption/"+job.manifest.id.uuidString)
        let source = root.appendingPathComponent("Helper/Payload/RetoolsDecryptHelper.app")
        let payload = source.appendingPathComponent(FairPlayManifest.resourceDirectory+"/Target")
        func verifyPayload(_ target: URL, stage: String) throws {
            do {
                try FairPlayFiles.verifyOriginals(job.manifest, in: target)
                let report: [String: Any] = ["stage":stage,"passed":true,"binaryCount":job.manifest.binaries.count]
                try? JSONSerialization.data(withJSONObject: report,options: [.sortedKeys]).write(to: root.appendingPathComponent("IntegrityCheck.json"),options: .atomic)
            } catch {
                let actual = (try? FairPlayFiles.binaryRecords(in: target)) ?? []
                let changed = job.manifest.binaries.filter { record in actual.first(where: { $0.path == record.path }) != record }.map(\.path)
                let report: [String: Any] = ["stage":stage,"passed":false,"expectedCount":job.manifest.binaries.count,"actualCount":actual.count,"changedPaths":changed,"actualPaths":actual.map(\.path)]
                try? JSONSerialization.data(withJSONObject: report,options: [.sortedKeys]).write(to: root.appendingPathComponent("IntegrityCheck.json"),options: .atomic)
                throw WorkspaceFailure(stage+"校验未通过："+error.localizedDescription)
            }
        }
        try verifyPayload(payload,stage: "签名前")
        guard bundleID.hasPrefix(FairPlayManifest.helperBundleID+"."), bundleID != Bundle.main.bundleIdentifier else { throw WorkspaceFailure("解密助手标识无效。") }
        let (selected,p12Path,password,profilePath) = try credentials(selectedID: identityID)
        let temporary = try temporaryDirectory(); defer { try? fm.removeItem(at: temporary) }
        let app = temporary.appendingPathComponent("RetoolsDecryptHelper.app")
        try fm.copyItem(at: source, to: app)
        var p12 = p12Path, secret = password, profile = profilePath
        if let fresh {
            let identity = try validatedIdentity(p12Data: fresh.p12, profileData: fresh.profile, password: fresh.password)
            guard identity.teamID == selected.teamID, identity.fingerprint == selected.fingerprint else { throw WorkspaceFailure("获取到的助手证书与所选证书不一致，请重新选择。") }
            let p = temporary.appendingPathComponent("helper.p12"), m = temporary.appendingPathComponent("helper.mobileprovision")
            try fresh.p12.write(to: p, options: .completeFileProtectionUntilFirstUserAuthentication)
            try fresh.profile.write(to: m, options: .completeFileProtectionUntilFirstUserAuthentication)
            p12 = p.path; profile = m.path; secret = fresh.password
        }
        try RTNative.signApp(app.path, p12: p12, password: secret, profile: profile, bundleID: bundleID,
            removeExtensions: false, hostBundle: false, options: ["preserveDecryptionPayload": true, "removeWatch": false])
        try verifyPayload(app.appendingPathComponent(FairPlayManifest.resourceDirectory+"/Target"),stage: "签名后")
        let archive = temporary.appendingPathComponent("DecryptHelper-signed.ipa")
        try ArchiveService.pack(app: app, to: archive)
        let destination = root.appendingPathComponent("DecryptHelper-signed.ipa")
        // Replace only our helper output after the entire signing and payload verification succeeds.
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: archive) }
        else { try fm.moveItem(at: archive, to: destination) }
        return destination
    }
    func sign(_ packageID: UUID, bundleID: String) throws -> WorkspaceState {
        try signPackage(packageID, bundleID: bundleID, material: credentials(), keepExtensions: true)
    }
    func saveSigningOptions(_ options: PackageSigningOptions, packageID: UUID) throws -> WorkspaceState {
        guard let index = state.packages.firstIndex(where: { $0.id == packageID }) else { throw WorkspaceFailure("找不到应用。") }
        var options = options
        if let resolved = options.selectedIdentity(in: state.identities) { options.selectIdentity(resolved) }
        try options.validate(for: state.packages[index])
        var next = state; next.packages[index].signingOptions = options
        return try commit(next)
    }
    func signProject(_ packageID: UUID, options: PackageSigningOptions, report: SigningReporter? = nil) throws -> WorkspaceState {
        guard let package = state.packages.first(where: { $0.id == packageID }) else { throw WorkspaceFailure("找不到应用。") }
        var options = options
        if options.identityID != nil {
            guard let resolved = options.selectedIdentity(in: state.identities) else { throw WorkspaceFailure("项目所选证书已移除，请重新选择。") }
            options.selectIdentity(resolved)
        }
        report?.report(.credentials, detail: "读取证书与描述文件")
        return try signPackage(packageID, bundleID: options.identifier(for: package), material: credentials(selectedID: options.identityID), options: options, keepExtensions: true, report: report)
    }
    func importSigningIcon(_ source: URL) throws -> String {
        let data = try SigningProjectService.normalizedIcon(readScoped(source, maximumBytes: 8_000_000)), name = "project-" + UUID().uuidString + ".png"
        try data.write(to: paths.icons.appendingPathComponent(name), options: .atomic)
        return name
    }
    func projectProvisioningIdentity(_ packageID: UUID, options: PackageSigningOptions) throws -> SigningIdentity? {
        guard let package = state.packages.first(where: { $0.id == packageID }) else { throw WorkspaceFailure("找不到应用。") }
        try options.validate(for: package)
        _ = try sourceArchive(package)
        guard !package.isEncrypted else { throw WorkspaceFailure("这个 IPA 的可执行文件已加密，无法重新签名。") }
        let selected = options.selectedIdentity(in: state.identities)
        if options.identityID != nil && selected == nil { throw WorkspaceFailure("项目所选证书已移除，请重新选择。") }
        let (identity, _, _, profile) = try credentials(selectedID: selected?.id)
        let payload = try RTNative.profilePayload(Data(contentsOf: URL(fileURLWithPath: profile)))
        guard let values = try PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any],
              let entitlements = values["Entitlements"] as? [String: Any] else { throw WorkspaceFailure("无法读取开发描述文件。") }
        guard entitlements["get-task-allow"] as? Bool == true else { return nil }
        let applicationID = entitlements["application-identifier"] as? String ?? ""
        let target = identity.teamID + "." + options.identifier(for: package)
        if applicationID == target { return nil }
        if applicationID.hasSuffix("*"), target.hasPrefix(String(applicationID.dropLast())), target.count > applicationID.count - 1 { return nil }
        return identity
    }
    func signProject(_ packageID: UUID, options: PackageSigningOptions, credentials: AppleAccountService.Credentials, expectedIdentity: SigningIdentity, report: SigningReporter? = nil) throws -> WorkspaceState {
        guard let package = state.packages.first(where: { $0.id == packageID }) else { throw WorkspaceFailure("找不到应用。") }
        let identity = try validatedIdentity(p12Data: credentials.p12, profileData: credentials.profile, password: credentials.password)
        guard identity.teamID == expectedIdentity.teamID, identity.fingerprint == expectedIdentity.fingerprint else {
            throw WorkspaceFailure("Apple ID 返回的证书与项目所选证书不一致，请重新准备该账号的开发签名并选择对应证书。")
        }
        let bundleID = options.identifier(for: package)
        guard identity.applicationIdentifier == identity.teamID + "." + bundleID else {
            throw WorkspaceFailure("Apple 返回的描述文件不匹配目标应用，未生成签名输出。")
        }
        let temp = try temporaryDirectory(); defer { try? fm.removeItem(at: temp) }
        let p12 = temp.appendingPathComponent("account.p12"), profile = temp.appendingPathComponent("account.mobileprovision")
        try credentials.p12.write(to: p12, options: .completeFileProtectionUntilFirstUserAuthentication)
        try credentials.profile.write(to: profile, options: .completeFileProtectionUntilFirstUserAuthentication)
        return try signPackage(packageID, bundleID: bundleID, material: (identity, p12.path, credentials.password, profile.path), options: options, report: report)
    }
    func importSigningEntitlements(_ source: URL) throws -> Data {
        let data = try readScoped(source, maximumBytes: 262144); let values = try PackageSigningOptions.entitlements(data)
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }
    func inspectSigningProject(_ packageID: UUID) throws -> SigningProjectInspection {
        try Task.checkCancellation()
        guard let package = state.packages.first(where: { $0.id == packageID }) else { throw WorkspaceFailure("找不到应用。") }
        let temp = try temporaryDirectory(); defer { try? fm.removeItem(at: temp) }
        let app = try ArchiveService.unpack(sourceArchive(package), to: temp.appendingPathComponent("Unpacked"))
        let info = try ArchiveService.metadata(at: app), executable = info["CFBundleExecutable"] as! String
        return SigningProjectInspection(dependencies: try MachOInspector.inspect(app.appendingPathComponent(executable)).dependencies, executable: executable)
    }
    private func prepareSigningCopy(_ package: AppPackage, options: PackageSigningOptions, temp: URL, keepExtensions: Bool = false, report: SigningReporter? = nil) throws -> URL {
        report?.report(.unpack, fraction: 0, detail: package.fileName)
        var unpacked = 0
        let app = try ArchiveService.unpack(sourceArchive(package), to: temp.appendingPathComponent("Unpacked")) { fraction, file in
            unpacked += 1
            report?.report(.unpack, fraction: fraction < 1 ? fraction : 0.999, detail: file)
        }
        report?.report(.unpack, fraction: 1, detail: "已解压 \(unpacked) 个文件")
        report?.report(.configure, detail: "名称、图标、Bundle ID 与应用选项")
        try SigningProjectService.apply(options, package: package, to: app, paths: paths, keepExtensions: keepExtensions)
        let entries = try PluginService.configuration(package.pluginInjections, legacy: package.pluginIDs ?? [], plugins: state.plugins)
        if entries.isEmpty { report?.skip(.inject, detail: "未选择插件") }
        else { report?.report(.inject, detail: "\(entries.count) 个动态库") }
        _ = try PluginService.materialize(PluginService.selected(PluginService.recordIDs(entries), from: state.plugins), in: app, namespace: package.id, paths: paths)
        try SigningProjectService.inject(entries, in: app, namespace: package.id)
        try SigningProjectService.patchMinimumOS(options.minimumOS, in: app)
        return app
    }
    /// 统计需要签名的 Mach-O 文件数，作为逐文件签名进度的分母。
    private static func machOCount(in app: URL) -> Int {
        let magics: Set<UInt32> = [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca]
        var count = 0
        let items = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let file = items?.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, (values.fileSize ?? 0) >= 4,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 4), data.count == 4, magics.contains(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) { count += 1 }
        }
        return max(1, count)
    }
    private func sourceArchive(_ package: AppPackage) throws -> URL {
        let file = paths.library.appendingPathComponent(package.fileName)
        guard fm.fileExists(atPath: file.path) else { throw WorkspaceFailure("原始 IPA 已被移动或删除。请在「文件」中恢复原文件，或重新导入 IPA 后再试。") }
        return file
    }
    func signingProjectPreview(_ packageID: UUID, options: PackageSigningOptions) throws -> URL {
        try Task.checkCancellation()
        guard let package = state.packages.first(where: { $0.id == packageID }) else { throw WorkspaceFailure("找不到应用。") }
        let temp = try temporaryDirectory()
        do {
            let app = try prepareSigningCopy(package, options: options, temp: temp, keepExtensions: true)
            try Task.checkCancellation()
            return app
        }
        catch { try? fm.removeItem(at: temp); throw error }
    }
    func discardSigningPreview(_ app: URL) {
        let parent = app.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard parent.deletingLastPathComponent().standardizedFileURL == paths.staging.standardizedFileURL,
              UUID(uuidString: parent.lastPathComponent) != nil else { return }
        try? fm.removeItem(at: parent)
    }
    func exportProjectPlugins(_ packageID: UUID, entryIDs: Set<String>? = nil) throws -> URL {
        guard let package = state.packages.first(where: { $0.id == packageID }) else { throw WorkspaceFailure("找不到应用。") }
        let entries = try PluginService.configuration(package.pluginInjections, legacy: package.pluginIDs ?? [], plugins: state.plugins).filter { entryIDs == nil || entryIDs!.contains($0.id) }
        guard !entries.isEmpty else { throw WorkspaceFailure("当前项目没有已选择的插件。") }
        let temp = try temporaryDirectory(); defer { try? fm.removeItem(at: temp) }
        let directory = temp.appendingPathComponent("Plugins"); try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for record in try PluginService.selected(PluginService.recordIDs(entries), from: state.plugins) {
            try fm.copyItem(at: paths.plugins.appendingPathComponent(record.id.uuidString + "/Payload"), to: directory.appendingPathComponent(record.id.uuidString))
        }
        try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("RetoolsPluginSelection.json"), options: .atomic)
        let destination = paths.exports.appendingPathComponent("Plugins-" + UUID().uuidString.prefix(8) + ".zip")
        try fm.zipItem(at: directory, to: destination, shouldKeepParent: true, compressionMethod: .deflate)
        return destination
    }
    func snapshot() -> WorkspaceState { state }
    func importPlugin(_ source: URL) throws -> WorkspaceState {
        let temp = try temporaryDirectory(); defer { try? fm.removeItem(at: temp) }
        let snapshot = temp.appendingPathComponent(source.lastPathComponent)
        try coordinatedRead(source) { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? Int.max) <= PluginService.maximumBytes else { throw WorkspaceFailure("插件体积超过 512 MB。"); }
            try fm.copyItem(at: url, to: snapshot)
        }
        let record = try PluginService.importFile(snapshot, paths: paths)
        do {
            guard !state.plugins.contains(where: { $0.fingerprint == record.fingerprint }) else { throw WorkspaceFailure("这份插件已经导入。") }
            var next = state; next.plugins.append(record)
            return try commit(next)
        } catch { try? fm.removeItem(at: paths.plugins.appendingPathComponent(record.id.uuidString)); throw error }
    }
    func deletePlugin(_ id: UUID) throws -> WorkspaceState {
        guard !state.packages.contains(where: { $0.pluginIDs?.contains(id) == true }),
              !state.containerApps.contains(where: { $0.pluginIDs?.contains(id) == true }) else { throw WorkspaceFailure("插件正被应用使用，请先取消对应应用的插件选择。") }
        guard state.plugins.contains(where: { $0.id == id }) else { return state }
        let temp = try temporaryDirectory(); defer { try? fm.removeItem(at: temp) }
        let source = paths.plugins.appendingPathComponent(id.uuidString), backup = temp.appendingPathComponent("plugin")
        try fm.moveItem(at: source, to: backup)
        var next = state; next.plugins.removeAll { $0.id == id }
        do { return try commit(next) }
        catch { try? fm.moveItem(at: backup, to: source); throw error }
    }
    func pluginDetails(_ id: UUID) throws -> (PluginRecord, [String]) {
        guard var record = state.plugins.first(where: { $0.id == id }) else { throw WorkspaceFailure("插件已不存在。") }
        let root = paths.plugins.appendingPathComponent(id.uuidString + "/Payload")
        let files = try PluginService.files(in: root)
        if record.binaries == nil { record.binaries = try PluginService.describe(record.executablePaths, root: root) }
        record.resourceCount = files.count - record.executablePaths.count
        return (record, files)
    }
    func setPackagePlugins(_ id: UUID, plugins: [UUID]) throws -> WorkspaceState {
        try setPackageInjections(id, entries: PluginService.configuration(nil, legacy: plugins, plugins: state.plugins))
    }
    func setPackageInjections(_ id: UUID, entries: [PluginInjection]) throws -> WorkspaceState {
        let entries = try PluginService.configuration(entries, legacy: [], plugins: state.plugins)
        guard let index = state.packages.firstIndex(where: { $0.id == id }) else { throw WorkspaceFailure("找不到应用。") }
        var next = state; next.packages[index].pluginIDs = PluginService.recordIDs(entries); next.packages[index].pluginInjections = entries
        return try commit(next)
    }
    func setContainerPlugins(_ id: UUID, plugins: [UUID]) throws -> WorkspaceState {
        try setContainerInjections(id, entries: PluginService.configuration(nil, legacy: plugins, plugins: state.plugins))
    }
    func setContainerInjections(_ id: UUID, entries: [PluginInjection]) throws -> WorkspaceState {
        let entries = try PluginService.configuration(entries, legacy: [], plugins: state.plugins)
        guard let index = state.containerApps.firstIndex(where: { $0.id == id }) else { throw WorkspaceFailure("找不到容器应用。") }
        var next = state; next.containerApps[index].pluginIDs = PluginService.recordIDs(entries); next.containerApps[index].pluginInjections = entries; next.containerApps[index].signedFingerprint = nil
        let app = next.containerApps[index], url = paths.applications.appendingPathComponent(app.folder)
        do { try writeContainerMetadata(app, at: url); return try commit(next) }
        catch { try? writeContainerMetadata(state.containerApps[index], at: url); throw error }
    }
    func reload() throws -> WorkspaceState {
        let loaded = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: paths.state))
        guard loaded.schemaVersion == 1 else { throw WorkspaceFailure("工作区版本不兼容。") }
        let normalized = SigningIdentityCatalog.normalized(loaded, paths: paths)
        if SigningIdentityCatalog.changed(loaded, normalized) {
            let result = try commit(normalized)
            SigningIdentityCatalog.cleanupRemoved(from: loaded, keeping: result, paths: paths)
            return result
        }
        state = loaded; return loaded
    }
    func importHostIdentity(_ material: AppleAccountService.Credentials) throws -> WorkspaceState {
        try saveIdentity(p12Data: material.p12, profileData: material.profile, password: material.password, forHost: true)
    }
    func signWithCredentials(_ packageID: UUID, bundleID: String, credentials: AppleAccountService.Credentials) throws -> WorkspaceState {
        let identity = try validatedIdentity(p12Data: credentials.p12, profileData: credentials.profile, password: credentials.password)
        let temp = try temporaryDirectory(); defer { try? fm.removeItem(at: temp) }
        let p12 = temp.appendingPathComponent("account.p12"), profile = temp.appendingPathComponent("account.mobileprovision")
        try credentials.p12.write(to: p12, options: .completeFileProtectionUntilFirstUserAuthentication)
        try credentials.profile.write(to: profile, options: .completeFileProtectionUntilFirstUserAuthentication)
        // Each job carries its own credentials; the user's selected certificate stays independent.
        return try signPackage(packageID, bundleID: bundleID, material: (identity, p12.path, credentials.password, profile.path))
    }
    /// Apple ID 签名第一步（SideStore 流程）：按项目配置准备签名副本，主应用与扩展改用新的 Bundle ID，
    /// 并列出每个 bundle 需要的 App ID、功能与 App Group。之后取得描述文件，再调用 finishAppleSigning。
    func prepareAppleSigning(_ packageID: UUID, bundleID: String, options provided: PackageSigningOptions? = nil, report: SigningReporter? = nil) throws -> AppleSigningPlan {
        guard let package = state.packages.first(where: { $0.id == packageID }) else { throw WorkspaceFailure("找不到应用。") }
        var options = provided ?? package.signingOptions ?? PackageSigningOptions(); options.bundleID = bundleID
        try options.validate(for: package)
        guard !package.isEncrypted else { throw WorkspaceFailure("这个 IPA 的可执行文件已加密，无法重新签名。") }
        guard bundleID.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else { throw WorkspaceFailure("请填写有效的 Bundle ID。") }
        let temp = try temporaryDirectory()
        do {
            let app = try prepareSigningCopy(package, options: options, temp: temp, keepExtensions: true, report: report)
            let mainName = options.name(for: package)
            var bundles: [AppleBundleRequest] = [], entitlements: [String: Data] = [:], folders: [String: String] = [:]
            var targets: [(String, URL)] = [("", app)]
            for folder in ["PlugIns", "Extensions"] {
                let items = (try? fm.contentsOfDirectory(at: app.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? []
                targets += items.filter { $0.pathExtension == "appex" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { (folder + "/" + $0.lastPathComponent, $0) }
            }
            for (relative, folder) in targets {
                var info = try ArchiveService.metadata(at: folder)
                guard let id = info["CFBundleIdentifier"] as? String, let executable = info["CFBundleExecutable"] as? String else {
                    throw WorkspaceFailure("\(relative.isEmpty ? "主应用" : relative) 缺少 Bundle ID 或可执行文件。")
                }
                // 与 SideStore 一致：后台任务标识跟随新的 Bundle ID，否则任务能注册却永远不会被调用。
                var changed = false
                if let tasks = info["BGTaskSchedulerPermittedIdentifiers"] as? [String], package.bundleID != bundleID {
                    info["BGTaskSchedulerPermittedIdentifiers"] = tasks.map { $0.hasPrefix(package.bundleID) ? bundleID + $0.dropFirst(package.bundleID.count) : $0 }; changed = true
                }
                for key in ["DTXcode", "DTXcodeBuild"] where info[key] != nil { info.removeValue(forKey: key); changed = true }
                if changed { try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: folder.appendingPathComponent("Info.plist"), options: .atomic) }
                let declared = ((try? RTNative.entitlements(ofExecutable: folder.appendingPathComponent(executable).path)) as? [String: Any]) ?? [:]
                let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? folder.deletingPathExtension().lastPathComponent
                bundles.append(AppleBundleRequest(bundleID: id, name: relative.isEmpty ? mainName : mainName + " " + name, entitlementKeys: declared.keys.sorted(),
                                                  appGroups: (declared["com.apple.security.application-groups"] as? [String]) ?? []))
                entitlements[id] = try PropertyListSerialization.data(fromPropertyList: declared, format: .binary, options: 0)
                folders[id] = relative
            }
            return AppleSigningPlan(packageID: packageID, bundleID: bundleID, options: options, persistOptions: provided != nil, temp: temp, app: app,
                                    bundles: bundles, entitlements: entitlements, folders: folders)
        } catch { try? fm.removeItem(at: temp); throw error }
    }
    func discardAppleSigning(_ plan: AppleSigningPlan) { try? fm.removeItem(at: plan.temp) }
    /// Apple ID 签名第二步：每个 bundle 用各自的描述文件签名；没有取得描述文件的扩展被移除。
    func finishAppleSigning(_ plan: AppleSigningPlan, credentials: AppleAppCredentials, expectedIdentity: SigningIdentity? = nil, report: SigningReporter? = nil) throws -> WorkspaceState {
        defer { try? fm.removeItem(at: plan.temp) }
        guard let main = credentials.profiles[plan.bundleID] else { throw WorkspaceFailure("Apple 未返回主应用的描述文件。") }
        let identity = try validatedIdentity(p12Data: credentials.p12, profileData: main, password: credentials.password)
        if let expectedIdentity, identity.teamID != expectedIdentity.teamID || identity.fingerprint != expectedIdentity.fingerprint {
            throw WorkspaceFailure("Apple ID 返回的证书与项目所选证书不一致，请重新准备该账号的开发签名并选择对应证书。")
        }
        guard identity.applicationIdentifier == identity.teamID + "." + plan.bundleID else { throw WorkspaceFailure("Apple 返回的描述文件不匹配目标应用，未生成签名输出。") }
        let material = plan.temp.appendingPathComponent("AppleCredentials", isDirectory: true)
        try fm.createDirectory(at: material, withIntermediateDirectories: true)
        let p12 = material.appendingPathComponent("account.p12")
        try credentials.p12.write(to: p12, options: .completeFileProtectionUntilFirstUserAuthentication)
        var bundles: [[String: Any]] = [], signed: [AppleBundleRequest] = []
        for request in plan.bundles {
            let folder = plan.folders[request.bundleID].map { $0.isEmpty ? plan.app : plan.app.appendingPathComponent($0) } ?? plan.app
            guard let data = credentials.profiles[request.bundleID] else {
                // 可用 App ID 不足等情况下只保留主应用，与 SideStore 移除扩展相同。
                if folder != plan.app { try? fm.removeItem(at: folder) }
                continue
            }
            // 文件提供扩展的文档分组改成实际分配到的 App Group。
            if folder != plan.app, var info = try? ArchiveService.metadata(at: folder), var extensionInfo = info["NSExtension"] as? [String: Any],
               let group = extensionInfo["NSExtensionFileProviderDocumentGroup"] as? String,
               let local = (credentials.appGroups[request.bundleID] ?? []).filter({ $0.contains(group) }).min(by: { $0.count < $1.count }) {
                extensionInfo["NSExtensionFileProviderDocumentGroup"] = local; info["NSExtension"] = extensionInfo
                try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: folder.appendingPathComponent("Info.plist"), options: .atomic)
            }
            let profile = material.appendingPathComponent("\(bundles.count).mobileprovision")
            try data.write(to: profile, options: .completeFileProtectionUntilFirstUserAuthentication)
            let declared = plan.entitlements[request.bundleID].flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any] ?? [:]
            bundles.append(["bundleID": request.bundleID, "profile": profile.path, "entitlements": declared])
            signed.append(request)
        }
        var nativeOptions: [String: Any] = ["removeWatch": plan.options.removeWatch]
        if let report {
            let total = Self.machOCount(in: plan.app), counter = SigningFileCounter()
            report.report(.sign, fraction: 0, detail: "共 \(total) 个可执行文件 · \(bundles.count) 份描述文件")
            let handler: @convention(block) (String) -> Void = { name in
                let done = counter.next()
                report.report(.sign, fraction: Double(min(done, total)) / Double(total), detail: "\(name)（\(min(done, total))/\(total)）")
            }
            nativeOptions["progress"] = handler
        }
        try RTNative.signApp(plan.app.path, p12: p12.path, password: credentials.password, bundles: bundles, options: nativeOptions)
        return try commitSignedOutput(packageID: plan.packageID, app: plan.app, temp: plan.temp, options: plan.options, persistOptions: plan.persistOptions,
                                      bundleID: plan.bundleID, expiresAt: min(identity.expiresAt, identity.certificateExpiresAt), appleBundles: signed, report: report)
    }
    /// keepExtensions：用导入的证书和描述文件签名时，与 LCSign 一样用同一份描述文件签名扩展并保留；
    /// Apple ID 取得的开发描述文件只覆盖主应用，扩展仍移除。
    private func signPackage(_ packageID: UUID, bundleID: String, material: (SigningIdentity, String, String, String), options provided: PackageSigningOptions? = nil, keepExtensions: Bool = false, report: SigningReporter? = nil) throws -> WorkspaceState {
        guard let index = state.packages.firstIndex(where: { $0.id == packageID }) else { throw WorkspaceFailure("找不到应用。") }
        let package = state.packages[index]
        var options = provided ?? package.signingOptions ?? PackageSigningOptions(); options.bundleID = bundleID
        try options.validate(for: package)
        guard !package.isEncrypted else { throw WorkspaceFailure("这个 IPA 的可执行文件已加密，无法重新签名。") }
        let (identity, p12, password, profile) = material
        guard bundleID.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else { throw WorkspaceFailure("请填写有效的 Bundle ID。") }
        guard identity.supports(bundleID: bundleID) else { throw WorkspaceFailure("当前描述文件不允许签名 \(bundleID)。请修改 Bundle ID，或选择匹配的描述文件。") }
        let temp = try temporaryDirectory(); defer { try? fm.removeItem(at: temp) }
        let app = try prepareSigningCopy(package, options: options, temp: temp, keepExtensions: keepExtensions, report: report)
        var nativeOptions: [String: Any] = ["removeWatch": options.removeWatch, "removeEmbedded": options.removeEmbedded]
        if let entitlements = options.customEntitlements { nativeOptions["customEntitlements"] = entitlements }
        if let report {
            let total = Self.machOCount(in: app)
            let counter = SigningFileCounter()
            report.report(.sign, fraction: 0, detail: "共 \(total) 个可执行文件 · \(identity.name)")
            let handler: @convention(block) (String) -> Void = { name in
                let done = counter.next()
                report.report(.sign, fraction: Double(min(done, total)) / Double(total), detail: "\(name)（\(min(done, total))/\(total)）")
            }
            nativeOptions["progress"] = handler
        }
        try RTNative.signApp(app.path, p12: p12, password: password, profile: profile, bundleID: bundleID, removeExtensions: !keepExtensions, hostBundle: false, options: nativeOptions)
        return try commitSignedOutput(packageID: packageID, app: app, temp: temp, options: options, persistOptions: provided != nil, bundleID: bundleID,
                                      expiresAt: min(identity.expiresAt, identity.certificateExpiresAt), report: report)
    }
    /// 打包签名结果、写入导出目录并更新工作区；写入失败时恢复上一次的输出。
    private func commitSignedOutput(packageID: UUID, app: URL, temp: URL, options: PackageSigningOptions, persistOptions: Bool, bundleID: String,
                                    expiresAt: Date, appleBundles: [AppleBundleRequest]? = nil, report: SigningReporter?) throws -> WorkspaceState {
        guard let index = state.packages.firstIndex(where: { $0.id == packageID }) else { throw WorkspaceFailure("找不到应用。") }
        let package = state.packages[index]
        let directory = paths.exports.appendingPathComponent(package.id.uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = package.id.uuidString + "/" + (try options.fileName(for: package))
        let export = paths.exports.appendingPathComponent(fileName)
        let partial = temp.appendingPathComponent("signed.ipa")
        report?.report(.pack, fraction: 0, detail: export.lastPathComponent)
        try ArchiveService.pack(app: app, to: partial) { fraction in report?.report(.pack, fraction: fraction, detail: export.lastPathComponent) }
        report?.report(.save, detail: "写入「文件 → Retools」")
        let backup = temp.appendingPathComponent("previous-output")
        if fm.fileExists(atPath: export.path) { try fm.copyItem(at: export, to: backup) }
        var next = state
        let oldFile = next.packages[index].signedFile
        next.packages[index].signedFile = fileName
        next.packages[index].signedAt = Date()
        next.packages[index].signedExpiresAt = expiresAt
        next.packages[index].signedBundleID = bundleID
        next.packages[index].appleBundles = appleBundles
        if persistOptions { next.packages[index].signingOptions = options }
        log("\(package.name) 签名完成", bundleID, "signature", in: &next)
        do {
            if fm.fileExists(atPath: export.path) { _ = try fm.replaceItemAt(export, withItemAt: partial) }
            else { try fm.moveItem(at: partial, to: export) }
            let result = try commit(next)
            if let oldFile, oldFile != fileName { try? fm.removeItem(at: paths.exports.appendingPathComponent(oldFile)) }
            return result
        } catch {
            try? fm.removeItem(at: export)
            if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: export) }
            throw error
        }
    }
    private func writeContainerMetadata(_ app: ContainerApp, at directory: URL) throws {
        let entries = try PluginService.configuration(app.pluginInjections, legacy: app.pluginIDs ?? [], plugins: state.plugins)
        let pluginPaths = entries.map { PluginService.loadPath($0, namespace: app.id) }
        let dict: [String: Any] = ["LCDataUUID": app.selectedContainerID.uuidString, "LCOrignalBundleIdentifier": app.bundleID, "RetoolsPluginPaths": pluginPaths,
                                   "RetoolsPluginEntries": entries.map { ["path": PluginService.loadPath($0, namespace: app.id), "weak": $0.loadKind == .optional] as [String: Any] },
                                   "LCPatchRevision": 7, "dontInjectTweakLoader": true, "dontLoadTweakLoader": true,
                                   "LCContainers": app.containers.map { ["folderName": $0.folderName, "name": $0.name] },
                                   "installationDate": app.installedAt]
        try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0).write(to: directory.appendingPathComponent("LCAppInfo.plist"), options: .atomic)
    }
    private func createData(_ container: DataContainer, bundleID: String, at base: URL? = nil) throws {
        let folder = base ?? paths.data.appendingPathComponent(container.folderName)
        for path in ["Documents", "Library/Preferences", "Library/Caches", "tmp"] { try fm.createDirectory(at: folder.appendingPathComponent(path), withIntermediateDirectories: true) }
        let dict: [String: Any] = ["appIdentifier": bundleID, "name": container.name, "keychainGroupId": 0, "isolateAppGroup": true, "spoofIdentifierForVendor": true, "spoofedIdentifierForVendor": container.id.uuidString]
        try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0).write(to: folder.appendingPathComponent("LCContainerInfo.plist"), options: .atomic)
    }
    func installContainer(_ packageID: UUID) throws -> WorkspaceState {
        guard let package = state.packages.first(where: { $0.id == packageID }) else { throw WorkspaceFailure("找不到应用。") }
        guard !package.isEncrypted else { throw WorkspaceFailure("加密 IPA 无法导入容器。") }
        let temp = try temporaryDirectory(); defer { try? fm.removeItem(at: temp) }
        let app = try ArchiveService.unpack(paths.library.appendingPathComponent(package.fileName), to: temp.appendingPathComponent("Unpacked"))
        let metadata = try ArchiveService.metadata(at: app)
        let result = try MachOInspector.inspect(app.appendingPathComponent(metadata["CFBundleExecutable"] as! String))
        guard result.hasARM64 else { throw WorkspaceFailure("容器需要 arm64 iOS 应用。") }
        try RTNative.prepareContainer(app.path)
        let id = UUID(), container = DataContainer(id: UUID(), name: "默认空间", createdAt: Date())
        let record = ContainerApp(id: id, packageID: packageID, name: package.name, bundleID: package.bundleID, version: package.version,
                                  folder: id.uuidString + ".app", iconFile: package.iconFile, containers: [container], selectedContainerID: container.id, installedAt: Date())
        let destination = paths.applications.appendingPathComponent(record.folder)
        do {
            try writeContainerMetadata(record, at: app)
            try createData(container, bundleID: record.bundleID)
            try fm.moveItem(at: app, to: destination)
            var next = state; next.containerApps.insert(record, at: 0)
            log("已导入容器", "\(record.name) · 默认空间", "shippingbox", in: &next)
            return try commit(next)
        } catch {
            try? fm.removeItem(at: destination); try? fm.removeItem(at: paths.data.appendingPathComponent(container.folderName)); throw error
        }
    }
    func addContainer(to appID: UUID, name: String) throws -> WorkspaceState {
        guard let index = state.containerApps.firstIndex(where: { $0.id == appID }) else { throw WorkspaceFailure("找不到容器应用。") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw WorkspaceFailure("空间名称应为 1 到 40 个字符。") }
        let container = DataContainer(id: UUID(), name: name, createdAt: Date())
        var next = state; next.containerApps[index].containers.append(container)
        do {
            try createData(container, bundleID: next.containerApps[index].bundleID)
            try writeContainerMetadata(next.containerApps[index], at: paths.applications.appendingPathComponent(next.containerApps[index].folder))
            log("已创建数据空间", name, "square.stack.3d.up", in: &next)
            return try commit(next)
        } catch {
            try? fm.removeItem(at: paths.data.appendingPathComponent(container.folderName))
            try? writeContainerMetadata(state.containerApps[index], at: paths.applications.appendingPathComponent(state.containerApps[index].folder)); throw error
        }
    }
    func selectContainer(appID: UUID, containerID: UUID) throws -> WorkspaceState {
        guard let index = state.containerApps.firstIndex(where: { $0.id == appID }), state.containerApps[index].containers.contains(where: { $0.id == containerID }) else { throw WorkspaceFailure("找不到数据空间。") }
        var next = state; next.containerApps[index].selectedContainerID = containerID
        let path = paths.applications.appendingPathComponent(next.containerApps[index].folder)
        do { try writeContainerMetadata(next.containerApps[index], at: path); return try commit(next) }
        catch { try? writeContainerMetadata(state.containerApps[index], at: path); throw error }
    }
    func resetContainer(appID: UUID, containerID: UUID) throws -> WorkspaceState {
        guard let app = state.containerApps.first(where: { $0.id == appID }), let container = app.containers.first(where: { $0.id == containerID }) else { throw WorkspaceFailure("找不到数据空间。") }
        let temp = try temporaryDirectory(); defer { try? fm.removeItem(at: temp) }
        let fresh = temp.appendingPathComponent("fresh"), backup = temp.appendingPathComponent("backup")
        try createData(container, bundleID: app.bundleID, at: fresh)
        let destination = paths.data.appendingPathComponent(container.folderName)
        try fm.moveItem(at: destination, to: backup)
        do {
            try fm.moveItem(at: fresh, to: destination)
            var next = state; log("已重置数据空间", "\(app.name) · \(container.name)", "arrow.counterclockwise", in: &next)
            return try commit(next)
        } catch {
            try? fm.removeItem(at: destination); try? fm.moveItem(at: backup, to: destination); throw error
        }
    }
    func deletePackage(_ id: UUID) throws -> WorkspaceState {
        guard let package = state.packages.first(where: { $0.id == id }) else { return state }
        var next = state; next.packages.removeAll { $0.id == id }
        log("已移除 IPA", package.name, "trash", in: &next)
        let temp = try temporaryDirectory(); defer { try? fm.removeItem(at: temp) }
        var files = [paths.library.appendingPathComponent(package.fileName)]
        files.append(paths.exports.appendingPathComponent(package.id.uuidString))
        if let signed = package.signedFile, !(signed as NSString).pathComponents.starts(with: [package.id.uuidString]) {
            files.append(paths.exports.appendingPathComponent(signed))
        }
        if let icon = package.iconFile, !next.packages.contains(where: { $0.iconFile == icon }), !next.containerApps.contains(where: { $0.iconFile == icon }) {
            files.append(paths.icons.appendingPathComponent(icon))
        }
        var moved: [(URL, URL)] = []
        do {
            for source in files where fm.fileExists(atPath: source.path) {
                let backup = temp.appendingPathComponent(UUID().uuidString)
                try fm.moveItem(at: source, to: backup); moved.append((source, backup))
            }
            return try commit(next)
        } catch { for (source, backup) in moved { try? fm.moveItem(at: backup, to: source) }; throw error }
    }
    func deleteContainerApp(_ id: UUID) throws -> WorkspaceState {
        guard let app = state.containerApps.first(where: { $0.id == id }) else { return state }
        var next = state; next.containerApps.removeAll { $0.id == id }
        let temp = try temporaryDirectory(); defer { try? fm.removeItem(at: temp) }
        var moved: [(URL, URL)] = []
        do {
            for source in [paths.applications.appendingPathComponent(app.folder)] + app.containers.map({ paths.data.appendingPathComponent($0.folderName) }) {
                let backup = temp.appendingPathComponent(UUID().uuidString)
                if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: backup); moved.append((source, backup)) }
            }
            log("已移除容器应用", app.name, "trash", in: &next)
            return try commit(next)
        } catch { for (source, backup) in moved { try? fm.moveItem(at: backup, to: source) }; throw error }
    }
    func selectIdentity(_ id: UUID) throws -> WorkspaceState {
        guard state.identities.contains(where: { $0.id == id }) else { throw WorkspaceFailure("找不到证书。") }
        var next = state; next.activeIdentityID = id; return try commit(next)
    }
    func selectHostIdentity(_ id: UUID?) throws -> WorkspaceState {
        guard id == nil || state.identities.contains(where: { $0.id == id }) else { throw WorkspaceFailure("找不到宿主证书。") }
        var next = state; next.hostIdentityID = id; return try commit(next)
    }
    func deleteIdentity(_ id: UUID) throws -> WorkspaceState {
        var next = state; next.identities.removeAll { $0.id == id }
        if next.activeIdentityID == id { next.activeIdentityID = next.identities.first?.id }
        // 删除的是容器证书时回到「跟随当前签名证书」，避免容器启动引用已不存在的证书。
        if next.hostIdentityID == id { next.hostIdentityID = nil }
        let password = try SecureStore.password(id: id)
        let temp = try temporaryDirectory(); defer { try? fm.removeItem(at: temp) }
        let source = paths.credentials.appendingPathComponent(id.uuidString), backup = temp.appendingPathComponent("identity")
        try fm.moveItem(at: source, to: backup)
        do {
            try SecureStore.delete(id: id)
            return try commit(next)
        } catch {
            try? SecureStore.save(password: password, id: id)
            try? fm.moveItem(at: backup, to: source)
            throw error
        }
    }
    func certificatePermissions(_ id: UUID) throws -> [CertificatePermission] {
        guard state.identities.contains(where: { $0.id == id }) else { throw WorkspaceFailure("找不到证书。") }
        let profile = paths.credentials.appendingPathComponent(id.uuidString).appendingPathComponent("profile.mobileprovision")
        return try CertificatePermission.parse(profile: Data(contentsOf: profile))
    }
    func diagnose() throws {
        let (identity, p12, password, profile) = try credentials(forHost: true)
        try Self.requireHostTeam(identity)
        do { try RTNative.testJITLess(p12, password: password, profile: profile) }
        catch { JITLessCheckRecord.forget(); throw error }
        JITLessCheckRecord.remember(identity)
    }
    /// iOS 只允许进程加载同一开发者团队签名的代码。证书团队与 Retools 自身团队不一致时，
    /// 系统会以 “different Team IDs” 拒绝 dlopen；提前给出可操作的提示，而不是原始加载错误。
    static func requireHostTeam(_ identity: SigningIdentity) throws {
        guard let host = RTNative.hostTeamIdentifier(), !host.isEmpty, host != identity.teamID else { return }
        throw WorkspaceFailure("容器证书「\(identity.name)」属于团队 \(identity.teamID)，而当前 Retools 由团队 \(host) 签名。iOS 只允许加载同一团队签名的代码，请在「容器运行设置」中选择团队 \(host) 的证书。")
    }
    /// iOS 26 起，LiveContainer 在 JIT 下不再绕过 dyld 的库校验（见 dyld_bypass_validation.m），
    /// 未签名的客体主程序会以 “missing code signature” 加载失败。因此 JIT 模式同样需要先用容器证书签名。
    static var jitRequiresSignedGuest: Bool {
        if #available(iOS 19.0, *) { return true }
        return false
    }
    func prepareLaunch(_ appID: UUID, mode: ContainerExecutionMode = .jitless) throws -> WorkspaceState {
        guard let index = state.containerApps.firstIndex(where: { $0.id == appID }) else { throw WorkspaceFailure("找不到容器应用。") }
        let app = state.containerApps[index], path = paths.applications.appendingPathComponent(app.folder)
        let entries = try PluginService.configuration(app.pluginInjections, legacy: app.pluginIDs ?? [], plugins: state.plugins)
        let plugins = try PluginService.selected(PluginService.recordIDs(entries), from: state.plugins)
        let materialized = try PluginService.materialize(plugins, in: path, namespace: app.id, paths: paths)
        try writeContainerMetadata(app, at: path)
        if mode == .jit, !Self.jitRequiresSignedGuest {
            var next = state; next.containerApps[index].lastLaunched = Date()
            log("使用 JIT 启动容器", next.containerApps[index].name, "bolt.fill", in: &next)
            return try commit(next)
        }
        let (identity, p12, password, profile): (SigningIdentity, String, String, String)
        do { (identity, p12, password, profile) = try credentials(forHost: true) }
        catch let error where mode == .jit { throw WorkspaceFailure("iOS 26 起，JIT 模式也需要先用容器证书签名应用才能加载。\(error.localizedDescription)") }
        try Self.requireHostTeam(identity)
        // Loading the signed probe verifies the actual host certificate and device trust.
        // 同一证书已检测通过时跳过：下面对客体主程序的 isSignatureTrusted 校验同样由系统实际判定。
        if !JITLessCheckRecord.isValid(for: identity) {
            do { try RTNative.testJITLess(p12, password: password, profile: profile) }
            catch { JITLessCheckRecord.forget(); throw error }
            JITLessCheckRecord.remember(identity)
        }
        let metadata = try ArchiveService.metadata(at: path)
        let binaryPath = path.appendingPathComponent(metadata["CFBundleExecutable"] as! String).path
        if materialized.changed || app.signedFingerprint != identity.fingerprint || !RTNative.isSignatureTrusted(binaryPath) {
            let enumerator = fm.enumerator(at: path, includingPropertiesForKeys: [.isRegularFileKey])
            var files: [String] = []
            while let file = enumerator?.nextObject() as? URL {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files.append(file.path) }
            }
            try RTNative.signBinaries(files, p12: p12, password: password, profile: profile, identifier: Bundle.main.bundleIdentifier ?? "com.reukix.retools")
        }
        guard RTNative.isSignatureTrusted(binaryPath) else { JITLessCheckRecord.forget(); throw WorkspaceFailure("系统未信任容器签名，请使用与 Retools 相同的签名证书。") }
        var next = state; next.containerApps[index].signedFingerprint = identity.fingerprint; next.containerApps[index].lastLaunched = Date()
        if mode == .jit { log("使用 JIT 启动容器", "\(app.name) · 已用容器证书签名", "bolt.fill", in: &next) }
        else { log("启动容器应用", "\(app.name) · \(app.selectedContainer?.name ?? "默认空间")", "play.fill", in: &next) }
        return try commit(next)
    }
    func storageUsage() -> Int64 {
        var size: Int64 = 0
        for root in [paths.library, paths.exports, paths.applications, paths.data] {
            let items = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
            while let file = items?.nextObject() as? URL {
                if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true { size += Int64(values.fileSize ?? 0) }
            }
        }
        return size
    }
    func prepareHostForRenewal(materials: [String: AppleAccountService.Credentials], renewalReceipt: String? = nil, requiresAppGroup: Bool = false) throws -> URL {
        let temp = try temporaryDirectory()
        do {
            var requiredGroup: String?
            if requiresAppGroup {
                guard let bundleID = Bundle.main.bundleIdentifier, let main = materials[bundleID] else { throw WorkspaceFailure("缺少 Retools 的签名配置。") }
                let profile = try ProfileRefresh.parse(main.profile)
                guard let team = profile.entitlements["com.apple.developer.team-identifier"] as? String else { throw WorkspaceFailure("描述文件缺少签名团队。") }
                try HostAppGroup.validateProfile(main.profile, bundleID: bundleID, teamID: team, requireAppGroup: true)
                requiredGroup = HostAppGroup.identifier(teamID: team)
            }
            let app = temp.appendingPathComponent("Retools.app")
            try fm.copyItem(at: Bundle.main.bundleURL, to: app)
            if let renewalReceipt {
                var info = try ArchiveService.metadata(at: app)
                info["RetoolsRenewalReceipt"] = renewalReceipt
                try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: app.appendingPathComponent("Info.plist"), options: .atomic)
            }
            var files: [String: [String: String]] = [:]
            for (bundleID, material) in materials {
                _ = try validatedIdentity(p12Data: material.p12, profileData: material.profile, password: material.password)
                let folder = temp.appendingPathComponent(UUID().uuidString)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let p12 = folder.appendingPathComponent("account.p12"), profile = folder.appendingPathComponent("account.mobileprovision")
                try material.p12.write(to: p12, options: .completeFileProtectionUntilFirstUserAuthentication)
                try material.profile.write(to: profile, options: .completeFileProtectionUntilFirstUserAuthentication)
                files[bundleID] = ["p12": p12.path, "password": material.password, "profile": profile.path]
            }
            try RTNative.signHostApp(app.path, credentials: files)
            if let requiredGroup, HostAppGroup.signedIdentifier(in: app) != requiredGroup {
                throw WorkspaceFailure("签名输出未保留所需 App Group，未生成安装包。")
            }
            for folder in try fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil) where folder.lastPathComponent != app.lastPathComponent { try fm.removeItem(at: folder) }
            guard fm.fileExists(atPath: app.appendingPathComponent("Info.plist").path) else { throw WorkspaceFailure("开发签名后的宿主文件不完整。") }
            return app
        } catch { try? fm.removeItem(at: temp); throw error }
    }
}

/// 原生签名回调可能在签名线程上触发，计数需要加锁。
/// 免 JIT 检测通过的记录。系统是否接受某张证书签名的代码，只取决于这张证书、它的描述文件
/// 和 Retools 自身的签名；三者都没变时结果不会变，无需每次打开或运行都重新签名、加载测试库。
/// 任一项变化、证书过期，或运行时被系统拒绝，记录即失效，下次运行前重新检测。
enum JITLessCheckRecord {
    static let defaultsKey = "RetoolsJITLessCheck"
    static func key(for identity: SigningIdentity, hostTeam: String? = RTNative.hostTeamIdentifier(),
                    hostCertificate: String? = ProfileRefresh.runningCertificateFingerprint) -> String {
        [identity.id.uuidString, identity.fingerprint, identity.profileScopeFingerprint ?? "",
         String(Int(identity.expiresAt.timeIntervalSince1970)), String(Int(identity.certificateExpiresAt.timeIntervalSince1970)),
         hostTeam ?? "", hostCertificate ?? ""].joined(separator: "|")
    }
    static func isValid(for identity: SigningIdentity, defaults: UserDefaults = .standard) -> Bool {
        !identity.isExpired && defaults.string(forKey: defaultsKey) == key(for: identity)
    }
    static func remember(_ identity: SigningIdentity, defaults: UserDefaults = .standard) { defaults.set(key(for: identity), forKey: defaultsKey) }
    static func forget(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: defaultsKey) }
}

final class SigningFileCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
