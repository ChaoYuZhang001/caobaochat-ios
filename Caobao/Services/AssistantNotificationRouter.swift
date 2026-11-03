#if os(iOS)
import Foundation
import UserNotifications
import UIKit

/// Notification callbacks only navigate within the current owner's workspace.
/// Registering the delegate never requests alert permission.
final class AssistantNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AssistantNotificationRouter()
    static let openTaskNotification = Notification.Name("assistant.open-task")
    static let openProactiveNotification = Notification.Name("assistant.open-proactive")
    @MainActor private var pendingTask: (owner: String, id: String)?
    @MainActor private var pendingProactiveRun: (owner: String, id: String)?

    @MainActor func takePendingTask() -> String? {
        defer { pendingTask = nil }
        guard let pendingTask, pendingTask.owner == (AuthService.shared.user?.id ?? "local-device") else { return nil }
        return pendingTask.id
    }

    @MainActor func takePendingProactiveRun() -> String? {
        defer { pendingProactiveRun = nil }
        guard let pendingProactiveRun,
              pendingProactiveRun.owner == (AuthService.shared.user?.id ?? "local-device") else { return nil }
        return pendingProactiveRun.id
    }

    @MainActor func install() { UNUserNotificationCenter.current().delegate = self }

    /// Remote registration is a side effect only after the user has already
    /// granted an alert-capable notification authorization. It never prompts.
    @MainActor func registerRemoteNotificationsIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus),
              settings.alertSetting == .enabled else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let values = response.notification.request.content.userInfo
        let owner = values["ownerId"] as? String
        let task = values["taskId"] as? String
        let route = values["route"] as? String
        let proactiveRun = values["proactiveRunId"] as? String
        Task { @MainActor in
            defer { completionHandler() }
            guard let owner, !owner.isEmpty, owner == (AuthService.shared.user?.id ?? "local-device") else { return }
            if route == "task", let task, !task.isEmpty {
                self.pendingTask = (owner, task)
                NotificationCenter.default.post(name: Self.openTaskNotification, object: task)
            } else if route == "proactive", let proactiveRun, !proactiveRun.isEmpty {
                self.pendingProactiveRun = (owner, proactiveRun)
                NotificationCenter.default.post(name: Self.openProactiveNotification, object: proactiveRun)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let owner = notification.request.content.userInfo["ownerId"] as? String
        Task { @MainActor in
            let currentOwner = AuthService.shared.user?.id ?? "local-device"
            completionHandler(owner == currentOwner ? [.banner, .sound] : [])
        }
    }
}
#endif
