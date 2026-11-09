import XCTest
@testable import IdeviceGateway

final class SelfJITSessionTests: XCTestCase {
    func testSelfAttachQueuesDetachBeforeTheClientIsStopped() throws {
        var noACK = false, detachPolicy = false, stopped = false, writes = 0
        var responses: [String] = []
        try SelfJITSession.enable(process: 1234, command: { command in
            // Once stopped, this client cannot issue another command or ACK.
            XCTAssertFalse(stopped)
            XCTAssertTrue(["QSetDetachOnError:1", "QStartNoAckMode"].contains(command))
            if command == "QSetDetachOnError:1" { detachPolicy = true }
            return "OK"
        }, disableACK: { noACK = true }, send: { bytes in
            XCTAssertTrue(noACK); XCTAssertTrue(detachPolicy); writes += 1
            let packet = String(decoding: bytes, as: UTF8.self)
            let regex = try NSRegularExpression(pattern: #"\$([^#$]*)#([0-9a-f]{2})"#)
            let matches = regex.matches(in: packet, range: NSRange(packet.startIndex..., in: packet))
            XCTAssertEqual(matches.count, 2)
            for match in matches {
                let body = String(packet[Range(match.range(at: 1), in: packet)!])
                let checksum = String(packet[Range(match.range(at: 2), in: packet)!])
                XCTAssertEqual(UInt8(checksum, radix: 16), body.utf8.reduce(UInt8(0), &+))
                if body == "vAttach;4d2" { stopped = true; responses.append("T05thread:1;") }
                else if body == "D", stopped { stopped = false; responses.append("OK") }
                else { XCTFail("Unexpected debugger command") }
            }
        }, read: {
            XCTAssertFalse(stopped, "A paused client cannot read or send its detach")
            return responses.isEmpty ? nil : responses.removeFirst()
        })
        XCTAssertEqual(writes, 1); XCTAssertFalse(stopped); XCTAssertTrue(responses.isEmpty)
    }
    func testRefusedNoACKDoesNotAttach() {
        XCTAssertThrowsError(try SelfJITSession.enable(process: 1234, command: { $0 == "QSetDetachOnError:1" ? "OK" : "" },
            disableACK: { XCTFail("ACK must remain enabled") }, send: { _ in XCTFail("Must not attach") }, read: { XCTFail("Must not read"); return nil }))
    }
    func testAttachErrorIsNotReportedAsSuccess() {
        var reads = 0
        XCTAssertThrowsError(try SelfJITSession.enable(process: 1234, command: { _ in "OK" }, disableACK: {}, send: { _ in }, read: {
            reads += 1; return "E01"
        }))
        XCTAssertEqual(reads, 1)
    }
    func testMissingDetachConfirmationIsNotReportedAsSuccess() {
        var replies = ["T05thread:1;", "E02"]
        XCTAssertThrowsError(try SelfJITSession.enable(process: 1234, command: { _ in "OK" }, disableACK: {}, send: { _ in }, read: { replies.removeFirst() }))
    }
}
