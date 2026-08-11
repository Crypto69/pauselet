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

    /// Identifiers used to wire notification buttons back to reminders.
    private enum Action {
        static let complete = "reminder.complete"
        static let snooze = "reminder.snooze"
        static let categoryPrefix = "reminder.category"
    }

    private static let reminderIDKey = "reminderID"

    /// Called when a notification cannot be delivered, so the caller can show
    /// the reminder some other way rather than dropping it silently.
    var fallbackPresenter: ((Reminder, ReminderCore.Settings) -> Void)?

    /// Whether the system will currently deliver notifications for us.
    ///
    /// Starts as `.unknown` rather than "no": on first launch the authorization
    /// request has not come back yet, and treating that as a refusal would send
    /// every early reminder down the fallback path.
    private enum Availability {
        case unknown
        case available
        case unavailable
    }

    private var availability: Availability = .unknown

    func configure() {
        center.delegate = self
        registerCategories()
        requestAuthorization()
    }

    private func requestAuthorization() {
        // Read the stored decision first. If the user has already answered, this
        // settles it without waiting; if not, the request below prompts them.
        refreshAuthorizationStatus()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.availability = granted ? .available : .unavailable
            }
        }
    }

    /// Re-reads the current authorization. System notifications are unavailable
    /// unless the app is notarized and the user has allowed them, and a reminder
    /// app that silently drops reminders is worse than useless — so we track
    /// this and fall back to the app's own windows when it is not available.
    func refreshAuthorizationStatus() {
        center.getNotificationSettings { [weak self] settings in
            let availability: Availability
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                availability = .available
            case .denied:
                availability = .unavailable
            case .notDetermined:
                // Still waiting on the user; leave the current value alone so a
                // pending prompt does not look like a refusal.
                return
            @unknown default:
                availability = .unavailable
            }
            Task { @MainActor in
                self?.availability = availability
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
    ///
    /// If the system will not deliver notifications — most commonly because the
    /// app is not notarized, or the user declined the prompt — the reminder is
    /// handed to `fallbackPresenter` instead. Missing a pressure-relief prompt
    /// because of a permissions technicality is not an acceptable failure.
    func post(_ reminder: Reminder, settings: ReminderCore.Settings) {
        if availability == .unavailable {
            fallbackPresenter?(reminder, settings)
            return
        }

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
        center.add(request) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil {
                    // Delivery failed; show it ourselves rather than losing it.
                    self.availability = .unavailable
                    self.fallbackPresenter?(reminder, settings)
                    return
                }
                // Accepted by the system. Confirm it was actually delivered
                // rather than silently swallowed, because a reminder that no
                // one sees is the one failure this app cannot afford.
                self.confirmDelivery(of: request.identifier, reminder: reminder, settings: settings)
            }
        }
    }

    /// Checks that a posted notification really reached the user, and shows the
    /// in-app card if it did not.
    private func confirmDelivery(
        of identifier: String, reminder: Reminder, settings: ReminderCore.Settings
    ) {
        Task { @MainActor [weak self] in
            // A moment's grace: the system registers a delivered notification
            // slightly after accepting it, and checking too eagerly would report
            // a false failure and show the card on top of a real banner.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }

            let delivered = await self.center.deliveredNotifications()
            let landed = delivered.contains { $0.request.identifier == identifier }
            guard !landed else { return }

            self.availability = .unavailable
            self.fallbackPresenter?(reminder, settings)
        }
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
