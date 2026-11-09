import XCTest
import CryptoKit
import AppleSigningFFI
@testable import LiveContainerSwiftUI

private final class PairingEventCapture: @unchecked Sendable {
    let ready = XCTestExpectation(description: "pairing listener ready")
    let terminal = XCTestExpectation(description: "pairing listener cancelled")
    private let lock = NSLock()
    private var values: [String] = []
    func receive(_ text: String) {
        let event = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        let type = event["type"] as? String ?? ""
        lock.withLock { values.append(type) }
        if type == "ready" { ready.fulfill() }
        if ["completed", "failed", "cancelled"].contains(type) { terminal.fulfill() }
    }
    var events: [String] { lock.withLock { values } }
}
private let pairingTestCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { text, context in
    guard let text, let context else { return }
    Unmanaged<PairingEventCapture>.fromOpaque(context).takeUnretainedValue().receive(String(cString: text))
}

final class DevicePairingTests: XCTestCase {
    private func record() throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((0..<32).map(UInt8.init)))
        return try PropertyListSerialization.data(fromPropertyList: ["private_key": key.rawRepresentation, "public_key": key.publicKey.rawRepresentation, "identifier": "retools-test-host", "alt_irk": Data(base64Encoded: "Mgp6ZGPzXM2ku9br46vsiw==")!], format: .xml, options: 0)
    }
    func testPairingRecordRejectsMismatchedPrivateKey() throws {
        var plist = try PropertyListSerialization.propertyList(from: record(), format: nil) as! [String: Any]
        plist["public_key"] = Data(repeating: 0, count: 32)
        let corrupt = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertThrowsError(try LocalDeviceLink.validatePairing(corrupt))
        XCTAssertEqual(try LocalDeviceLink.validatePairing(record()).mode, "rppairing")
    }
    func testDiscoveryOnlyAcceptsAuthenticatedDeviceAdvertisement() throws {
        let data = try record(), identifier = "2BE6E510-0325-4365-923E-B14C6F57DB3A"
        XCTAssertTrue(RemotePairingDiscovery.matches(record: data, identifier: identifier, authTag: "kXjlTr2l"))
        XCTAssertFalse(RemotePairingDiscovery.matches(record: data, identifier: "different-device", authTag: "kXjlTr2l"))
        XCTAssertFalse(RemotePairingDiscovery.matches(record: data, identifier: identifier, authTag: "AAAAAAAA"))
    }
    func testAutomaticallyImportsOnlyOneValidFileAndKeepsOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = "retools.tests.pairing.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root); try? SecureStore.deleteData(key: key) }
        let source = root.appendingPathComponent("device.mobiledevicepairing"), data = try record()
        try data.write(to: source)
        let link = LocalDeviceLink(pairingKey: key)
        let mode = try await link.importDiscoveredPairing(in: root)
        XCTAssertEqual(mode, "rppairing")
        XCTAssertEqual(try Data(contentsOf: source), data)
        XCTAssertNotNil(try SecureStore.data(key: key))
        let second = try await link.importDiscoveredPairing(in: root)
        XCTAssertNil(second)
    }
    func testDoesNotChooseBetweenMultipleValidPairingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = "retools.tests.pairing.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root); try? SecureStore.deleteData(key: key) }
        try record().write(to: root.appendingPathComponent("first.mobilepair"))
        try record().write(to: root.appendingPathComponent("second.mobilepair"))
        let result = try await LocalDeviceLink(pairingKey: key).importDiscoveredPairing(in: root)
        XCTAssertNil(result); XCTAssertNil(try SecureStore.data(key: key))
    }
    func testNativePairingCanBeCancelledWhileWaitingForDevice() async {
        let capture = PairingEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        defer { Unmanaged<PairingEventCapture>.fromOpaque(context).release() }
        let handle = "{}".withCString { rt_device_pairing_start($0, pairingTestCallback, context) }
        XCTAssertNotEqual(handle, 0)
        await fulfillment(of: [capture.ready], timeout: 5)
        rt_device_pairing_cancel(handle)
        await fulfillment(of: [capture.terminal], timeout: 5)
        XCTAssertEqual(capture.events.filter { ["completed", "failed", "cancelled"].contains($0) }, ["cancelled"])
    }
    func testCompletedPairingIdentityIsSavedAtomicallyWithHostIdentity() async throws {
        let key = "retools.tests.pairing.\(UUID().uuidString)"
        defer { try? SecureStore.deleteData(key: key) }
        let link = LocalDeviceLink(pairingKey: key), data = try record(), irk = Data(repeating: 7, count: 16)
        try await link.importPairedIdentity(data, hostIRK: irk)
        let saved = try XCTUnwrap(SecureStore.data(key: key))
        let plist = try PropertyListSerialization.propertyList(from: saved, format: nil) as? [String: Any]
        XCTAssertEqual(plist?["retools_host_irk"] as? Data, irk)
        let valid = try await link.hasSavedPairing(); XCTAssertTrue(valid)
        do { try await link.importPairedIdentity(data, hostIRK: Data()); XCTFail("invalid host identity accepted") } catch {}
        XCTAssertEqual(try SecureStore.data(key: key), saved)
    }
}
