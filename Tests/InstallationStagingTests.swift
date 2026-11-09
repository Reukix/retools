import XCTest
import IdeviceGateway
@testable import LiveContainerSwiftUI

final class InstallationStagingTests: XCTestCase {
    func testSameProfileDoesNotConfirmAnInstallWithoutThisAttemptsReceipt() {
        XCTAssertFalse(RenewalScheduling.confirmsInstall(expectedProfile: "same-profile", expectedReceipt: "new-attempt", currentProfile: "same-profile", currentReceipt: "previous-attempt"))
        XCTAssertFalse(RenewalScheduling.confirmsInstall(expectedProfile: "same-profile", expectedReceipt: nil, currentProfile: "same-profile", currentReceipt: nil))
        XCTAssertTrue(RenewalScheduling.confirmsInstall(expectedProfile: "same-profile", expectedReceipt: "new-attempt", currentProfile: "same-profile", currentReceipt: "new-attempt"))
    }
    func testRootAliasKeepsInfoPlistAtBundleRootAndUploadsEveryFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixture", withExtension: "ipa"))
        let app = try ArchiveService.unpack(fixture, to: root.appendingPathComponent("Original"))
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        let plan = try AppBundleStagingPlan(appURL: alias, bundleID: "com.retools.fixture")
        XCTAssertTrue(plan.entries.contains { $0.relativePath == "Info.plist" })
        XCTAssertTrue(plan.entries.contains { $0.relativePath == "Fixture" })
        XCTAssertFalse(plan.entries.contains { $0.relativePath.hasPrefix("private/") || $0.relativePath.hasPrefix("/") })
        XCTAssertEqual(try AppBundleStagingPlan.relativePath(app.appendingPathComponent("Info.plist"), root: alias), "Info.plist")
        try plan.validateUploadedInfo(plan.infoData)
        XCTAssertThrowsError(try plan.validateUploadedInfo(Data("incomplete".utf8)))
        XCTAssertThrowsError(try AppBundleStagingPlan(appURL: alias, bundleID: "dev.wrong.app"))
    }
    func testRejectsNestedLinksAndSiblingDirectoryPrefix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixture", withExtension: "ipa"))
        let app = try ArchiveService.unpack(fixture, to: root)
        XCTAssertThrowsError(try AppBundleStagingPlan.relativePath(app.deletingLastPathComponent().appendingPathComponent("Fixture.app-other/secret"), root: app))
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try AppBundleStagingPlan(appURL: app, bundleID: "com.retools.fixture"))
    }
    func testFailedRenewalRetriesSoonerThanSuccessfulChecks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = RenewalSettings(); settings.lastAttempt = now
        settings.lastAttemptSucceeded = false; settings.failureCount = 1
        XCTAssertEqual(RenewalScheduling.nextEligible(settings: settings, now: now), now.addingTimeInterval(900))
        settings.failureCount = 2
        XCTAssertEqual(RenewalScheduling.nextEligible(settings: settings, now: now), now.addingTimeInterval(1800))
        settings.lastAttemptSucceeded = true
        XCTAssertEqual(RenewalScheduling.nextEligible(settings: settings, now: now), now.addingTimeInterval(21600))
        settings.lastAttemptSucceeded = nil; settings.lastSuccess = now
        XCTAssertEqual(RenewalScheduling.nextEligible(settings: settings, now: now), now.addingTimeInterval(21600))
    }
}
