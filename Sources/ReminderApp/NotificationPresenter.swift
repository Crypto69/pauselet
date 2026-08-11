import Foundation
import UserNotifications
import ReminderCore

/// Posts system notifications for the `.normal` and `.important` tiers, and
/// routes the buttons the user taps back to the engine.
///
/// The two intrusive tiers (`.subtle`, `.critical`) bypass this entirely and use
/// custom windows, because macOS notifications cannot be made either quiet
/// enough or insistent enough for those cases.
@MainActor
final class NotificationPresenter: NSObject {
    weak var engine: ReminderEngine?

    private let center = UNUserNotificationCenter.current()
    private var isAuthorized = false

    /// Identifiers used to wire notification buttons back to reminders.
    private enum Action {
        static let complete = "reminder.complete"
        static let snooze = "reminder.snooze"
        static let categoryPrefix = "reminder.category"
    }

    private static let reminderIDKey = "reminderID"

    func configure() {
        center.delegate = self
        registerCategories()
        requestAuthorization()
    }

    private func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.isAuthorized = granted
            }
        }
    }

    /// Two categories so the sound-carrying tier can be distinguished, and so
    /// both get Done / Snooze buttons directly in the notification.
    private func registerCategories() {
        let complete = UNNotificationAction(
            identifier: Action.complete,
            title: "Done",
            options: [.authenticationRequired]
        )
        let snooze = UNNotificationAction(
            identifier: Action.snooze,
            title: "Snooze",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Action.categoryPrefix,
            actions: [complete, snooze],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Posts a notification for `reminder`. Delivered immediately.
    func post(_ reminder: Reminder, settings: ReminderCore.Settings) {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        if !reminder.message.isEmpty {
            content.body = reminder.message
        }
        content.categoryIdentifier = Action.categoryPrefix
        content.userInfo = [Self.reminderIDKey: reminder.id.uuidString]

        // Only the important tier makes noise; normal stays silent so a busy
        // reminder set does not become a stream of chimes.
        if settings.soundEnabled && reminder.priority >= .important {
            if let name = reminder.soundName {
                content.sound = UNNotificationSound(
                    named: UNNotificationSoundName(rawValue: "\(name).aiff")
                )
            } else {
                content.sound = .default
            }
        }

        if reminder.priority >= .important {
            content.interruptionLevel = .timeSensitive
        }

        let request = UNNotificationRequest(
            identifier: "\(reminder.id.uuidString)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    private func reminderID(from response: UNNotificationResponse) -> UUID? {
        let info = response.notification.request.content.userInfo
        guard let raw = info[Self.reminderIDKey] as? String else { return nil }
        return UUID(uuidString: raw)
    }
}

extension NotificationPresenter: UNUserNotificationCenterDelegate {
    /// Show the banner even when the app is frontmost — the user may well be
    /// working in the reminder window itself.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            defer { completionHandler() }
            guard let id = self.reminderID(from: response) else { return }
            switch response.actionIdentifier {
            case Action.complete, UNNotificationDefaultActionIdentifier:
                self.engine?.complete(id: id)
            case Action.snooze:
                self.engine?.snooze(id: id)
            case UNNotificationDismissActionIdentifier:
                self.engine?.dismiss(id: id)
            default:
                break
            }
        }
    }
}
