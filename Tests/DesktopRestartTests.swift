import XCTest
import IdeviceGateway
@testable import LiveContainerSwiftUI

final class DesktopRestartTests: XCTestCase {
    private func recordFile() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("desktop-restart-\(UUID().uuidString).json") }

    func testOnlyExactSystemDesktopExecutableCanBeTargeted() throws {
        let system = DeviceProcessInfo(pid: 55, name: "SpringBoard", appName: DesktopRestart.executable, isApplication: false, cpu: nil, memory: nil)
        let impostor = DeviceProcessInfo(pid: 7, name: "SpringBoard", appName: "/var/containers/Bundle/Application/X/Fake.app/SpringBoard", isApplication: true, cpu: nil, memory: nil)
        XCTAssertEqual(try DesktopRestart.target(in: [impostor, system]).pid, 55)
        XCTAssertThrowsError(try DesktopRestart.target(in: [impostor]))
        XCTAssertThrowsError(try DesktopRestart.target(in: [system, system]))
        var invalid = system; invalid.pid = 1
        XCTAssertThrowsError(try DesktopRestart.target(in: [invalid]))
    }

    func testSupportInspectionNeverTerminatesAProcess() async throws {
        let backend = SampleDeviceToolsBackend()
        let target = try await DesktopRestart.inspect(backend: backend)
        XCTAssertEqual(target.pid, 55)
        let checks = await backend.signalPermissionChecks, terminations = await backend.terminationRequests
        XCTAssertEqual(checks, [55])
        XCTAssertTrue(terminations.isEmpty)
    }

    func testPermissionDenialStopsBeforeDispatch() async throws {
        let backend = SampleDeviceToolsBackend(terminationBehavior: .reject)
        let file = recordFile(); defer { try? FileManager.default.removeItem(at: file) }
        do { _ = try await DesktopRestart.request(backend: backend, recordURL: file); XCTFail("Permission denial should stop the request") }
        catch { XCTAssertTrue(error.localizedDescription.contains("拒绝")) }
        let terminations = await backend.terminationRequests
        XCTAssertTrue(terminations.isEmpty)
        XCTAssertNil(DesktopRestart.load(from: file))
    }

    func testChangedDesktopPIDConfirmsRestart() async throws {
        let backend = SampleDeviceToolsBackend(terminationBehavior: .desktopRestart)
        let file = recordFile(); defer { try? FileManager.default.removeItem(at: file) }
        let record = try await DesktopRestart.request(backend: backend, recordURL: file)
        XCTAssertTrue(record.submitted)
        XCTAssertEqual(record.originalPID, 55)
        XCTAssertEqual(record.confirmedPID, 155)
        XCTAssertEqual(DesktopRestart.load(from: file), record)
        let terminations = await backend.terminationRequests
        XCTAssertEqual(terminations, [55])
    }

    func testAcceptedRequestWithoutPIDChangeIsNotReportedAsConfirmed() async throws {
        let backend = SampleDeviceToolsBackend(terminationBehavior: .ignore)
        let file = recordFile(); defer { try? FileManager.default.removeItem(at: file) }
        let record = try await DesktopRestart.request(backend: backend, recordURL: file)
        XCTAssertTrue(record.submitted)
        XCTAssertNil(record.confirmedPID)
        let rechecked = try await DesktopRestart.verify(backend: backend, recordURL: file)
        XCTAssertNil(rechecked?.confirmedPID)
        let terminations = await backend.terminationRequests
        XCTAssertEqual(terminations, [55], "Verification must not retry or target another daemon")
    }

    func testConnectionLossAfterRequestKeepsAnUnconfirmedRecord() async throws {
        let backend = SampleDeviceToolsBackend(terminationBehavior: .verificationFails)
        let file = recordFile(); defer { try? FileManager.default.removeItem(at: file) }
        let record = try await DesktopRestart.request(backend: backend, recordURL: file)
        XCTAssertTrue(record.submitted)
        XCTAssertNil(record.confirmedPID)
        XCTAssertNotNil(record.error)
        XCTAssertEqual(DesktopRestart.load(from: file), record)
        let terminations = await backend.terminationRequests
        XCTAssertEqual(terminations, [55])
    }

    func testNextLaunchVerificationOnlyReadsState() async throws {
        let backend = SampleDeviceToolsBackend(terminationBehavior: .desktopRestart)
        let file = recordFile(); defer { try? FileManager.default.removeItem(at: file) }
        try DesktopRestart.save(DesktopRestart.Record(requestedAt: Date(), originalPID: 55), to: file)
        try await backend.killProcess(pid: 55)
        let record = try await DesktopRestart.verify(backend: backend, recordURL: file)
        XCTAssertEqual(record?.confirmedPID, 155)
        let checks = await backend.signalPermissionChecks, terminations = await backend.terminationRequests
        XCTAssertTrue(checks.isEmpty)
        XCTAssertEqual(terminations, [55])
    }
}
