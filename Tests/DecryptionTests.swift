import XCTest
import RetoolsNative
@testable import LiveContainerSwiftUI

final class DecryptionTests: XCTestCase {
    func testBinaryInventoryDoesNotOpenProtectedStoreMetadata() throws {
        let app = try source(), job = try manifest(app)
        let license = app.appendingPathComponent("SC_Info/Target.sinf")
        try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath: license.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath: license.path) }
        try FairPlayFiles.verifyOriginals(job,in: app)
        let copy = root.appendingPathComponent("Copy.app")
        try FairPlayRunner.copyWorkingTree(source: app,to: copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.appendingPathComponent("SC_Info").path))
        try binary().write(to: app.appendingPathComponent("Unexpected.dylib"))
        XCTAssertThrowsError(try FairPlayFiles.verifyOriginals(job,in: app),"Additional executable code must still fail verification")
    }
    func testWorkingCopyIsWritableAndOmitsInstalledStoreMetadata() throws {
        let app = try source(), signature = app.appendingPathComponent("_CodeSignature")
        try FileManager.default.createDirectory(at: signature,withIntermediateDirectories: true)
        try Data("seal".utf8).write(to: signature.appendingPathComponent("CodeResources"))
        let before = try FairPlayFiles.hash(app.appendingPathComponent("Target"))
        let locked = [app,app.appendingPathComponent("SC_Info"),signature]
        for directory in locked { try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath: directory.path) }
        try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath: app.appendingPathComponent("Target").path)
        defer { for directory in locked { try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath: directory.path) } }
        let copy = root.appendingPathComponent("Writable.app")
        try FairPlayRunner.copyWorkingTree(source: app,to: copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.appendingPathComponent("SC_Info").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.appendingPathComponent("_CodeSignature").path))
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: copy.appendingPathComponent("Target").path))
        XCTAssertEqual(try FairPlayFiles.hash(copy.appendingPathComponent("Target")),before)
        XCTAssertEqual(try FairPlayFiles.hash(app.appendingPathComponent("Target")),before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("SC_Info/Target.sinf").path))
    }
    func testRefreshingHelperRuntimePreservesPreparedPayloadAndAuthorization() throws {
        let jobs = root.appendingPathComponent("Jobs")
        let job = try DecryptionPreparation.prepare(source: ipa(source()),template: DecryptionPreparation.templateURL(),root: jobs)
        let folder = jobs.appendingPathComponent(job.manifest.id.uuidString)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("HelperTemplate.sha256"))
        try DecryptionPreparation.refreshTemplate(job,template: DecryptionPreparation.templateURL(),root: jobs)
        let helper = folder.appendingPathComponent("Helper/Payload/RetoolsDecryptHelper.app")
        try FairPlayFiles.verifyOriginals(job.manifest,in: helper.appendingPathComponent("RetoolsPayload/Target"))
        let refreshed = try JSONDecoder().decode(FairPlayManifest.self,from: Data(contentsOf: helper.appendingPathComponent(FairPlayManifest.fileName)))
        XCTAssertEqual(refreshed,job.manifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("HelperTemplate.sha256").path))
    }
    func testHelperArchiveStoresEncryptedBinariesWithoutRecompression() throws {
        let jobs = root.appendingPathComponent("Jobs")
        let job = try DecryptionPreparation.prepare(source: ipa(source()),template: DecryptionPreparation.templateURL(),root: jobs)
        let archive = try Archive(url: jobs.appendingPathComponent(job.manifest.id.uuidString+"/DecryptHelper.ipa"),accessMode: .read)
        let entry = try XCTUnwrap(archive["Payload/RetoolsDecryptHelper.app/RetoolsPayload/Target/Target"])
        XCTAssertFalse(entry.isCompressed)
    }
    func testSigningServiceWithRealPreparedHelper() async throws {
        guard let path = ProcessInfo.processInfo.environment["RETOOLS_REAL_HELPER_IPA"] else { throw XCTSkip("Requires an explicitly supplied local prepared helper") }
        let paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"),support: root.appendingPathComponent("Support"))
        try paths.createDirectories()
        let archive = try Archive(url: URL(fileURLWithPath: path),accessMode: .read)
        let manifestPath = "Payload/RetoolsDecryptHelper.app/"+FairPlayManifest.fileName
        let entry = try XCTUnwrap(archive[manifestPath]); var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let manifest = try JSONDecoder().decode(FairPlayManifest.self,from: data)
        let folder = paths.support.appendingPathComponent("Decryption/"+manifest.id.uuidString)
        _ = try ArchiveService.unpack(URL(fileURLWithPath: path),to: folder.appendingPathComponent("Helper"))
        let service = WorkspaceService(paths: paths,state: WorkspaceState())
        let bundle = Bundle(for: Self.self)
        let p12 = try XCTUnwrap(bundle.url(forResource: "PluginIdentity",withExtension: "p12"))
        let profile = try XCTUnwrap(bundle.url(forResource: "PluginIdentity",withExtension: "mobileprovision"))
        let state = try await service.importIdentity(p12: p12,profile: profile,password: "test-only")
        let identity = try XCTUnwrap(state.identities.first)
        let output = try await service.signDecryptionHelper(PreparedDecryption(manifest: manifest),identityID: identity.id,bundleID: "dev.retools.decrypt.test",fresh: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("IntegrityCheck.json"))) as? [String: Any])
        XCTAssertEqual(report["passed"] as? Bool,true)
        XCTAssertEqual(report["stage"] as? String,"签名后")
    }
    func testSigningRealPreparedHelperPreservesAllBinaries() throws {
        guard let path = ProcessInfo.processInfo.environment["RETOOLS_REAL_HELPER_IPA"] else { throw XCTSkip("Requires an explicitly supplied local prepared helper") }
        let helper = try ArchiveService.unpack(URL(fileURLWithPath: path), to: root.appendingPathComponent("RealHelper"))
        let manifest = try JSONDecoder().decode(FairPlayManifest.self, from: Data(contentsOf: helper.appendingPathComponent(FairPlayManifest.fileName)))
        let payload = helper.appendingPathComponent("RetoolsPayload/Target")
        let before = try FairPlayFiles.binaryRecords(in: payload)
        XCTAssertEqual(before,manifest.binaries,"Prepared source must match before signing")
        let bundle = Bundle(for: Self.self)
        let p12 = try XCTUnwrap(bundle.url(forResource: "PluginIdentity", withExtension: "p12"))
        let profile = try XCTUnwrap(bundle.url(forResource: "PluginIdentity", withExtension: "mobileprovision"))
        try RTNative.signApp(helper.path, p12: p12.path, password: "test-only", profile: profile.path,
            bundleID: "dev.retools.decrypt.test", removeExtensions: false, hostBundle: false,
            options: ["preserveDecryptionPayload":true,"removeWatch":false])
        let after = try FairPlayFiles.binaryRecords(in: payload)
        for record in before {
            XCTAssertEqual(after.first(where: { $0.path == record.path }),record,"Changed payload binary: \(record.path)")
        }
        XCTAssertEqual(after.count,before.count)
        XCTAssertEqual(after,manifest.binaries)
    }
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func testBinaryRecordsAreStableAcrossDirectoryURLForms() throws {
        let app = try source(framework: true)
        let expected = try FairPlayFiles.binaryRecords(in: app)
        let directory = URL(fileURLWithPath: app.path+"/",isDirectory: true)
        XCTAssertEqual(try FairPlayFiles.binaryRecords(in: directory),expected)
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias,withDestinationURL: app.deletingLastPathComponent())
        XCTAssertEqual(try FairPlayFiles.binaryRecords(in: alias.appendingPathComponent(app.lastPathComponent)),expected)
    }
    private func word(_ value: UInt64, in data: inout Data, at: Int, width: Int = 4, big: Bool = false) {
        for index in 0..<width { data[at+index] = UInt8(truncatingIfNeeded: value >> ((big ? width-1-index : index)*8)) }
    }
    private func binary(cpu: UInt64 = 0x0100000c) -> Data {
        var data = Data(repeating: 0x7b, count: 32768)
        word(0xfeedfacf, in: &data, at: 0); word(cpu, in: &data, at: 4)
        word(0, in: &data, at: 8); word(2, in: &data, at: 12)
        word(1, in: &data, at: 16); word(24, in: &data, at: 20)
        word(0x2c, in: &data, at: 32); word(24, in: &data, at: 36)
        word(16384, in: &data, at: 40); word(16384, in: &data, at: 44); word(1, in: &data, at: 48)
        return data
    }
    private func source(license: Bool = true, framework: Bool = false) throws -> URL {
        let app = root.appendingPathComponent(UUID().uuidString+"/Target.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("SC_Info"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleExecutable":"Target", "CFBundleIdentifier":"com.example.target", "CFBundleDisplayName":"测试目标", "CFBundleVersion":"1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try binary().write(to: app.appendingPathComponent("Target"))
        if license { try Data("test-license-only".utf8).write(to: app.appendingPathComponent("SC_Info/Target.sinf")) }
        if framework {
            let nested = app.appendingPathComponent("Frameworks/Kit.framework")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try binary().write(to: nested.appendingPathComponent("Kit"))
            let manifest: [String: Any] = ["SinfPaths":["SC_Info/Target.sinf"], "SinfReplicationPaths":["Frameworks/Kit.framework/SC_Info/Kit.sinf"]]
            try PropertyListSerialization.data(fromPropertyList: manifest, format: .binary, options: 0).write(to: app.appendingPathComponent("SC_Info/Manifest.plist"))
        }
        return app
    }
    private func manifest(_ app: URL) throws -> FairPlayManifest {
        FairPlayManifest(schemaVersion: 1, id: UUID(), name: "测试目标", bundleID: "com.example.target", appFileName: "Target.app", binaries: try FairPlayFiles.binaryRecords(in: app))
    }
    private func ipa(_ app: URL) throws -> URL {
        let file = root.appendingPathComponent(UUID().uuidString+".ipa")
        try ArchiveService.pack(app: app, to: file); return file
    }
    func testParsesEncryptedRegionAndAbsoluteCryptIDPosition() throws {
        let slice = try XCTUnwrap(FairPlayMachO.inspect(binary()).first)
        XCTAssertEqual(slice.encryptedOffset,16384); XCTAssertEqual(slice.encryptedSize,16384)
        XCTAssertEqual(slice.cryptIDOffset,48); XCTAssertEqual(slice.cryptID,1)
    }
    func testRejectsEncryptionOutsideSliceAndInsideHeader() {
        var data = binary(); word(UInt64.max >> 32, in: &data, at: 44)
        XCTAssertThrowsError(try FairPlayMachO.inspect(data))
        data = binary(); word(32, in: &data, at: 40)
        XCTAssertThrowsError(try FairPlayMachO.inspect(data))
    }
    func testRejectsNonARM64EncryptionAndTruncatedCommands() {
        XCTAssertThrowsError(try FairPlayMachO.inspect(binary(cpu: 0x01000007)))
        var data = binary(); word(32768, in: &data, at: 36)
        XCTAssertThrowsError(try FairPlayMachO.inspect(data))
    }
    func testParsesFat64AndRejectsOverlappingSlices() throws {
        var data = Data(repeating: 0, count: 16384)
        word(0xcafebabf, in: &data, at: 0, big: true); word(1, in: &data, at: 4, big: true)
        word(0x0100000c, in: &data, at: 8, big: true)
        word(16384, in: &data, at: 16, width: 8, big: true); word(32768, in: &data, at: 24, width: 8, big: true)
        data.append(binary())
        let slices = try FairPlayMachO.inspect(data)
        XCTAssertEqual(slices.first?.cryptIDOffset,16432)
        word(2, in: &data, at: 4, big: true)
        data.replaceSubrange(40..<72, with: data[8..<40])
        XCTAssertThrowsError(try FairPlayMachO.inspect(data))
    }
    func testLicenseReplicationAndTraversalRejection() throws {
        let app = try source(framework: true)
        try DecryptionPreparation.replicateLicenses(in: app)
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("SC_Info/Target.sinf")), try Data(contentsOf: app.appendingPathComponent("Frameworks/Kit.framework/SC_Info/Kit.sinf")))
        let bad: [String: Any] = ["SinfPaths":["SC_Info/Target.sinf"],"SinfReplicationPaths":["../../outside.sinf"]]
        try PropertyListSerialization.data(fromPropertyList: bad, format: .binary, options: 0).write(to: app.appendingPathComponent("SC_Info/Manifest.plist"))
        XCTAssertThrowsError(try DecryptionPreparation.replicateLicenses(in: app))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.sinf").path))
    }
    func testPreparationEmbedsSourceAndReplicatesFrameworkLicense() throws {
        let app = try source(framework: true), before = try Data(contentsOf: app.appendingPathComponent("Target"))
        let input = try ipa(app), jobs = root.appendingPathComponent("Jobs")
        let job = try DecryptionPreparation.prepare(source: input, template: DecryptionPreparation.templateURL(), root: jobs)
        XCTAssertEqual(job.manifest.encryptedCount,2)
        let helper = try ArchiveService.unpack(jobs.appendingPathComponent(job.manifest.id.uuidString+"/DecryptHelper.ipa"), to: root.appendingPathComponent("ReadHelper"))
        let payload = helper.appendingPathComponent("RetoolsPayload/Target")
        try FairPlayFiles.verifyOriginals(job.manifest, in: payload)
        XCTAssertEqual(try Data(contentsOf: payload.appendingPathComponent("Target")), before)
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Target")), before)
    }
    func testInstalledSnapshotPreservesSourceAndPreparesLicensedHelper() throws {
        let installed = try source(framework: true)
        let original = try Data(contentsOf: installed.appendingPathComponent("Target"))
        let originalLicense = try Data(contentsOf: installed.appendingPathComponent("SC_Info/Target.sinf"))
        let snapshot = root.appendingPathComponent("Snapshot.app")
        try InstalledDecryptionSource.copyBundle(root: installed, bundleID: "com.example.target", to: snapshot)
        XCTAssertEqual(try Data(contentsOf: snapshot.appendingPathComponent("Target")), original)
        XCTAssertEqual(try Data(contentsOf: snapshot.appendingPathComponent("SC_Info/Target.sinf")), originalLicense)
        let job = try DecryptionPreparation.prepare(source: ipa(snapshot), template: DecryptionPreparation.templateURL(), root: root.appendingPathComponent("InstalledJobs"))
        XCTAssertEqual(job.manifest.encryptedCount, 2)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("Target")), original)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("SC_Info/Target.sinf")), originalLicense)
    }
    func testInstalledSnapshotRejectsWrongIdentityAndSymlinksWithoutLeavingPartialCopy() throws {
        let installed = try source(), snapshot = root.appendingPathComponent("Rejected.app")
        XCTAssertThrowsError(try InstalledDecryptionSource.copyBundle(root: installed, bundleID: "com.example.wrong", to: snapshot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        try FileManager.default.createSymbolicLink(atPath: installed.appendingPathComponent("Outside").path, withDestinationPath: root.path)
        XCTAssertThrowsError(try InstalledDecryptionSource.copyBundle(root: installed, bundleID: "com.example.target", to: snapshot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("Target").path))
    }
    func testInstalledBundleTargetRejectsParentsAndPathTraversal() throws {
        let base = "/var/containers/Bundle/Application/11111111-1111-4111-8111-111111111111"
        XCTAssertEqual(try InstalledDecryptionSource.bundleRoot(base + "/Target.app").path, "/private" + base + "/Target.app")
        for path in [base, base + "/Target.app/../Other.app", base + "/.app", base + "/Target.app/", base + "/Target.app/a", "/Applications/Target.app"] {
            XCTAssertThrowsError(try InstalledDecryptionSource.bundleRoot(path), path)
        }
    }
    func testPreparationMissingLicenseDoesNotReplacePreviousJob() throws {
        let jobs = root.appendingPathComponent("Jobs")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try "previous".write(to: jobs.appendingPathComponent("Current"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DecryptionPreparation.prepare(source: ipa(source(license: false)), template: DecryptionPreparation.templateURL(), root: jobs))
        XCTAssertEqual(try String(contentsOf: jobs.appendingPathComponent("Current")),"previous")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: jobs.path),["Current"])
    }
    func testNoopDecryptDoesNotClearCryptIDOrPublishIPA() throws {
        let app = try source(), job = try manifest(app), output = root.appendingPathComponent("Output")
        let original = try Data(contentsOf: app.appendingPathComponent("Target"))
        XCTAssertThrowsError(try FairPlayRunner.run(manifest: job, source: app, outputDirectory: output, decrypt: { _,_,_ in }))
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Target")), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path),[])
    }
    func testLaterBinaryFailureCannotPublishPartialIPA() throws {
        let app = try source(framework: true), job = try manifest(app), output = root.appendingPathComponent("Output")
        var attempts = 0
        XCTAssertThrowsError(try FairPlayRunner.run(manifest: job, source: app, outputDirectory: output, decrypt: { _,copy,slice in
            attempts += 1
            if attempts == 2 { throw FairPlayFailure("simulated system failure") }
            let handle = try FileHandle(forWritingTo: copy); defer { try? handle.close() }
            try handle.seek(toOffset: slice.offset+slice.encryptedOffset); try handle.write(contentsOf: Data([1,2,3,4]))
        }))
        XCTAssertEqual(attempts,2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path),[])
        try FairPlayFiles.verifyOriginals(job, in: app)
    }
    func testOutputRoundTripUsesCopiesAndClearsOnlyVerifiedEncryption() throws {
        // An injected test writer checks the pipeline; this does not claim actual FairPlay decryption.
        let app = try source(), job = try manifest(app), output = root.appendingPathComponent("Output")
        let file = try FairPlayRunner.run(manifest: job, source: app, outputDirectory: output, decrypt: { _,copy,slice in
            let handle = try FileHandle(forWritingTo: copy); defer { try? handle.close() }
            try handle.seek(toOffset: slice.offset+slice.encryptedOffset); try handle.write(contentsOf: Data([0xc0,3,0x5f,0xd6]))
        })
        let unpacked = try ArchiveService.unpack(file, to: root.appendingPathComponent("OutputCheck"))
        XCTAssertTrue(try FairPlayMachO.inspect(unpacked.appendingPathComponent("Target")).allSatisfy { $0.cryptID == 0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("SC_Info").path))
        try FairPlayFiles.verifyOriginals(job, in: app)
    }
    func testTamperedSourceAndUnsafeManifestAreRejected() throws {
        let app = try source(), job = try manifest(app)
        try Data("tampered".utf8).write(to: app.appendingPathComponent("Target"))
        XCTAssertThrowsError(try FairPlayFiles.verifyOriginals(job, in: app))
        let bad = FairPlayManifest(schemaVersion: 1, id: UUID(), name: "bad", bundleID: "bad", appFileName: "../Bad.app", binaries: job.binaries)
        XCTAssertThrowsError(try bad.validate())
    }
    func testSigningPreservesNestedEncryptedPayloadAndSealsItAsResources() throws {
        let app = try source(framework: true), input = try ipa(app), jobs = root.appendingPathComponent("Jobs")
        let job = try DecryptionPreparation.prepare(source: input, template: DecryptionPreparation.templateURL(), root: jobs)
        let helper = jobs.appendingPathComponent(job.manifest.id.uuidString+"/Helper/Payload/RetoolsDecryptHelper.app")
        let payload = helper.appendingPathComponent("RetoolsPayload/Target")
        let extensionFolder = payload.appendingPathComponent("PlugIns/Preserved.appex")
        try FileManager.default.createDirectory(at: extensionFolder,withIntermediateDirectories: true)
        let extensionInfo: [String: Any] = ["CFBundleIdentifier":"dev.retools.decrypt.preserved", "CFBundleExecutable":"Preserved"]
        try PropertyListSerialization.data(fromPropertyList: extensionInfo,format: .binary,options: 0).write(to: extensionFolder.appendingPathComponent("Info.plist"))
        let before = try Dictionary(uniqueKeysWithValues: FairPlayFiles.regularFiles(in: payload).map { file in
            (String(file.path.dropFirst(payload.path.count+1)),try FairPlayFiles.hash(file))
        })
        let bundle = Bundle(for: Self.self)
        let p12 = try XCTUnwrap(bundle.url(forResource: "PluginIdentity", withExtension: "p12"))
        let profile = try XCTUnwrap(bundle.url(forResource: "PluginIdentity", withExtension: "mobileprovision"))
        try RTNative.signApp(helper.path, p12: p12.path, password: "test-only", profile: profile.path,
            bundleID: "dev.retools.decrypt.test", removeExtensions: false, hostBundle: false,
            options: ["preserveDecryptionPayload":true,"removeWatch":false])
        try FairPlayFiles.verifyOriginals(job.manifest, in: helper.appendingPathComponent("RetoolsPayload/Target"))
        let after = try Dictionary(uniqueKeysWithValues: FairPlayFiles.regularFiles(in: payload).map { file in
            (String(file.path.dropFirst(payload.path.count+1)),try FairPlayFiles.hash(file))
        })
        XCTAssertEqual(before,after,"Encrypted payload resources, extension metadata and SINF must all stay byte-for-byte intact")
        let resources = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: helper.appendingPathComponent("_CodeSignature/CodeResources")), format: nil) as? [String: Any])
        let files = try XCTUnwrap(resources["files2"] as? [String: Any])
        XCTAssertNotNil(files["RetoolsPayload/Target/Target"])
        XCTAssertNotNil(files["RetoolsPayload/Target/Frameworks/Kit.framework/Kit"])
        let attachment = XCTAttachment(data: try Data(contentsOf: ipa(helper)), uniformTypeIdentifier: "public.zip-archive")
        attachment.name = "DecryptionHelper-Synthetic-Signed"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
