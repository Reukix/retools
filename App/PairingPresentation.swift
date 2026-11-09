import ActivityKit
import UIKit
import UserNotifications

@MainActor
final class PairingPresentation {
    private var activity: ActivityKit.Activity<PairingActivityAttributes>?
    private var updateTask: Task<Void, Never>?
    private var session: UUID?
    private var notificationID: String?
    private var deadline = Date()
    private var notificationsAllowed = false

    static func prefersIsland(isPhone: Bool, topInset: CGFloat, activitiesEnabled: Bool) -> Bool {
        // The host is portrait-only. Dynamic Island iPhones reserve at least 51pt;
        // notched and Home-button iPhones use a smaller portrait safe-area inset.
        isPhone && topInset >= 51 && activitiesEnabled
    }
    func begin(session id: UUID) async {
        session = id; deadline = Date().addingTimeInterval(300); notificationsAllowed = false
        let top = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter(\.isKeyWindow).map { $0.safeAreaInsets.top }.max() ?? 0
        if Self.prefersIsland(isPhone: UIDevice.current.userInterfaceIdiom == .phone, topInset: top,
                              activitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled) {
            do {
                activity = try ActivityKit.Activity.request(attributes: PairingActivityAttributes(sessionID: id),
                    content: ActivityContent(state: .init(phase: "正在准备设备配对…", deadline: deadline), staleDate: deadline), pushType: nil)
                return
            } catch { /* Use local notifications if Live Activities are unavailable. */ }
        }
        let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        guard session == id else { return }
        notificationsAllowed = allowed
        notificationID = "dev.retools.ios.pairing.\(id.uuidString)"
    }
    func update(phase: String, pin: String? = nil) {
        guard session != nil else { return }
        let state = PairingActivityAttributes.ContentState(phase: phase, pin: pin, deadline: deadline)
        if let activity {
            let previous = updateTask
            updateTask = Task { await previous?.value; await activity.update(ActivityContent(state: state, staleDate: deadline)) }
        } else if notificationsAllowed, let notificationID {
            let content = UNMutableNotificationContent()
            content.title = pin == nil ? "Retools 设备配对" : "Retools 配对码"
            content.body = pin.map { "\($0) · 在系统设置中输入" } ?? phase
            if pin != nil { content.sound = .default }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notificationID, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)), withCompletionHandler: nil)
        }
    }
    func finish(succeeded: Bool, message: String) {
        session = nil
        if let notificationID {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [notificationID])
            center.removeDeliveredNotifications(withIdentifiers: [notificationID])
        }
        notificationID = nil
        guard let activity else { return }
        self.activity = nil
        let previous = updateTask
        let state = PairingActivityAttributes.ContentState(phase: message, deadline: Date(), finished: true, succeeded: succeeded)
        updateTask = Task {
            await previous?.value
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: succeeded ? .after(Date().addingTimeInterval(8)) : .immediate)
        }
    }
}
