import Foundation
import AppleSigningFFI

@MainActor
final class RemotePairingDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var continuation: CheckedContinuation<UInt16?, Never>?
    private var timeout: Task<Void, Never>?
    private let record: Data
    init(record: Data) { self.record = record }

    nonisolated static func matches(record: Data, identifier: String, authTag: String) -> Bool {
        record.withUnsafeBytes { bytes in
            identifier.withCString { id in authTag.withCString { tag in
                rt_device_pairing_matches(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, id, tag)
            } }
        }
    }
    static func discoverPort(record: Data) async -> UInt16? {
        guard let plist = try? PropertyListSerialization.propertyList(from: record, format: nil) as? [String: Any],
              (plist["alt_irk"] as? Data)?.count == 16 else { return nil }
        let discovery = RemotePairingDiscovery(record: record)
        return await discovery.run()
    }
    private func run() async -> UInt16? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            browser.delegate = self
            browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.finish(nil)
            }
        }
    }
    private func finish(_ port: UInt16?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        browser.stop(); browser.delegate = nil
        services.forEach { $0.delegate = nil; $0.stop() }; services = []
        continuation.resume(returning: port)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self; service.resolve(withTimeout: 4)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) { finish(nil) }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard (1...65535).contains(sender.port), let txtData = sender.txtRecordData() else { return }
        let txt = NetService.dictionary(fromTXTRecord: txtData)
        let identifier = txt["identifier"].flatMap { String(data: $0, encoding: .utf8) } ?? sender.name
        guard let tag = txt["authTag"].flatMap({ String(data: $0, encoding: .utf8) }),
              Self.matches(record: record, identifier: identifier, authTag: tag) else { return }
        finish(UInt16(sender.port))
    }
}
