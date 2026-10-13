import Foundation
import UserNotifications

/// Banner notifications. Only works from the packaged app: a bare `swift run` binary has no
/// bundle, and UNUserNotificationCenter traps without one.
enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// Banners are only shown for the frontmost app when its delegate says so, and Pinstill can
    /// still be frontmost after its popover closes.
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner])
        }
    }
    private static let delegate = Delegate()

    private static func center() -> UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        return center
    }

    static func requestAuthorization() async -> Bool {
        guard available else { return false }
        return (try? await center().requestAuthorization(options: [.alert])) ?? false
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
