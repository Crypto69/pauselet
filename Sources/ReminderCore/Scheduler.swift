import Foundation

/// Pure scheduling logic: given a reminder and "now", when should it next fire?
///
/// Everything here is a static function over explicit inputs so the behaviour
/// can be tested exhaustively without waiting on wall-clock time. The live app
/// layers a timer on top of this; the timer only ever asks these questions.
public enum Scheduler {

    /// The next date at which `reminder` should fire, or `nil` if it never will
    /// (disabled, or a weekly schedule with no weekdays selected).
    ///
    /// - Parameters:
    ///   - reminder: The reminder to evaluate.
    ///   - now: The reference time.
    ///   - calendar: Calendar used for wall-clock schedules.
    public static func nextFireDate(
        for reminder: Reminder,
        now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard reminder.isEnabled else { return nil }

        // A snooze is authoritative: it is the user saying "not before this
        // time", and it is also a promise that the reminder *will* come back.
        //
        // It therefore wins over the natural slot in both directions — it can
        // pull a fire in (snooze 2 min on an hourly reminder) and push one out
        // (snooze an already-overdue reminder). It also stays the answer once
        // elapsed, so a snooze whose moment passed between two ticks fires late
        // rather than silently evaporating. The engine clears `snoozedUntil` the
        // moment it honours it, so this can never fire twice.
        if let snoozedUntil = reminder.snoozedUntil {
            return snoozedUntil
        }
        return baseFireDate(for: reminder, now: now, calendar: calendar)
    }

    /// The next fire date ignoring any active snooze.
    private static func baseFireDate(
        for reminder: Reminder,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        switch reminder.schedule {
        case .interval(let minutes):
            let clamped = max(1, minutes)
            let seconds = TimeInterval(clamped * 60)
            // Intervals run from the last fire; a brand new reminder starts its
            // first interval from when it was created, so a 20-minute reminder
            // added now fires in 20 minutes rather than immediately.
            let anchor = reminder.lastFiredAt ?? reminder.createdAt
            let candidate = anchor.addingTimeInterval(seconds)
            if candidate > now { return candidate }
            // Overdue (app was asleep, or we are past due). Fire now rather than
            // replaying every interval that elapsed while we were away.
            return now

        case .dailyAt(let hour, let minute, let dayInterval):
            return nextDailyFireDate(
                hour: hour,
                minute: minute,
                dayInterval: max(1, dayInterval),
                lastFiredAt: reminder.lastFiredAt,
                createdAt: reminder.createdAt,
                now: now,
                calendar: calendar
            )

        case .weeklyAt(let hour, let minute, let weekdays):
            return nextWeeklyFireDate(
                hour: hour,
                minute: minute,
                weekdays: weekdays,
                now: now,
                calendar: calendar
            )
        }
    }

    static func nextDailyFireDate(
        hour: Int,
        minute: Int,
        dayInterval: Int,
        lastFiredAt: Date?,
        createdAt: Date,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        // The cycle is anchored on the day of the last fire (or creation), so
        // "every 2 days" stays in phase rather than drifting.
        let anchorDate = lastFiredAt ?? createdAt
        let anchorDay = calendar.startOfDay(for: anchorDate)

        // Walk forward from the anchor in `dayInterval` steps until we find a
        // slot in the future. Starting at step 0 catches a today-slot that has
        // not yet passed for a reminder that has never fired.
        var step = lastFiredAt == nil ? 0 : dayInterval
        // Bound the search so a pathological input cannot spin forever.
        let maxSteps = dayInterval * 400 + 400
        while step <= maxSteps {
            guard let day = calendar.date(byAdding: .day, value: step, to: anchorDay),
                  let slot = calendar.date(
                    bySettingHour: hour, minute: minute, second: 0, of: day
                  )
            else { return nil }
            if slot > now { return slot }
            step += dayInterval
        }
        return nil
    }

    static func nextWeeklyFireDate(
        hour: Int,
        minute: Int,
        weekdays: Set<Int>,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        guard !weekdays.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        // Check today plus the next 7 days so every weekday is covered even if
        // today's slot has already passed.
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: day)
            guard weekdays.contains(weekday) else { continue }
            guard let slot = calendar.date(
                bySettingHour: hour, minute: minute, second: 0, of: day
            ) else { continue }
            if slot > now { return slot }
        }
        return nil
    }

    /// Whether `reminder` is due to fire at `now`, accounting for global
    /// settings such as pause and quiet hours.
    public static func isDue(
        _ reminder: Reminder,
        now: Date,
        settings: Settings,
        calendar: Calendar = .current
    ) -> Bool {
        guard reminder.isEnabled else { return false }
        guard !isPaused(settings: settings, now: now) else { return false }
        guard !isSuppressedByQuietHours(
            priority: reminder.priority, settings: settings, now: now, calendar: calendar
        ) else { return false }
        guard let next = nextFireDate(for: reminder, now: now, calendar: calendar) else {
            return false
        }
        return next <= now
    }

    /// True when the master pause is active. A timed pause expires on its own.
    public static func isPaused(settings: Settings, now: Date) -> Bool {
        if let until = settings.pausedUntil {
            return now < until
        }
        return settings.isPaused
    }

    /// True when quiet hours should suppress a reminder of this priority.
    public static func isSuppressedByQuietHours(
        priority: Priority,
        settings: Settings,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let quiet = settings.quietHours
        guard quiet.contains(now, calendar: calendar) else { return false }
        if quiet.allowsCritical && priority == .critical { return false }
        return true
    }

    /// The soonest upcoming reminder across `reminders`, used for the menu bar
    /// countdown. Ties break toward the higher priority.
    public static func nextUpcoming(
        among reminders: [Reminder],
        now: Date,
        calendar: Calendar = .current
    ) -> (reminder: Reminder, date: Date)? {
        var best: (reminder: Reminder, date: Date)?
        for reminder in reminders {
            guard let date = nextFireDate(for: reminder, now: now, calendar: calendar) else {
                continue
            }
            guard let current = best else {
                best = (reminder, date)
                continue
            }
            if date < current.date
                || (date == current.date && reminder.priority > current.reminder.priority) {
                best = (reminder, date)
            }
        }
        return best
    }

    /// Human-readable countdown such as "in 4 min" or "in 2h 10m".
    public static func countdownText(from now: Date, to date: Date) -> String {
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 { return "now" }
        let totalMinutes = Int(remaining.rounded(.up)) / 60
        if totalMinutes < 1 { return "<1 min" }
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
}
