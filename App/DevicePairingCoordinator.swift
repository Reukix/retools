import Foundation
import SwiftUI
import AppleSigningFFI

private final class DevicePairingContext {
    weak var owner: DevicePairingCoordinator?
    let session: UUID
    init(owner: DevicePairingCoordinator, session: UUID) { self.owner = owner; self.session = session }
}
private let devicePairingEvent: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { pointer, context in
    guard let pointer, let context else { return }
    let text = String(cString: pointer)
    DispatchQueue.main.async {
        let box = Unmanaged<DevicePairingContext>.fromOpaque(context).takeUnretainedValue()
        let event = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        box.owner?.receive(event, session: box.session)
        if ["completed", "failed", "cancelled"].contains(event["type"] as? String ?? "") {
            Unmanaged<DevicePairingContext>.fromOpaque(context).release()
        }
    }
}

@MainActor
final class DevicePairingCoordinator: NSObject, ObservableObject, NetServiceDelegate {
    static let shared = DevicePairingCoordinator()
    @Published private(set) var isRunning = false
    @Published private(set) var status = "尚未开始设备配对"
    @Published private(set) var pin: String?
    @Published private(set) var error: String?
    private var service: NetService?
    private var handle: UInt64 = 0
    private var session: UUID?
    private var cancelReason: String?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var completion: ((String) -> Void)?
    private var link: LocalDeviceLink?
    private let presentation = PairingPresentation()

    func start(using link: LocalDeviceLink, completion: @escaping (String) -> Void) {
        guard !isRunning else { return }
        #if targetEnvironment(simulator)
        error = "设备端配对需要 iOS 27 或更新版本的真实 iPhone。"; return
        #else
        guard #available(iOS 27.0, *) else { error = "当前系统请使用已有配对文件；设备端配对需要 iOS 27。"; return }
        self.link = link; self.completion = completion
        let id = UUID(); session = id; isRunning = true; pin = nil; error = nil; cancelReason = nil
        status = "正在准备本机配对服务…"
        Task {
            await presentation.begin(session: id)
            guard session == id, isRunning else { return }
            do {
                let request: [String: Any] = [:]
                // A new pairing gets a fresh host identity. Keep the currently
                // working record until the user completes this new session.
                let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
                background = UIApplication.shared.beginBackgroundTask(withName: "Retools Device Pairing") { [weak self] in
                    Task { @MainActor in self?.cancel(reason: "系统结束了后台配对时间，请返回 Retools 重试。") }
                }
                let context = Unmanaged.passRetained(DevicePairingContext(owner: self, session: id)).toOpaque()
                handle = json.withCString { rt_device_pairing_start($0, devicePairingEvent, context) }
                if handle == 0 {
                    Unmanaged<DevicePairingContext>.fromOpaque(context).release()
                    finish(error: "无法启动设备配对服务。")
                }
            } catch { finish(error: error.localizedDescription) }
        }
        #endif
    }
    func cancel(reason: String? = nil) {
        cancelReason = reason
        service?.stop(); service = nil
        if handle != 0 { rt_device_pairing_cancel(handle) }
        else { finish(error: reason) }
    }
    fileprivate func receive(_ event: [String: Any], session id: UUID) {
        guard session == id else { return }
        switch event["type"] as? String {
        case "ready":
            guard let identifier = event["identifier"] as? String, let port = event["port"] as? Int,
                  (1...65535).contains(port), let txt = event["txt"] as? [String: String] else {
                cancel(reason: "配对服务返回了无效的广播参数。"); return
            }
            let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: identifier, port: Int32(port))
            service.delegate = self
            service.setTXTRecord(NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) }))
            self.service = service; service.publish()
            status = "请打开系统设置 → 隐私与安全性 → 开发者模式，选择「与 Retools 配对」。"
            presentation.update(phase: "请在系统开发者模式中选择「与 Retools 配对」")
        case "connected":
            status = "系统已连接，正在建立安全配对…"
            presentation.update(phase: status)
        case "pin":
            guard let pin = event["pin"] as? String else { return }
            self.pin = pin; status = "请在系统设置中输入下面的配对码。"
            presentation.update(phase: status, pin: pin)
        case "completed":
            guard let encoded = event["record"] as? String, let record = Data(base64Encoded: encoded),
                  let irk = (event["host_irk"] as? String).flatMap({ Data(base64Encoded: $0) }), irk.count == 16, let link else {
                finish(error: "系统未返回完整的配对记录。"); return
            }
            status = "正在安全保存配对记录…"
            Task {
                do {
                    try await link.importPairedIdentity(record, hostIRK: irk)
                    let udid = event["udid"] as? String ?? ""
                    let completion = self.completion
                    finish(error: nil, succeeded: true); status = "配对记录已自动保存"
                    completion?(udid)
                } catch { finish(error: error.localizedDescription) }
            }
        case "failed": finish(error: event["error"] as? String ?? "设备配对未完成。")
        case "cancelled": finish(error: cancelReason)
        default: break
        }
    }
    private func finish(error: String?, succeeded: Bool = false) {
        self.error = error; status = error ?? "配对已结束"
        isRunning = false; pin = nil; handle = 0; session = nil; completion = nil; link = nil
        service?.delegate = nil; service?.stop(); service = nil
        if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
        presentation.finish(succeeded: succeeded, message: error ?? (succeeded ? "配对完成，记录已自动保存" : "配对已结束"))
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === service else { return }
        cancel(reason: "无法发布配对服务，请在系统设置中允许 Retools 访问本地网络后重试。")
    }
}
