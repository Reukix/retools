import XCTest
import RetoolsNative
@testable import LiveContainerSwiftUI

final class HostAppGroupTests: XCTestCase {
    private let team = "GROUPTEAM1"
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }
    private func makeApp(_ suffix: String = "") throws -> URL {
        let app = try ArchiveService.unpack(fixture("Fixture", "ipa"), to: root.appendingPathComponent("Unpacked" + suffix))
        var info = try ArchiveService.metadata(at: app)
        info[HostAppGroup.metadataKey] = HostAppGroup.baseIdentifier
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        return app
    }
    private func sign(_ app: URL, profile: String = "HostGroupIdentity") throws {
        let credentials = ["com.retools.fixture": ["p12": try fixture("HostGroupIdentity", "p12").path,
            "profile": try fixture(profile, "mobileprovision").path, "password": "test-only"]]
        try RTNative.signHostApp(app.path, credentials: credentials)
    }
    func testHostSigningPreservesOnlyDedicatedAuthorizedGroup() throws {
        let app = try makeApp()
        try sign(app)
        let entitlements = try RTNative.entitlements(ofExecutable: app.appendingPathComponent("Fixture").path)
        XCTAssertEqual(entitlements[HostAppGroup.entitlement] as? [String], [HostAppGroup.identifier(teamID: team)])
        XCTAssertEqual(HostAppGroup.signedIdentifier(in: app), HostAppGroup.identifier(teamID: team))
        XCTAssertTrue(RTNative.usesPrivateSandbox())
    }
    func testSigningDoesNotInventAppGroupAuthorization() throws {
        let app = try makeApp()
        try sign(app, profile: "HostGroupIdentityNoGroup")
        let entitlements = try RTNative.entitlements(ofExecutable: app.appendingPathComponent("Fixture").path)
        XCTAssertNil(entitlements[HostAppGroup.entitlement])
        XCTAssertNil(HostAppGroup.signedIdentifier(in: app))
    }
    func testUnreadableSignatureIsNotTreatedAsAnUnconfiguredInstallation() throws {
        let app = try makeApp()
        try Data("invalid executable".utf8).write(to: app.appendingPathComponent("Fixture"))
        XCTAssertThrowsError(try HostAppGroup.readSignedIdentifier(in: app))
    }
    func testRequestsAssignGroupToMainAppOnlyWhenSelected() throws {
        let app = try makeApp()
        let ext = app.appendingPathComponent("PlugIns/Pairing.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.retools.fixture.pairing", "CFBundleExecutable": "Pairing"], format: .xml, options: 0)
            .write(to: ext.appendingPathComponent("Info.plist"))
        let enabled = try HostAppGroup.signingRequests(in: app, includeAppGroup: true)
        XCTAssertEqual(enabled.map(\.bundleID), ["com.retools.fixture", "com.retools.fixture.pairing"])
        XCTAssertEqual(enabled.first?.appGroups, [HostAppGroup.baseIdentifier])
        XCTAssertEqual(enabled.last?.appGroups, [])
        XCTAssertTrue(try HostAppGroup.signingRequests(in: app, includeAppGroup: false).allSatisfy { $0.appGroups.isEmpty })
    }
    func testProfileValidationRejectsMissingGroupAndDifferentIdentity() throws {
        let data = try Data(contentsOf: fixture("HostGroupIdentity", "mobileprovision"))
        XCTAssertNoThrow(try HostAppGroup.validateProfile(data, bundleID: "com.retools.fixture", teamID: team, requireAppGroup: true))
        XCTAssertThrowsError(try HostAppGroup.validateProfile(data, bundleID: "com.other.app", teamID: team, requireAppGroup: true))
        XCTAssertThrowsError(try HostAppGroup.validateProfile(data, bundleID: "com.retools.fixture", teamID: "OTHERTEAM", requireAppGroup: true))
        let noGroup = try Data(contentsOf: fixture("HostGroupIdentityNoGroup", "mobileprovision"))
        XCTAssertThrowsError(try HostAppGroup.validateProfile(noGroup, bundleID: "com.retools.fixture", teamID: team, requireAppGroup: true))
        XCTAssertNoThrow(try HostAppGroup.validateProfile(noGroup, bundleID: "com.retools.fixture", teamID: team, requireAppGroup: false))
    }
    func testPreparedHostReadsBackAppGroupAfterSigning() async throws {
        let paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        try paths.createDirectories()
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        let p12 = try Data(contentsOf: fixture("HostGroupIdentity", "p12"))
        var materials: [String: AppleAccountService.Credentials] = [:]
        for request in try HostAppGroup.signingRequests(in: Bundle.main.bundleURL, includeAppGroup: true) {
            let suffix = request.bundleID == Bundle.main.bundleIdentifier ? "Host" : "Extension"
            materials[request.bundleID] = AppleAccountService.Credentials(p12: p12,
                profile: try Data(contentsOf: fixture("HostGroupIdentity" + suffix, "mobileprovision")), password: "test-only")
        }
        let app = try await service.prepareHostForRenewal(materials: materials, requiresAppGroup: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        XCTAssertEqual(HostAppGroup.signedIdentifier(in: app), HostAppGroup.identifier(teamID: team))
        let extensions = try FileManager.default.contentsOfDirectory(at: app.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil)
        for ext in extensions where ext.pathExtension == "appex" {
            let name = try XCTUnwrap(try ArchiveService.metadata(at: ext)["CFBundleExecutable"] as? String)
            XCTAssertNil(try RTNative.entitlements(ofExecutable: ext.appendingPathComponent(name).path)[HostAppGroup.entitlement])
        }
    }
    func testGroupRecognitionRejectsOtherTeamAndUnrelatedGroups() {
        let key = "com.apple.developer.team-identifier"
        XCTAssertNil(HostAppGroup.identifier(in: [key: team, HostAppGroup.entitlement: ["group.unrelated", HostAppGroup.identifier(teamID: "OTHERTEAM")]]))
        XCTAssertEqual(HostAppGroup.identifier(in: [key: team, HostAppGroup.entitlement: [HostAppGroup.baseIdentifier]]), HostAppGroup.baseIdentifier)
    }
    func testProfileOnlyRefreshChecksGroupValues() {
        let certificate = Data("synthetic-certificate".utf8)
        let signed: [String: Any] = ["application-identifier": team + ".dev.retools.ios", HostAppGroup.entitlement: [HostAppGroup.identifier(teamID: team)]]
        var allowed = signed
        allowed[HostAppGroup.entitlement] = ["group.other"]
        var profile = ProfileRefresh.Profile(uuid: "test", expiry: Date().addingTimeInterval(3600), applicationIdentifier: team + ".dev.retools.ios", entitlements: allowed, certificates: [certificate])
        XCTAssertEqual(ProfileRefresh.blocker(profile: profile, signingCertificate: certificate, signedEntitlements: signed, currentExpiry: nil), "新描述文件未授权当前 App Group")
        allowed[HostAppGroup.entitlement] = [HostAppGroup.identifier(teamID: team), "group.other"]
        profile = ProfileRefresh.Profile(uuid: "test", expiry: profile.expiry, applicationIdentifier: profile.applicationIdentifier, entitlements: allowed, certificates: [certificate])
        XCTAssertNil(ProfileRefresh.blocker(profile: profile, signingCertificate: certificate, signedEntitlements: signed, currentExpiry: nil))
    }
    func testReadWriteCheckPreservesExistingFilesAndCleansProbe() throws {
        let existing = root.appendingPathComponent("existing.txt")
        let original = Data("keep existing data".utf8)
        try original.write(to: existing)
        let group = HostAppGroup.identifier(teamID: team)
        let status = HostAppGroup.check(group: group, container: { _ in self.root })
        XCTAssertTrue(status.verified)
        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.txt"])
        XCTAssertFalse(HostAppGroup.check(group: group, container: { _ in nil }).verified)
        XCTAssertFalse(HostAppGroup.check(group: group, container: { _ in existing }).verified)
        XCTAssertEqual(try Data(contentsOf: existing), original)
    }
    func testOldDevelopmentManifestStillDecodes() throws {
        let old = "{\"bundleID\":\"dev.retools.ios\",\"build\":\"50\",\"targetTeam\":\"GROUPTEAM1\",\"backupID\":\"00000000-0000-0000-0000-000000000001\",\"getTaskAllow\":true}"
        XCTAssertNil(try JSONDecoder().decode(DevelopmentSigningManifest.self, from: Data(old.utf8)).appGroup)
    }
}
