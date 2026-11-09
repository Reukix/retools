import XCTest
import RetoolsNative
@testable import LiveContainerSwiftUI

final class LocalFileAccessTests: XCTestCase {
    private let containerPath = "/private/var/mobile/Containers/Data/Application/11111111-1111-4111-8111-111111111111"
    private var root: URL!
    private var container: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        container = root.appendingPathComponent("Container")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testTargetAcceptsContainerAliasesAndKeepsRelativeComponents() throws {
        let target = try LocalFileTarget(containerPath + "/Documents/存档/")
        XCTAssertEqual(target.root.path, containerPath)
        XCTAssertEqual(target.components, ["Documents", "存档"])
        XCTAssertEqual(try LocalFileTarget(String(containerPath.dropFirst(8)) + "/Documents/存档"), target)
        for prefix in ["/var/mobile/Containers/Shared/AppGroup/", "/var/mobile/Containers/Data/PluginKitPlugin/"] {
            XCTAssertNoThrow(try LocalFileTarget(prefix + "11111111-1111-4111-8111-111111111111"))
        }
    }
    func testTargetRejectsParentsTraversalInvalidUUIDAndSystemDirectories() {
        for path in ["/", "/var/mobile/Containers/Data/Application/", containerPath + "/../elsewhere", containerPath + "/./Documents",
                     containerPath + "//Documents", containerPath + "/a\0b", "/var/containers/Data/System", "/var/mobile/Containers/Data/InternalDaemon/11111111-1111-4111-8111-111111111111",
                     containerPath + "-extra", "/var/mobile/Containers/Data/Application/not-a-uuid"] {
            XCTAssertThrowsError(try LocalFileTarget(path), path)
        }
    }
    func testReaderListsHiddenFilesAndRejectsSymlinkTraversal() throws {
        let folder = container.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let contents = Data("user-owned test data".utf8)
        try contents.write(to: folder.appendingPathComponent("save.txt"))
        try contents.write(to: container.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: container.appendingPathComponent("linked-file"), withDestinationURL: folder.appendingPathComponent("save.txt"))
        try FileManager.default.createSymbolicLink(at: container.appendingPathComponent("linked-folder"), withDestinationURL: folder)
        let entries = try LocalFileReader.entries(root: container, components: [])
        XCTAssertEqual(entries.first?.name, "Documents")
        XCTAssertTrue(entries.contains { $0.name == ".hidden" && $0.kind == .file })
        XCTAssertEqual(entries.first(where: { $0.name == "linked-file" })?.kind, .symbolicLink)
        XCTAssertEqual(try LocalFileReader.read(root: container, components: ["Documents", "save.txt"]), contents)
        XCTAssertThrowsError(try LocalFileReader.read(root: container, components: ["linked-file"]))
        XCTAssertThrowsError(try LocalFileReader.read(root: container, components: ["linked-folder", "save.txt"]))
        XCTAssertThrowsError(try LocalFileReader.entries(root: container, components: ["linked-folder"]))
        XCTAssertThrowsError(try LocalFileReader.read(root: container, components: ["..", "anything"]))
        XCTAssertThrowsError(try LocalFileReader.read(root: container, components: ["Documents/save.txt"]))
    }
    func testReaderRejectsDirectoryAsFileAndBoundsSize() throws {
        try Data(repeating: 0, count: 1024).write(to: container.appendingPathComponent("file"))
        XCTAssertThrowsError(try LocalFileReader.read(root: container, components: ["file"], maximumBytes: 16))
        XCTAssertThrowsError(try LocalFileReader.read(root: container, components: []))
        let link = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: container)
        XCTAssertThrowsError(try LocalFileReader.entries(root: link, components: []))
    }
    func testServiceReleasesEveryGrantOnSuccessAndReadFailure() async throws {
        let backend = RecordingLocalAccess()
        let physical = try XCTUnwrap(container)
        let service = LocalFileAccessService(backend: backend, rootForTarget: { _ in physical })
        let entries = try await service.entries(path: containerPath, group: "test-group")
        XCTAssertTrue(entries.isEmpty)
        do { _ = try await service.read(path: containerPath + "/missing", group: "test-group"); XCTFail("Missing file accepted") } catch { }
        XCTAssertEqual(backend.events, ["acquire", "release:42", "acquire", "release:42"])
    }
    func testInvalidTargetAndFailedGrantNeverReadFiles() async throws {
        let backend = RecordingLocalAccess(fail: true)
        let physical = try XCTUnwrap(container)
        let service = LocalFileAccessService(backend: backend, rootForTarget: { _ in physical })
        do { _ = try await service.entries(path: "/", group: "test-group"); XCTFail("Root accepted") } catch { }
        XCTAssertEqual(backend.events, [])
        do { _ = try await service.entries(path: containerPath, group: "test-group"); XCTFail("Denied grant accepted") } catch { }
        XCTAssertEqual(backend.events, ["acquire"])
    }
    func testCancellationAfterAcquiringGrantStillReleasesIt() async throws {
        let backend = RecordingLocalAccess(cancel: true)
        let physical = try XCTUnwrap(container)
        let service = LocalFileAccessService(backend: backend, rootForTarget: { _ in physical })
        let path = containerPath
        let task = Task { try await service.entries(path: path, group: "test-group") }
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch is CancellationError { }
        XCTAssertEqual(backend.events, ["acquire", "release:42"])
    }
    func testExportUsesHostCopyAfterReleasingGrant() async throws {
        let contents = Data("exported test data".utf8)
        try contents.write(to: container.appendingPathComponent("sample.txt"))
        let backend = RecordingLocalAccess()
        let physical = try XCTUnwrap(container)
        let service = LocalFileAccessService(backend: backend, rootForTarget: { _ in physical })
        let file = try await service.export(path: containerPath + "/sample.txt", group: "test-group")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertTrue(file.path.hasPrefix(LocalFileAccessService.exportFolder.path + "/"))
        XCTAssertEqual(try Data(contentsOf: file), contents)
        XCTAssertEqual(try Data(contentsOf: container.appendingPathComponent("sample.txt")), contents)
        XCTAssertEqual(backend.events, ["acquire", "release:42"])
    }
    func testFailedReleaseStopsFurtherAccess() async throws {
        let backend = RecordingLocalAccess(releaseSucceeds: false)
        let physical = try XCTUnwrap(container)
        let service = LocalFileAccessService(backend: backend, rootForTarget: { _ in physical })
        for _ in 0..<2 {
            do { _ = try await service.entries(path: containerPath, group: "test-group"); XCTFail("Failed release ignored") }
            catch { XCTAssertTrue(error.localizedDescription.contains("退出 Retools")) }
        }
        XCTAssertEqual(backend.events, ["acquire", "release:42"])
    }
    func testAppContainerMetadataAndOldCacheCompatibility() throws {
        let plist: [String: Any] = ["CFBundleIdentifier": "example.app", "Container": containerPath,
                                   "GroupContainers": ["group.example": "/var/mobile/Containers/Shared/AppGroup/11111111-1111-4111-8111-111111111111"]]
        let app = try XCTUnwrap(DeviceInstalledApp.parse(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)))
        XCTAssertEqual(app.dataContainerPath, containerPath)
        XCTAssertEqual(app.groupContainerPaths?.count, 1)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as? [String: Any])
        old.removeValue(forKey: "dataContainerPath"); old.removeValue(forKey: "groupContainerPaths")
        let decoded = try JSONDecoder().decode(DeviceInstalledApp.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.dataContainerPath); XCTAssertNil(decoded.groupContainerPaths)
    }
    func testSimulatorDoesNotInvokeExploit() throws {
        #if targetEnvironment(simulator)
        XCTAssertNotNil(LocalFileAccessService.unavailableReason)
        XCTAssertThrowsError(try RTNative.acquireLocalFileAccess(containerPath, group: "test-group"))
        #endif
    }
}

private final class RecordingLocalAccess: LocalFileAccessBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let fail: Bool
    private let cancel: Bool
    private let releaseSucceeds: Bool
    var events: [String] { lock.withLock { recorded } }
    init(fail: Bool = false, cancel: Bool = false, releaseSucceeds: Bool = true) { self.fail = fail; self.cancel = cancel; self.releaseSucceeds = releaseSucceeds }
    func acquire(root: String, group: String) throws -> Int64 {
        lock.withLock { recorded.append("acquire") }
        if fail { throw WorkspaceFailure("Synthetic permission denial") }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        return 42
    }
    func release(_ handle: Int64) -> Bool { lock.withLock { recorded.append("release:\(handle)") }; return releaseSucceeds }
}
