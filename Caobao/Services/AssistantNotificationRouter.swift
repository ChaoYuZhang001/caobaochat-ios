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

    private static func validRouteValue(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }

    @MainActor func takePendingTask() -> String? {
        guard let pendingTask else { return nil }
        let currentOwner = AuthService.shared.user?.id ?? "local-device"
        guard AssistantOwnerIdentity.matches(pendingTask.owner, currentOwner) else {
            // During cold launch AuthService may still be restoring the
            // session. Keep the payload until the authenticated owner is
            // available; discard it only after a different signed-in owner
            // is known, so one account cannot consume another's route.
            if currentOwner != "local-device" { self.pendingTask = nil }
            return nil
        }
        self.pendingTask = nil
        return pendingTask.id
    }

    @MainActor func takePendingProactiveRun() -> String? {
        guard let pendingProactiveRun else { return nil }
        let currentOwner = AuthService.shared.user?.id ?? "local-device"
        guard AssistantOwnerIdentity.matches(pendingProactiveRun.owner, currentOwner) else {
            if currentOwner != "local-device" { self.pendingProactiveRun = nil }
            return nil
        }
        self.pendingProactiveRun = nil
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
        let owner = Self.validRouteValue(values["ownerId"] as? String)
        let task = Self.validRouteValue(values["taskId"] as? String)
        let route = values["route"] as? String
        let proactiveRun = Self.validRouteValue(values["proactiveRunId"] as? String)
        Task { @MainActor in
            defer { completionHandler() }
            // Store the owner-bound route before checking the live session.
            // On a cold launch authentication restoration can finish after
            // this callback; takePendingTask/takePendingProactiveRun performs
            // the owner check when the workspace is ready.
            guard let owner, !owner.isEmpty else { return }
            if route == "task", let task {
                self.pendingTask = (owner, task)
                NotificationCenter.default.post(name: Self.openTaskNotification, object: task)
            } else if route == "proactive", let proactiveRun {
                self.pendingProactiveRun = (owner, proactiveRun)
                NotificationCenter.default.post(name: Self.openProactiveNotification, object: proactiveRun)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let owner = Self.validRouteValue(notification.request.content.userInfo["ownerId"] as? String)
        Task { @MainActor in
            let currentOwner = AuthService.shared.user?.id ?? "local-device"
            completionHandler(AssistantOwnerIdentity.matches(owner, currentOwner) ? [.banner, .sound] : [])
        }
    }
}
#endif
