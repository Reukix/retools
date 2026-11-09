import Foundation
import IdeviceGateway

@objc(RetoolsDeviceDebugger)
public final class RTDeviceDebugger: NSObject {
    @objc(enableWithPairing:host:port:process:completion:)
    public static func enable(pairing: Data, host: String, port: UInt16, process: UInt32, completion: @escaping (String?) -> Void) {
        Task.detached {
            let gateway = IdeviceGateway()
            do {
                gateway.setLogging(false); gateway.setDeviceEndpointIp(host); gateway.setPort(port, for: .rppairing)
                try await gateway.start(pairingFileContent: String(decoding: pairing, as: UTF8.self), preferred: .rppairing)
                guard process == UInt32(getpid()) else { throw NSError(domain: "Retools", code: 1, userInfo: [NSLocalizedDescriptionKey: "JIT 目标与当前容器进程不一致。"]) }
                try await gateway.debugCurrentProcess()
                try? await gateway.stop()
                completion(nil)
            } catch { try? await gateway.stop(); completion(error.localizedDescription) }
        }
    }
}
