import Foundation

/// Pure scheduling logic: given a reminder and "now", when should it next fire?
///
/// Everything here is a static function over explicit inputs so the behaviour
/// can be tested exhaustively without waiting on wall-clock time. The live app
/// layers a timer on top of this; the timer only ever asks these questions.
///
/// The central concept is the *pending* fire: the moment the reminder is next
/// obliged to fire, computed purely from its own anchors (`lastFiredAt`,
/// `createdAt`) and never from "now". A pending date in the past means the
/// reminder is overdue and fires at the next tick. Computing due-ness this way
/// is what lets a daily 17:00 reminder actually fire when a tick lands at
/// 17:00:04 — a "next future slot" formulation can only ever see tomorrow.
public enum Scheduler {

    /// The next date at which `reminder` should fire, or `nil` if it never will
    /// (disabled, or a weekly schedule with no weekdays selected).
    ///
    /// An overdue reminder answers `now`: it fires at the next tick, and the
    /// menu bar should say "due", not count down to a slot that already passed.
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
        guard let pending = pendingFireDate(for: reminder, calendar: calendar) else {
            return nil
        }
        return pending > now ? pending : now
    }

    /// The moment `reminder` is next obliged to fire, independent of "now".
    ///
    /// A date in the past means the reminder is overdue: it should fire at the
    /// next opportunity. Firing stamps `lastFiredAt`, which moves the pending
    /// date forward — that stamp is the only thing that consumes a slot, so a
    /// slot that passes while the app is asleep is delivered late rather than
    /// silently skipped.
    public static func pendingFireDate(
        for reminder: Reminder,
        calendar: Calendar = .current
    ) -> Date? {
        guard reminder.isEnabled else { return nil }
        if let snoozedUntil = reminder.snoozedUntil {
            return snoozedUntil
        }
        return nextScheduleSlot(for: reminder, calendar: calendar)
    }

    /// The first slot of `reminder`'s schedule strictly after its anchor
    /// (`lastFiredAt`, or `createdAt` if it has never fired), ignoring any
    /// snooze. This is the schedule's own opinion of when it fires next.
    public static func nextScheduleSlot(
        for reminder: Reminder,
        calendar: Calendar = .current
    ) -> Date? {
        let anchor = reminder.lastFiredAt ?? reminder.createdAt
        switch reminder.schedule {
        case .interval(let minutes):
            let clamped = max(1, minutes)
            // Intervals run from the last fire; a brand new reminder starts its
            // first interval from when it was created, so a 20-minute reminder
            // added now fires in 20 minutes rather than immediately.
            return anchor.addingTimeInterval(TimeInterval(clamped * 60))

        case .dailyAt(let hour, let minute, let dayInterval):
            return firstDailySlot(
                after: anchor,
                hour: hour,
                minute: minute,
                dayInterval: max(1, dayInterval),
                calendar: calendar
            )

        case .weeklyAt(let hour, let minute, let weekdays):
            return firstWeeklySlot(
                after: anchor,
                hour: hour,
                minute: minute,
                weekdays: weekdays,
                calendar: calendar
            )
        }
    }

    /// The first daily-grid slot strictly after `anchor`. The grid is anchored
    /// on `anchor`'s day, so "every 2 days" stays in phase rather than drifting.
    static func firstDailySlot(
        after anchor: Date,
        hour: Int,
        minute: Int,
        dayInterval: Int,
        calendar: Calendar
    ) -> Date? {
        let anchorDay = calendar.startOfDay(for: anchor)
        // Starting at step 0 catches an anchor-day slot that is still ahead of
        // the anchor itself (a reminder created in the morning for 17:00).
        var step = 0
        // Bound the search so a pathological input cannot spin forever.
        let maxSteps = dayInterval * 400 + 400
        while step <= maxSteps {
            // A day whose slot cannot be materialised (a DST hole) is skipped
            // rather than aborting the whole search.
            if let day = calendar.date(byAdding: .day, value: step, to: anchorDay),
               let slot = calendar.date(
                bySettingHour: hour, minute: minute, second: 0, of: day
               ),
               slot > anchor {
                return slot
            }
            step += dayInterval
        }
        return nil
    }

    /// The first selected-weekday slot strictly after `anchor`.
    static func firstWeeklySlot(
        after anchor: Date,
        hour: Int,
        minute: Int,
        weekdays: Set<Int>,
        calendar: Calendar
    ) -> Date? {
        guard !weekdays.isEmpty else { return nil }
        let anchorDay = calendar.startOfDay(for: anchor)
        // Check the anchor day plus the next 7 so every weekday is covered even
        // if the anchor day's own slot has already passed.
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: anchorDay),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let slot = calendar.date(
                    bySettingHour: hour, minute: minute, second: 0, of: day
                  )
            else { continue }
            if slot > anchor { return slot }
        }
        return nil
    }

    /// For a wall-clock schedule, the most recent slot that has already passed:
    /// after the anchor, at or before `now`. `nil` for interval schedules and
    /// when no slot has elapsed.
    ///
    /// This is what the engine stamps into `lastFiredAt` when a wall-clock
    /// reminder fires. Stamping the slot rather than the tick time keeps an
    /// "every 2 days" grid in phase, and collapsing to the *latest* elapsed
    /// slot is what turns a week of missed slots into a single catch-up fire
    /// instead of a cascade.
    public static func latestElapsedSlot(
        for reminder: Reminder,
        now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        let anchor = reminder.lastFiredAt ?? reminder.createdAt
        switch reminder.schedule {
        case .interval:
            return nil

        case .dailyAt(let hour, let minute, let dayInterval):
            let interval = max(1, dayInterval)
            let anchorDay = calendar.startOfDay(for: anchor)
            let nowDay = calendar.startOfDay(for: now)
            guard let days = calendar.dateComponents(
                [.day], from: anchorDay, to: nowDay
            ).day, days >= 0 else { return nil }
            // Jump straight to the last grid day at or before today, then walk
            // back a step at a time; the answer is at most a couple of
            // iterations away regardless of how long the gap was.
            var step = (days / interval) * interval
            while step >= 0 {
                if let day = calendar.date(byAdding: .day, value: step, to: anchorDay),
                   let slot = calendar.date(
                    bySettingHour: hour, minute: minute, second: 0, of: day
                   ) {
                    if slot <= now {
                        return slot > anchor ? slot : nil
                    }
                }
                step -= interval
            }
            return nil

        case .weeklyAt(let hour, let minute, let weekdays):
            guard !weekdays.isEmpty else { return nil }
            let today = calendar.startOfDay(for: now)
            // Walk backwards from today; the most recent selected slot is
            // within the last 7 days if one exists at all.
            for offset in 0...7 {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                      weekdays.contains(calendar.component(.weekday, from: day)),
                      let slot = calendar.date(
                        bySettingHour: hour, minute: minute, second: 0, of: day
                      )
                else { continue }
                if slot <= now && slot > anchor { return slot }
                if slot <= now { return nil }
            }
            return nil
        }
    }

    // MARK: - The advance step

    /// The engine's next action on a reminder: the one decision that
    /// `ReminderEngine.tick()` applies when its moment arrives and that the
    /// projection (`projectedFires`) applies over and over to look ahead.
    ///
    /// Keeping this a single pure function is what stops the live engine and
    /// pre-scheduled delivery (iOS) from disagreeing about when a reminder
    /// reaches the user or what it is stamped with: there is one policy, and
    /// both sides can only apply it.
    public struct FireStep: Equatable, Sendable {
        public enum Outcome: Equatable, Sendable {
            /// The reminder reaches the user at `fireDate`.
            case deliver
            /// A wall-clock slot that passed inside quiet hours is consumed
            /// unheard at `fireDate` and recorded as missed — "daily at
            /// 23:00" must not arrive at 07:00.
            case skip
        }

        /// When the engine acts: delivers the reminder, or notices the skip.
        public let fireDate: Date
        /// What `lastFiredAt` becomes: the wall-clock slot the fire honours
        /// (so an "every 2 days" grid stays in phase), or the delivery moment
        /// for interval and snoozed fires.
        public let stampDate: Date
        public let outcome: Outcome

        public init(fireDate: Date, stampDate: Date, outcome: Outcome) {
            self.fireDate = fireDate
            self.stampDate = stampDate
            self.outcome = outcome
        }

        /// Writes the step into `reminder`, exactly as the engine does the
        /// moment it acts on it.
        public func apply(to reminder: inout Reminder) {
            reminder.lastFiredAt = stampDate
            reminder.snoozedUntil = nil
        }
    }

    /// The next thing the engine will do with `reminder` at or after `now`,
    /// or `nil` if nothing will ever happen (disabled, paused indefinitely, a
    /// weekly schedule with no days).
    ///
    /// The rules, in order:
    /// - An indefinite pause schedules nothing. A timed pause schedules
    ///   nothing before it ends, and re-anchors interval reminders to its end
    ///   — the same thing the engine does when the pause expires — so a long
    ///   pause never dumps an overdue fire the instant it lifts.
    /// - A snooze is authoritative and fires exactly once, at its moment.
    /// - A fire that falls due inside quiet hours waits for the window to
    ///   end. Interval and snoozed fires are then delivered ("it has been an
    ///   hour since water" is still true at 07:00); a wall-clock slot is
    ///   judged *at the slot*: one that passed inside the window is skipped,
    ///   one that passed outside it (the app was asleep from 17:00 until the
    ///   window began) is delivered late, stamped with the slot.
    /// - Overdue wall-clock slots collapse to the latest elapsed one, so a
    ///   week away becomes a single catch-up rather than a cascade.
    public static func nextStep(
        for reminder: Reminder,
        from now: Date,
        settings: Settings,
        calendar: Calendar = .current
    ) -> FireStep? {
        guard reminder.isEnabled else { return nil }
        if settings.pausedUntil == nil, settings.isPaused { return nil }

        var sim = reminder
        var cursor = now
        if let until = settings.pausedUntil, until > now {
            cursor = until
            if case .interval = sim.schedule, (sim.lastFiredAt ?? sim.createdAt) < until {
                sim.lastFiredAt = until
            }
        }

        guard let pending = pendingFireDate(for: sim, calendar: calendar) else { return nil }
        let due = max(pending, cursor)
        guard let fireAt = deliveryMoment(
            for: due, priority: sim.priority, settings: settings, calendar: calendar
        ) else { return nil }

        if sim.snoozedUntil != nil || !sim.schedule.isWallClock {
            return FireStep(fireDate: fireAt, stampDate: fireAt, outcome: .deliver)
        }

        let slot = latestElapsedSlot(for: sim, now: fireAt, calendar: calendar) ?? fireAt
        let skipped = isSuppressedByQuietHours(
            priority: sim.priority, settings: settings, now: slot, calendar: calendar
        )
        return FireStep(fireDate: fireAt, stampDate: slot, outcome: skipped ? .skip : .deliver)
    }

    /// When a fire that falls due at `due` is actually acted on: `due` itself,
    /// or — if quiet hours cover it — the moment the window ends. `nil` only
    /// when the window's end cannot be computed.
    public static func deliveryMoment(
        for due: Date,
        priority: Priority,
        settings: Settings,
        calendar: Calendar = .current
    ) -> Date? {
        guard isSuppressedByQuietHours(
            priority: priority, settings: settings, now: due, calendar: calendar
        ) else { return due }
        return settings.quietHours.nextEnd(after: due, calendar: calendar)
    }

    /// Whether `reminder` is due to fire at `now`, accounting for global
    /// settings such as pause and quiet hours. Defined through `nextStep` so
    /// it cannot disagree with what the engine would actually do.
    public static func isDue(
        _ reminder: Reminder,
        now: Date,
        settings: Settings,
        calendar: Calendar = .current
    ) -> Bool {
        guard let step = nextStep(
            for: reminder, from: now, settings: settings, calendar: calendar
        ) else { return false }
        return step.fireDate <= now
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
