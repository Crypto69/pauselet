import Foundation
import ReminderCore

/// The complete set of notification requests that should be pending, computed
/// purely from engine state so the budget math is testable without any iOS
/// framework.
///
/// Critical reminders are normally absent — AlarmKit carries them — but any
/// critical reminder alarms are *not* carrying (authorization denied, or a
/// single alarm that failed to schedule) is included as a time-sensitive
/// notification: a demoted reminder beats a dropped one.
struct NotificationPlan: Equatable {

    enum Interruption: String, Equatable {
        case passive
        case active
        case timeSensitive
    }

    struct Item: Equatable {
        let identifier: String
        let reminderID: UUID
        let title: String
        let body: String
        let fireDate: Date
        let stampDate: Date
        let priority: Priority
        /// Resolved bundled sound name (no extension), or `nil` for the
        /// system default sound.
        let soundName: String?
        let playsSound: Bool
        let interruption: Interruption
        /// Whether `fireDate` is a wall-clock slot (fire at 17:00 local, in
        /// whatever time zone the device is in by then) rather than an
        /// absolute moment (an interval elapsing, a snooze ending, a
        /// catch-up), which must not shift if the zone changes.
        let isWallClockSlot: Bool
        /// A Critical reminder's advance warning rather than the reminder:
        /// `fireDate` is when it shows and `stampDate` the takeover it
        /// announces. Never reconciled as a fire.
        var isWarning = false
    }

    let items: [Item]

    /// Slots claimed out of the system's 64-pending-request cap. The headroom
    /// covers immediate foreground posts and editor previews, which must not
    /// be squeezed out by a full schedule.
    static let budget = 60

    /// How many upcoming fires to project per reminder before allocation.
    static let projectionDepth = 8

    static let identifierPrefix = "pauselet-scheduled-"
    /// Advance warnings use their own prefix so nothing that reconciles
    /// fires (which keys on `identifierPrefix`) can mistake one for the
    /// reminder itself.
    static let warningPrefix = "pauselet-warning-"

    static func warningIdentifier(
        reminderID: UUID, takeoverAt: Date, contentKey: String
    ) -> String {
        "\(warningPrefix)\(reminderID.uuidString)-\(Int(takeoverAt.timeIntervalSince1970))-\(contentKey)"
    }

    /// The request identifier encodes the reminder, the stamp, and a digest of
    /// everything else baked into the request, so a refill can tell an
    /// already-pending request that is still exactly right from one that must
    /// be replaced — by comparing identifiers alone.
    static func identifier(reminderID: UUID, stampDate: Date, contentKey: String) -> String {
        "\(identifierPrefix)\(reminderID.uuidString)-\(Int(stampDate.timeIntervalSince1970))-\(contentKey)"
    }

    /// A stable digest of a request's content. `Hasher` is seeded per process,
    /// so this is a hand-rolled FNV-1a over the fields instead.
    static func contentKey(
        title: String,
        body: String,
        fireDate: Date,
        soundName: String?,
        playsSound: Bool,
        interruption: Interruption,
        isWallClockSlot: Bool
    ) -> String {
        let material = [
            title, body, String(Int(fireDate.timeIntervalSince1970)),
            soundName ?? "", playsSound ? "1" : "0", interruption.rawValue,
            isWallClockSlot ? "1" : "0",
        ].joined(separator: "\u{1F}")
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in material.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    static func build(
        reminders: [Reminder],
        settings: Settings,
        now: Date,
        alarmsCarrying: Set<UUID>,
        calendar: Calendar = .current
    ) -> NotificationPlan {
        let eligible = reminders.filter {
            $0.isEnabled && ($0.priority != .critical || !alarmsCarrying.contains($0.id))
        }
        let projections = eligible.map { reminder in
            (
                reminderID: reminder.id,
                fires: Scheduler.projectedFires(
                    for: reminder, from: now, limit: projectionDepth,
                    settings: settings, calendar: calendar
                )
            )
        }
        // Warnings are scheduled whoever carries the takeover: an AlarmKit
        // alarm covers the takeover itself, not the heads-up before it. Only
        // future ones: a warning already due would be posted again on every
        // refill, since nothing records that it was shown.
        let warnings = reminders.compactMap { reminder -> (reminderID: UUID, warnings: [ReminderWarning])? in
            let upcoming = Scheduler.projectedWarnings(
                for: reminder, from: now, limit: projectionDepth,
                settings: settings, calendar: calendar
            ).filter { $0.warnAt > now }
            return upcoming.isEmpty ? nil : (reminder.id, upcoming)
        }
        let entries = NotificationBudget.allocate(
            projections: projections, warnings: warnings, budget: budget
        )
        let byIDAll = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })

        let items = entries.compactMap { entry -> Item? in
            if entry.isWarning {
                guard let reminder = byIDAll[entry.reminderID] else { return nil }
                return warningItem(
                    for: reminder, warnAt: entry.fire.fireDate,
                    takeoverAt: entry.fire.stampDate, settings: settings, calendar: calendar
                )
            }
            guard let reminder = byID[entry.reminderID] else { return nil }
            let soundName = Sounds.bundledName(for: reminder.soundName)
            let playsSound = settings.playsSound(for: reminder.priority)
            let interruption = interruption(for: reminder.priority)
            let isWallClockSlot = reminder.schedule.isWallClock
                && entry.fire.fireDate == entry.fire.stampDate
            let key = contentKey(
                title: reminder.title, body: reminder.message,
                fireDate: entry.fire.fireDate, soundName: soundName,
                playsSound: playsSound, interruption: interruption,
                isWallClockSlot: isWallClockSlot
            )
            return Item(
                identifier: identifier(
                    reminderID: reminder.id, stampDate: entry.fire.stampDate, contentKey: key
                ),
                reminderID: reminder.id,
                title: reminder.title,
                body: reminder.message,
                fireDate: entry.fire.fireDate,
                stampDate: entry.fire.stampDate,
                priority: reminder.priority,
                soundName: soundName,
                playsSound: playsSound,
                interruption: interruption,
                isWallClockSlot: isWallClockSlot
            )
        }
        return NotificationPlan(items: items)
    }

    /// §3.2 of the plan: subtle goes straight to Notification Center, normal
    /// behaves normally, important (and critical, when demoted to a
    /// notification) pierces Focus modes that allow time-sensitive delivery.
    /// A warning is a time-sensitive notification with the default chime: it
    /// must get through a Focus to be any use, and its sound belongs to the
    /// takeover, not to the heads-up.
    static func warningItem(
        for reminder: Reminder,
        warnAt: Date,
        takeoverAt: Date,
        settings: Settings,
        calendar: Calendar
    ) -> Item {
        let title = Scheduler.warningTitle(for: reminder)
        let body = Scheduler.warningMessage(takeoverAt: takeoverAt, calendar: calendar)
        let playsSound = settings.playsSound(for: .important)
        let key = contentKey(
            title: title, body: body, fireDate: warnAt, soundName: nil,
            playsSound: playsSound, interruption: .timeSensitive, isWallClockSlot: false
        )
        return Item(
            identifier: warningIdentifier(
                reminderID: reminder.id, takeoverAt: takeoverAt, contentKey: key
            ),
            reminderID: reminder.id,
            title: title,
            body: body,
            fireDate: warnAt,
            stampDate: takeoverAt,
            priority: reminder.priority,
            soundName: nil,
            playsSound: playsSound,
            interruption: .timeSensitive,
            isWallClockSlot: false,
            isWarning: true
        )
    }

    static func interruption(for priority: Priority) -> Interruption {
        switch priority {
        case .subtle: return .passive
        case .normal: return .active
        case .important, .critical: return .timeSensitive
        }
    }
}
