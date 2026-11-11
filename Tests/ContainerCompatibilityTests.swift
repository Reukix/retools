import XCTest
import RetoolsNative
@testable import LiveContainerSwiftUI

final class ContainerCompatibilityTests: XCTestCase {
    private var root: URL!
    private var paths: WorkspacePaths!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        try paths.createDirectories()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func fixture(_ name: String, _ ext: String) throws -> URL { try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext)) }
    private func installed() async throws -> (WorkspaceService, ContainerApp) {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        var state = try await service.importIPA(fixture("Fixture", "ipa"))
        state = try await service.installContainer(try XCTUnwrap(state.packages.first?.id))
        return (service, try XCTUnwrap(state.containerApps.first))
    }
    private func plist(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }
    private func addFixtureDependency(_ path: String, to file: URL) throws {
        var data = try Data(contentsOf: file)
        func word(_ offset: Int) -> UInt32 { data[offset..<offset+4].enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) } }
        func set(_ value: UInt32, at offset: Int) { for i in 0..<4 { data[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) } }
        let count = word(16), size = word(20), offset = 32 + Int(size), bytes = Array(path.utf8) + [0]
        let length = (24 + bytes.count + 7) & ~7
        guard offset + length < data.count, data[offset..<offset+length].allSatisfy({ $0 == 0 }) else { throw WorkspaceFailure("Fixture has no header padding") }
        set(0xc, at: offset); set(UInt32(length), at: offset+4); set(24, at: offset+8)
        data.replaceSubrange(offset+24..<offset+24+bytes.count, with: bytes)
        set(count+1, at: 16); set(size+UInt32(length), at: 20)
        try data.write(to: file)
    }
    func testOlderShortLoaderPlaceholderCanBeEnabledWithoutCorruptingCommands() throws {
        let app = try ArchiveService.unpack(fixture("Fixture", "ipa"), to: root.appendingPathComponent("OldImport"))
        try RTNative.prepareContainer(app.path)
        let file = app.appendingPathComponent("Fixture")
        var data = try Data(contentsOf: file)
        func word(_ offset: Int) -> UInt32 { data[offset..<offset+4].enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) } }
        func set(_ value: UInt32, at offset: Int) { for i in 0..<4 { data[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) } }
        let size = Int(word(20)), end = 32 + size
        var cursor = 32, found = false
        for _ in 0..<word(16) {
            let length = Int(word(cursor+4))
            if word(cursor) == 0x114514 {
                XCTAssertEqual(length, 72)
                let tail = Data(data[cursor+72..<end])
                data.replaceSubrange(cursor+56..<end-16, with: tail)
                data.replaceSubrange(end-16..<end, with: Data(repeating: 0, count: 16))
                set(56, at: cursor+4); set(UInt32(size-16), at: 20); found = true; break
            }
            cursor += length
        }
        XCTAssertTrue(found)
        try data.write(to: file)
        XCTAssertNoThrow(try MachOInspector.inspect(file))
        _ = try RTNative.configureContainer(app.path, injectTweakLoader: true)
        XCTAssertTrue(try MachOInspector.inspect(file).dependencies.contains { $0.path == "@loader_path/../../Tweaks/TweakLoader.dylib" })
    }
    func testLoaderModesPatchExecutableAndPersistCompatibilityOptions() async throws {
        let (service, app) = try await installed()
        let directory = paths.applications.appendingPathComponent(app.folder), executable = directory.appendingPathComponent("Fixture")
        let marker = paths.data.appendingPathComponent(app.selectedContainerID.uuidString + "/Documents/keep.txt")
        try Data("keep app data".utf8).write(to: marker)
        var options = ContainerRuntimeOptions()
        for mode in [ContainerLoaderMode.injected, .delayed, .disabled, .injected] {
            options.loaderMode = mode
            options.spoofSDKVersion = mode == .injected
            options.hideLiveContainer = true; options.fixFilePicker = true; options.fixLocalNotification = true
            options.language = "zh-Hans"; options.orientation = .landscape; options.legacyFilePicker = true
            options.useHostBundleID = mode == .delayed; options.remark = "容器兼容回归"
            let state = try await service.setContainerRuntimeOptions(app.id, options: options)
            XCTAssertEqual(state.containerApps.first?.runtimeOptions, options)
            let binary = try MachOInspector.inspect(executable)
            XCTAssertEqual(binary.dependencies.contains { $0.path.hasSuffix("/TweakLoader.dylib") }, mode.injects)
            let info = try plist(directory.appendingPathComponent("LCAppInfo.plist"))
            XCTAssertEqual(info["dontInjectTweakLoader"] as? Bool, !mode.injects)
            XCTAssertEqual(info["dontLoadTweakLoader"] as? Bool, !mode.loads)
            XCTAssertEqual(info["fixFilePickerNew"] as? Bool, true)
            XCTAssertEqual(info["LCSelectedLanguage"] as? String, "zh-Hans")
            XCTAssertEqual(info["LCOrientationLock"] as? Int, 1)
            XCTAssertEqual(info["spoofSDKVersion"] != nil, options.spoofSDKVersion)
            XCTAssertEqual(try plist(directory.appendingPathComponent("Info.plist"))["CFBundleIdentifier"] as? String, options.useHostBundleID ? Bundle.main.bundleIdentifier : app.bundleID)
            XCTAssertEqual(try String(contentsOf: marker), "keep app data")
            let saved = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: paths.state))
            XCTAssertEqual(saved.containerApps.first?.runtimeOptions, options)
        }
    }
    func testInvalidOptionsLeaveBinaryMetadataAndStateUnchanged() async throws {
        let (service, app) = try await installed()
        let directory = paths.applications.appendingPathComponent(app.folder)
        let binary = try Data(contentsOf: directory.appendingPathComponent("Fixture")), metadata = try Data(contentsOf: directory.appendingPathComponent("LCAppInfo.plist")), state = try Data(contentsOf: paths.state)
        var options = ContainerRuntimeOptions(); options.loaderMode = .disabled; options.tweakFolder = "../escape"
        do { _ = try await service.setContainerRuntimeOptions(app.id, options: options); XCTFail("Unsafe folder was accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Fixture")), binary)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("LCAppInfo.plist")), metadata)
        XCTAssertEqual(try Data(contentsOf: paths.state), state)
    }
    func testMetadataMigrationInvalidatesSigningCacheBeforeSpaceOperations() async throws {
        for operation in 0..<3 {
            let (original, app) = try await installed()
            var state = try await original.reload()
            state.containerApps[0].signedFingerprint = "cached-signature"
            state.containerApps[0].signedRuntimeRevision = WorkspaceService.containerSigningRevision
            let directory = paths.applications.appendingPathComponent(app.folder)
            let metadata = directory.appendingPathComponent("LCAppInfo.plist")
            var info = try plist(metadata); info.removeValue(forKey: "RetoolsRuntimeRevision")
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: metadata)
            let service = WorkspaceService(paths: paths, state: state)
            switch operation {
            case 0: state = try await service.selectContainer(appID: app.id, containerID: app.selectedContainerID)
            case 1: state = try await service.addContainer(to: app.id, name: "新增空间")
            default: state = try await service.setContainerDataOptions(app.id, containerID: app.selectedContainerID, name: "空间设置", options: ContainerDataOptions())
            }
            XCTAssertNil(state.containerApps.first?.signedFingerprint)
            XCTAssertEqual(try plist(metadata)["RetoolsRuntimeRevision"] as? Int, 1)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".retools-patch-") })
        }
    }
    func testFailedNativePatchLeavesOriginalExecutableAndInodeUntouched() throws {
        let app = try ArchiveService.unpack(fixture("Fixture", "ipa"), to: root.appendingPathComponent("Unsupported"))
        let file = app.appendingPathComponent("Fixture")
        var bytes = try Data(contentsOf: file)
        let cpu: UInt32 = 0x01000007
        for i in 0..<4 { bytes[4+i] = UInt8(truncatingIfNeeded: cpu >> (i*8)) }
        try bytes.write(to: file)
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        XCTAssertThrowsError(try RTNative.configureContainer(app.path, injectTweakLoader: true))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber, inode)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: app.path).contains { $0.hasPrefix(".retools-patch-") })
    }
    func testDataOptionsUpdateOneSpaceWithoutChangingItsFilesOrOtherSpaces() async throws {
        let (service, app) = try await installed()
        var state = try await service.addContainer(to: app.id, name: "第二空间")
        let second = try XCTUnwrap(state.containerApps.first?.containers.last)
        let secondMetadata = paths.data.appendingPathComponent(second.folderName + "/LCContainerInfo.plist")
        let original = try Data(contentsOf: secondMetadata)
        let marker = paths.data.appendingPathComponent(app.selectedContainerID.uuidString + "/Documents/keep.txt")
        try Data("keep".utf8).write(to: marker)
        var options = ContainerDataOptions(); options.isolateAppGroup = false; options.spoofIdentifierForVendor = false; options.identifierForVendor = UUID()
        state = try await service.setContainerDataOptions(app.id, containerID: app.selectedContainerID, name: "独立空间", options: options)
        let metadata = try plist(paths.data.appendingPathComponent(app.selectedContainerID.uuidString + "/LCContainerInfo.plist"))
        XCTAssertEqual(metadata["isolateAppGroup"] as? Bool, false)
        XCTAssertEqual(metadata["spoofIdentifierForVendor"] as? Bool, false)
        XCTAssertEqual(metadata["spoofedIdentifierForVendor"] as? String, options.identifierForVendor?.uuidString)
        XCTAssertEqual(state.containerApps.first?.containers.first?.name, "独立空间")
        XCTAssertEqual(try Data(contentsOf: secondMetadata), original)
        XCTAssertEqual(try String(contentsOf: marker), "keep")
    }
    func testOlderSettingsUseCompatibleDefaultsAndPerAppLaunchMode() throws {
        let options = try JSONDecoder().decode(ContainerRuntimeOptions.self, from: Data("{}".utf8))
        XCTAssertTrue(options.spoofSDKVersion); XCTAssertEqual(options.loaderMode, .injected)
        XCTAssertEqual(ContainerLaunchMode.global.resolve(.jitless), .jitless)
        XCTAssertEqual(ContainerLaunchMode.jit.resolve(.jitless), .jit)
        XCTAssertEqual(ContainerLaunchMode.jitless.resolve(.jit), .jitless)
    }
    func testImportedIPAListsExistingDebLibrariesAndPreservesOriginalPackage() async throws {
        let app = try ArchiveService.unpack(fixture("Fixture", "ipa"), to: root.appendingPathComponent("Unpacked"))
        let plugin = try PluginService.importFile(fixture("FixturePlugin", "deb"), paths: paths)
        let namespace = UUID()
        let materialized = try PluginService.materialize([plugin], in: app, namespace: namespace, paths: paths)
        let relative = try XCTUnwrap(materialized.libraries.first)
        var result = try EmbeddedLibraryInspector.inspect(app: app)
        XCTAssertEqual(result.first { $0.path == relative }?.linkedBy, [])
        try RTNative.injectLibraries(["@executable_path/" + relative], weak: [true], intoExecutable: app.appendingPathComponent("Fixture").path)
        let ipa = root.appendingPathComponent("AlreadyInjected.ipa"); try ArchiveService.pack(app: app, to: ipa)
        let original = try Data(contentsOf: ipa)
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        let state = try await service.importIPA(ipa), package = try XCTUnwrap(state.packages.first)
        result = try await service.embeddedLibraries(for: .package(package.id))
        let library = try XCTUnwrap(result.first { $0.path == relative })
        XCTAssertTrue(library.isPresent); XCTAssertGreaterThan(library.byteCount, 0)
        XCTAssertEqual(library.linkedBy, ["Fixture"]); XCTAssertEqual(library.weakLinkedBy, ["Fixture"])
        XCTAssertEqual(package.embeddedLibraries, result)
        XCTAssertEqual(try Data(contentsOf: ipa), original)
        XCTAssertEqual(try Data(contentsOf: paths.library.appendingPathComponent(package.fileName)), original)
        XCTAssertTrue(package.pluginIDs?.isEmpty ?? true)
    }
    func testInventoryRecognizesTransitiveFrameworkLinksAndMissingDependencies() throws {
        let app = try ArchiveService.unpack(fixture("Fixture", "ipa"), to: root.appendingPathComponent("Unpacked"))
        try RTNative.prepareContainer(app.path)
        let framework = app.appendingPathComponent("Frameworks/Injected.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let library = framework.appendingPathComponent("Injected")
        try FileManager.default.copyItem(at: app.appendingPathComponent("Fixture"), to: library)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.injected", "CFBundleExecutable": "Injected"], format: .binary, options: 0).write(to: framework.appendingPathComponent("Info.plist"))
        let helper = app.appendingPathComponent("Frameworks/Helper.dylib")
        try FileManager.default.copyItem(at: fixture("FixturePlugin", "dylib"), to: helper)
        try addFixtureDependency("@loader_path/../Helper.dylib", to: library)
        try addFixtureDependency("@rpath/Injected.framework/Injected", to: app.appendingPathComponent("Fixture"))
        try addFixtureDependency("@executable_path/Missing.dylib", to: app.appendingPathComponent("Fixture"))
        let inventory = try EmbeddedLibraryInspector.inspect(app: app)
        XCTAssertEqual(inventory.first { $0.path == "Frameworks/Injected.framework/Injected" }?.isFramework, true)
        XCTAssertEqual(inventory.first { $0.path == "Frameworks/Helper.dylib" }?.linkedBy, ["Frameworks/Injected.framework/Injected"])
        XCTAssertEqual(inventory.first { $0.path == "Missing.dylib" }?.isPresent, false)
        XCTAssertFalse(inventory.contains { $0.path.hasPrefix("/usr/lib/") })
    }
    func testInventoryReadsLoaderManifestWithoutFollowingUnsafeOrOversizedEntries() throws {
        let app = try ArchiveService.unpack(fixture("Fixture", "ipa"), to: root.appendingPathComponent("ManifestApp"))
        let plugin = try PluginService.importFile(fixture("FixturePlugin", "dylib"), paths: paths)
        let namespace = UUID()
        let materialized = try PluginService.materialize([plugin], in: app, namespace: namespace, paths: paths)
        let relative = try XCTUnwrap(materialized.libraries.first)
        let owner = "Frameworks/RetoolsPlugins-\(namespace.uuidString)/RetoolsPluginLoader.dylib"
        try FileManager.default.copyItem(at: fixture("FixturePlugin", "dylib"), to: app.appendingPathComponent(owner))
        let manifest = app.appendingPathComponent("Frameworks/RetoolsPlugins-\(namespace.uuidString)/RetoolsPlugins.json")
        var bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "entries": [["path": relative, "optional": true], ["path": "../escape.dylib", "optional": false]]])
        try bytes.write(to: manifest)
        var inventory = try EmbeddedLibraryInspector.inspect(app: app)
        XCTAssertEqual(inventory.first { $0.path == relative }?.weakLinkedBy, [owner])
        XCTAssertFalse(inventory.contains { $0.path.contains("escape") })
        bytes.append(Data(repeating: 32, count: 1_048_576))
        try bytes.write(to: manifest)
        inventory = try EmbeddedLibraryInspector.inspect(app: app)
        XCTAssertEqual(inventory.first { $0.path == relative }?.linkedBy, [])
    }
}
