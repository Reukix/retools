import XCTest
@testable import LiveContainerSwiftUI

final class DecryptionCacheTests: XCTestCase {
    private var root: URL!
    private var paths: WorkspacePaths!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        try paths.createDirectories()
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    @discardableResult private func write(_ data: String, to url: URL) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(data.utf8).write(to: url)
        return url
    }

    func testEmptyCacheCanBeScannedAndCleared() throws {
        XCTAssertEqual(try DecryptionCache.size(paths: paths), 0)
        XCTAssertEqual(try DecryptionCache.clear(paths: paths), 0)
        XCTAssertTrue(try DecryptionCache.savedResults(paths: paths).isEmpty)
    }

    func testCleanupPreservesAllResultsAndUserDataWhileRemovingTaskAndDownloadCopies() throws {
        let first = UUID().uuidString, second = UUID().uuidString
        let jobs = paths.support.appendingPathComponent("Decryption")
        let task = try write("helper", to: jobs.appendingPathComponent(first + "/Helper/Payload/Helper.app/Target"))
        let archive = try write("archive", to: jobs.appendingPathComponent(second + "/DecryptHelper.ipa"))
        try write("first-result", to: jobs.appendingPathComponent(first + "/Result.ipa"))
        try write("second-result", to: jobs.appendingPathComponent(second + "/Result.ipa"))
        let current = try write(first, to: jobs.appendingPathComponent("Current"))
        let download = try write("download", to: paths.support.appendingPathComponent("StoreDownloads/download-123.ipa"))
        let partial = try write("partial", to: paths.support.appendingPathComponent("StoreDownloads/download-456.ipa.tmp"))
        let staging = try write("snapshot", to: paths.staging.appendingPathComponent("InstalledSource-test/Target"))
        let kept = [
            try write("component", to: paths.support.appendingPathComponent("StoreDownloads/AppleAssets/Component")),
            try write("credential", to: paths.credentials.appendingPathComponent("identity.p12")),
            try write("library", to: paths.library.appendingPathComponent("Original.ipa")),
            try write("signed", to: paths.exports.appendingPathComponent("Signed.ipa")),
            try write("backup", to: paths.support.appendingPathComponent("LocalFileBackups/original")),
            try write("other", to: paths.staging.appendingPathComponent("OtherTask/source"))
        ]
        // A previous export must survive a name collision without being replaced.
        let previous = try write("previous", to: paths.exports.appendingPathComponent("Decrypted/" + first + "-decrypted.ipa"))
        let expected = Int64("helperarchivesnapshotdownloadpartial".utf8.count + first.utf8.count)
        XCTAssertEqual(try DecryptionCache.size(paths: paths), expected)
        XCTAssertEqual(try DecryptionCache.clear(paths: paths), expected)
        for item in [task, archive, current, download, partial, staging] { XCTAssertFalse(fm.fileExists(atPath: item.path), item.path) }
        for item in kept { XCTAssertTrue(fm.fileExists(atPath: item.path), item.path) }
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "previous")
        let results = try DecryptionCache.savedResults(paths: paths)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(try Set(results.map { try String(contentsOf: $0, encoding: .utf8) }), Set(["first-result", "second-result", "previous"]))
        XCTAssertEqual(try DecryptionCache.size(paths: paths), 0)
    }

    func testFailureToPreserveResultStopsTaskAndDownloadDeletion() throws {
        let task = paths.support.appendingPathComponent("Decryption/" + UUID().uuidString)
        let result = try write("result", to: task.appendingPathComponent("Result.ipa"))
        let helper = try write("helper", to: task.appendingPathComponent("DecryptHelper.ipa"))
        let download = try write("download", to: paths.support.appendingPathComponent("StoreDownloads/download-123.ipa"))
        try write("blocked", to: paths.exports.appendingPathComponent("Decrypted"))
        XCTAssertThrowsError(try DecryptionCache.clear(paths: paths))
        for item in [result, helper, download] { XCTAssertTrue(fm.fileExists(atPath: item.path)) }
    }

    func testCleanupRejectsLinkedCacheRootAndDoesNotFollowLinkedTask() throws {
        let outside = try write("keep", to: root.appendingPathComponent("Outside/Result.ipa"))
        let jobs = paths.support.appendingPathComponent("Decryption")
        try fm.createSymbolicLink(at: jobs, withDestinationURL: outside.deletingLastPathComponent())
        XCTAssertThrowsError(try DecryptionCache.clear(paths: paths))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
        try fm.removeItem(at: jobs)
        try fm.createDirectory(at: jobs, withIntermediateDirectories: true)
        let linkedTask = jobs.appendingPathComponent(UUID().uuidString)
        try fm.createSymbolicLink(at: linkedTask, withDestinationURL: outside.deletingLastPathComponent())
        try DecryptionCache.clear(paths: paths)
        XCTAssertFalse(fm.fileExists(atPath: linkedTask.path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    }

    @MainActor func testControllerDropsRemovedTaskAndRestoresPreservedResultAfterCleanup() throws {
        let manifest = FairPlayManifest(schemaVersion: 1, id: UUID(), name: "Target", bundleID: "test.target", appFileName: "Target.app",
                                        binaries: [.init(path: "Target", sha256: String(repeating: "0", count: 64), encryptedSlices: 1)])
        let job = paths.support.appendingPathComponent("Decryption/" + manifest.id.uuidString)
        try fm.createDirectory(at: job, withIntermediateDirectories: true)
        try write(manifest.id.uuidString, to: job.deletingLastPathComponent().appendingPathComponent("Current"))
        try JSONEncoder().encode(PreparedDecryption(manifest: manifest)).write(to: job.appendingPathComponent("Job.json"), options: .atomic)
        let controller = DecryptionController(paths: paths)
        XCTAssertEqual(controller.job?.manifest.id, manifest.id)
        controller.sourceIssue = "old issue"
        try write("result", to: job.appendingPathComponent("Result.ipa"))
        try write("helper", to: job.appendingPathComponent("DecryptHelper.ipa"))
        try DecryptionCache.clear(paths: paths)
        controller.reload()
        XCTAssertNil(controller.job)
        XCTAssertNil(controller.sourceIssue)
        let result = try XCTUnwrap(controller.result)
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "result")
        XCTAssertTrue(result.path.hasPrefix(paths.exports.path + "/Decrypted/"))
        XCTAssertEqual(DecryptionController(paths: paths).result, result)
    }
}
