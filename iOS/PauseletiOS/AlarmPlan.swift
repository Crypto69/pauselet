import Foundation
import ReminderCore

/// Maps critical reminders onto AlarmKit's two schedule shapes, purely, so the
/// mapping rules are testable without the framework.
///
/// AlarmKit natively recurs weekly at a wall-clock time. Everything that fits
/// that shape uses it — a relative alarm keeps firing even if the app never
/// runs again. Everything else (intervals, every-N-days grids, snoozes, timed
/// pauses, quiet hours that critical must respect, a slot already consumed by
/// an early completion) becomes a one-shot fixed-date alarm at the next
/// projected fire, re-armed on acknowledgment or at the next foreground pass.
enum AlarmPlan {

    /// Everything that goes into a scheduled alarm. Persisted as the alarm
    /// registry, and compared whole on each sync: a change to *any* field —
    /// the schedule, but also the title, message, icon, or sound baked into
    /// the alarm — means the system's copy is stale and must be replaced.
    struct Spec: Equatable, Codable {
        enum Kind: Equatable, Codable {
            /// `weekdays` uses Calendar numbering: 1 = Sunday … 7 = Saturday.
            case relativeWeekly(hour: Int, minute: Int, weekdays: Set<Int>)
            case fixed(fireDate: Date, stampDate: Date)
        }

        let reminderID: UUID
        let title: String
        let message: String
        let symbolName: String
        /// The bundled sound the alarm plays. Critical always sounds — see
        /// `Sounds.criticalSound(for:)`.
        let soundName: String
        let kind: Kind
    }

    static func specs(
        for reminders: [Reminder],
        settings: Settings,
        now: Date,
        calendar: Calendar = .current
    ) -> [Spec] {
        // Paused indefinitely: no alarms at all. Resume triggers a fresh sync.
        if settings.isPaused && settings.pausedUntil == nil { return [] }

        return reminders
            .filter { $0.isEnabled && $0.priority == .critical }
            .compactMap { reminder in
                spec(for: reminder, settings: settings, now: now, calendar: calendar)
            }
    }

    private static func spec(
        for reminder: Reminder,
        settings: Settings,
        now: Date,
        calendar: Calendar
    ) -> Spec? {
        guard let kind = kind(for: reminder, settings: settings, now: now, calendar: calendar)
        else { return nil }
        return Spec(
            reminderID: reminder.id,
            title: reminder.title,
            message: alertMessage(for: reminder),
            symbolName: reminder.symbolName,
            soundName: Sounds.criticalSound(for: reminder),
            kind: kind
        )
    }

    /// The system alert and Live Activity are templated, so the exercise list
    /// itself can only appear after "Open". With no message of its own, an
    /// exercise reminder at least says what is waiting.
    static func alertMessage(for reminder: Reminder) -> String {
        if reminder.message.isEmpty, let summary = reminder.exerciseSummary {
            return summary
        }
        return reminder.message
    }

    private static func kind(
        for reminder: Reminder,
        settings: Settings,
        now: Date,
        calendar: Calendar
    ) -> Spec.Kind? {
        // A relative recurrence surrenders control to the system, so it is
        // only safe when nothing could need to suppress or move a fire: no
        // snooze pending, no timed pause running, no quiet hours that
        // critical is expected to respect, and no slot already consumed —
        // completing a daily reminder early stamps `lastFiredAt` with the
        // upcoming slot, and the system alarm would still ring at it.
        let canRecur = reminder.snoozedUntil == nil
            && settings.pausedUntil == nil
            && (!settings.quietHours.isEnabled || settings.quietHours.allowsCritical)
            && (reminder.lastFiredAt ?? .distantPast) <= now

        switch reminder.schedule {
        case .weeklyAt(let hour, let minute, let weekdays)
            where canRecur && !weekdays.isEmpty:
            return .relativeWeekly(hour: hour, minute: minute, weekdays: weekdays)

        case .dailyAt(let hour, let minute, let dayInterval)
            where canRecur && dayInterval <= 1:
            // Daily is weekly-on-every-day.
            return .relativeWeekly(hour: hour, minute: minute, weekdays: Set(1...7))

        default:
            guard let fire = Scheduler.projectedFires(
                for: reminder, from: now, limit: 1, settings: settings, calendar: calendar
            ).first else { return nil }
            return .fixed(fireDate: fire.fireDate, stampDate: fire.stampDate)
        }
    }

    /// The most recent time a relative rule rang at or before `date`, or
    /// `nil` if it has no selected days. A relative alarm repeats system-side
    /// without the app running, so the occurrence being acknowledged is
    /// computed from the rule rather than read from a cached date.
    static func latestOccurrence(
        hour: Int,
        minute: Int,
        weekdays: Set<Int>,
        atOrBefore date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard !weekdays.isEmpty else { return nil }
        let today = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let slot = calendar.date(
                    bySettingHour: hour, minute: minute, second: 0, of: day
                  )
            else { continue }
            if slot <= date { return slot }
        }
        return nil
    }
}
