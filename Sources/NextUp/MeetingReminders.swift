import AppKit
import UserNotifications

/// Posts a banner shortly before each meeting. Banners draw over full-screen apps,
/// so the reminder still lands when the menu bar is hidden.
final class MeetingReminders: NSObject, UNUserNotificationCenterDelegate {
    static let leadTime: TimeInterval = 60

    private static let joinCategory = "meeting.join"
    private static let plainCategory = "meeting"
    private static let joinAction = "join"
    private static let idPrefix = "meeting."

    // Lazy: current() throws when the binary runs outside an app bundle (the --snapshot debug mode).
    private lazy var center = UNUserNotificationCenter.current()

    func activate() {
        center.delegate = self
        let join = UNNotificationAction(identifier: Self.joinAction, title: "Join", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.joinCategory, actions: [join], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.plainCategory, actions: [], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Replaces every pending reminder, so calling this after each calendar reload is idempotent.
    func schedule(_ meetings: [Meeting], now: Date = Date()) {
        center.removeAllPendingNotificationRequests()
        let horizon = now.addingTimeInterval(24 * 3600)
        for meeting in meetings {
            let fireDate = meeting.start.addingTimeInterval(-Self.leadTime)
            guard fireDate > now, fireDate < horizon else { continue }

            let content = UNMutableNotificationContent()
            content.title = meeting.title
            content.body = "Starts in \(Int(Self.leadTime / 60)) min · \(Format.timeRange(meeting))"
            content.sound = .default
            content.categoryIdentifier = meeting.link == nil ? Self.plainCategory : Self.joinCategory
            if let url = meeting.destination { content.userInfo = ["url": url.absoluteString] }

            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(identifier: Self.idPrefix + meeting.id, content: content, trigger: trigger))
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier != UNNotificationDismissActionIdentifier,
           let value = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: value) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
