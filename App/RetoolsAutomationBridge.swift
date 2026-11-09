import Foundation
import UIKit
import UserNotifications

@MainActor
@objc(RetoolsAutomationBridge)
final class RetoolsAutomationBridge: NSObject {
    @objc(runWithRequest:completion:)
    static func run(request: String, completion: @escaping (Bool, String) -> Void) {
        Task {
            let store = WorkspaceStore.shared, renewal = RenewalController.shared
            var answered = false
            func finish(_ success: Bool, _ message: String) {
                guard !answered else { return }; answered = true; completion(success, message)
            }
            do {
                for _ in 0..<60 {
                    if !store.isWorking, !renewal.isWorking, !DevicePairingCoordinator.shared.isRunning { break }
                    try await Task.sleep(for: .seconds(1))
                }
                guard !store.isWorking, !renewal.isWorking, !DevicePairingCoordinator.shared.isRunning else { throw WorkspaceFailure("Retools 正在处理其他任务，请稍后再运行快捷指令。") }
                renewal.attach(store)
                let value = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: String] ?? [:]
                switch value["action"] {
                case "refresh-all":
                    guard !renewal.settings.packageIDs.isEmpty || renewal.settings.renewHost else { throw WorkspaceFailure("请先在 Retools 的自动续签设置中选择需要续签的应用。") }
                    if let blocker = renewal.autoRenewBlocker { throw WorkspaceFailure("无法续签：\(blocker)。") }
                    let success = await renewal.renew(force: true, beforeSelfInstall: {
                        RenewalNotice.post(title: "Retools 正在更新自身", body: "Retools 需要重装才能续签，稍后重新打开 Retools 确认结果。")
                        finish(true, "Retools 自身更新已提交，重新打开应用后确认续签结果。")
                    })
                    let message = renewal.errorMessage ?? renewal.settings.lastResult
                    RenewalNotice.post(title: success ? "Retools 续签完成" : "Retools 续签未完成", body: message)
                    if UIApplication.shared.applicationState == .background { renewal.errorMessage = nil }
                    finish(success, message)
                case "install-ipa":
                    let accountID = value["account"].flatMap { $0.isEmpty ? nil : $0 } ?? renewal.settings.defaultAccountID
                    guard renewal.settings.accounts.contains(where: { $0.id == accountID && $0.isReady }) else { throw WorkspaceFailure("请先在 Retools 中登录并选择有效的签名账号。") }
                    guard renewal.settings.hasPairing else { throw WorkspaceFailure("请先在 Retools 中完成设备配对和回环连接配置。") }
                    let base = store.paths.support.appendingPathComponent("ShortcutImports").standardizedFileURL
                    guard let file = value["file"] else { throw WorkspaceFailure("快捷指令未提供 IPA。") }
                    let source = URL(fileURLWithPath: file).standardizedFileURL
                    guard source.deletingLastPathComponent().deletingLastPathComponent() == base,
                          UUID(uuidString: source.deletingLastPathComponent().lastPathComponent) != nil,
                          source.lastPathComponent == "source.ipa",
                          source.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent() == base.resolvingSymlinksInPath() else { throw WorkspaceFailure("快捷指令文件不在有效的临时导入目录中。") }
                    store.isWorking = true; store.workLabel = "正在导入快捷指令的 IPA…"
                    do { store.state = try await store.service.importIPA(source) }
                    catch { store.isWorking = false; store.workLabel = ""; throw error }
                    store.isWorking = false; store.workLabel = ""
                    guard let package = store.state.packages.first, !package.isEncrypted else { throw WorkspaceFailure("此 IPA 不能用于重新签名安装。") }
                    renewal.settings.packageIDs.insert(package.id); renewal.settings.packageAccounts[package.id.uuidString] = accountID; renewal.save()
                    let success = await renewal.renew(force: true, onlyPackages: [package.id], includeHost: false)
                    store.selectedTab = .library
                    finish(success, success ? "\(package.name) 已签名并安装" : (renewal.errorMessage ?? renewal.settings.lastResult))
                default: throw WorkspaceFailure("无法识别这个 Retools 快捷指令动作。")
                }
            } catch {
                if request.contains("refresh-all") { RenewalNotice.post(title: "Retools 续签未完成", body: error.localizedDescription) }
                finish(false, error.localizedDescription)
            }
        }
    }
}

/// 后台续签（例如快捷指令定时自动化）完成后发一条本地通知。只在已获得通知权限时发送，不在后台申请权限。
enum RenewalNotice {
    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = String(body.prefix(240)); content.sound = .default
            content.threadIdentifier = "dev.retools.renewal"
            center.add(UNNotificationRequest(identifier: "dev.retools.renewal." + UUID().uuidString, content: content, trigger: nil))
        }
    }
    /// 在前台由用户操作时申请通知权限。
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}
