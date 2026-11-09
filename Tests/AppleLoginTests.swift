import XCTest
@testable import LiveContainerSwiftUI

final class AppleLoginTests: XCTestCase {
    func testMigratesOldDefaultAndPreservesCustomAnisetteServer() throws {
        XCTAssertEqual(AppleLoginConfiguration.migratedAnisetteURL("https://ani.iloader.app/"), "https://new.ani.sidestore.io")
        XCTAssertEqual(AppleLoginConfiguration.migratedAnisetteURL("https://my.example/anisette"), "https://my.example/anisette")
        XCTAssertEqual(try AppleLoginConfiguration.validatedAnisetteURL(" https://my.example/anisette/ "), "https://my.example/anisette")
        for url in ["http://example.com", "https://", "https://user:password@example.com", "https://example.com?token=secret"] {
            XCTAssertThrowsError(try AppleLoginConfiguration.validatedAnisetteURL(url))
        }
    }
    func testUnknownTwoFactorRequiresChoosingDeliveryMethod() {
        let prompt = TwoFactorBroker.TwoFactorPrompt(json: "{\"unknown\":true,\"sms\":false,\"numbers\":[{\"id\":2,\"numberWithDialCode\":\"+86 •••• 12\"}]}")
        XCTAssertTrue(prompt.requiresMethodSelection)
        XCTAssertFalse(prompt.isSMS)
        XCTAssertEqual(prompt.numbers.first?.id, 2)
        XCTAssertTrue(prompt.text.contains("请选择"))
    }
    func testSMSTwoFactorKeepsSelectedNumberAndAppleError() {
        let prompt = TwoFactorBroker.TwoFactorPrompt(json: "{\"unknown\":false,\"sms\":true,\"selectedNumberId\":3,\"lastError\":\"验证码未被接受\",\"numbers\":[]}")
        XCTAssertFalse(prompt.requiresMethodSelection)
        XCTAssertTrue(prompt.isSMS)
        XCTAssertEqual(prompt.selectedNumberID, 3)
        XCTAssertEqual(prompt.text, "验证码未被接受")
    }
    func testServiceCheckRejectsHTTPBeforeAnyNetwork() async {
        do { _ = try await AppleAccountService().checkService(anisetteURL: "http://example.invalid"); XCTFail("HTTP accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTTPS")) }
    }
    func testAppleEngineInitializesTLSBeforeNetwork() async {
        do {
            _ = try await AppleAccountService().checkService(anisetteURL: "https://127.0.0.1:1")
            XCTFail("Unexpected service on local closed port")
        } catch {
            XCTAssertTrue(AuthDiagnostics.detail(error).contains("无法准备 Apple ID 验证服务"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("engine stopped unexpectedly"), error.localizedDescription)
        }
    }
    @MainActor
    func testPreviousDefaultMigrationLoadsExistingSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{\"anisetteURL\":\"https://ani.iloader.app\",\"hasPairing\":true,\"hostIP\":\"10.9.0.1\"}".utf8).write(to: paths.support.appendingPathComponent("renewal.json"))
        let controller = RenewalController(paths: paths)
        XCTAssertEqual(controller.settings.anisetteURL, "https://new.ani.sidestore.io")
        XCTAssertTrue(controller.settings.hasPairing)
        XCTAssertEqual(controller.settings.hostIP, "10.9.0.1")
    }
    func testChangingAnisetteEndpointPreservesSigningKeys() {
        let state = ["anisette_state": "old-adi", "retools_anisette_endpoint": "https://old.example", "certificate": "private-key", "retools_auth": "session"]
        let changed = AppleLoginConfiguration.stateForEndpoint(state, endpoint: "https://new.example")
        XCTAssertNil(changed["anisette_state"])
        XCTAssertEqual(changed["certificate"], "private-key")
        XCTAssertEqual(changed["retools_auth"], "session")
        XCTAssertEqual(AppleLoginConfiguration.stateForEndpoint(state, endpoint: "https://old.example")["anisette_state"], "old-adi")
    }
    func testAuthenticationDiagnosticRedactsSecretsAndKeepsErrorCode() throws {
        let raw = "Auth error -80045: This action cannot be completed.\n/Users/example/project/src/lib.rs:68\nuser@example.com password=SensitivePassword123 token=abcdef123456789"
        let sanitized = AuthDiagnostics.sanitized(raw, secrets: ["SensitivePassword123"])
        XCTAssertFalse(sanitized.contains("user@example.com"))
        XCTAssertFalse(sanitized.contains("SensitivePassword123"))
        XCTAssertFalse(sanitized.contains("abcdef123456789"))
        XCTAssertFalse(sanitized.contains("/Users/example"))
        XCTAssertTrue(AuthDiagnostics.summary(raw).contains("-80045"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        AuthDiagnostics.record(stage: "账号认证", message: raw, secrets: ["SensitivePassword123"], paths: paths)
        XCTAssertEqual(AuthDiagnostics.entries(paths: paths).first?.stage, "账号认证")
        XCTAssertFalse(AuthDiagnostics.entries(paths: paths).first?.message.contains("SensitivePassword123") ?? true)
    }
    @MainActor
    func testLoginValidationUsesAccountErrorTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = RenewalController(paths: paths)
        controller.login(password: "")
        XCTAssertEqual(controller.errorTitle, "Apple ID 登录失败")
        XCTAssertTrue(controller.errorMessage?.contains("Apple ID") == true)
        XCTAssertFalse(controller.isWorking)
    }
}
