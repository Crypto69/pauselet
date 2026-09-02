import Foundation
import UserNotifications
import ReminderCore

/// Turns `NotificationPlan`s into real `UNNotificationRequest`s and routes the
/// buttons the user taps back to the engine — the iOS counterpart of the macOS
/// `NotificationPresenter`, with pre-scheduling in place of immediate posts.
@MainActor
final class NotificationScheduler: NSObject {

    weak var model: AppModel?
    private let engine: ReminderEngine
    private let center = UNUserNotificationCenter.current()

    enum ActionID {
        static let complete = "pauselet.complete"
        static let snooze = "pauselet.snooze"
        static let category = "pauselet.reminder"
    }

    enum ResponseAction {
        case complete
        case snooze
        case dismiss
    }

    /// Prefixes distinguish the three kinds of request this app makes, so a
    /// refill only ever cancels its own scheduled requests and the delegate
    /// can tell a live foreground post from a pre-scheduled delivery.
    private static let livePrefix = "pauselet-live-"
    private static let previewPrefix = "pauselet-preview-"

    private nonisolated static let reminderIDKey = "reminderID"
    private nonisolated static let stampKey = "stamp"

    init(engine: ReminderEngine) {
        self.engine = engine
        super.init()
    }

    func configure() {
        center.delegate = self
        let complete = UNNotificationAction(
            identifier: ActionID.complete, title: "Done", options: []
        )
        let snooze = UNNotificationAction(
            identifier: ActionID.snooze, title: "Snooze", options: []
        )
        let category = UNNotificationCategory(
            identifier: ActionID.category,
            actions: [complete, snooze],
            intentIdentifiers: [],
            // Dismissing a notification is information too — the macOS app
            // records it, so this one does as well.
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(
                options: [.alert, .sound, .badge]
            )) ?? false
        @unknown default:
            return false
        }
    }

    var authorizationStatus: UNAuthorizationStatus {
        get async {
            await center.notificationSettings().authorizationStatus
        }
    }

    // MARK: - Scheduling

    /// Brings the pending set in line with the plan: removes requests the
    /// plan no longer wants, adds the ones it lacks, and leaves the rest
    /// untouched. A request's identifier digests its whole content, so
    /// "already pending with this identifier" means "already exactly right" —
    /// most of a refill after a routine edit is a no-op.
    ///
    /// Also clears delivered notifications for reminders that no longer exist
    /// or are switched off, so Notification Center does not keep showing a
    /// reminder the user deleted.
    func refill(
        reminders: [Reminder],
        settings: ReminderCore.Settings,
        now: Date,
        alarmsCarrying: Set<UUID>
    ) async {
        let plan = NotificationPlan.build(
            reminders: reminders, settings: settings, now: now,
            alarmsCarrying: alarmsCarrying
        )
        let wanted = Dictionary(plan.items.map { ($0.identifier, $0) }) { first, _ in first }

        let pending = await center.pendingNotificationRequests()
        let pendingOurs = Set(pending.map(\.identifier).filter {
            $0.hasPrefix(NotificationPlan.identifierPrefix)
        })

        let stale = pendingOurs.subtracting(wanted.keys)
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(stale))
        }

        let missing = plan.items.filter { !pendingOurs.contains($0.identifier) }
        // The adds are independent; letting them overlap turns sixty round
        // trips into one.
        await withTaskGroup(of: Void.self) { group in
            for item in missing {
                let request = makeRequest(for: item, now: now)
                group.addTask { @MainActor in
                    try? await self.center.add(request)
                }
            }
        }

        let active = Set(reminders.filter(\.isEnabled).map(\.id))
        let delivered = await center.deliveredNotifications()
        let orphaned = delivered.compactMap { notification -> String? in
            let request = notification.request
            guard request.identifier.hasPrefix(NotificationPlan.identifierPrefix)
                    || request.identifier.hasPrefix(Self.livePrefix),
                  let id = Self.reminderID(from: request.content.userInfo),
                  !active.contains(id)
            else { return nil }
            return request.identifier
        }
        if !orphaned.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: orphaned)
        }
    }

    private func makeRequest(for item: NotificationPlan.Item, now: Date) -> UNNotificationRequest {
        let trigger: UNNotificationTrigger
        let interval = item.fireDate.timeIntervalSince(now)
        if interval <= 1 {
            // Already due (an overdue reminder being scheduled from the
            // background path): deliver promptly rather than dropping it.
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        } else if item.isWallClockSlot {
            // Floating local time: "17:00" stays 17:00 if the device changes
            // time zone before then.
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: item.fireDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        } else {
            // An absolute moment: a zone change must not move it, and a
            // calendar trigger would.
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        }
        return UNNotificationRequest(
            identifier: item.identifier, content: makeContent(for: item), trigger: trigger
        )
    }

    private func makeContent(for item: NotificationPlan.Item) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = item.title
        if !item.body.isEmpty { content.body = item.body }
        content.categoryIdentifier = ActionID.category
        content.userInfo = [
            Self.reminderIDKey: item.reminderID.uuidString,
            Self.stampKey: item.stampDate.timeIntervalSince1970,
        ]
        if item.playsSound {
            if let name = item.soundName {
                content.sound = UNNotificationSound(
                    named: UNNotificationSoundName("\(name).caf")
                )
            } else {
                content.sound = .default
            }
        }
        switch item.interruption {
        case .passive: content.interruptionLevel = .passive
        case .active: content.interruptionLevel = .active
        case .timeSensitive: content.interruptionLevel = .timeSensitive
        }
        return content
    }

    // MARK: - Immediate posts (foreground fires and previews)

    /// Posts `reminder` right now — used when the engine fires it while the
    /// app is frontmost, so it lands in Notification Center exactly as a
    /// background delivery would have, and to hand an unacknowledged critical
    /// takeover to the lock screen when the app leaves the foreground.
    func postImmediate(_ reminder: Reminder, settings: ReminderCore.Settings) {
        let item = liveItem(for: reminder, settings: settings)
        let content = makeContent(for: item)
        let request = UNNotificationRequest(
            identifier: "\(Self.livePrefix)\(reminder.id.uuidString)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    /// Posts a one-off preview. Carries no reminder ID, so its buttons can
    /// never touch the real reminder's schedule or history.
    func postPreview(_ reminder: Reminder, settings: ReminderCore.Settings) {
        let item = liveItem(for: reminder, settings: settings)
        let content = makeContent(for: item)
        content.userInfo = [:]
        let request = UNNotificationRequest(
            identifier: "\(Self.previewPrefix)\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    private func liveItem(
        for reminder: Reminder, settings: ReminderCore.Settings
    ) -> NotificationPlan.Item {
        let now = Date()
        return NotificationPlan.Item(
            identifier: "",
            reminderID: reminder.id,
            title: reminder.title,
            body: reminder.message,
            fireDate: now,
            stampDate: now,
            priority: reminder.priority,
            soundName: Sounds.bundledName(for: reminder.soundName),
            playsSound: settings.playsSound(for: reminder.priority),
            interruption: NotificationPlan.interruption(for: reminder.priority),
            isWallClockSlot: false
        )
    }

    // MARK: - Reconciliation input

    /// Every scheduled notification the system delivered while the app was
    /// away, ready for `recordExternalFires`.
    func deliveredExternalFires() async -> [ReminderEngine.ExternalFire] {
        let delivered = await center.deliveredNotifications()
        return delivered.compactMap { notification in
            let request = notification.request
            guard request.identifier.hasPrefix(NotificationPlan.identifierPrefix),
                  let id = Self.reminderID(from: request.content.userInfo),
                  let stamp = request.content.userInfo[Self.stampKey] as? TimeInterval
            else { return nil }
            return ReminderEngine.ExternalFire(
                reminderID: id,
                stampDate: Date(timeIntervalSince1970: stamp),
                deliveredAt: notification.date
            )
        }
    }

    private nonisolated static func reminderID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard let raw = userInfo[Self.reminderIDKey] as? String else { return nil }
        return UUID(uuidString: raw)
    }
}

extension NotificationScheduler: UNUserNotificationCenterDelegate {

    /// Foreground delivery policy: pre-scheduled requests are suppressed while
    /// the app is frontmost — the engine's own tick presents the reminder
    /// in-app within seconds — while live posts and previews show as banners.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let identifier = notification.request.identifier
        Task { @MainActor in
            if identifier.hasPrefix(NotificationPlan.identifierPrefix),
               self.model?.isActive == true {
                completionHandler([])
            } else {
                completionHandler([.banner, .sound, .list])
            }
        }
    }

    /// The completion handler is called only after the follow-up scheduling
    /// pass has run: a response handled on a locked phone launches the app in
    /// the background, and the process may be suspended the moment the
    /// handler is called. Without the await, a snooze tapped there could
    /// never come back.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        let identifier = request.identifier
        let userInfo = request.content.userInfo
        let deliveredAt = response.notification.date
        let actionIdentifier = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            guard let id = Self.reminderID(from: userInfo) else { return }

            // A pre-scheduled delivery the user acted on definitely fired;
            // make sure the engine knows before recording their response.
            if identifier.hasPrefix(NotificationPlan.identifierPrefix),
               let stamp = userInfo[Self.stampKey] as? TimeInterval {
                self.engine.recordExternalFire(
                    id: id, at: Date(timeIntervalSince1970: stamp), deliveredAt: deliveredAt
                )
            }

            let action: ResponseAction
            switch actionIdentifier {
            case ActionID.complete, UNNotificationDefaultActionIdentifier:
                action = .complete
            case ActionID.snooze:
                action = .snooze
            case UNNotificationDismissActionIdentifier:
                action = .dismiss
            default:
                return
            }
            await self.model?.handleNotificationResponse(reminderID: id, action: action)
        }
    }
}
