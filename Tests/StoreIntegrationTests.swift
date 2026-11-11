import XCTest
@testable import LiveContainerSwiftUI

@MainActor
final class StoreIntegrationTests: XCTestCase {
    private enum Stop: Error { case failed }
    func testFailedCoverInstallNeverUninstallsTheExistingApp() async {
        var removed = false
        do {
            try await StoreVersionInstallation.run(reinstall: false, installed: true, canBackUp: true,
                backup: { XCTFail("Cover installation must not delete or back up data") },
                uninstall: { removed = true }, install: { replacing in XCTAssertTrue(replacing); throw Stop.failed })
            XCTFail("Must report the system rejection")
        } catch { XCTAssertFalse(removed) }
    }
    func testFailedBackupPreventsRemovalAndInstallation() async {
        var events: [String] = []
        do {
            try await StoreVersionInstallation.run(reinstall: true, installed: true, canBackUp: true,
                backup: { events.append("backup"); throw Stop.failed },
                uninstall: { events.append("remove") }, install: { _ in events.append("install") })
            XCTFail("Must stop after backup failure")
        } catch { XCTAssertEqual(events, ["backup"]) }
    }
    func testConfirmedReinstallBacksUpBeforeRemovalAndDoesNotUpgrade() async throws {
        var events: [String] = []
        try await StoreVersionInstallation.run(reinstall: true, installed: true, canBackUp: true,
            backup: { events.append("backup") }, uninstall: { events.append("remove") },
            install: { replacing in XCTAssertFalse(replacing); events.append("install") })
        XCTAssertEqual(events, ["backup", "remove", "install"])
    }
    private func archive(_ info: [String: Any], root: URL) throws -> URL {
        let file = root.appendingPathComponent(UUID().uuidString + ".ipa")
        let zip = try Archive(url: file, accessMode: .create)
        var metadata = info; metadata["CFBundleExecutable"] = "Test"
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        try zip.addEntry(with: "Payload/Test.app/Info.plist", type: .file, uncompressedSize: Int64(data.count)) { offset, size in
            data.subdata(in: Int(offset)..<min(data.count, Int(offset) + size))
        }
        try zip.addEntry(with: "Payload/Test.app/Test", type: .file, uncompressedSize: Int64(4)) { _, _ in Data([0xcf, 0xfa, 0xed, 0xfe]) }
        return file
    }
    func testStoreVersionInspectionRejectsSelfAndOtherDevicePlatforms() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try StoreArchiveInfo.inspect(archive(["CFBundleIdentifier": Bundle.main.bundleIdentifier!], root: root)))
        XCTAssertThrowsError(try StoreArchiveInfo.inspect(archive(["CFBundleIdentifier": "../escape"], root: root)))
        XCTAssertThrowsError(try StoreArchiveInfo.inspect(archive(["CFBundleIdentifier": "example.tv", "CFBundleSupportedPlatforms": ["AppleTVOS"], "UIDeviceFamily": [3]], root: root)))
        let info = try StoreArchiveInfo.inspect(archive(["CFBundleIdentifier": "example.ios", "CFBundleShortVersionString": "1.9", "CFBundleVersion": "19", "UIDeviceFamily": [1, 2]], root: root))
        XCTAssertEqual(info.bundleID, "example.ios")
        let installed = try XCTUnwrap(DeviceInstalledApp.parse(PropertyListSerialization.data(fromPropertyList:
            ["CFBundleIdentifier": "example.ios", "CFBundleShortVersionString": "1.10", "CFBundleVersion": "20"], format: .binary, options: 0)))
        XCTAssertTrue(info.isOlder(than: installed))
        XCTAssertFalse(StoreArchiveInfo(name: "Test", bundleID: "example.ios", version: "1.10", build: "21").isOlder(than: installed))
    }

    func testImportFromStorePreservesOriginalAndSiblingDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        try paths.createDirectories()
        let downloads = paths.documents.appendingPathComponent("Retools/StoreDownloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let source = downloads.appendingPathComponent("Original.ipa")
        let sibling = downloads.appendingPathComponent("AnotherDownload.txt")
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixture", withExtension: "ipa"))
        try FileManager.default.copyItem(at: fixture, to: source)
        try Data("keep".utf8).write(to: sibling)
        let original = try Data(contentsOf: source)
        let store = WorkspaceStore(paths: paths)
        try await store.importStoreDownload(source)
        XCTAssertEqual(store.state.packages.count, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try String(contentsOf: sibling), "keep")
        XCTAssertFalse(store.isWorking)
    }
}
