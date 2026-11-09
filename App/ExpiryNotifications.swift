import SwiftUI
import UserNotifications
import WidgetKit

/// 把 Apple ID 签名应用（含 Retools 自身）的有效期同步到桌面小组件和本地通知。
/// 续签设置保存、应用库变化或回到前台时调用；内容没变时不重复刷新小组件。
@MainActor
enum ExpiryPublisher {
    private static var lastPublished: ExpirySnapshot?

    static func publish(store: WorkspaceStore, renewal: RenewalController) {
        let items = SignedAppItem.all(store: store, renewal: renewal).compactMap { item -> ExpirySnapshot.Item? in
            // 没有描述文件的 Retools（例如模拟器或 Xcode 直接运行）不显示。
            if item.package == nil, item.expiry == nil { return nil }
            return ExpirySnapshot.Item(id: item.id, name: item.name, expiry: item.expiry, autoRenew: item.autoRenew, isHost: item.package == nil)
        }
        let snapshot = ExpirySnapshot(items: items, updatedAt: Date(), lastRenewal: renewal.settings.lastResult)
        if lastPublished.map({ $0.items != snapshot.items || $0.lastRenewal != snapshot.lastRenewal }) ?? true {
            lastPublished = snapshot
            ExpirySnapshotStore.save(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        }
        Task { await ExpiryNotifications.reschedule(items) }
    }
}

enum ExpiryNotifications {
    static let enabledKey = "RetoolsExpiryNotifications"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    private static let prefix = "retools.expiry."

    /// 每个应用两条提醒：到期前 1 天、到期时。续签成功后有效期后移，提醒随之重排，所以只有没续上的才会真正弹出。
    static func reschedule(_ items: [ExpirySnapshot.Item], now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard enabled, items.contains(where: { $0.expiry != nil }), await authorized(center) else { return }
        for item in items {
            guard let expiry = item.expiry, expiry > now else { continue }
            let soon = expiry.addingTimeInterval(-24 * 3600)
            if soon > now {
                add(center, id: prefix + item.id + ".soon", at: soon, title: "「\(item.name)」明天到期",
                    body: item.autoRenew ? "自动续签还没有完成。打开 Retools 检查配对与 Apple ID，或手动续签。" : "打开 Retools 续签，避免应用无法打开。")
            }
            add(center, id: prefix + item.id + ".expired", at: expiry, title: "「\(item.name)」已到期",
                body: item.isHost ? "Retools 需要重新签名后才能打开。" : "打开 Retools 续签后即可继续使用。")
        }
    }

    /// 后台续签结束时告知结果；Retools 在前台时界面已经显示结果，不再发通知。
    @MainActor
    static func renewalFinished(successes: Int, failures: Int, details: [String]) {
        guard enabled, successes + failures > 0, UIApplication.shared.applicationState != .active else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard await authorized(center, requestIfNeeded: false) else { return }
            let content = UNMutableNotificationContent()
            content.title = failures == 0 ? "续签完成" : "续签未全部完成"
            content.body = failures == 0 ? "\(successes) 项已续签并安装。" : ([ "\(successes) 项成功，\(failures) 项失败。" ] + details.prefix(2)).joined(separator: "\n")
            content.sound = failures == 0 ? nil : .default
            content.threadIdentifier = "retools.renewal"
            try? await center.add(UNNotificationRequest(identifier: "retools.renewal.result", content: content, trigger: nil))
        }
    }

    private static func add(_ center: UNUserNotificationCenter, id: String, at date: Date, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        content.threadIdentifier = "retools.expiry"
        content.userInfo = ["url": "retools://expiry"]
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }

    /// 首次有需要提醒的应用时才请求通知权限。
    private static func authorized(_ center: UNUserNotificationCenter, requestIfNeeded: Bool = true) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined:
            guard requestIfNeeded else { return false }
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default: return false
        }
    }
}
