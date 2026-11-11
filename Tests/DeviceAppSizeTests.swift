import XCTest
@testable import LiveContainerSwiftUI

final class DeviceAppSizeTests: XCTestCase {
    private func app(_ values: [String: Any]) throws -> DeviceInstalledApp {
        var plist: [String: Any] = ["CFBundleIdentifier": "test.app"]
        plist.merge(values) { _, new in new }
        return try XCTUnwrap(DeviceInstalledApp.parse(PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)))
    }

    func testUnknownSizeAndReportedZeroRemainDistinctAcrossCacheRoundTrip() throws {
        let unknown = try app([:])
        XCTAssertNil(unknown.reportedBundleSize); XCTAssertNil(unknown.reportedDataSize)
        let measured = try app(["StaticDiskUsage": 1024, "DynamicDiskUsage": 0])
        XCTAssertEqual(measured.reportedBundleSize, 1024); XCTAssertEqual(measured.reportedDataSize, 0)
        let restored = try JSONDecoder().decode(DeviceInstalledApp.self, from: JSONEncoder().encode(measured))
        XCTAssertEqual(restored.reportedDataSize, 0)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(measured)) as? [String: Any])
        legacy.removeValue(forKey: "bundleSizeKnown"); legacy.removeValue(forKey: "dataSizeKnown")
        let old = try JSONDecoder().decode(DeviceInstalledApp.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.reportedBundleSize, 1024); XCTAssertNil(old.reportedDataSize)
        XCTAssertNil(try app(["StaticDiskUsage": -1]).reportedBundleSize)
    }

    @MainActor func testSizesSurviveCallerCancellationAndUpdateBothAppCategories() async throws {
        let backend = SampleDeviceToolsBackend(sizeReadingBehavior: .held)
        let store = DeviceToolsStore(backend: backend), renewal = RenewalController()
        await store.loadApps(renewal: renewal)
        XCTAssertTrue(store.apps.allSatisfy { $0.reportedBundleSize == nil })
        let caller = Task { await store.loadAppSizes(renewal: renewal) }
        let deadline = Date().addingTimeInterval(3)
        while !(await backend.sizeReadingStarted), Date() < deadline { await Task.yield() }
        let started = await backend.sizeReadingStarted
        XCTAssertTrue(started)
        caller.cancel()
        let second = Task { await store.loadAppSizes(renewal: renewal) }
        await backend.releaseAppSizes()
        await caller.value; await second.value
        XCTAssertEqual(store.sizesPhase, .ready)
        let utm = try XCTUnwrap(store.apps.first { $0.bundleID == "com.utmapp.UTM" })
        XCTAssertEqual(utm.reportedBundleSize, 412_000_000)
        XCTAssertEqual(utm.reportedDataSize, 2_300_000_000)
        await store.loadApps(renewal: renewal)
        XCTAssertEqual(store.apps.first { $0.bundleID == utm.bundleID }?.reportedDataSize, 2_300_000_000)
        await store.loadSystemApps(renewal: renewal)
        XCTAssertEqual(store.systemApps.first { $0.bundleID == "com.apple.weather" }?.reportedDataSize, 0)
        await store.loadAppSizes(renewal: renewal)
        let calls = await backend.serviceCalls
        XCTAssertEqual(calls.filter { $0 == "sizes:Any" }.count, 1)
    }

    @MainActor func testSizeFailureCanRetryAndMissingFieldsAreNotReportedAsZero() async throws {
        let backend = SampleDeviceToolsBackend(sizeReadingBehavior: .failed)
        let store = DeviceToolsStore(backend: backend), renewal = RenewalController()
        await store.loadApps(renewal: renewal)
        await store.loadAppSizes(renewal: renewal)
        guard case .failed = store.sizesPhase else { return XCTFail("Size failures must be visible") }
        XCTAssertFalse(store.loadingSizes)
        XCTAssertTrue(store.apps.allSatisfy { $0.reportedDataSize == nil })
        await backend.setSizeReadingBehavior(.missing)
        await store.loadAppSizes(renewal: renewal, force: true)
        guard case .failed = store.sizesPhase else { return XCTFail("An empty size response must be visible") }
        await backend.setSizeReadingBehavior(.normal)
        await store.loadAppSizes(renewal: renewal, force: true)
        XCTAssertEqual(store.sizesPhase, .ready)
        XCTAssertTrue(store.apps.contains { $0.reportedBundleSize != nil })
    }
}
