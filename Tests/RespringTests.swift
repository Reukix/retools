import XCTest
@testable import LiveContainerSwiftUI

final class RespringTests: XCTestCase {
    @MainActor
    func testSimulatorNeverEntersExecutableState() async {
        #if targetEnvironment(simulator)
        XCTAssertFalse(RespringSession.platformAllowsExecution)
        let session = RespringSession()
        await session.run { DesktopRestart.Record(requestedAt: Date(), originalPID: 55) }
        XCTAssertEqual(session.phase, .unavailable)
        XCTAssertFalse(session.isAttempting)
        #endif
    }

    @MainActor
    func testStopDuringPreparationPreventsExecution() async {
        let session = RespringSession(executionAllowed: true, preparationDelay: .seconds(5))
        var invoked = false
        let work = Task { await session.run { invoked = true; return DesktopRestart.Record(requestedAt: Date(), originalPID: 55) } }
        for _ in 0..<100 where session.phase == .idle { await Task.yield() }
        XCTAssertEqual(session.phase, .preparing)
        session.stop(); work.cancel()
        await work.value
        XCTAssertEqual(session.phase, .stopped)
        XCTAssertFalse(session.isAttempting)
        XCTAssertFalse(invoked)
    }

    @MainActor
    func testStopWhileRunningDoesNotRestartOnReturn() async {
        let session = RespringSession(executionAllowed: true, preparationDelay: .zero)
        let work = Task { await session.run {
            try await Task.sleep(for: .seconds(5))
            return DesktopRestart.Record(requestedAt: Date(), originalPID: 55)
        } }
        for _ in 0..<100 {
            if session.phase == .running { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(session.phase, .running)
        session.stop(); work.cancel()
        await work.value
        await session.run { XCTFail("A stopped attempt must not restart"); return DesktopRestart.Record(requestedAt: Date(), originalPID: 55) }
        XCTAssertEqual(session.phase, .stopped)
    }

    @MainActor
    func testViewTaskCancellationStopsAttempt() async {
        let session = RespringSession(executionAllowed: true, preparationDelay: .zero)
        let work = Task { await session.run {
            try await Task.sleep(for: .seconds(5))
            return DesktopRestart.Record(requestedAt: Date(), originalPID: 55)
        } }
        for _ in 0..<100 {
            if session.phase == .running { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        work.cancel()
        await work.value
        XCTAssertEqual(session.phase, .stopped)
    }

    @MainActor
    func testDeviceServiceFailureDoesNotClaimSuccess() async {
        let session = RespringSession(executionAllowed: true, preparationDelay: .zero)
        await session.run { throw WorkspaceFailure("设备拒绝请求") }
        XCTAssertEqual(session.phase, .failed("设备拒绝请求"))
        XCTAssertFalse(session.isAttempting)
    }

    @MainActor
    func testSimulatorDoesNotInvokeDeviceRestartOperation() async {
        let session = RespringSession(executionAllowed: false)
        var invoked = false
        await session.run {
            invoked = true
            return DesktopRestart.Record(requestedAt: Date(), originalPID: 55)
        }
        XCTAssertFalse(invoked)
        XCTAssertEqual(session.phase, .unavailable)
    }

    @MainActor
    func testDeviceRequestMustObservePIDChangeBeforeShowingConfirmation() async {
        let session = RespringSession(executionAllowed: true, preparationDelay: .zero)
        await session.run {
            var record = DesktopRestart.Record(requestedAt: Date(), originalPID: 55)
            record.submitted = true
            return record
        }
        XCTAssertEqual(session.phase, .submitted)
        let confirmed = RespringSession(executionAllowed: true, preparationDelay: .zero)
        await confirmed.run {
            var record = DesktopRestart.Record(requestedAt: Date(), originalPID: 55)
            record.submitted = true; record.confirmedPID = 155
            return record
        }
        XCTAssertEqual(confirmed.phase, .confirmed)
    }

    @MainActor
    func testStoppingDevicePreparationCancelsBeforeDispatch() async {
        let session = RespringSession(executionAllowed: true, preparationDelay: .zero)
        var dispatched = false
        let work = Task {
            await session.run {
                try await Task.sleep(for: .seconds(5))
                dispatched = true
                return DesktopRestart.Record(requestedAt: Date(), originalPID: 55)
            }
        }
        for _ in 0..<100 {
            if session.phase == .running { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        session.stop()
        await work.value
        XCTAssertFalse(dispatched)
        XCTAssertEqual(session.phase, .stopped)
    }
}
