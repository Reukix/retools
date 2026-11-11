import XCTest
@testable import LiveContainerSwiftUI

final class InjectedPluginDetectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func words(_ values: [UInt32]) -> Data {
        Data(values.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } })
    }
    private func dependency(_ path: String, weak: Bool = false) -> Data {
        let name = Data(path.utf8) + Data([0])
        let size = (24 + name.count + 7) & ~7
        return words([weak ? 0x80000018 : 0xc, UInt32(size), 24, 2, 0, 0]) + name + Data(repeating: 0, count: size - 24 - name.count)
    }
    private func binary(native: [String] = [], injected: [String] = [], dylib: Bool = false) -> Data {
        var commands = words([0x32, 24, 2, 0x000f0000, 0x001a0000, 0])
        for path in native { commands.append(dependency(path)) }
        commands.append(words([0x26, 16, 0, 0]))
        for path in injected { commands.append(dependency(path)) }
        // A subsequent re-sign can put CODE_SIGNATURE after the injected items.
        commands.append(words([0x1d, 16, 0, 0]))
        return words([0xfeedfacf, 0x0100000c, 0, dylib ? 6 : 2, UInt32(3 + native.count + injected.count), UInt32(commands.count), 0, 0]) + commands
    }
    private func app(native: [String], injected: [String] = []) throws -> URL {
        let app = root.appendingPathComponent(UUID().uuidString + ".app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Telegram", "CFBundleIdentifier": "org.telegram.Telegram"], format: .binary, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try binary(native: native, injected: injected).write(to: app.appendingPathComponent("Telegram"))
        return app
    }
    private func library(_ path: String, in app: URL, native: [String] = []) throws {
        let file = app.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try binary(native: native, dylib: true).write(to: file)
        if file.deletingLastPathComponent().pathExtension == "framework" {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": file.lastPathComponent, "CFBundleIdentifier": "native." + file.lastPathComponent], format: .binary, options: 0).write(to: file.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        }
    }
    func testNativeFrameworksAndNativeDylibsAreNotPlugins() throws {
        let names = ["AAASSOptimizer", "boringssl", "TelegramCore", "Postbox"]
        let app = try app(native: names.map { "@rpath/\($0).framework/\($0)" } + ["@executable_path/Frameworks/libCustom.dylib"])
        for name in names { try library("Frameworks/\(name).framework/\(name)", in: app) }
        try library("Frameworks/libCustom.dylib", in: app)
        let result = try EmbeddedLibraryInspector.inspect(app: app)
        XCTAssertEqual(result.count, 5)
        XCTAssertTrue(result.filter(\.isInjectedPlugin).isEmpty)
    }
    func testTelegramWithLeadOnlyShowsLeadAsPluginIncludingFrameworkInjection() throws {
        for leadPath in ["Frameworks/Lead.dylib", "Frameworks/Lead.framework/Lead"] {
            let app = try app(native: ["@rpath/TelegramCore.framework/TelegramCore", "@executable_path/Frameworks/boringssl.framework/boringssl"], injected: ["@executable_path/" + leadPath])
            try library("Frameworks/TelegramCore.framework/TelegramCore", in: app)
            try library("Frameworks/boringssl.framework/boringssl", in: app)
            try library(leadPath, in: app)
            let result = try EmbeddedLibraryInspector.inspect(app: app)
            XCTAssertEqual(result.filter(\.isInjectedPlugin).map(\.path), [leadPath])
            XCTAssertEqual(result.first { $0.path == leadPath }?.pluginEvidence, [.appendedLoadCommand])
        }
    }
    func testLoadControlManagedPluginsExcludeRuntimeAndNativeDependencies() throws {
        let app = try app(native: ["@rpath/TelegramCore.framework/TelegramCore", "@executable_path/Frameworks/libNative.dylib"], injected: ["@executable_path/Frameworks/LoadControl.dylib"])
        try library("Frameworks/TelegramCore.framework/TelegramCore", in: app)
        try library("Frameworks/libNative.dylib", in: app)
        try library("Frameworks/LoadControl.dylib", in: app, native: ["@loader_path/libsubstrate.dylib"])
        try library("Frameworks/libsubstrate.dylib", in: app)
        try library("Frameworks/Lead.dylib", in: app, native: ["@loader_path/LeadHelper.dylib"])
        try library("Frameworks/LeadHelper.dylib", in: app)
        try library("Frameworks/libswiftCore.dylib", in: app)
        let result = try EmbeddedLibraryInspector.inspect(app: app)
        XCTAssertEqual(result.filter(\.isInjectedPlugin).map(\.path), ["Frameworks/Lead.dylib"])
    }
    func testUnlinkedFilesDoNotBecomePluginsWithoutLoaderEvidence() throws {
        let app = try app(native: [])
        try library("Frameworks/Unused.dylib", in: app)
        let result = try EmbeddedLibraryInspector.inspect(app: app)
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].isInjectedPlugin)
    }
    func testSymbolicAppRootProducesCanonicalBundleRelativePaths() throws {
        let app = try app(native: [], injected: ["@executable_path/Frameworks/Lead.dylib"])
        try library("Frameworks/Lead.dylib", in: app)
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        XCTAssertEqual(try EmbeddedLibraryInspector.inspect(app: alias).map(\.path), ["Frameworks/Lead.dylib"])
    }
    func testLegacyInventoryIsRebuiltAndCachedWithoutChangingIPA() async throws {
        let app = try app(native: ["@rpath/Postbox.framework/Postbox"], injected: ["@executable_path/Frameworks/Lead.dylib"])
        try library("Frameworks/Postbox.framework/Postbox", in: app)
        try library("Frameworks/Lead.dylib", in: app)
        let ipa = root.appendingPathComponent("LeadTelegram.ipa")
        try ArchiveService.pack(app: app, to: ipa)
        let bytes = try Data(contentsOf: ipa)
        let paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support")); try paths.createDirectories()
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        var state = try await service.importIPA(ipa)
        let id = try XCTUnwrap(state.packages.first?.id)
        state.packages[0].embeddedLibraries = []; state.packages[0].embeddedLibraryInspectionVersion = nil
        let legacy = WorkspaceService(paths: paths, state: state)
        let result = try await legacy.embeddedLibraries(for: .package(id))
        XCTAssertEqual(result.filter(\.isInjectedPlugin).map(\.name), ["Lead.dylib"])
        let persisted = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: paths.state))
        XCTAssertEqual(persisted.packages.first?.embeddedLibraryInspectionVersion, EmbeddedLibraryInspector.version)
        XCTAssertEqual(try Data(contentsOf: ipa), bytes)
        XCTAssertEqual(try Data(contentsOf: paths.library.appendingPathComponent(state.packages[0].fileName)), bytes)
    }
    func testActualReadingArchiveWhenProvided() throws {
        let ipa = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PluginDetectionReading.ipa")
        guard FileManager.default.fileExists(atPath: ipa.path) else { throw XCTSkip("Optional private device archive is not bundled with tests") }
        let app = try ArchiveService.unpack(ipa, to: root.appendingPathComponent("Actual"))
        let result = try EmbeddedLibraryInspector.inspect(app: app)
        XCTAssertEqual(Set(result.filter(\.isInjectedPlugin).map(\.name)), ["120hz.dylib", "fanqiefn.dylib", "FanqieX-1.6.2.dylib"])
        XCTAssertFalse(result.contains { $0.path.hasPrefix("ing.app/") })
        XCTAssertFalse(result.first { $0.name == "AAASSOptimizer" }?.isInjectedPlugin ?? true)
        XCTAssertTrue(result.first { $0.name == "LoadControl.dylib" }?.isInjectionSupport ?? false)
    }
}
