import XCTest
import RetoolsNative
import CryptoKit
@testable import LiveContainerSwiftUI

final class WorkspaceTests: XCTestCase {
    private var root: URL!
    private var paths: WorkspacePaths!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = WorkspacePaths(documents: root.appendingPathComponent("Documents"), support: root.appendingPathComponent("Support"))
        try paths.createDirectories()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func fixture(_ name: String, ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }
    func testArchiveRejectsTraversalAndAbsolutePaths() throws {
        for path in ["../evil", "Payload/../../evil", "/tmp/evil", "Payload\\..\\evil", "Payload/./Info.plist"] {
            XCTAssertThrowsError(try ArchiveService.validate(path: path), path)
        }
        XCTAssertNoThrow(try ArchiveService.validate(path: "Payload/Fixture.app/Info.plist"))
    }
    func testRuntimeUsesPrivateSandboxWithoutAppGroup() {
        XCTAssertTrue(RTNative.usesPrivateSandbox())
    }
    func testMachORejectsTruncatedAndOverflowingCommands() throws {
        XCTAssertThrowsError(try MachOInspector.inspect(Data([0, 1, 2])))
        var data = Data(repeating: 0, count: 48)
        func word(_ value: UInt32, at offset: Int) { for i in 0..<4 { data[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) } }
        word(0xfeedfacf, at: 0); word(0x0100000c, at: 4); word(1, at: 16); word(16, at: 20)
        word(0x2c, at: 32); word(UInt32.max, at: 36)
        XCTAssertThrowsError(try MachOInspector.inspect(data))
        let file = root.appendingPathComponent("TruncatedMachO")
        try data.write(to: file)
        XCTAssertThrowsError(try MachOInspector.inspect(file))
    }
    func testMachODetectsEncryption() throws {
        var data = Data(repeating: 0, count: 56)
        func word(_ value: UInt32, at offset: Int) { for i in 0..<4 { data[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) } }
        word(0xfeedfacf, at: 0); word(0x0100000c, at: 4); word(1, at: 16); word(24, at: 20)
        word(0x2c, at: 32); word(24, at: 36); word(1, at: 48)
        let result = try MachOInspector.inspect(data)
        XCTAssertTrue(result.isEncrypted); XCTAssertTrue(result.hasARM64)
    }
    func testMachOReadsGuestSDKSeparatelyFromMinimumOS() throws {
        for command: UInt32 in [0x32, 0x25] {
            let length = command == 0x32 ? 24 : 16
            var data = Data(repeating: 0, count: 32 + length)
            func word(_ value: UInt32, at offset: Int) { for i in 0..<4 { data[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) } }
            word(0xfeedfacf, at: 0); word(0x0100000c, at: 4)
            word(1, at: 16); word(UInt32(length), at: 20)
            word(command, at: 32); word(UInt32(length), at: 36)
            if command == 0x32 { word(2, at: 40) }
            word(0x00110000, at: command == 0x32 ? 44 : 40)
            word(0x00120501, at: command == 0x32 ? 48 : 44)
            let result = try MachOInspector.inspect(data)
            XCTAssertEqual(result.minimumOS, "17.0.0")
            XCTAssertEqual(result.sdkVersion, 0x00120501)
            try MachOInspector.setMinimumOS(0x00100000, in: &data)
            XCTAssertEqual(try MachOInspector.inspect(data).sdkVersion, 0x00120501)
            if command == 0x32 {
                word(7, at: 40) // An iOS simulator SDK must not configure a device guest.
                XCTAssertNil(try MachOInspector.inspect(data).sdkVersion)
                word(2, at: 40); word(0x01000007, at: 4)
                XCTAssertNil(try MachOInspector.inspect(data).sdkVersion)
            }
        }
    }
    func testMachOReadsFatFileAcrossLargeSparseGaps() throws {
        func binary(cpu: UInt32, sdk: UInt32) -> Data {
            var data = Data(repeating: 0, count: 56)
            func word(_ value: UInt32, at offset: Int) { for i in 0..<4 { data[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) } }
            word(0xfeedfacf, at: 0); word(cpu, at: 4); word(2, at: 12)
            word(1, at: 16); word(24, at: 20)
            word(0x32, at: 32); word(24, at: 36); word(2, at: 40)
            word(0x00110000, at: 44); word(sdk, at: 48)
            return data
        }
        let file = root.appendingPathComponent("SparseUniversalMachO")
        var header = Data()
        for value: UInt32 in [0xcafebabe, 2, 0x01000007, 3, 65_536, 56, 16, 0x0100000c, 0, 268_435_456, 56, 16] {
            for shift in [24, 16, 8, 0] { header.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        try header.write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: 65_536); try handle.write(contentsOf: binary(cpu: 0x01000007, sdk: 0x001b0000))
        try handle.seek(toOffset: 268_435_456); try handle.write(contentsOf: binary(cpu: 0x0100000c, sdk: 0x00120501))
        let result = try MachOInspector.inspect(file)
        XCTAssertTrue(result.hasARM64); XCTAssertFalse(result.isEncrypted)
        XCTAssertEqual(result.sdkVersion, 0x00120501); XCTAssertEqual(result.minimumOS, "17.0.0")
        // A truncated slice must still be rejected by the file-backed reader.
        try handle.truncate(atOffset: 268_435_480)
        XCTAssertThrowsError(try MachOInspector.inspect(file))
    }
    func testMachOFileReaderPreservesPathsAcrossReadBoundaries() throws {
        let dependency = "@executable_path/Frameworks/注入插件.dylib", rpath = "@loader_path/Frameworks"
        let padding = 65_496, libraryLength = (24 + dependency.utf8.count + 8) & ~7, rpathLength = (12 + rpath.utf8.count + 8) & ~7
        var data = Data(repeating: 0, count: 32 + padding + libraryLength + rpathLength)
        func word(_ value: UInt32, at offset: Int) { for i in 0..<4 { data[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) } }
        word(0xfeedfacf, at: 0); word(0x0100000c, at: 4); word(2, at: 12)
        word(3, at: 16); word(UInt32(data.count - 32), at: 20)
        word(0x1b, at: 32); word(UInt32(padding), at: 36)
        let libraryOffset = 32 + padding, rpathOffset = libraryOffset + libraryLength
        word(0xc, at: libraryOffset); word(UInt32(libraryLength), at: libraryOffset+4); word(24, at: libraryOffset+8)
        data.replaceSubrange(libraryOffset+24..<libraryOffset+24+dependency.utf8.count, with: dependency.utf8)
        word(0x8000001c, at: rpathOffset); word(UInt32(rpathLength), at: rpathOffset+4); word(12, at: rpathOffset+8)
        data.replaceSubrange(rpathOffset+12..<rpathOffset+12+rpath.utf8.count, with: rpath.utf8)
        let file = root.appendingPathComponent("BoundaryMachO")
        try data.write(to: file)
        for result in [try MachOInspector.inspect(data), try MachOInspector.inspect(file)] {
            XCTAssertEqual(result.dependencies.map(\.path), [dependency]); XCTAssertEqual(result.rpaths, [rpath])
        }
    }
    func testContainerRestoresGuestSDKCompatibilityForExistingImports() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        var state = try await service.importIPA(fixture("Fixture", ext: "ipa"))
        state = try await service.installContainer(try XCTUnwrap(state.packages.first?.id))
        let app = try XCTUnwrap(state.containerApps.first)
        let directory = paths.applications.appendingPathComponent(app.folder)
        let file = directory.appendingPathComponent("LCAppInfo.plist")
        func metadata() throws -> [String: Any] {
            try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        }
        let originalSDK = try XCTUnwrap(MachOInspector.inspect(directory.appendingPathComponent("Fixture")).sdkVersion)
        XCTAssertEqual(try metadata()["spoofSDKVersion"] as? UInt32, max(originalSDK, 0x000b0000))
        // Give the fixture an older SDK than the test host, so using the host's
        // SDK or Info.plist cannot accidentally satisfy this regression test.
        let executable = directory.appendingPathComponent("Fixture")
        var binary = try Data(contentsOf: executable)
        func word(_ offset: Int) -> UInt32 { binary[offset..<offset+4].enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) } }
        var cursor = 32, sdkOffset: Int?
        for _ in 0..<word(16) {
            let kind = word(cursor)
            if kind == 0x32 || kind == 0x25 { sdkOffset = cursor + (kind == 0x32 ? 16 : 12); break }
            cursor += Int(word(cursor + 4))
        }
        let offset = try XCTUnwrap(sdkOffset)
        func setGuestSDK(_ value: UInt32) throws {
            for i in 0..<4 { binary[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
            // Preserve the signed fixture's inode and signature while changing
            // its header, matching LC's in-place executable patching.
            let handle = try FileHandle(forWritingTo: executable)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: binary[offset..<offset+4])
        }
        let guestSDK: UInt32 = 0x00120501
        try setGuestSDK(guestSDK)
        state = try await service.selectContainer(appID: app.id, containerID: app.selectedContainerID)
        let marker = paths.data.appendingPathComponent(app.selectedContainerID.uuidString + "/Documents/value.txt")
        try Data("keep guest data".utf8).write(to: marker)
        var legacy = try metadata(); legacy.removeValue(forKey: "spoofSDKVersion")
        try PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0).write(to: file)
        // Launch preparation rewrites legacy metadata before checking credentials.
        // No certificate is supplied so this test never launches guest code.
        do { _ = try await service.prepareLaunch(app.id) } catch {}
        XCTAssertEqual(try metadata()["spoofSDKVersion"] as? UInt32, guestSDK)
        XCTAssertEqual(try metadata()["LCDataUUID"] as? String, app.selectedContainerID.uuidString)
        XCTAssertEqual(try String(contentsOf: marker), "keep guest data")
        state = try await service.addContainer(to: app.id, name: "第二空间")
        XCTAssertEqual(try metadata()["spoofSDKVersion"] as? UInt32, guestSDK)
        XCTAssertEqual(state.containerApps.first?.containers.count, 2)
        try setGuestSDK(0x00090000)
        _ = try await service.selectContainer(appID: app.id, containerID: app.selectedContainerID)
        XCTAssertEqual(try metadata()["spoofSDKVersion"] as? UInt32, 0x000b0000)
        try setGuestSDK(0)
        _ = try await service.selectContainer(appID: app.id, containerID: app.selectedContainerID)
        XCTAssertNil(try metadata()["spoofSDKVersion"])
    }
    func testIdentityBundleMatchingDoesNotBroadenWildcard() {
        var identity = SigningIdentity(id: UUID(), name: "Test", teamID: "TEAM", profileName: "Profile", applicationIdentifier: "TEAM.com.example.*", expiresAt: .distantFuture, certificateExpiresAt: .distantFuture, fingerprint: "test", importedAt: Date())
        XCTAssertTrue(identity.supports(bundleID: "com.example.app"))
        XCTAssertFalse(identity.supports(bundleID: "com.examples.app"))
        XCTAssertFalse(identity.supports(bundleID: "com.example."))
        identity.applicationIdentifier = "TEAM.com.example.app"
        XCTAssertTrue(identity.supports(bundleID: "dev.retools.ios"))
    }
    func testImportPersistsMetadataAndKeepsOriginalSnapshot() async throws {
        let source = root.appendingPathComponent("source.ipa")
        try FileManager.default.copyItem(at: fixture("Fixture", ext: "ipa"), to: source)
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        let state = try await service.importIPA(source)
        let package = try XCTUnwrap(state.packages.first)
        XCTAssertEqual(package.name, "测试应用"); XCTAssertEqual(package.version, "1.2.3")
        XCTAssertFalse(package.isEncrypted)
        try Data("changed".utf8).write(to: source)
        XCTAssertGreaterThan(try Data(contentsOf: paths.library.appendingPathComponent(package.fileName)).count, 1000)
        let persisted = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: paths.state))
        XCTAssertEqual(persisted.packages.first?.id, package.id)
    }
    func testReplacingWithNewVersionKeepsConfigurationAndRemovesOldFiles() async throws {
        let source = root.appendingPathComponent("source.ipa")
        try FileManager.default.copyItem(at: fixture("Fixture", ext: "ipa"), to: source)
        let importer = WorkspaceService(paths: paths, state: WorkspaceState())
        let imported = try await importer.importIPA(source)
        var original = try XCTUnwrap(imported.packages.first)
        // 模拟已有的签名配置与旧版本信息。
        var options = PackageSigningOptions(); options.bundleID = "com.example.custom"
        original.signingOptions = options; original.signedBundleID = "com.retools.fixture.TEAM"; original.version = "1.0.0"
        let oldSigned = paths.exports.appendingPathComponent(original.id.uuidString + "/old.ipa")
        try FileManager.default.createDirectory(at: oldSigned.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("signed".utf8).write(to: oldSigned)
        original.signedFile = original.id.uuidString + "/old.ipa"; original.appleBundles = [AppleBundleRequest(bundleID: "x", name: "x", entitlementKeys: [], appGroups: [])]
        var seeded = imported; seeded.packages[0] = original
        let service = WorkspaceService(paths: paths, state: seeded)
        let oldFile = paths.library.appendingPathComponent(original.fileName)

        let state = try await service.replacePackageIPA(original.id, with: source)
        let updated = try XCTUnwrap(state.packages.first)
        XCTAssertEqual(state.packages.count, 1)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.version, "1.2.3")
        XCTAssertEqual(updated.signingOptions?.bundleID, "com.example.custom")
        XCTAssertEqual(updated.signedBundleID, "com.retools.fixture.TEAM")
        XCTAssertNil(updated.signedFile); XCTAssertNil(updated.appleBundles)
        XCTAssertNotEqual(updated.fileName, original.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.library.appendingPathComponent(updated.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldSigned.path))
    }
    func testReplacingRejectsDifferentBundleIdentifier() async throws {
        let source = root.appendingPathComponent("source.ipa")
        try FileManager.default.copyItem(at: fixture("Fixture", ext: "ipa"), to: source)
        var imported = try await WorkspaceService(paths: paths, state: WorkspaceState()).importIPA(source)
        imported.packages[0].bundleID = "com.example.other"
        let package = imported.packages[0]
        let service = WorkspaceService(paths: paths, state: imported)
        do { _ = try await service.replacePackageIPA(package.id, with: source); XCTFail("Different bundle accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("不同")) }
        let state = await service.snapshot()
        XCTAssertEqual(state.packages.first?.fileName, package.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.library.appendingPathComponent(package.fileName).path))
    }
    func testInvalidImportLeavesLibraryEmpty() async throws {
        let source = root.appendingPathComponent("invalid.ipa"); try Data("invalid".utf8).write(to: source)
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        do { _ = try await service.importIPA(source); XCTFail("invalid IPA accepted") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.library.path).isEmpty)
    }
    func testCertificateRejectsWrongPasswordAndMismatchedProfile() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        let p12 = try fixture("TestIdentity", ext: "p12"), profile = try fixture("TestIdentity", ext: "mobileprovision")
        do { _ = try await service.importIdentity(p12: p12, profile: profile, password: "wrong"); XCTFail("wrong password accepted") } catch {}
        do { _ = try await service.importIdentity(p12: p12, profile: fixture("OtherIdentity", ext: "mobileprovision"), password: "test-only"); XCTFail("mismatch accepted") } catch {}
        do { _ = try await service.importIdentity(p12: p12, profile: fixture("TestIdentityExpired", ext: "mobileprovision"), password: "test-only"); XCTFail("expired profile accepted") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.credentials.path).isEmpty)
    }
    func testSigningProducesIndependentIPAAndStoresPasswordOnlyInKeychain() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        var state = try await service.importIPA(fixture("Fixture", ext: "ipa"))
        let package = try XCTUnwrap(state.packages.first)
        let original = try Data(contentsOf: paths.library.appendingPathComponent(package.fileName))
        state = try await service.importIdentity(p12: fixture("TestIdentity", ext: "p12"), profile: fixture("TestIdentity", ext: "mobileprovision"), password: "test-only")
        let identity = try XCTUnwrap(state.identities.first)
        defer { try? SecureStore.delete(id: identity.id) }
        XCTAssertEqual(try SecureStore.password(id: identity.id), "test-only")
        XCTAssertFalse(try String(contentsOf: paths.state).contains("test-only"))
        state = try await service.sign(package.id, bundleID: package.bundleID)
        let signed = try XCTUnwrap(state.packages.first?.signedFile)
        let app = try ArchiveService.unpack(paths.exports.appendingPathComponent(signed), to: root.appendingPathComponent("Signed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("_CodeSignature/CodeResources").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path))
        XCTAssertEqual(try Data(contentsOf: paths.library.appendingPathComponent(package.fileName)), original)
        XCTAssertEqual(state.packages.first?.signedBundleID, package.bundleID)
    }
    func testRenewalSigningUsesJobCredentialsWithoutChangingSelectedIdentity() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        var state = try await service.importIPA(fixture("Fixture", ext: "ipa"))
        let package = try XCTUnwrap(state.packages.first)
        state = try await service.importIdentity(p12: fixture("TestIdentity", ext: "p12"), profile: fixture("TestIdentityExact", ext: "mobileprovision"), password: "test-only")
        let selected = try XCTUnwrap(state.activeIdentityID)
        defer { try? SecureStore.delete(id: selected) }
        let material = AppleAccountService.Credentials(p12: try Data(contentsOf: fixture("TestIdentity", ext: "p12")), profile: try Data(contentsOf: fixture("TestIdentity", ext: "mobileprovision")), password: "test-only")
        state = try await service.signWithCredentials(package.id, bundleID: package.bundleID, credentials: material)
        XCTAssertEqual(state.activeIdentityID, selected)
        XCTAssertEqual(state.identities.count, 1)
        XCTAssertNotNil(state.packages.first?.signedFile)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.staging.path).isEmpty)
    }
    func testHostIdentityIsStoredIndependentlyOfManualSigningSelection() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        var state = try await service.importIdentity(p12: fixture("TestIdentity", ext: "p12"), profile: fixture("TestIdentityExact", ext: "mobileprovision"), password: "test-only")
        let selected = try XCTUnwrap(state.activeIdentityID)
        let material = AppleAccountService.Credentials(p12: try Data(contentsOf: fixture("TestIdentity", ext: "p12")), profile: try Data(contentsOf: fixture("TestIdentity", ext: "mobileprovision")), password: "test-only")
        state = try await service.importHostIdentity(material)
        defer { for identity in state.identities { try? SecureStore.delete(id: identity.id) } }
        XCTAssertEqual(state.activeIdentityID, selected)
        XCTAssertNotEqual(state.hostIdentityID, selected)
        XCTAssertEqual(state.identities.count, 2)
        let reloaded = try await service.reload(); XCTAssertEqual(reloaded.hostIdentityID, state.hostIdentityID)
    }
    func testRepeatedCertificateImportReusesOneConfiguration() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        let p12 = try fixture("TestIdentity", ext: "p12"), profile = try fixture("TestIdentity", ext: "mobileprovision")
        let first = try await service.importIdentity(p12: p12, profile: profile, password: "test-only")
        let id = try XCTUnwrap(first.activeIdentityID)
        defer { try? SecureStore.delete(id: id) }
        let repeated = try await service.importIdentity(p12: p12, profile: profile, password: "test-only")
        XCTAssertEqual(repeated.identities.count, 1); XCTAssertEqual(repeated.activeIdentityID, id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.credentials.path), [id.uuidString])
    }
    func testRenewedHostProfileReplacesOldRevisionAndKeepsManualSelection() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        let manual = try await service.importIdentity(p12: fixture("TestIdentity", ext: "p12"), profile: fixture("TestIdentityExact", ext: "mobileprovision"), password: "test-only")
        let selected = try XCTUnwrap(manual.activeIdentityID)
        let material = AppleAccountService.Credentials(p12: try Data(contentsOf: fixture("TestIdentity", ext: "p12")), profile: try Data(contentsOf: fixture("TestIdentity", ext: "mobileprovision")), password: "test-only")
        let first = try await service.importHostIdentity(material), oldID = try XCTUnwrap(first.hostIdentityID)
        let renewed = AppleAccountService.Credentials(p12: material.p12, profile: try Data(contentsOf: fixture("TestIdentityRenewed", ext: "mobileprovision")), password: material.password)
        let updated = try await service.importHostIdentity(renewed), hostID = try XCTUnwrap(updated.hostIdentityID)
        defer { for id in [selected, oldID, hostID] { try? SecureStore.delete(id: id) } }
        XCTAssertEqual(updated.identities.count, 2); XCTAssertEqual(updated.activeIdentityID, selected)
        XCTAssertEqual(updated.identities.first { $0.id == hostID }?.profileName, "Retools Updated Test Profile")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.credentials.appendingPathComponent(oldID.uuidString).path))
        XCTAssertEqual(try Data(contentsOf: paths.credentials.appendingPathComponent(hostID.uuidString + "/profile.mobileprovision")), renewed.profile)
        let repeated = try await service.importHostIdentity(renewed)
        XCTAssertEqual(repeated.identities.count, 2); XCTAssertEqual(repeated.hostIdentityID, hostID)
        XCTAssertEqual(repeated.activeIdentityID, selected)
    }
    func testLegacyDuplicateCleanupRemapsSelectionsAndPrefersUnexpiredProfile() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        var state = try await service.importIdentity(p12: fixture("TestIdentity", ext: "p12"), profile: fixture("TestIdentity", ext: "mobileprovision"), password: "test-only")
        var older = try XCTUnwrap(state.identities.first), kept = older
        kept.id = UUID(); kept.profileScopeFingerprint = nil
        older.profileScopeFingerprint = nil; older.expiresAt = .distantPast; older.importedAt = Date().addingTimeInterval(60)
        try FileManager.default.copyItem(at: paths.credentials.appendingPathComponent(older.id.uuidString), to: paths.credentials.appendingPathComponent(kept.id.uuidString))
        try SecureStore.save(password: "test-only", id: kept.id)
        defer { for id in [older.id, kept.id] { try? SecureStore.delete(id: id) } }
        state.identities = [older, kept]; state.activeIdentityID = older.id; state.hostIdentityID = older.id
        try JSONEncoder().encode(state).write(to: paths.state)
        let loaded = try await service.reload()
        XCTAssertEqual(loaded.identities.count, 1); XCTAssertEqual(loaded.activeIdentityID, kept.id); XCTAssertEqual(loaded.hostIdentityID, kept.id)
        XCTAssertEqual(try SecureStore.password(id: kept.id), "test-only")
        XCTAssertThrowsError(try SecureStore.password(id: older.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.credentials.appendingPathComponent(older.id.uuidString).path))
        let repeated = try await service.reload(); XCTAssertEqual(repeated.identities, loaded.identities)
    }
    func testFailedProfileReplacementKeepsPreviousCredentialsAndSelections() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        let material = AppleAccountService.Credentials(p12: try Data(contentsOf: fixture("TestIdentity", ext: "p12")), profile: try Data(contentsOf: fixture("TestIdentity", ext: "mobileprovision")), password: "test-only")
        let state = try await service.importHostIdentity(material), id = try XCTUnwrap(state.hostIdentityID)
        defer { try? SecureStore.delete(id: id) }
        try FileManager.default.removeItem(at: paths.state)
        try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: false)
        let renewed = AppleAccountService.Credentials(p12: material.p12, profile: try Data(contentsOf: fixture("TestIdentityRenewed", ext: "mobileprovision")), password: material.password)
        do { _ = try await service.importHostIdentity(renewed); XCTFail("Failed workspace commit was accepted") } catch {}
        let unchanged = await service.snapshot()
        XCTAssertEqual(unchanged.identities, state.identities); XCTAssertEqual(unchanged.hostIdentityID, id)
        XCTAssertEqual(unchanged.activeIdentityID, state.activeIdentityID)
        XCTAssertEqual(try SecureStore.password(id: id), "test-only")
        XCTAssertEqual(try Data(contentsOf: paths.credentials.appendingPathComponent(id.uuidString + "/profile.mobileprovision")), material.profile)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.credentials.path), [id.uuidString])
    }
    func testCertificateScopeRetainsDifferentPermissionsAndDeviceAuthorizations() throws {
        let base: [String: Any] = ["UUID": "old", "ExpirationDate": Date(), "Entitlements": ["application-identifier": "TEAM.example", "get-task-allow": true], "ProvisionedDevices": ["first", "second"]]
        var revision = base; revision["UUID"] = "renewed"; revision["ExpirationDate"] = Date().addingTimeInterval(3600); revision["ProvisionedDevices"] = ["second", "first"]
        XCTAssertEqual(try SigningIdentityCatalog.profileScope(base), try SigningIdentityCatalog.profileScope(revision))
        revision["Entitlements"] = ["application-identifier": "TEAM.example", "get-task-allow": false]
        XCTAssertNotEqual(try SigningIdentityCatalog.profileScope(base), try SigningIdentityCatalog.profileScope(revision))
        revision = base; revision["ProvisionedDevices"] = ["third"]
        XCTAssertNotEqual(try SigningIdentityCatalog.profileScope(base), try SigningIdentityCatalog.profileScope(revision))
        revision = base; revision["ProvisionsAllDevices"] = true
        XCTAssertNotEqual(try SigningIdentityCatalog.profileScope(base), try SigningIdentityCatalog.profileScope(revision))
    }
    func testPreparedHostSurvivesCredentialCleanupAndCanBeArchived() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        let material = AppleAccountService.Credentials(p12: try Data(contentsOf: fixture("TestIdentity", ext: "p12")), profile: try Data(contentsOf: fixture("TestIdentity", ext: "mobileprovision")), password: "test-only")
        let id = try XCTUnwrap(Bundle.main.bundleIdentifier)
        var materials = [id: material]
        for url in (try? FileManager.default.contentsOfDirectory(at: Bundle.main.bundleURL.appendingPathComponent("PlugIns"), includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "appex" {
            let info = try ArchiveService.metadata(at: url)
            if let bundleID = info["CFBundleIdentifier"] as? String { materials[bundleID] = material }
        }
        let receipt = UUID().uuidString
        let app = try await service.prepareHostForRenewal(materials: materials, renewalReceipt: receipt)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Info.plist").path))
        XCTAssertEqual(try ArchiveService.metadata(at: app)["CFBundleIdentifier"] as? String, id)
        XCTAssertEqual(try ArchiveService.metadata(at: app)["RetoolsRenewalReceipt"] as? String, receipt)
        let archive = root.appendingPathComponent("host.ipa")
        try ArchiveService.pack(app: app, to: archive)
        XCTAssertGreaterThan(try Data(contentsOf: archive, options: .mappedIfSafe).count, 1000)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path), ["Retools.app"])
    }
    func testHostSigningRejectsProfileForDifferentBundleIdentifier() throws {
        let app = try ArchiveService.unpack(fixture("Fixture", ext: "ipa"), to: root.appendingPathComponent("Host"))
        let credentials = ["com.retools.fixture": ["p12": try fixture("TestIdentity", ext: "p12").path,
            "profile": try fixture("TestIdentityExact", ext: "mobileprovision").path, "password": "test-only"]]
        XCTAssertThrowsError(try RTNative.signHostApp(app.path, credentials: credentials))
    }
    func testSignedRuntimeLibraryIncludesMatchingXMLAndDEREntitlements() throws {
        let source = Bundle.main.bundleURL.appendingPathComponent("Frameworks/RuntimeProbe.framework/RuntimeProbe")
        let target = root.appendingPathComponent("RuntimeProbe")
        try FileManager.default.copyItem(at: source, to: target)
        try RTNative.signBinaries([target.path], p12: fixture("TestIdentity", ext: "p12").path, password: "test-only", profile: fixture("TestIdentity", ext: "mobileprovision").path, identifier: "dev.retools.ios")
        let data = try Data(contentsOf: target)
        func word(_ offset: Int, big: Bool = false) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw WorkspaceFailure("Truncated signature") }
            return data[offset..<offset+4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ((big ? 3 - $1.offset : $1.offset) * 8) }
        }
        var cursor = 32, base: Int?
        for _ in 0..<Int(try word(16)) {
            if try word(cursor) == 0x1d { base = Int(try word(cursor + 8)); break }
            cursor += Int(try word(cursor + 4))
        }
        let signature = try XCTUnwrap(base)
        var blobs: [UInt32: Data] = [:], locations: [UInt32: Int] = [:]
        for i in 0..<Int(try word(signature + 8, big: true)) {
            let entry = signature + 12 + i * 8, type = try word(entry, big: true)
            let start = signature + Int(try word(entry + 4, big: true))
            let end = start + Int(try word(start + 4, big: true))
            guard start + 8 <= end, end <= data.count else { throw WorkspaceFailure("Truncated signature slot") }
            blobs[type] = data.subdata(in: start+8..<end)
            locations[type] = start
        }
        let xml = try XCTUnwrap(blobs[5]), der = try XCTUnwrap(blobs[7])
        XCTAssertEqual((try PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any])?.count, 0)
        XCTAssertFalse(der.isEmpty)
        // Apple's versioned DER format uses constructed tag 0xb0 for a dictionary.
        XCTAssertEqual(Array(der), [0x70, 0x05, 0x02, 0x01, 0x01, 0xb0, 0x00])
        let codeDirectory = try XCTUnwrap(locations[0]), derStart = try XCTUnwrap(locations[7])
        XCTAssertGreaterThanOrEqual(try word(codeDirectory + 24, big: true), 7)
        let hashOffset = Int(try word(codeDirectory + 16, big: true)), hashSize = Int(data[codeDirectory + 36])
        XCTAssertEqual(hashSize, 32)
        let derHashOffset = codeDirectory + hashOffset - 7 * hashSize
        let fullDER = data.subdata(in: derStart..<derStart + Int(try word(derStart + 4, big: true)))
        XCTAssertEqual(data.subdata(in: derHashOffset..<derHashOffset + hashSize), Data(SHA256.hash(data: fullDER)))
    }
    func testContainerSpacesRemainIndependentAndSurviveRemovingOriginalIPA() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        var state = try await service.importIPA(fixture("Fixture", ext: "ipa"))
        let package = try XCTUnwrap(state.packages.first)
        state = try await service.installContainer(package.id)
        let app = try XCTUnwrap(state.containerApps.first), first = try XCTUnwrap(app.containers.first)
        state = try await service.addContainer(to: app.id, name: "第二空间")
        let second = try XCTUnwrap(state.containerApps.first?.containers.last)
        XCTAssertNotEqual(first.id, second.id)
        let firstFile = paths.data.appendingPathComponent(first.folderName + "/Documents/value.txt")
        let secondFile = paths.data.appendingPathComponent(second.folderName + "/Documents/value.txt")
        try Data("first".utf8).write(to: firstFile); try Data("second".utf8).write(to: secondFile)
        state = try await service.selectContainer(appID: app.id, containerID: second.id)
        XCTAssertEqual(state.containerApps.first?.selectedContainerID, second.id)
        state = try await service.resetContainer(appID: app.id, containerID: first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path)); XCTAssertEqual(try String(contentsOf: secondFile), "second")
        state = try await service.deletePackage(package.id)
        XCTAssertTrue(state.packages.isEmpty); XCTAssertEqual(state.containerApps.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.applications.appendingPathComponent(app.folder).path))
        state = try await service.deleteContainerApp(app.id)
        XCTAssertTrue(state.containerApps.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: secondFile.path))
    }
    func testJITContainerPreparationDoesNotRequireJITLessCertificate() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        var state = try await service.importIPA(fixture("Fixture", ext: "ipa"))
        let package = try XCTUnwrap(state.packages.first)
        state = try await service.installContainer(package.id)
        let container = try XCTUnwrap(state.containerApps.first)
        if WorkspaceService.jitRequiresSignedGuest {
            // iOS 26 起 LiveContainer 不再在 JIT 下绕过库校验，JIT 模式同样需要容器证书。
            do { _ = try await service.prepareLaunch(container.id, mode: .jit); XCTFail("JIT accepted an unsigned guest on iOS 26+") }
            catch { XCTAssertTrue(error.localizedDescription.contains("iOS 26")); XCTAssertTrue(error.localizedDescription.contains("P12")) }
        } else {
            state = try await service.prepareLaunch(container.id, mode: .jit)
            XCTAssertNotNil(state.containerApps.first?.lastLaunched)
            XCTAssertNil(state.containerApps.first?.signedFingerprint)
        }
        do { _ = try await service.prepareLaunch(container.id, mode: .jitless); XCTFail("JIT-less accepted without a certificate") }
        catch { XCTAssertTrue(error.localizedDescription.contains("P12")) }
    }
    func testDeletingContainerCertificateFallsBackToCurrentCertificate() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        var state = try await service.importIdentity(p12: fixture("TestIdentity", ext: "p12"), profile: fixture("TestIdentity", ext: "mobileprovision"), password: "test-only")
        let first = try XCTUnwrap(state.identities.first)
        state = try await service.importIdentity(p12: fixture("OtherIdentity", ext: "p12"), profile: fixture("OtherIdentity", ext: "mobileprovision"), password: "test-only")
        let second = try XCTUnwrap(state.identities.first { $0.id != first.id })
        defer { try? SecureStore.delete(id: first.id); try? SecureStore.delete(id: second.id) }
        state = try await service.selectHostIdentity(second.id)
        XCTAssertEqual(state.validHostIdentityID, second.id)
        state = try await service.deleteIdentity(second.id)
        XCTAssertNil(state.hostIdentityID, "删除的容器证书仍被引用")
        XCTAssertNil(state.validHostIdentityID)
        // 旧数据里残留的失效引用也按「跟随当前签名证书」处理。
        var stale = state; stale.hostIdentityID = UUID()
        XCTAssertNil(stale.validHostIdentityID)
    }
    func testJITLessCheckRecordSurvivesRestartAndExpiresWithCertificateChanges() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "JITLessCheck-" + UUID().uuidString))
        let future = Date().addingTimeInterval(7 * 24 * 3600)
        let identity = SigningIdentity(id: UUID(), name: "Test", teamID: "TEAM", profileName: "P", applicationIdentifier: "TEAM.*",
                                       expiresAt: future, certificateExpiresAt: future, fingerprint: "aa", importedAt: Date(), profileScopeFingerprint: nil)
        XCTAssertFalse(JITLessCheckRecord.isValid(for: identity, defaults: defaults), "没有检测过不应显示通过")
        JITLessCheckRecord.remember(identity, defaults: defaults)
        XCTAssertTrue(JITLessCheckRecord.isValid(for: identity, defaults: defaults), "同一证书的检测结果应在重新打开后保留")
        var renewed = identity; renewed.expiresAt = future.addingTimeInterval(3600)
        XCTAssertFalse(JITLessCheckRecord.isValid(for: renewed, defaults: defaults), "描述文件更新后应重新检测")
        var replaced = identity; replaced.fingerprint = "bb"
        XCTAssertFalse(JITLessCheckRecord.isValid(for: replaced, defaults: defaults), "更换证书后应重新检测")
        var expired = identity; expired.expiresAt = Date().addingTimeInterval(-60)
        JITLessCheckRecord.remember(expired, defaults: defaults)
        XCTAssertFalse(JITLessCheckRecord.isValid(for: expired, defaults: defaults), "过期证书不应显示通过")
        JITLessCheckRecord.remember(identity, defaults: defaults)
        XCTAssertNotEqual(JITLessCheckRecord.key(for: identity, hostTeam: "TEAM", hostCertificate: "x"),
                          JITLessCheckRecord.key(for: identity, hostTeam: "TEAM", hostCertificate: "y"), "Retools 重签后应重新检测")
        JITLessCheckRecord.forget(defaults: defaults)
        XCTAssertFalse(JITLessCheckRecord.isValid(for: identity, defaults: defaults), "运行被拒绝后应清除记录")
    }
    func testSigningRejectsDevelopmentProfileForDifferentAppBeforeCreatingOutput() async throws {
        let service = WorkspaceService(paths: paths, state: WorkspaceState())
        var state = try await service.importIPA(fixture("Fixture", ext: "ipa"))
        let package = try XCTUnwrap(state.packages.first)
        state = try await service.importIdentity(p12: fixture("TestIdentity", ext: "p12"), profile: fixture("TestIdentityExact", ext: "mobileprovision"), password: "test-only")
        let identity = try XCTUnwrap(state.identities.first)
        defer { try? SecureStore.delete(id: identity.id) }
        do { _ = try await service.sign(package.id, bundleID: "dev.retools.ios"); XCTFail("Mismatched development profile accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("开发描述文件不匹配")) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.exports.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.staging.path).isEmpty)
        state = try await service.sign(package.id, bundleID: "com.retools.profile-identity")
        let signed = try XCTUnwrap(state.packages.first?.signedFile)
        let app = try ArchiveService.unpack(paths.exports.appendingPathComponent(signed), to: root.appendingPathComponent("ExactSigned"))
        let info = try ArchiveService.metadata(at: app)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.retools.profile-identity")
        let data = try Data(contentsOf: app.appendingPathComponent(info["CFBundleExecutable"] as! String))
        func word(_ offset: Int, big: Bool = false) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw WorkspaceFailure("Truncated test executable") }
            return data[offset..<offset+4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ((big ? 3 - $1.offset : $1.offset) * 8) }
        }
        var cursor = 32, signature: Int?
        for _ in 0..<Int(try word(16)) {
            if try word(cursor) == 0x1d { signature = Int(try word(cursor + 8)); break }
            cursor += Int(try word(cursor + 4))
        }
        let base = try XCTUnwrap(signature)
        var actualEntitlements: [String: Any]?
        for index in 0..<Int(try word(base + 8, big: true)) {
            let slot = base + 12 + index * 8
            guard try word(slot, big: true) == 5 else { continue }
            let start = base + Int(try word(slot + 4, big: true))
            let end = start + Int(try word(start + 4, big: true))
            guard start + 8 <= end, end <= data.count else { throw WorkspaceFailure("Truncated entitlement slot") }
            actualEntitlements = try PropertyListSerialization.propertyList(from: data.subdata(in: start+8..<end), format: nil) as? [String: Any]
        }
        let entitlements = try XCTUnwrap(actualEntitlements)
        XCTAssertEqual(entitlements["application-identifier"] as? String, "TESTTEAM01.com.retools.profile-identity")
        // A re-signed app keeps the profile's wildcard keychain group, like LCSign.
        XCTAssertEqual(entitlements["keychain-access-groups"] as? [String], ["TESTTEAM01.*"])
    }
    @MainActor
    func testRenewalOnlyQueuesNearExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(RenewalController.isDue(expiry: now.addingTimeInterval(24 * 3600), now: now))
        XCTAssertTrue(RenewalController.isDue(expiry: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(RenewalController.isDue(expiry: now.addingTimeInterval(3 * 24 * 3600), now: now))
        XCTAssertTrue(RenewalController.isDue(expiry: nil, now: now))
    }
    func testAppleAccountRejectsInsecureAnisetteBeforeNetwork() async {
        let account = AppleAccountService()
        do { _ = try await account.login(email: "test@example.invalid", password: "test", anisetteURL: "http://example.invalid"); XCTFail("HTTP endpoint accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTTPS")) }
        try? SecureStore.deleteData(key: "apple.state.test@example.invalid")
    }
}
