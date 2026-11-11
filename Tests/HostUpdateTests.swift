import XCTest
import RetoolsNative
@testable import LiveContainerSwiftUI

final class HostUpdateTests: XCTestCase {
    private var root: URL!
    private var paths: WorkspacePaths!
    private var identities = Set<UUID>()
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        try paths.createDirectories()
    }
    override func tearDownWithError() throws {
        for id in identities { try? SecureStore.delete(id: id) }
        try? FileManager.default.removeItem(at: root)
    }
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }
    private func write(_ info: [String: Any], to bundle: URL) throws {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
    }
    private func app(_ name: String, id: String = "dev.retools.ios", pairingID: String? = nil) throws -> URL {
        let app = try ArchiveService.unpack(fixture("Fixture", "ipa"), to: root.appendingPathComponent(name))
        try FileManager.default.moveItem(at: app.appendingPathComponent("Fixture"), to: app.appendingPathComponent("Retools"))
        var info = try ArchiveService.metadata(at: app)
        info["CFBundleIdentifier"] = id; info["CFBundleExecutable"] = "Retools"
        info["CFBundleVersion"] = "999"; info["RetoolsPrivateSandbox"] = true
        info[HostAppGroup.metadataKey] = HostAppGroup.baseIdentifier
        info["BGTaskSchedulerPermittedIdentifiers"] = ["dev.retools.ios.renewal", "dev.retools.ios.new-task"]
        try write(info, to: app)
        let ext = app.appendingPathComponent("PlugIns/RetoolsPairingWidget.appex")
        try write(["CFBundleIdentifier": pairingID ?? id + ".pairing", "CFBundleExecutable": "RetoolsPairingWidget", "CFBundlePackageType": "XPC!"], to: ext)
        try FileManager.default.copyItem(at: app.appendingPathComponent("Retools"), to: ext.appendingPathComponent("RetoolsPairingWidget"))
        return app
    }
    private func materials() throws -> [String: AppleAccountService.Credentials] {
        let p12 = try Data(contentsOf: fixture("HostGroupIdentity", "p12"))
        return ["dev.retools.ios": AppleAccountService.Credentials(p12: p12, profile: try Data(contentsOf: fixture("HostGroupIdentityHost", "mobileprovision")), password: "test-only"),
                "dev.retools.ios.pairing": AppleAccountService.Credentials(p12: p12, profile: try Data(contentsOf: fixture("HostGroupIdentityExtension", "mobileprovision")), password: "test-only")]
    }
    private func plan() async throws -> (WorkspaceService, HostUpdatePlan, Data) {
        let source = root.appendingPathComponent("Update.ipa")
        try ArchiveService.pack(app: app("Incoming"), to: source)
        let original = try Data(contentsOf: source)
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        let imported = try await service.importIPA(source)
        let package = try XCTUnwrap(imported.packages.first)
        let state = try await service.importIdentity(p12: fixture("HostGroupIdentity", "p12"), profile: fixture("HostGroupIdentity", "mobileprovision"), password: "test-only")
        identities.formUnion(state.identities.map(\.id))
        let prepared = try await service.prepareHostUpdate(package.id, options: PackageSigningOptions())
        let plan = try XCTUnwrap(prepared)
        return (service, plan, original)
    }
    func testRecognizesUnsignedAndPreviouslyRenamedRetoolsWithoutRoutingOtherApps() {
        XCTAssertTrue(HostUpdate.isCandidate("dev.retools.ios", installedID: "dev.retools.ios.TEAM"))
        XCTAssertTrue(HostUpdate.isCandidate("dev.retools.ios.TEAM", installedID: "dev.retools.ios.TEAM"))
        XCTAssertTrue(HostUpdate.isCandidate("custom.retools", installedID: "custom.retools"))
        XCTAssertFalse(HostUpdate.isCandidate("com.example.app", installedID: "dev.retools.ios"))
    }
    func testUpdateUsesInstalledIdentifiersAndKeepsNewVersionAndBackgroundTasks() throws {
        let incoming = try app("New")
        let installed = try app("Current", id: "custom.retools.TEAM", pairingID: "custom.retools.TEAM.widget.TEAM")
        let currentBytes = try Data(contentsOf: installed.appendingPathComponent("Info.plist"))
        try HostUpdate.normalize(incoming, installed: installed)
        let info = try ArchiveService.metadata(at: incoming)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "custom.retools.TEAM")
        XCTAssertEqual(info["CFBundleVersion"] as? String, "999")
        XCTAssertEqual(info["BGTaskSchedulerPermittedIdentifiers"] as? [String], ["dev.retools.ios.renewal", "dev.retools.ios.new-task"])
        XCTAssertNotNil(info["RetoolsRenewalReceipt"])
        XCTAssertEqual(try ArchiveService.metadata(at: incoming.appendingPathComponent("PlugIns/RetoolsPairingWidget.appex"))["CFBundleIdentifier"] as? String, "custom.retools.TEAM.widget.TEAM")
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("Info.plist")), currentBytes)
    }
    func testRejectsIncompleteUpdateAndUnrelatedApp() throws {
        let incoming = try app("Incomplete"), installed = try app("Installed")
        try FileManager.default.removeItem(at: incoming.appendingPathComponent("PlugIns"))
        XCTAssertThrowsError(try HostUpdate.normalize(incoming, installed: installed))
        let unrelated = try ArchiveService.unpack(fixture("Fixture", "ipa"), to: root.appendingPathComponent("Unrelated"))
        XCTAssertThrowsError(try HostUpdate.normalize(unrelated, installed: installed))
    }
    func testSignsImportedVersionWithSeparateExtensionProfileAndPreservesOriginalIPA() async throws {
        let (service, plan, original) = try await plan()
        let state = try await service.finishHostUpdate(plan, materials: materials())
        let package = try XCTUnwrap(state.packages.first)
        let output = try ArchiveService.unpack(paths.exports.appendingPathComponent(try XCTUnwrap(package.signedFile)), to: root.appendingPathComponent("Signed"))
        XCTAssertEqual(try ArchiveService.metadata(at: output)["CFBundleVersion"] as? String, "999", "不得重新打包旧的运行版本")
        XCTAssertEqual(package.signedBundleID, Bundle.main.bundleIdentifier)
        XCTAssertEqual(package.signingOptions?.bundleID, Bundle.main.bundleIdentifier)
        XCTAssertNotNil(try HostUpdate.validateInstall(output, teamID: "GROUPTEAM1", installedID: "dev.retools.ios", requiresAppGroup: true).receipt)
        XCTAssertEqual(try Data(contentsOf: paths.library.appendingPathComponent(package.fileName)), original)
        XCTAssertNil(state.hostIdentityID, "只生成签名输出时不能提前替换当前宿主证书")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.temp.path))
        let ext = output.appendingPathComponent("PlugIns/RetoolsPairingWidget.appex")
        XCTAssertEqual(try ProfileRefresh.parse(Data(contentsOf: ext.appendingPathComponent("embedded.mobileprovision"))).applicationIdentifier, "GROUPTEAM1.dev.retools.ios.pairing")
        try FileManager.default.removeItem(at: ext.appendingPathComponent("embedded.mobileprovision"))
        XCTAssertThrowsError(try HostUpdate.validateInstall(output, teamID: "GROUPTEAM1", installedID: "dev.retools.ios", requiresAppGroup: true))
    }
    func testMissingExtensionProfileDoesNotProducePartialUpdate() async throws {
        let (service, plan, _) = try await plan()
        var materials = try materials(); materials.removeValue(forKey: "dev.retools.ios.pairing")
        do { _ = try await service.finishHostUpdate(plan, materials: materials); XCTFail("缺少扩展配置时不能签名") }
        catch { XCTAssertTrue(error.localizedDescription.contains("描述文件")) }
        let state = await service.snapshot()
        XCTAssertNil(state.packages.first?.signedFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.temp.path))
    }
    func testUpdateRejectsDifferentTeamAndReceiptMismatch() async throws {
        let (service, plan, _) = try await plan()
        let state = try await service.finishHostUpdate(plan, materials: materials())
        let output = try ArchiveService.unpack(paths.exports.appendingPathComponent(try XCTUnwrap(state.packages.first?.signedFile)), to: root.appendingPathComponent("Check"))
        XCTAssertThrowsError(try HostUpdate.validateInstall(output, teamID: "OTHERTEAM", installedID: "dev.retools.ios", requiresAppGroup: true))
        XCTAssertThrowsError(try HostUpdate.validateInstall(output, teamID: "GROUPTEAM1", installedID: "different.app", requiresAppGroup: true))
        var info = try ArchiveService.metadata(at: output); info.removeValue(forKey: "RetoolsRenewalReceipt")
        try write(info, to: output)
        XCTAssertThrowsError(try HostUpdate.validateInstall(output, teamID: "GROUPTEAM1", installedID: "dev.retools.ios", requiresAppGroup: true))
    }
}
