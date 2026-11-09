import XCTest
import CryptoKit
@testable import LiveContainerSwiftUI

final class PluginTests: XCTestCase {
    private var root: URL!
    private var paths: WorkspacePaths!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        try paths.createDirectories()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func fixture(_ name: String, _ ext: String) throws -> URL { try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)) }
    func testLegacyWorkspaceRetainsDataWhenPluginFieldsAreAbsent() throws {
        var state = WorkspaceState(); state.activeIdentityID = UUID()
        var dictionary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        dictionary.removeValue(forKey: "plugins")
        let restored = try JSONDecoder().decode(WorkspaceState.self, from: JSONSerialization.data(withJSONObject: dictionary))
        XCTAssertEqual(restored.activeIdentityID, state.activeIdentityID); XCTAssertTrue(restored.plugins.isEmpty)
    }
    func testDebianXZAndGzipImportLibrariesAndResourcesWithoutControlScripts() async throws {
        for name in ["FixturePlugin", "FixturePluginGzip"] {
            let record = try PluginService.importFile(fixture(name, "deb"), paths: paths)
            let payload = paths.plugins.appendingPathComponent(record.id.uuidString + "/Payload")
            XCTAssertEqual(record.kind, .deb)
            XCTAssertEqual(record.executablePaths, ["Library/MobileSubstrate/DynamicLibraries/FixturePlugin.dylib"])
            XCTAssertEqual(try String(contentsOf: payload.appendingPathComponent("Library/Application Support/Fixture/message.txt")), "fixture resource")
            XCTAssertFalse(FileManager.default.fileExists(atPath: payload.appendingPathComponent("postinst").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: payload.appendingPathComponent("control").path))
            let binary = try XCTUnwrap(record.binaries?.first)
            XCTAssertEqual(binary.bundleFilters, ["com.retools.fixture"])
            XCTAssertEqual(binary.executableFilters, ["Fixture"])
            XCTAssertEqual(binary.installName, "@rpath/FixturePlugin.dylib")
            XCTAssertEqual(binary.minimumOS, "17.0.0")
            XCTAssertTrue(binary.dependencies.contains { $0.path == "/usr/lib/libSystem.B.dylib" && !$0.isWeak })
            XCTAssertEqual(record.resourceCount, 2)
        }
    }
    func testPerLibraryConfigurationPreservesOrderAndRejectsUnknownOrDuplicateEntries() throws {
        var record = try PluginService.importFile(fixture("FixturePlugin", "dylib"), paths: paths)
        record.executablePaths.append("Second.dylib")
        let legacy = try PluginService.configuration(nil, legacy: [record.id], plugins: [record])
        XCTAssertEqual(legacy.map(\.path), record.executablePaths)
        let onlySecond = PluginInjection(pluginID: record.id, path: "Second.dylib", loadKind: .optional)
        XCTAssertEqual(try PluginService.configuration([onlySecond], legacy: [], plugins: [record]), [onlySecond])
        XCTAssertThrowsError(try PluginService.configuration([onlySecond, onlySecond], legacy: [], plugins: [record]))
        XCTAssertThrowsError(try PluginService.configuration([PluginInjection(pluginID: record.id, path: "Missing.dylib")], legacy: [], plugins: [record]))
    }
    func testWeakSigningWritesWeakLoadCommandAndContainerMetadata() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        var state = try await service.importIPA(fixture("Fixture", "ipa"))
        state = try await service.importPlugin(fixture("FixturePlugin", "deb"))
        let plugin = try XCTUnwrap(state.plugins.first), package = try XCTUnwrap(state.packages.first)
        let entry = PluginInjection(pluginID: plugin.id, path: plugin.executablePaths[0], loadKind: .optional)
        state = try await service.setPackageInjections(package.id, entries: [entry])
        state = try await service.importIdentity(p12: fixture("PluginIdentity", "p12"), profile: fixture("PluginIdentity", "mobileprovision"), password: "test-only")
        let identity = try XCTUnwrap(state.activeIdentityID); defer { try? SecureStore.delete(id: identity) }
        state = try await service.sign(package.id, bundleID: package.bundleID)
        let output = paths.exports.appendingPathComponent(try XCTUnwrap(state.packages.first?.signedFile))
        let app = try ArchiveService.unpack(output, to: root.appendingPathComponent("WeakSigned"))
        let binary = try MachOInspector.inspect(app.appendingPathComponent("Fixture"))
        let path = "@executable_path/" + PluginService.loadPath(entry, namespace: package.id)
        XCTAssertEqual(binary.dependencies.first { $0.path == path }?.isWeak, true)
        state = try await service.installContainer(package.id)
        let container = try XCTUnwrap(state.containerApps.first)
        state = try await service.setContainerInjections(container.id, entries: [entry])
        let meta = try PropertyListSerialization.propertyList(from: Data(contentsOf: paths.applications.appendingPathComponent(container.folder + "/LCAppInfo.plist")), format: nil) as! [String: Any]
        let entries = try XCTUnwrap(meta["RetoolsPluginEntries"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["weak"] as? Bool, true)
        XCTAssertEqual(state.containerApps.first?.pluginInjections, [entry])
    }
    func testUnsafeDebianPathsAndSymlinksLeavePluginLibraryEmpty() async throws {
        for name in ["UnsafePlugin", "SymlinkPlugin"] {
            XCTAssertThrowsError(try PluginService.importFile(fixture(name, "deb"), paths: paths))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.plugins.path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.dylib").path))
    }
    func testRejectsExecutableRenamedAsDylib() throws {
        let app = try ArchiveService.unpack(fixture("Fixture", "ipa"), to: root.appendingPathComponent("original"))
        let fake = root.appendingPathComponent("fake.dylib")
        try FileManager.default.copyItem(at: app.appendingPathComponent("Fixture"), to: fake)
        XCTAssertThrowsError(try PluginService.importFile(fake, paths: paths))
    }
    func testPluginMaterializationIsCachedAndDoesNotChangeSource() throws {
        let record = try PluginService.importFile(fixture("FixturePlugin", "deb"), paths: paths)
        let source = paths.plugins.appendingPathComponent(record.id.uuidString + "/Payload/" + record.executablePaths[0])
        let original = try Data(contentsOf: source)
        let app = root.appendingPathComponent("Target.app"), id = UUID()
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let first = try PluginService.materialize([record], in: app, namespace: id, paths: paths)
        XCTAssertTrue(first.changed)
        let second = try PluginService.materialize([record], in: app, namespace: id, paths: paths)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let removed = try PluginService.materialize([], in: app, namespace: id, paths: paths)
        XCTAssertTrue(removed.changed); XCTAssertTrue(removed.libraries.isEmpty)
    }
    func testSigningInjectsRealLoadCommandAndSignedPluginIntoCopy() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        var state = try await service.importIPA(fixture("Fixture", "ipa"))
        let package = try XCTUnwrap(state.packages.first)
        let original = try Data(contentsOf: paths.library.appendingPathComponent(package.fileName))
        state = try await service.importPlugin(fixture("FixturePlugin", "deb"))
        let plugin = try XCTUnwrap(state.plugins.first)
        state = try await service.setPackagePlugins(package.id, plugins: [plugin.id])
        state = try await service.importIdentity(p12: fixture("PluginIdentity", "p12"), profile: fixture("PluginIdentity", "mobileprovision"), password: "test-only")
        let identity = try XCTUnwrap(state.activeIdentityID); defer { try? SecureStore.delete(id: identity) }
        state = try await service.sign(package.id, bundleID: package.bundleID)
        let output = paths.exports.appendingPathComponent(try XCTUnwrap(state.packages.first?.signedFile))
        let app = try ArchiveService.unpack(output, to: root.appendingPathComponent("Signed"))
        let executable = try Data(contentsOf: app.appendingPathComponent("Fixture"))
        let relative = try XCTUnwrap(PluginService.loadPaths([plugin], namespace: package.id).first)
        XCTAssertTrue(executable.range(of: Data(("@executable_path/" + relative).utf8)) != nil)
        let dylib = try Data(contentsOf: app.appendingPathComponent(relative))
        XCTAssertTrue(dylib.range(of: Data("TESTTEAM01".utf8)) != nil)
        XCTAssertEqual(try Data(contentsOf: paths.library.appendingPathComponent(package.fileName)), original)
        let inspection = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PluginValidation")
        try FileManager.default.createDirectory(at: inspection, withIntermediateDirectories: true)
        let copy = inspection.appendingPathComponent("Injected.ipa"); try? FileManager.default.removeItem(at: copy); try FileManager.default.copyItem(at: output, to: copy)
    }
    func testPluginInUseCannotBeDeletedAndContainerConfigurationPersists() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        var state = try await service.importIPA(fixture("Fixture", "ipa"))
        state = try await service.installContainer(try XCTUnwrap(state.packages.first?.id))
        state = try await service.importPlugin(fixture("FixturePlugin", "dylib"))
        let plugin = try XCTUnwrap(state.plugins.first), app = try XCTUnwrap(state.containerApps.first)
        state = try await service.setContainerPlugins(app.id, plugins: [plugin.id])
        let metadata = try PropertyListSerialization.propertyList(from: Data(contentsOf: paths.applications.appendingPathComponent(app.folder + "/LCAppInfo.plist")), format: nil) as! [String: Any]
        XCTAssertEqual((metadata["RetoolsPluginPaths"] as? [String])?.count, 1)
        do { _ = try await service.deletePlugin(plugin.id); XCTFail("Plugin in use was deleted") } catch {}
        state = try await service.setContainerPlugins(app.id, plugins: [])
        state = try await service.deletePlugin(plugin.id)
        XCTAssertTrue(state.plugins.isEmpty)
    }
}
