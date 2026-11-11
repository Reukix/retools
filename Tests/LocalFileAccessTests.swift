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
    func testTargetRejectsParentsTraversalInvalidUUIDAndUnrelatedDirectories() {
        for path in ["/", "/var/mobile/Containers/Data/Application/", containerPath + "/../elsewhere", containerPath + "/./Documents",
                     containerPath + "//Documents", containerPath + "/a\0b", "/var/containers/Data/SystemOther", "/var/mobile/Containers/Data/InternalDaemon/not-a-uuid",
                     containerPath + "-extra", "/var/mobile/Containers/Data/Application/not-a-uuid"] {
            XCTAssertThrowsError(try LocalFileTarget(path), path)
        }
    }
    func testWQContainerCategoriesStayInsideTheirDocumentedRoots() throws {
        let daemon = try LocalFileTarget("/var/mobile/Containers/Data/InternalDaemon/11111111-1111-4111-8111-111111111111/Library")
        XCTAssertEqual(LocalFileArea.of(daemon), .daemon)
        let system = try LocalFileTarget("/var/containers/Data/System/Library")
        XCTAssertEqual(system.root.path, "/private/var/containers/Data/System")
        XCTAssertEqual(system.components, ["Library"])
        let group = try LocalFileTarget("/var/containers/Shared/SystemGroup/systemgroup.com.apple.osanalytics/Library/Logs")
        XCTAssertEqual(LocalFileArea.of(group), .systemGroup)
        XCTAssertEqual(group.components, ["Library", "Logs"])
        for path in ["/var/containers/Shared/SystemGroup/not-a-group", "/var/containers/Shared/SystemGroup/systemgroup.",
                     "/var/containers/Data/System/../Shared", "/var/containers/Shared/SystemGroup/systemgroup.com.apple.test/../elsewhere"] {
            XCTAssertThrowsError(try LocalFileTarget(path), path)
        }
    }

    func testAppGroupParentSupportsAliasesAndKeepsUUIDAccessSeparate() throws {
        let parent = try LocalFileTarget("/var/mobile/Containers/Shared/AppGroup/")
        XCTAssertEqual(parent.root.path, "/private/var/mobile/Containers/Shared/AppGroup")
        XCTAssertTrue(parent.components.isEmpty)
        XCTAssertEqual(try LocalFileTarget(parent.root.path), parent)
        XCTAssertEqual(LocalFileArea.of(parent), .appGroup)

        let child = try LocalFileTarget(parent.path + "/11111111-1111-4111-8111-111111111111/Library")
        XCTAssertEqual(child.root.path, parent.path + "/11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(child.components, ["Library"])
        let metadata = try LocalFileTarget(parent.path + "/.metadata")
        XCTAssertEqual(metadata.root, parent.root)
        XCTAssertEqual(metadata.components, [".metadata"])
        for path in [parent.path + "/../elsewhere", parent.path + "/./Library", parent.path + "//Library",
                     parent.path + "Other", "/var/mobile/Containers/Shared"] {
            XCTAssertThrowsError(try LocalFileTarget(path), path)
        }
    }

    func testAppGroupParentListingAndChildReadReleaseTheirOwnGrants() async throws {
        let uuid = "11111111-1111-4111-8111-111111111111"
        let physical = try XCTUnwrap(container)
        try FileManager.default.createDirectory(at: physical.appendingPathComponent(uuid), withIntermediateDirectories: true)
        let contents = Data("group data".utf8)
        try contents.write(to: physical.appendingPathComponent(uuid + "/data.txt"))
        try Data("metadata".utf8).write(to: physical.appendingPathComponent(".metadata"))
        let backend = RecordingLocalAccess()
        let service = LocalFileAccessService(backend: backend, rootForTarget: {
            $0.root.path == LocalFileTarget.appGroupParent ? physical : physical.appendingPathComponent(uuid)
        })
        let parent = "/var/mobile/Containers/Shared/AppGroup"
        let entries = try await service.entries(path: parent, group: "test-group")
        XCTAssertEqual(Set(entries.map(\.name)), Set([uuid, ".metadata"]))
        let data = try await service.read(path: parent + "/" + uuid + "/data.txt", group: "test-group")
        XCTAssertEqual(data, contents)
        let metadata = try await service.read(path: parent + "/.metadata", group: "test-group")
        XCTAssertEqual(metadata, Data("metadata".utf8))
        XCTAssertEqual(backend.acquiredRoots, ["/private" + parent, "/private" + parent + "/" + uuid, "/private" + parent])
        XCTAssertEqual(backend.events, ["acquire", "release:42", "acquire", "release:42", "acquire", "release:42"])
    }

    @MainActor
    func testLocalCatalogNormalizesDeduplicatesAndKeepsKnownNames() throws {
        let catalog = LocalFileCatalog(cache: root.appendingPathComponent("catalog.json"))
        let named = try XCTUnwrap(LocalFileContainer.parse(["path": containerPath, "name": "示例应用", "identifier": "example.app"]))
        let alias = try XCTUnwrap(LocalFileContainer.parse(["path": String(containerPath.dropFirst(8))]))
        catalog.merge([named, alias])
        XCTAssertEqual(catalog.containers.count, 1)
        XCTAssertEqual(catalog.containers.first?.title, "示例应用")
        XCTAssertNil(LocalFileContainer.parse(["path": containerPath + "/Documents"]))
        XCTAssertNil(LocalFileContainer.parse(["path": "/var/containers/Bundle/Application/unsafe.app"]))
        let restored = LocalFileCatalog(cache: root.appendingPathComponent("catalog.json"))
        XCTAssertEqual(restored.containers, catalog.containers)
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
    private var roots: [String] = []
    private let fail: Bool
    private let cancel: Bool
    private let releaseSucceeds: Bool
    var events: [String] { lock.withLock { recorded } }
    var acquiredRoots: [String] { lock.withLock { roots } }
    init(fail: Bool = false, cancel: Bool = false, releaseSucceeds: Bool = true) { self.fail = fail; self.cancel = cancel; self.releaseSucceeds = releaseSucceeds }
    func acquire(root: String, group: String) throws -> Int64 {
        lock.withLock { recorded.append("acquire"); roots.append(root) }
        if fail { throw WorkspaceFailure("Synthetic permission denial") }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        return 42
    }
    func release(_ handle: Int64) -> Bool { lock.withLock { recorded.append("release:\(handle)") }; return releaseSucceeds }
}
