import XCTest
@testable import LiveContainerSwiftUI

final class DeviceFileAccessTests: XCTestCase {
    private let container = "/var/mobile/Containers/Data/Application/11111111-1111-4111-8111-111111111111"
    private func app(_ extra: [String: Any] = [:]) throws -> DeviceInstalledApp {
        var plist: [String: Any] = ["CFBundleIdentifier": "example.app", "Container": container]
        plist.merge(extra) { _, new in new }
        return try XCTUnwrap(DeviceInstalledApp.parse(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)))
    }
    func testManualLocalDirectoryUsesValidatedRootAndPreservesNestedPath() throws {
        let input = try LocalFileTarget(container + "/Documents/Saves")
        let app = DeviceFileAccess.localApp(for: input)
        let target = try DeviceFileAccess.target(for: app, path: "/" + input.components.joined(separator: "/"))
        XCTAssertEqual(target, input)
        XCTAssertFalse(app.filesAccessible, "本机入口不应伪造配对服务的文件权限")
    }
    func testRelativeBrowserPathsStayInsideSelectedAppContainer() throws {
        let app = try app()
        XCTAssertEqual(try DeviceFileAccess.target(for: app, path: "/").components, [])
        let target = try DeviceFileAccess.target(for: app, path: "/Documents/save.txt")
        XCTAssertEqual(target.root.path, "/private" + container)
        XCTAssertEqual(target.components, ["Documents", "save.txt"])
        for path in ["Documents/file", "/../file", "/Documents//file", "/Documents/../../file"] {
            XCTAssertThrowsError(try DeviceFileAccess.target(for: app, path: path), path)
        }
        var missing = app; missing.dataContainerPath = nil
        XCTAssertThrowsError(try DeviceFileAccess.target(for: missing, path: "/"))
        var nested = app; nested.dataContainerPath = container + "/Documents"
        XCTAssertThrowsError(try DeviceFileAccess.target(for: nested, path: "/"))
    }
    func testSharedDataUsesItsOwnContainerAndFiltersInvalidRoots() throws {
        let group = "/var/mobile/Containers/Shared/AppGroup/22222222-2222-4222-8222-222222222222"
        let app = try app(["GroupContainers": ["group.example": group, "group.alias": "/private" + group,
                                               "group.invalid": "/var/containers/Data/System", "group.nested": group + "/Library",
                                               "group.parent": "/var/mobile/Containers/Shared/AppGroup"]])
        let roots = DeviceFileAccess.sharedRoots(for: app)
        XCTAssertEqual(roots.count, 1)
        let target = try DeviceFileAccess.target(for: app, path: "/data.json", root: roots.first)
        XCTAssertEqual(target.root.path, "/private" + group)
        XCTAssertEqual(target.components, ["data.json"])
    }
    func testAppGroupParentBrowserCanOpenAChildContainerAndParentMetadata() throws {
        let parent = try LocalFileTarget("/var/mobile/Containers/Shared/AppGroup")
        let app = DeviceFileAccess.localApp(for: parent)
        XCTAssertEqual(try DeviceFileAccess.target(for: app, path: "/"), parent)
        let child = try DeviceFileAccess.target(for: app, path: "/22222222-2222-4222-8222-222222222222/Documents")
        XCTAssertEqual(child.root.path, parent.path + "/22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(child.components, ["Documents"])
        let metadata = try DeviceFileAccess.target(for: app, path: "/.metadata")
        XCTAssertEqual(metadata.root, parent.root)
        XCTAssertEqual(metadata.components, [".metadata"])
        XCTAssertThrowsError(try DeviceFileAccess.target(for: app, path: "/../elsewhere"))
    }
    func testLocalRowsReuseBrowserPathsSizeAndModificationDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let file = DeviceFileAccess.item(LocalFileEntry(name: "存档.txt", kind: .file, bytes: 42, modified: date), in: "/Documents")
        XCTAssertEqual(file.path, "/Documents/存档.txt")
        XCTAssertEqual(file.name, "存档.txt")
        XCTAssertEqual(file.size, 42)
        XCTAssertEqual(file.modified, date)
        XCTAssertFalse(file.isDirectory)
    }
}
