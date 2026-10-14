import UserNotifications

enum IdleNotifier {
    static let undoWindow: TimeInterval = 10

    private static let identifier = "mactivity.idle-cutoff"
    private static var authorized = false
    private static let delegate = Delegate()

    static var canUndo: Bool {
        IdleTimeout.notify && authorized
    }

    static func install() {
        UNUserNotificationCenter.current().delegate = delegate
        refreshAuthorization()
    }

    static func requestAccess(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                authorized = granted
                completion(granted)
            }
        }
    }

    static func post() {
        let content = UNMutableNotificationContent()
        content.title = "Tracking stopped"
        content.body = "Move or type in the next 10 seconds to keep this block."
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func withdraw() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private static func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                authorized = settings.authorizationStatus == .authorized
            }
        }
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound])
        }
    }
}
