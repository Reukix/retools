import XCTest
import Darwin
@testable import LiveContainerSwiftUI

final class LocalFileMutationTests: XCTestCase {
    private var base: URL!
    private var container: URL!
    private var backups: URL!
    private let logical = "/private/var/mobile/Containers/Data/Application/11111111-1111-4111-8111-111111111111"

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        container = base.appendingPathComponent("Container"); backups = base.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }
    private func put(_ name: String, _ text: String = "original user contents") throws -> LocalFileSnapshot {
        try Data(text.utf8).write(to: container.appendingPathComponent(name))
        return try LocalFileMutation.snapshot(root: container, components: [name])
    }
    private func version(_ name: String) throws -> LocalFileVersion {
        var info = stat()
        guard lstat(container.appendingPathComponent(name).path, &info) == 0 else { throw LocalFileMutation.failure("test stat") }
        return LocalFileVersion(info)
    }
    private func replace(_ name: String, data: Data, expected: LocalFileVersion) throws {
        try LocalFileMutation.replace(root: container, components: [name], originalPath: logical + "/" + name, input: .data(data), expected: expected, backups: backups)
    }

    func testSaveBacksUpAndPreservesInodeOwnerAndPermissions() throws {
        _ = try put("settings.txt")
        XCTAssertEqual(chmod(container.appendingPathComponent("settings.txt").path, 0o640), 0)
        let before = try LocalFileMutation.snapshot(root: container, components: ["settings.txt"])
        let data = Data("saved changes".utf8)
        try replace("settings.txt", data: data, expected: before.version)
        let after = try LocalFileMutation.snapshot(root: container, components: ["settings.txt"])
        XCTAssertEqual(after.data, data)
        XCTAssertTrue(after.version.sameIdentity(as: before.version))
        let backup = try XCTUnwrap(LocalFileBackupStore.list(in: backups).first)
        XCTAssertEqual(try Data(contentsOf: backup.file(in: backups)), before.data)
        XCTAssertEqual(backup.originalPath, logical + "/settings.txt")
    }

    func testStaleEditorCannotOverwriteNewerContents() throws {
        let before = try put("file.txt")
        let changed = Data("newer contents from another app".utf8)
        try changed.write(to: container.appendingPathComponent("file.txt"))
        XCTAssertThrowsError(try replace("file.txt", data: Data("stale edit".utf8), expected: before.version))
        XCTAssertEqual(try Data(contentsOf: container.appendingPathComponent("file.txt")), changed)
        XCTAssertTrue(LocalFileBackupStore.list(in: backups).isEmpty)
    }

    func testPartialWriteFailureRestoresOriginalFromBackup() throws {
        let before = try put("file.txt", "long original content retained in a backup")
        var writes = 0
        XCTAssertThrowsError(try LocalFileMutation.replace(root: container, components: ["file.txt"], originalPath: logical + "/file.txt", input: .data(Data("new replacement contents".utf8)), expected: before.version, backups: backups, write: { fd, pointer, count, offset in
            writes += 1
            if writes == 1 { return pwrite(fd, pointer, min(4, count), offset) }
            errno = ENOSPC; return -1
        })) { error in XCTAssertTrue(error.localizedDescription.contains("原文件已恢复")) }
        XCTAssertEqual(try Data(contentsOf: container.appendingPathComponent("file.txt")), before.data)
        XCTAssertTrue(try version("file.txt").sameIdentity(as: before.version))
        XCTAssertEqual(LocalFileBackupStore.list(in: backups).count, 1)
    }

    func testFailureDoesNotRollBackOverConcurrentWriter() throws {
        let before = try put("file.txt", "long original content retained in a backup")
        var writes = 0
        XCTAssertThrowsError(try LocalFileMutation.replace(root: container, components: ["file.txt"], originalPath: logical + "/file.txt", input: .data(Data("new replacement contents".utf8)), expected: before.version, backups: backups, write: { fd, pointer, count, offset in
            writes += 1
            if writes == 1 { return pwrite(fd, pointer, min(4, count), offset) }
            _ = Data("Z".utf8).withUnsafeBytes { pwrite(fd, $0.baseAddress!, 1, 12) }
            errno = ENOSPC; return -1
        })) { error in XCTAssertTrue(error.localizedDescription.contains("核对")) }
        let current = try Data(contentsOf: container.appendingPathComponent("file.txt"))
        XCTAssertEqual(current[12], UInt8(ascii: "Z"))
        let backup = try XCTUnwrap(LocalFileBackupStore.list(in: backups).first)
        XCTAssertEqual(try Data(contentsOf: backup.file(in: backups)), before.data)
    }

    func testSymlinksHardlinksAndContainerRootCannotBeOverwritten() throws {
        let original = try put("original.txt")
        try FileManager.default.createSymbolicLink(at: container.appendingPathComponent("link"), withDestinationURL: container.appendingPathComponent("original.txt"))
        XCTAssertThrowsError(try replace("link", data: Data(), expected: original.version))
        try FileManager.default.linkItem(at: container.appendingPathComponent("original.txt"), to: container.appendingPathComponent("hardlink"))
        let linked = try LocalFileMutation.snapshot(root: container, components: ["hardlink"])
        XCTAssertThrowsError(try replace("hardlink", data: Data(), expected: linked.version))
        XCTAssertThrowsError(try LocalFileMutation.remove(root: container, components: [], originalPath: logical, expected: version("."), backups: backups))
        XCTAssertEqual(try Data(contentsOf: container.appendingPathComponent("original.txt")), original.data)
    }

    func testCreateAndRenameNeverReplaceExistingEntries() throws {
        let source = try put("one.txt", "one"), other = try put("two.txt", "two")
        XCTAssertThrowsError(try LocalFileMutation.create(root: container, components: ["two.txt"], input: .data(Data("replacement".utf8)), backups: backups))
        XCTAssertThrowsError(try LocalFileMutation.rename(root: container, components: ["one.txt"], name: "two.txt", expected: source.version, backups: backups))
        XCTAssertEqual(try Data(contentsOf: container.appendingPathComponent("two.txt")), other.data)
        try LocalFileMutation.rename(root: container, components: ["one.txt"], name: "renamed.txt", expected: source.version, backups: backups)
        XCTAssertEqual(try Data(contentsOf: container.appendingPathComponent("renamed.txt")), source.data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.appendingPathComponent("one.txt").path))
    }

    func testDeleteBacksUpFilesAndRefusesNonemptyDirectories() throws {
        try LocalFileMutation.makeDirectory(root: container, components: ["Folder"], backups: backups)
        try Data("keep".utf8).write(to: container.appendingPathComponent("Folder/file.txt"))
        XCTAssertThrowsError(try LocalFileMutation.remove(root: container, components: ["Folder"], originalPath: logical + "/Folder", expected: version("Folder"), backups: backups))
        let file = try LocalFileMutation.snapshot(root: container, components: ["Folder", "file.txt"])
        try LocalFileMutation.remove(root: container, components: ["Folder", "file.txt"], originalPath: logical + "/Folder/file.txt", expected: file.version, backups: backups)
        let backup = try XCTUnwrap(LocalFileBackupStore.list(in: backups).first)
        XCTAssertEqual(try Data(contentsOf: backup.file(in: backups)), file.data)
        try LocalFileMutation.remove(root: container, components: ["Folder"], originalPath: logical + "/Folder", expected: version("Folder"), backups: backups)
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.appendingPathComponent("Folder").path))
    }

    func testBackupStorageAndItsAncestorsCannotBeRenamedOrDeleted() throws {
        let protected = container.appendingPathComponent("Saved/Backups")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        try Data("backup contents".utf8).write(to: protected.appendingPathComponent("original"))
        XCTAssertThrowsError(try LocalFileMutation.rename(root: container, components: ["Saved"], name: "Moved", expected: version("Saved"), backups: protected))
        XCTAssertThrowsError(try LocalFileMutation.create(root: container, components: ["Saved", "Backups", "new.txt"], input: .data(Data()), backups: protected))
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.appendingPathComponent("original").path))
    }

    func testReadOnlyFileReportsPermissionFailureWithoutChangingIt() throws {
        if geteuid() == 0 { throw XCTSkip("Requires normal POSIX user permissions") }
        _ = try put("readonly.txt")
        let path = container.appendingPathComponent("readonly.txt").path
        XCTAssertEqual(chmod(path, 0o400), 0); defer { chmod(path, 0o600) }
        let snapshot = try LocalFileMutation.snapshot(root: container, components: ["readonly.txt"])
        XCTAssertThrowsError(try replace("readonly.txt", data: Data(), expected: snapshot.version))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), snapshot.data)
    }

    func testLargeBinaryImportAndExportStreamBeyondEditorLimit() throws {
        let source = base.appendingPathComponent("source.bin"), destination = base.appendingPathComponent("export.bin")
        let size: Int64 = 33 * 1024 * 1024 + 17
        let fd = Darwin.open(source.path, O_CREAT | O_RDWR | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(size)), 0)
        try LocalFileMutation.writeAll(fd, data: Data("header".utf8), offset: 0)
        try LocalFileMutation.writeAll(fd, data: Data("footer".utf8), offset: size - 6)
        Darwin.close(fd)
        try LocalFileMutation.create(root: container, components: ["large.bin"], input: .file(source), backups: backups)
        XCTAssertEqual(try version("large.bin").bytes, size)
        XCTAssertThrowsError(try LocalFileMutation.snapshot(root: container, components: ["large.bin"]))
        try LocalFileMutation.export(root: container, components: ["large.bin"], to: destination)
        let readFD = Darwin.open(destination.path, O_RDONLY); defer { Darwin.close(readFD) }
        XCTAssertEqual(try LocalFileVersion.read(readFD).bytes, size)
        XCTAssertEqual(try LocalFileMutation.read(readFD, offset: 0, count: 6), Data("header".utf8))
        XCTAssertEqual(try LocalFileMutation.read(readFD, offset: size - 6, count: 6), Data("footer".utf8))
    }

    func testBinaryPlistEditingPreservesFormatAndRejectsInvalidEdits() throws {
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["name": "before", "enabled": true, "count": 3], format: .binary, options: 0)
        try bytes.write(to: container.appendingPathComponent("config.plist"))
        let snapshot = try LocalFileMutation.snapshot(root: container, components: ["config.plist"])
        let document = try LocalEditableDocument(path: logical + "/config.plist", snapshot: snapshot)
        let edited = try document.encoded(document.text.replacingOccurrences(of: "before", with: "after"))
        XCTAssertTrue(edited.starts(with: Data("bplist".utf8)))
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: edited, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(values["name"] as? String, "after"); XCTAssertEqual(values["enabled"] as? Bool, true)
        XCTAssertEqual(values["count"] as? Int, 3)
        XCTAssertThrowsError(try document.encoded("invalid plist"))
    }

    func testTextEditingPreservesByteOrderMarksAndRejectsBinary() throws {
        let version = try put("file").version
        for (bom, encoding) in [(Data([0xef, 0xbb, 0xbf]), String.Encoding.utf8), (Data([0xff, 0xfe]), .utf16LittleEndian), (Data([0xfe, 0xff]), .utf16BigEndian)] {
            let doc = try LocalEditableDocument(path: logical + "/text.txt", snapshot: LocalFileSnapshot(data: bom + "你好".data(using: encoding)!, version: version))
            XCTAssertEqual(try doc.encoded("修改"), bom + "修改".data(using: encoding)!)
        }
        XCTAssertThrowsError(try LocalEditableDocument(path: logical + "/binary", snapshot: LocalFileSnapshot(data: Data([0, 1, 2]), version: version)))
    }

    func testMutationServiceUsesOneLeaseAndReleasesItOnFailure() async throws {
        let backend = WriteAccessBackend(), physical = try XCTUnwrap(container)
        let service = LocalFileAccessService(backend: backend, rootForTarget: { _ in physical }, backups: backups)
        try await service.createTextFile(directory: logical, name: "created.txt", group: "test")
        XCTAssertEqual(backend.events, ["acquire", "release"])
        do { try await service.createTextFile(directory: logical, name: "created.txt", group: "test"); XCTFail("Existing file accepted") } catch { }
        XCTAssertEqual(backend.events, ["acquire", "release", "acquire", "release"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: physical.appendingPathComponent("created.txt").path))
    }

    func testInvalidNamesAndIntermediateSymlinksCannotMutateOutsideContainer() throws {
        try FileManager.default.createSymbolicLink(at: container.appendingPathComponent("redirect"), withDestinationURL: base)
        for components in [["..", "outside"], ["bad/name"], ["redirect", "outside"], ["."]] {
            XCTAssertThrowsError(try LocalFileMutation.create(root: container, components: components, input: .data(Data()), backups: backups))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("outside").path))
    }
}

private final class WriteAccessBackend: LocalFileAccessBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.withLock { recorded } }
    func acquire(root: String, group: String) throws -> Int64 { lock.withLock { recorded.append("acquire") }; return 7 }
    func release(_ handle: Int64) -> Bool { lock.withLock { recorded.append("release") }; return true }
}
