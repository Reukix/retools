import XCTest
import Foundation
import ImageIO
import CoreGraphics
import Darwin
import MachO
import RetoolsNative
@testable import LiveContainerSwiftUI

final class SigningProjectTests: XCTestCase {
    private var root: URL!
    private var paths: WorkspacePaths!
    private var passwords = Set<UUID>()
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        try paths.createDirectories()
    }
    override func tearDownWithError() throws {
        for id in passwords { try? SecureStore.delete(id: id) }
        try? FileManager.default.removeItem(at: root)
    }
    private func fixture(_ name: String, _ ext: String) throws -> URL { try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)) }
    private func makeService() async throws -> (WorkspaceService, AppPackage) {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        let state = try await service.importIPA(fixture("Fixture", "ipa"))
        return (service, try XCTUnwrap(state.packages.first))
    }
    @discardableResult private func identity(_ name: String, service: WorkspaceService) async throws -> SigningIdentity {
        let state = try await service.importIdentity(p12: fixture(name, "p12"), profile: fixture(name, "mobileprovision"), password: "test-only")
        passwords.formUnion(state.identities.map(\.id))
        return try XCTUnwrap(state.identities.first { $0.id == state.activeIdentityID })
    }
    private func outputApp(_ state: WorkspaceState, folder: String) throws -> URL {
        let file = try XCTUnwrap(state.packages.first?.signedFile)
        return try ArchiveService.unpack(paths.exports.appendingPathComponent(file), to: root.appendingPathComponent(folder))
    }
    private func attachOutput(_ state: WorkspaceState, name: String) throws {
        let file = try XCTUnwrap(state.packages.first?.signedFile)
        let attachment = XCTAttachment(data: try Data(contentsOf: paths.exports.appendingPathComponent(file)), uniformTypeIdentifier: "public.zip-archive")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func signatureEntitlements(_ executable: URL) throws -> [String: Any] {
        let bytes = try Data(contentsOf: executable)
        let start = try XCTUnwrap(bytes.range(of: Data("<?xml".utf8)))
        let end = try XCTUnwrap(bytes.range(of: Data("</plist>".utf8), in: start.lowerBound..<bytes.endIndex))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes[start.lowerBound..<end.upperBound], format: nil) as? [String: Any])
    }
    func testSigningReportsEveryStageInOrderWithPerFileProgress() async throws {
        let (service, package) = try await makeService()
        _ = try await identity("PluginIdentity", service: service)
        final class Recorder: @unchecked Sendable {
            let lock = NSLock(); var events: [SigningEvent] = []
            func add(_ event: SigningEvent) { lock.lock(); events.append(event); lock.unlock() }
        }
        let recorder = Recorder()
        var options = PackageSigningOptions(); options.bundleID = "com.retools.progress"
        let state = try await service.signProject(package.id, options: options, report: SigningReporter { recorder.add($0) })
        XCTAssertNotNil(state.packages.first?.signedFile)
        let events = recorder.events
        // 阶段只前进不后退，且覆盖签名的全部本地阶段（未选插件时注入阶段标记为跳过）。
        let stages = events.map(\.stage)
        XCTAssertEqual(stages, stages.sorted())
        XCTAssertEqual(Set(stages), [.credentials, .unpack, .configure, .inject, .sign, .pack, .save])
        XCTAssertTrue(events.contains { $0.stage == .inject && $0.skipped })
        let signing = events.filter { $0.stage == .sign }
        XCTAssertTrue(signing.contains { ($0.detail ?? "").contains("/") }, "逐文件签名进度未送达：\(signing.map { $0.detail ?? "" })")
        XCTAssertEqual(events.last(where: { $0.stage == .pack })?.fraction, 1)
        XCTAssertEqual(events.last(where: { $0.stage == .unpack })?.fraction, 1)
    }
    func testSigningCertificateIsReadBackAndDecidesProfileOnlyRefresh() async throws {
        let (service, package) = try await makeService()
        _ = try await identity("PluginIdentity", service: service)
        var options = PackageSigningOptions(); options.bundleID = "com.retools.refresh"
        let state = try await service.signProject(package.id, options: options)
        let app = try outputApp(state, folder: "Refresh")
        let executable = app.appendingPathComponent(try XCTUnwrap(ArchiveService.metadata(at: app)["CFBundleExecutable"] as? String))
        let certificate = try RTNative.signingCertificate(ofExecutable: executable.path)
        let entitlements = try XCTUnwrap(try RTNative.entitlements(ofExecutable: executable.path) as? [String: Any])
        let profile = try ProfileRefresh.parse(Data(contentsOf: fixture("PluginIdentity", "mobileprovision")))
        XCTAssertTrue(profile.certificates.contains(certificate), "签名证书应来自所用描述文件")
        let signedAppID = try XCTUnwrap(entitlements["application-identifier"] as? String)
        XCTAssertTrue(signedAppID.hasSuffix(".com.retools.refresh"))
        // 同一张证书、同一应用标识的新描述文件：可以只更新描述文件。
        let same = ProfileRefresh.Profile(uuid: "NEW", expiry: Date().addingTimeInterval(7 * 86400), applicationIdentifier: signedAppID,
                                          entitlements: entitlements, certificates: profile.certificates)
        XCTAssertNil(ProfileRefresh.blocker(profile: same, executable: executable, currentExpiry: Date()))
        // 证书换了、标识不同、缺授权、已过期：都必须退回整包重装。
        let other = try ProfileRefresh.parse(Data(contentsOf: fixture("OtherIdentity", "mobileprovision")))
        let otherCert = ProfileRefresh.Profile(uuid: "B", expiry: same.expiry, applicationIdentifier: signedAppID, entitlements: entitlements, certificates: other.certificates)
        XCTAssertEqual(ProfileRefresh.blocker(profile: otherCert, executable: executable, currentExpiry: nil), "签名证书已更换")
        let otherID = ProfileRefresh.Profile(uuid: "C", expiry: same.expiry, applicationIdentifier: "TEAM.other.app", entitlements: entitlements, certificates: profile.certificates)
        XCTAssertNotNil(ProfileRefresh.blocker(profile: otherID, executable: executable, currentExpiry: nil))
        var fewer = entitlements; fewer.removeValue(forKey: "get-task-allow"); fewer.removeValue(forKey: "keychain-access-groups")
        if fewer.count < entitlements.count {
            let missing = ProfileRefresh.Profile(uuid: "D", expiry: same.expiry, applicationIdentifier: signedAppID, entitlements: fewer, certificates: profile.certificates)
            XCTAssertTrue(ProfileRefresh.blocker(profile: missing, executable: executable, currentExpiry: nil)?.contains("缺少授权") == true)
        }
        let expired = ProfileRefresh.Profile(uuid: "E", expiry: Date().addingTimeInterval(-60), applicationIdentifier: signedAppID, entitlements: entitlements, certificates: profile.certificates)
        XCTAssertEqual(ProfileRefresh.blocker(profile: expired, executable: executable, currentExpiry: nil), "新描述文件已过期")
    }
    func testInstalledSignatureDecidesProfileOnlyRenewalForOtherApps() async throws {
        let (service, package) = try await makeService()
        _ = try await identity("PluginIdentity", service: service)
        var options = PackageSigningOptions(); options.bundleID = "com.retools.installed"
        let state = try await service.signProject(package.id, options: options)
        let app = try outputApp(state, folder: "Installed")
        let signature = try XCTUnwrap(InstalledSignature.read(app: app), "已签名应用应能读出签名")
        XCTAssertTrue(signature.applicationIdentifier.hasSuffix(".com.retools.installed"))
        XCTAssertTrue(signature.entitlementKeys.contains("application-identifier"))
        // 记录可以存进续签设置再读出（JSON 往返）。
        var settings = RenewalSettings(); settings.installedSignatures[package.id.uuidString] = signature
        let decoded = try JSONDecoder().decode(RenewalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.installedSignatures[package.id.uuidString], signature)
        // 同一证书、同一标识、授权齐全的新描述文件：只更新描述文件。
        let embedded = try ProfileRefresh.parse(Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision")))
        let renewed = ProfileRefresh.Profile(uuid: "RENEWED", expiry: Date().addingTimeInterval(7 * 86400), applicationIdentifier: signature.applicationIdentifier,
                                             entitlements: Dictionary(uniqueKeysWithValues: signature.entitlementKeys.map { ($0, true as Any) }), certificates: embedded.certificates)
        XCTAssertNil(signature.blocker(for: renewed))
        // 另一张证书签发的描述文件：必须整包重装。
        let other = try ProfileRefresh.parse(Data(contentsOf: fixture("OtherIdentity", "mobileprovision")))
        let switched = ProfileRefresh.Profile(uuid: "OTHER", expiry: renewed.expiry, applicationIdentifier: signature.applicationIdentifier,
                                              entitlements: renewed.entitlements, certificates: other.certificates)
        XCTAssertEqual(signature.blocker(for: switched), "签名证书已更换")
    }
    func testUnsignedExecutableHasNoSigningCertificate() throws {
        // 模拟器测试包是临时签名，没有证书：必须判定为「无法读取」，从而退回整包重装。
        let executable = try XCTUnwrap(Bundle(for: Self.self).executableURL)
        XCTAssertThrowsError(try RTNative.signingCertificate(ofExecutable: executable.path))
        let profile = ProfileRefresh.Profile(uuid: "A", expiry: Date().addingTimeInterval(86400), applicationIdentifier: "T.a", entitlements: [:], certificates: [])
        XCTAssertEqual(ProfileRefresh.blocker(profile: profile, executable: executable, currentExpiry: nil), "无法读取当前签名证书")
    }
    @MainActor func testProgressModelIgnoresLateEventsAndMarksFailure() {
        let model = SigningProgressModel(appName: "Fixture", install: true)
        model.apply(SigningEvent(stage: .unpack, fraction: 0.5))
        model.apply(SigningEvent(stage: .sign, fraction: 0.2, detail: "Fixture（1/3）"))
        model.apply(SigningEvent(stage: .unpack, fraction: 0.9))
        XCTAssertEqual(model.current, .sign)
        XCTAssertEqual(model.states[.unpack], .done)
        model.fail("签名引擎未能完成签名")
        XCTAssertEqual(model.states[.sign], .failed)
        XCTAssertEqual(model.states[.install], .pending)
        XCTAssertEqual(model.outcome, .failed("签名引擎未能完成签名"))
        model.apply(SigningEvent(stage: .pack, fraction: 1))
        XCTAssertEqual(model.states[.pack], .pending)
    }
    func testProjectMetadataCustomOutputAndMinimumVersionAffectOnlySignedCopy() async throws {
        let (service, package) = try await makeService()
        _ = try await identity("PluginIdentity", service: service)
        let original = try Data(contentsOf: paths.library.appendingPathComponent(package.fileName))
        var options = PackageSigningOptions(); options.displayName = "My Workspace App"; options.bundleID = "com.retools.changed"; options.version = "2.3.4"; options.outputName = "Custom Name"; options.minimumOS = "16.0"; options.gameMode = .enabled
        let state = try await service.signProject(package.id, options: options)
        XCTAssertEqual(((state.packages.first?.signedFile ?? "") as NSString).lastPathComponent, "Custom Name.ipa")
        let app = try outputApp(state, folder: "First"), info = try ArchiveService.metadata(at: app)
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, options.displayName)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, options.bundleID)
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, options.version)
        XCTAssertEqual(info["MinimumOSVersion"] as? String, "16.0")
        XCTAssertEqual(info["UIFileSharingEnabled"] as? Bool, true)
        XCTAssertEqual(info["GCSupportsGameMode"] as? Bool, true)
        XCTAssertEqual(try MachOInspector.inspect(app.appendingPathComponent("Fixture")).minimumOS, "16.0.0")
        XCTAssertEqual(try Data(contentsOf: paths.library.appendingPathComponent(package.fileName)), original)
        try attachOutput(state, name: "ProjectConfigured.ipa")
        options.version = "3.0"
        let repeated = try await service.signProject(package.id, options: options)
        XCTAssertEqual(repeated.packages.first?.signedFile, state.packages.first?.signedFile)
        XCTAssertEqual(try ArchiveService.metadata(at: outputApp(repeated, folder: "Repeated"))["CFBundleShortVersionString"] as? String, "3.0")
    }
    func testEntitlementsCanReducePermissionButCannotRequestUnprovisionedCapability() async throws {
        let (service, package) = try await makeService(); _ = try await identity("TestIdentity", service: service)
        var options = PackageSigningOptions()
        options.customEntitlements = try PropertyListSerialization.data(fromPropertyList: ["get-task-allow": false], format: .xml, options: 0)
        let state = try await service.signProject(package.id, options: options)
        let app = try outputApp(state, folder: "Entitlements")
        XCTAssertEqual(try signatureEntitlements(app.appendingPathComponent("Fixture"))["get-task-allow"] as? Bool, false)
        let oldOutput = try Data(contentsOf: paths.exports.appendingPathComponent(try XCTUnwrap(state.packages.first?.signedFile)))
        options.customEntitlements = try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.cs.allow-jit": true], format: .xml, options: 0)
        do { _ = try await service.signProject(package.id, options: options); XCTFail("Unprovisioned entitlement accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("未授权")) }
        XCTAssertEqual(try Data(contentsOf: paths.exports.appendingPathComponent(try XCTUnwrap(state.packages.first?.signedFile))), oldOutput)
    }
    func testCertificateChoiceIsPerProjectAndRetainsOtherGlobalSelection() async throws {
        let (service, package) = try await makeService()
        let selected = try await identity("TestIdentity", service: service)
        let global = try await identity("OtherIdentity", service: service)
        var options = PackageSigningOptions(); options.selectIdentity(selected)
        let state = try await service.signProject(package.id, options: options)
        XCTAssertEqual(state.activeIdentityID, global.id)
        let app = try outputApp(state, folder: "SpecificIdentity")
        XCTAssertEqual(try signatureEntitlements(app.appendingPathComponent("Fixture"))["com.apple.developer.team-identifier"] as? String, selected.teamID)
    }
    func testProjectSelectionFollowsEquivalentRenewedCredentialAndQueuedDraft() async throws {
        let (service, package) = try await makeService()
        let selected = try await identity("TestIdentity", service: service)
        var options = PackageSigningOptions(); options.selectIdentity(selected)
        _ = try await service.saveSigningOptions(options, packageID: package.id)
        let material = AppleAccountService.Credentials(p12: try Data(contentsOf: fixture("TestIdentity", "p12")), profile: try Data(contentsOf: fixture("TestIdentityRenewed", "mobileprovision")), password: "test-only")
        let renewed = try await service.importHostIdentity(material)
        passwords.formUnion(renewed.identities.map(\.id))
        XCTAssertEqual(renewed.packages.first?.signingOptions?.identityID, renewed.hostIdentityID)
        let queued = try await service.saveSigningOptions(options, packageID: package.id)
        XCTAssertEqual(queued.packages.first?.signingOptions?.identityID, renewed.hostIdentityID)
        let signed = try await service.signProject(package.id, options: options)
        XCTAssertEqual(signed.packages.first?.signingOptions?.identityID, renewed.hostIdentityID)
    }
    func testAppleIDProjectProvisioningPreservesCertificateChoiceAndProjectOptions() async throws {
        let (service, package) = try await makeService()
        let selected = try await identity("TestIdentity", service: service)
        let exact = try await service.importIdentity(p12: fixture("TestIdentity", "p12"), profile: fixture("TestIdentityExact", "mobileprovision"), password: "test-only")
        passwords.formUnion(exact.identities.map(\.id))
        let development = try XCTUnwrap(exact.identities.first { $0.id == exact.activeIdentityID })
        var options = PackageSigningOptions(); options.selectIdentity(development)
        options.displayName = "Apple ID Project"; options.outputName = "Development Project"; options.fileSharing = false
        let provisioning = try await service.projectProvisioningIdentity(package.id, options: options)
        XCTAssertEqual(provisioning?.id, development.id)
        let material = AppleAccountService.Credentials(p12: try Data(contentsOf: fixture("TestIdentity", "p12")), profile: try Data(contentsOf: fixture("TestIdentityProject", "mobileprovision")), password: "test-only")
        let state = try await service.signProject(package.id, options: options, credentials: material, expectedIdentity: development)
        XCTAssertEqual(state.activeIdentityID, development.id)
        XCTAssertEqual(state.identities.count, 2)
        var normalized = options; normalized.bundleID = package.bundleID
        XCTAssertEqual(state.packages.first?.signingOptions, normalized)
        XCTAssertTrue(state.packages.first?.signedFile?.hasSuffix("/Development Project.ipa") == true)
        let app = try outputApp(state, folder: "AppleID")
        XCTAssertEqual(try ArchiveService.metadata(at: app)["CFBundleDisplayName"] as? String, "Apple ID Project")
        XCTAssertEqual(try signatureEntitlements(app.appendingPathComponent("Fixture"))["application-identifier"] as? String, "TESTTEAM01.com.retools.fixture")
        var manual = options; manual.selectIdentity(selected)
        let manualProvisioning = try await service.projectProvisioningIdentity(package.id, options: manual)
        XCTAssertNil(manualProvisioning)
        let output = paths.exports.appendingPathComponent(try XCTUnwrap(state.packages.first?.signedFile))
        let previousOutput = try Data(contentsOf: output)
        let wrongProfile = AppleAccountService.Credentials(p12: material.p12, profile: try Data(contentsOf: fixture("TestIdentityExact", "mobileprovision")), password: material.password)
        do { _ = try await service.signProject(package.id, options: options, credentials: wrongProfile, expectedIdentity: development); XCTFail("Wrong target profile accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("不匹配目标应用")) }
        let other = AppleAccountService.Credentials(p12: try Data(contentsOf: fixture("OtherIdentity", "p12")), profile: try Data(contentsOf: fixture("OtherIdentityProject", "mobileprovision")), password: "test-only")
        do { _ = try await service.signProject(package.id, options: options, credentials: other, expectedIdentity: development); XCTFail("Different signing identity accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("证书与项目所选证书不一致")) }
        XCTAssertEqual(try Data(contentsOf: output), previousOutput)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.staging.path).isEmpty)
    }
    func testLibraryDeletionRemovesOutputsAndSurvivesMissingOriginalWhileKeepingContainerData() async throws {
        let (service, package) = try await makeService()
        _ = try await identity("PluginIdentity", service: service)
        var options = PackageSigningOptions(); options.outputName = "First"
        let first = try await service.signProject(package.id, options: options)
        options.outputName = "Second"
        let second = try await service.signProject(package.id, options: options)
        let installed = try await service.installContainer(package.id)
        let container = try XCTUnwrap(installed.containerApps.first)
        let marker = paths.data.appendingPathComponent(try XCTUnwrap(container.containers.first).folderName + "/Documents/kept.txt")
        try Data("keep".utf8).write(to: marker)
        try FileManager.default.removeItem(at: paths.library.appendingPathComponent(package.fileName))
        let removed = try await service.deletePackage(package.id)
        XCTAssertTrue(removed.packages.isEmpty); XCTAssertEqual(removed.containerApps.count, 1)
        for state in [first, second] { XCTAssertFalse(FileManager.default.fileExists(atPath: paths.exports.appendingPathComponent(try XCTUnwrap(state.packages.first?.signedFile)).path)) }
        XCTAssertEqual(try String(contentsOf: marker), "keep")
        let reloaded = try await service.reload(); XCTAssertTrue(reloaded.packages.isEmpty)
    }
    func testEmbeddedProfileRemovalAndTIPAProduceConfiguredArchive() async throws {
        let (service, package) = try await makeService(); _ = try await identity("PluginIdentity", service: service)
        var options = PackageSigningOptions(); options.removeEmbedded = true; options.format = .tipa
        let state = try await service.signProject(package.id, options: options)
        XCTAssertTrue(state.packages.first?.signedFile?.hasSuffix(".tipa") == true)
        let app = try outputApp(state, folder: "TIPA")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("_CodeSignature/CodeResources").path))
        try attachOutput(state, name: "ProjectWithoutEmbedded.tipa")
    }
    func testProjectPreviewAppliesURLAndWatchSettingsAndCleansTemporaryCopy() async throws {
        let sourceApp = try ArchiveService.unpack(fixture("Fixture", "ipa"), to: root.appendingPathComponent("Source"))
        var info = try ArchiveService.metadata(at: sourceApp); info["CFBundleURLTypes"] = [["CFBundleURLSchemes": ["example"]]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: sourceApp.appendingPathComponent("Info.plist"))
        try FileManager.default.createDirectory(at: sourceApp.appendingPathComponent("Watch/Example.app"), withIntermediateDirectories: true)
        try Data("watch resource".utf8).write(to: sourceApp.appendingPathComponent("Watch/Example.app/marker"))
        let source = root.appendingPathComponent("source.ipa"); try ArchiveService.pack(app: sourceApp, to: source)
        let service = WorkspaceService(paths: paths, state: WorkspaceState()), state = try await service.importIPA(source)
        let package = try XCTUnwrap(state.packages.first)
        var options = PackageSigningOptions(); options.removeURLSchemes = true
        let preview = try await service.signingProjectPreview(package.id, options: options)
        XCTAssertNil(try ArchiveService.metadata(at: preview)["CFBundleURLTypes"])
        await service.discardSigningPreview(preview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))
        _ = try await identity("TestIdentity", service: service)
        let signed = try await service.signProject(package.id, options: options)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try outputApp(signed, folder: "WithoutWatch").appendingPathComponent("Watch").path))
    }
    /// 用导入证书签名时与 LCSign 一致：扩展保留、随主应用改名、带同一份描述文件并签名；
    /// Apple ID 取得的单应用描述文件签名仍移除扩展。
    func testCertificateSigningKeepsAndSignsExtensionsWhileAppleIDSigningRemovesThem() async throws {
        let sourceApp = try ArchiveService.unpack(fixture("Fixture", "ipa"), to: root.appendingPathComponent("ExtensionSource"))
        let originalID = try XCTUnwrap(ArchiveService.metadata(at: sourceApp)["CFBundleIdentifier"] as? String)
        let appex = sourceApp.appendingPathComponent("PlugIns/Share.appex")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceApp.appendingPathComponent("Fixture"), to: appex.appendingPathComponent("Share"))
        let extensionInfo: [String: Any] = ["CFBundleIdentifier": originalID + ".Share", "CFBundleExecutable": "Share", "CFBundleName": "Share",
                                            "CFBundlePackageType": "XPC!", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
                                            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.share-services"]]
        try PropertyListSerialization.data(fromPropertyList: extensionInfo, format: .xml, options: 0).write(to: appex.appendingPathComponent("Info.plist"))
        let source = root.appendingPathComponent("extension.ipa"); try ArchiveService.pack(app: sourceApp, to: source)
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        let imported = try await service.importIPA(source)
        let package = try XCTUnwrap(imported.packages.first)
        _ = try await identity("TestIdentity", service: service)

        var options = PackageSigningOptions(); options.bundleID = "com.retools.keep-extensions"
        let kept = try await service.signProject(package.id, options: options)
        let app = try outputApp(kept, folder: "KeptExtensions")
        let signedExtension = app.appendingPathComponent("PlugIns/Share.appex")
        XCTAssertEqual(try ArchiveService.metadata(at: signedExtension)["CFBundleIdentifier"] as? String, "com.retools.keep-extensions.Share")
        XCTAssertEqual(try Data(contentsOf: signedExtension.appendingPathComponent("embedded.mobileprovision")),
                       try Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: signedExtension.appendingPathComponent("_CodeSignature/CodeResources").path))
        let executable = signedExtension.appendingPathComponent("Share")
        XCTAssertNoThrow(try RTNative.signingCertificate(ofExecutable: executable.path))
        let entitlements = try XCTUnwrap(try RTNative.entitlements(ofExecutable: executable.path) as? [String: Any])
        XCTAssertEqual(entitlements["application-identifier"] as? String, "TESTTEAM01.com.retools.keep-extensions")
        XCTAssertEqual(entitlements["keychain-access-groups"] as? [String], ["TESTTEAM01.*"])

        // Apple ID（SideStore 流程）：先列出主应用与扩展，扩展跟随新的主应用标识。
        let plan = try await service.prepareAppleSigning(package.id, bundleID: "com.retools.profile-identity")
        XCTAssertEqual(plan.bundles.map(\.bundleID), ["com.retools.profile-identity", "com.retools.profile-identity.Share"])
        XCTAssertEqual(plan.folders["com.retools.profile-identity.Share"], "PlugIns/Share.appex")
        // 没有取得描述文件的扩展被移除；授权只保留原应用声明的项与身份项，不带描述文件的通配钥匙串组。
        let credentials = AppleAppCredentials(p12: try Data(contentsOf: fixture("TestIdentity", "p12")), password: "test-only",
                                              profiles: ["com.retools.profile-identity": try Data(contentsOf: fixture("TestIdentityExact", "mobileprovision"))],
                                              appGroups: [:], teamType: "free", extensionsRemoved: true)
        let renewed = try await service.finishAppleSigning(plan, credentials: credentials)
        let appleApp = try outputApp(renewed, folder: "AppleIDExtensions")
        XCTAssertFalse(FileManager.default.fileExists(atPath: appleApp.appendingPathComponent("PlugIns/Share.appex").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.temp.path))
        let appleEntitlements = try XCTUnwrap(try RTNative.entitlements(ofExecutable: appleApp.appendingPathComponent("Fixture").path) as? [String: Any])
        XCTAssertEqual(appleEntitlements["application-identifier"] as? String, "TESTTEAM01.com.retools.profile-identity")
        XCTAssertNil(appleEntitlements["keychain-access-groups"])
        XCTAssertEqual(renewed.packages.first?.signedBundleID, "com.retools.profile-identity")
        XCTAssertEqual(renewed.packages.first?.appleBundles?.map(\.bundleID), ["com.retools.profile-identity"])
    }
    func testInspectionAndPreviewFailuresCanBeRetriedWithoutLeavingWorkCopies() async throws {
        let (service, package) = try await makeService()
        let archive = paths.library.appendingPathComponent(package.fileName)
        let original = try Data(contentsOf: archive)
        let staging = try FileManager.default.contentsOfDirectory(atPath: paths.staging.path)
        try Data("broken archive".utf8).write(to: archive)
        do { _ = try await service.inspectSigningProject(package.id); XCTFail("Invalid archive inspected") } catch { }
        do { _ = try await service.signingProjectPreview(package.id, options: PackageSigningOptions()); XCTFail("Invalid archive previewed") } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.staging.path), staging)
        try original.write(to: archive)
        let inspection = try await service.inspectSigningProject(package.id)
        XCTAssertEqual(inspection.executable, "Fixture")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.staging.path), staging)
        let preview = try await service.signingProjectPreview(package.id, options: PackageSigningOptions())
        XCTAssertEqual(inspection.dependencies, try MachOInspector.inspect(preview.appendingPathComponent("Fixture")).dependencies)
        await service.discardSigningPreview(preview)
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.staging.path), staging)
    }
    func testCancelledProjectReadsPreserveOriginalAndLeaveNoWorkCopies() async throws {
        let (service, package) = try await makeService()
        let original = try Data(contentsOf: paths.library.appendingPathComponent(package.fileName))
        let staging = try FileManager.default.contentsOfDirectory(atPath: paths.staging.path)
        let preview = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.signingProjectPreview(package.id, options: PackageSigningOptions())
        }
        do { _ = try await preview.value; XCTFail("Cancelled preview completed") }
        catch is CancellationError { }
        let inspection = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.inspectSigningProject(package.id)
        }
        do { _ = try await inspection.value; XCTFail("Cancelled inspection completed") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: paths.library.appendingPathComponent(package.fileName)), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.staging.path), staging)
    }
    func testMissingLibrarySourceHasActionableErrorForBothReaders() async throws {
        let (service, package) = try await makeService()
        try FileManager.default.removeItem(at: paths.library.appendingPathComponent(package.fileName))
        do { _ = try await service.inspectSigningProject(package.id); XCTFail("Missing source inspected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("移动或删除")) }
        do { _ = try await service.signingProjectPreview(package.id, options: PackageSigningOptions()); XCTFail("Missing source previewed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("移动或删除")) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.staging.path).isEmpty)
    }
    func testLoaderRouteWritesManifestAndActuallyLoadsSimulatorLibrary() async throws {
        let (service, package) = try await makeService()
        let probe = Bundle.main.bundleURL.appendingPathComponent("Frameworks/RuntimeProbe.framework/RuntimeProbe")
        let input = root.appendingPathComponent("SimulatorProbe.dylib"); try FileManager.default.copyItem(at: probe, to: input)
        var state = try await service.importPlugin(input)
        let plugin = try XCTUnwrap(state.plugins.first)
        let entry = PluginInjection(pluginID: plugin.id, path: plugin.executablePaths[0], signingTarget: .loader)
        state = try await service.setPackageInjections(package.id, entries: [entry])
        let preview = try await service.signingProjectPreview(package.id, options: PackageSigningOptions())
        let loader = preview.appendingPathComponent("Frameworks/RetoolsPlugins-\(package.id.uuidString)/RetoolsPluginLoader.dylib")
        let binary = try MachOInspector.inspect(preview.appendingPathComponent("Fixture"))
        XCTAssertTrue(binary.dependencies.contains { $0.path.hasSuffix("RetoolsPluginLoader.dylib") })
        XCTAssertFalse(binary.dependencies.contains { $0.path.hasSuffix("SimulatorProbe.dylib") })
        let handle = dlopen(loader.path, RTLD_NOW | RTLD_GLOBAL)
        let failure = dlerror().map { String(cString: $0) } ?? "unknown loader error"
        XCTAssertNotNil(handle, failure)
        if let handle { dlclose(handle) }
        let expected = preview.appendingPathComponent(PluginService.loadPath(entry, namespace: package.id)).resolvingSymlinksInPath().path
        let loaded = (0..<_dyld_image_count()).compactMap { _dyld_get_image_name($0).map { String(cString: $0) } }
        XCTAssertTrue(loaded.contains(expected), "Loader did not load the selected library")
        await service.discardSigningPreview(preview)
    }
    func testOutputNameCannotEscapeProjectDirectory() async throws {
        let (_, package) = try await makeService()
        for value in ["../other", "/tmp/test", "nested/output", "bad\nname"] {
            var options = PackageSigningOptions(); options.outputName = value
            XCTAssertThrowsError(try options.validate(for: package))
        }
    }
    func testSigningLoaderRouteSignsLoaderManifestAndSelectedLibrary() async throws {
        let (service, package) = try await makeService()
        _ = try await identity("PluginIdentity", service: service)
        var state = try await service.importPlugin(fixture("FixturePlugin", "deb"))
        let plugin = try XCTUnwrap(state.plugins.first)
        let entry = PluginInjection(pluginID: plugin.id, path: plugin.executablePaths[0], loadKind: .optional, signingTarget: .loader)
        state = try await service.setPackageInjections(package.id, entries: [entry])
        state = try await service.signProject(package.id, options: PackageSigningOptions())
        let app = try outputApp(state, folder: "SignedLoader"), base = app.appendingPathComponent("Frameworks/RetoolsPlugins-" + package.id.uuidString)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("RetoolsPlugins.json"))) as? [String: Any])
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["path"] as? String, PluginService.loadPath(entry, namespace: package.id)); XCTAssertEqual(entries.first?["optional"] as? Bool, true)
        XCTAssertTrue(try Data(contentsOf: base.appendingPathComponent("RetoolsPluginLoader.dylib")).count > 1000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent(PluginService.loadPath(entry, namespace: package.id)).path))
        try attachOutput(state, name: "ProjectLoader.ipa")
    }
    func testCustomIconProducesInstalledIconSizesAndReferences() async throws {
        let (service, package) = try await makeService(); _ = try await identity("PluginIdentity", service: service)
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let bytes = NSMutableData(), image = try XCTUnwrap(context.makeImage())
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)); CGImageDestinationAddImage(encoder, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        let source = root.appendingPathComponent("icon.png"); try (bytes as Data).write(to: source)
        var options = PackageSigningOptions(); options.iconFile = try await service.importSigningIcon(source); options.repairDarkIcon = false
        let state = try await service.signProject(package.id, options: options), app = try outputApp(state, folder: "CustomIcon")
        let file = app.appendingPathComponent("RetoolsIcon60x60@3x.png")
        let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(decoded, 0, nil)?.width, 180)
        let info = try ArchiveService.metadata(at: app)
        let primary = (info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        XCTAssertTrue((primary?["CFBundleIconFiles"] as? [String] ?? []).contains("RetoolsIcon60x60"))
        XCTAssertNil(primary?["CFBundleIconName"])
        try attachOutput(state, name: "ProjectCustomIcon.ipa")
    }
    func testFailedOverwriteRestoresPreviousSignedArtifact() async throws {
        let (service, package) = try await makeService(); _ = try await identity("TestIdentity", service: service)
        var options = PackageSigningOptions(); options.outputName = "Stable output"
        let first = try await service.signProject(package.id, options: options), file = paths.exports.appendingPathComponent(try XCTUnwrap(first.packages.first?.signedFile))
        let data = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: paths.state); try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: false)
        options.version = "2.0"
        do { _ = try await service.signProject(package.id, options: options); XCTFail("Workspace commit failure was ignored") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), data)
        let unchanged = await service.snapshot(); XCTAssertEqual(unchanged.packages.first?.signedAt, first.packages.first?.signedAt)
    }
    func testOversizedIconAndEntitlementFilesAreRejected() async throws {
        let (service, _) = try await makeService()
        let file = root.appendingPathComponent("oversized.dat"); try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file); try handle.truncate(atOffset: 8_000_001); try handle.close()
        do { _ = try await service.importSigningIcon(file); XCTFail("Oversized icon accepted") } catch {}
        do { _ = try await service.importSigningEntitlements(file); XCTFail("Oversized entitlements accepted") } catch {}
    }
}
