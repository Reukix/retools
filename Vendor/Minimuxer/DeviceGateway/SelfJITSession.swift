import Foundation

/// Self-attachment stops the client too. Queue detach in the same transport write
/// so debugserver can resume the process without another client-side instruction.
enum SelfJITSession {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func enable(process: UInt32, command: (String) throws -> String?, disableACK: () -> Void,
                       send: (Data) throws -> Void, read: () throws -> String?) throws {
        guard process > 0 else { throw Failure(message: "JIT 目标进程无效。") }
        guard try command("QSetDetachOnError:1") == "OK" else {
            throw Failure(message: "调试服务未接受断线分离设置，未附加进程。")
        }
        guard try command("QStartNoAckMode") == "OK" else {
            throw Failure(message: "调试服务不支持免确认模式，未附加进程。")
        }
        disableACK()
        func packet(_ body: String) -> Data {
            let checksum = body.utf8.reduce(UInt8(0)) { $0 &+ $1 }
            return Data("$\(body)#\(String(format: "%02x", checksum))".utf8)
        }
        try send(packet("vAttach;\(String(process, radix: 16))") + packet("D"))
        let attached = try read() ?? ""
        guard ["T", "S"].contains(String(attached.prefix(1))), attached.count >= 3,
              attached.dropFirst().prefix(2).allSatisfy(\.isHexDigit) else {
            throw Failure(message: "调试服务未确认附加进程：\(attached.prefix(80))")
        }
        let detached = try read() ?? ""
        guard detached == "OK" else { throw Failure(message: "调试服务未确认分离进程：\(detached.prefix(80))") }
    }
}
