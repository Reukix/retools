import XCTest
@testable import LiveContainerSwiftUI

final class SigningMigrationTests: XCTestCase {
    private func payload() -> SigningMigration.Payload {
        SigningMigration.Payload(bundleID: "dev.retools.ios", targetTeam: "TESTTEAM", workspace: WorkspaceState(), renewal: RenewalSettings(),
            passwords: [:], accountData: ["apple.state.test@example.invalid": Data("test-vault-token".utf8)], credentialFiles: [:])
    }
    func testEncryptedBackupAuthenticatesCodeBundleAndTeam() throws {
        let input = payload(), (envelope, code) = try SigningMigration.seal(input)
        let encoded = try JSONEncoder().encode(envelope)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("test-vault-token"))
        let restored = try SigningMigration.open(envelope, code: code, bundleID: "dev.retools.ios", team: "TESTTEAM")
        XCTAssertEqual(restored.accountData, input.accountData)
        XCTAssertThrowsError(try SigningMigration.open(envelope, code: code, bundleID: "dev.other.app", team: "TESTTEAM"))
        XCTAssertThrowsError(try SigningMigration.open(envelope, code: code, bundleID: "dev.retools.ios", team: "OTHERTEAM"))
        XCTAssertThrowsError(try SigningMigration.open(envelope, code: "RTM1-" + Data(repeating: 0, count: 32).base64EncodedString(), bundleID: "dev.retools.ios", team: "TESTTEAM"))
        var altered = envelope.sealed; altered[altered.count - 1] ^= 1
        let bad = SigningMigration.Envelope(version: envelope.version, id: envelope.id, targetTeam: envelope.targetTeam, sealed: altered)
        XCTAssertThrowsError(try SigningMigration.open(bad, code: code, bundleID: "dev.retools.ios", team: "TESTTEAM"))
    }
    func testRestorePreservesNewerExistingAccountAndRejectsUntrustedPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        let key = "apple.state.migration-test-\(UUID().uuidString.lowercased())@example.invalid"
        defer { try? FileManager.default.removeItem(at: root); try? SecureStore.deleteData(key: key) }
        let newer = Data("newer-token".utf8)
        try SecureStore.saveData(newer, key: key)
        let payload = SigningMigration.Payload(bundleID: "dev.retools.ios", targetTeam: "TESTTEAM", workspace: WorkspaceState(), renewal: RenewalSettings(), passwords: [:], accountData: [key: Data("older-token".utf8)], credentialFiles: [:])
        try SigningMigration.restore(payload, paths: paths)
        XCTAssertEqual(try SecureStore.data(key: key), newer)
        let invalid = SigningMigration.Payload(bundleID: "dev.retools.ios", targetTeam: "TESTTEAM", workspace: WorkspaceState(), renewal: RenewalSettings(), passwords: [:], accountData: [:], credentialFiles: ["../escape": Data()])
        XCTAssertThrowsError(try SigningMigration.restore(invalid, paths: paths))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
    }
}
