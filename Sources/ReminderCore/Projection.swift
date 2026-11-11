import Foundation

/// One projected future delivery of a reminder.
///
/// `fireDate` is when the reminder reaches the user. `stampDate` is what
/// `lastFiredAt` must be stamped with when that fire is honoured — the
/// wall-clock slot for daily/weekly schedules, the delivery time otherwise —
/// mirroring what `ReminderEngine.tick()` stamps, so a fire delivered by the
/// system while the app was not running can be reconciled into exactly the
/// state a live tick would have produced.
public struct ProjectedFire: Equatable, Sendable {
    public let fireDate: Date
    public let stampDate: Date

    public init(fireDate: Date, stampDate: Date) {
        self.fireDate = fireDate
        self.stampDate = stampDate
    }
}

extension Scheduler {

    /// The next `limit` times `reminder` will actually reach the user.
    ///
    /// This is the keystone of pre-scheduled delivery (iOS): there is no tick
    /// loop watching the clock, so everything the engine would have decided at
    /// fire time must be decided now. It is nothing more than `nextStep`
    /// applied repeatedly — the same step `tick()` applies once — so the
    /// projection cannot hold an opinion the live engine does not share.
    /// Skipped slots (wall-clock slots inside quiet hours) are consumed but
    /// not returned; they are not deliveries.
    public static func projectedFires(
        for reminder: Reminder,
        from now: Date,
        limit: Int,
        settings: Settings,
        calendar: Calendar = .current
    ) -> [ProjectedFire] {
        guard reminder.isEnabled, limit > 0 else { return [] }

        var sim = reminder
        var cursor = now
        var fires: [ProjectedFire] = []
        // Bounded so a schedule that can never deliver (every slot inside
        // quiet hours, say) terminates instead of spinning.
        var iterations = 0
        let maxIterations = limit * 16 + 64

        while fires.count < limit, iterations < maxIterations {
            iterations += 1
            guard let step = nextStep(
                for: sim, from: cursor, settings: settings, calendar: calendar
            ) else { break }
            step.apply(to: &sim)
            cursor = step.fireDate
            if step.outcome == .deliver {
                fires.append(ProjectedFire(fireDate: step.fireDate, stampDate: step.stampDate))
            }
        }
        return fires
    }
}

/// An advance warning of a Critical takeover: shown at `warnAt`, saying the
/// screen will be taken over at `takeoverAt`.
public struct ReminderWarning: Equatable, Sendable {
    public let warnAt: Date
    public let takeoverAt: Date

    public init(warnAt: Date, takeoverAt: Date) {
        self.warnAt = warnAt
        self.takeoverAt = takeoverAt
    }
}

extension Scheduler {

    /// The next `limit` advance warnings of `reminder`'s takeovers, judged
    /// from `now`.
    ///
    /// Built on the same `nextStep` walk as `projectedFires`, so a warning
    /// can only ever announce a takeover the engine will actually deliver —
    /// quiet hours, pauses and skipped slots move or remove it exactly as
    /// they move or remove the takeover. A takeover gets no warning when:
    /// - it is a snooze coming back (the user just chose when);
    /// - the warning moment falls inside a pause, or inside quiet hours that
    ///   the takeover itself respects;
    /// - the warning moment is not after the previous fire, which happens
    ///   when the lead is as long as the interval.
    ///
    /// A warning whose moment has passed is still returned while its takeover
    /// is ahead, so an app that starts inside the window can still warn; the
    /// warning names the takeover's time, so it stays true however late.
    public static func projectedWarnings(
        for reminder: Reminder,
        from now: Date,
        limit: Int,
        settings: Settings,
        calendar: Calendar = .current
    ) -> [ReminderWarning] {
        guard reminder.isEnabled, reminder.priority == .critical,
              let minutes = reminder.warningMinutes, minutes > 0, limit > 0
        else { return [] }
        let lead = TimeInterval(minutes * 60)

        var sim = reminder
        var cursor = now
        var warnings: [ReminderWarning] = []
        var iterations = 0
        let maxIterations = limit * 16 + 64

        while warnings.count < limit, iterations < maxIterations {
            iterations += 1
            let wasSnoozed = sim.snoozedUntil != nil
            let previous = sim.lastFiredAt ?? sim.createdAt
            guard let step = nextStep(
                for: sim, from: cursor, settings: settings, calendar: calendar
            ) else { break }
            step.apply(to: &sim)
            cursor = step.fireDate
            guard step.outcome == .deliver, !wasSnoozed, step.fireDate > now else { continue }
            let warnAt = step.fireDate.addingTimeInterval(-lead)
            guard warnAt > previous,
                  !isPaused(settings: settings, now: warnAt),
                  !isSuppressedByQuietHours(
                    priority: .critical, settings: settings, now: warnAt, calendar: calendar
                  )
            else { continue }
            warnings.append(ReminderWarning(warnAt: warnAt, takeoverAt: step.fireDate))
        }
        return warnings
    }

    /// The lead an editor accepts: one minute up to a day — long enough for
    /// any heads-up, short enough that a typo cannot set one weeks ahead.
    public static let warningMinutesRange = 1...1440

    /// Whether a warning of `minutes` would have to come before the previous
    /// takeover of a repeating `schedule` — so none would ever be shown. The
    /// editors say so rather than leave the user waiting for a card.
    public static func warningOutlastsInterval(_ minutes: Int, schedule: Schedule) -> Bool {
        switch schedule {
        case .interval(let interval), .timedInterval(let interval, _, _, _, _, _):
            return minutes >= interval
        case .dailyAt, .weeklyAt:
            return false
        }
    }

    /// Whether a reminder's advance warning chimes: sounds are on (the warning
    /// follows the Important tier's rule, as its card does) and the reminder
    /// has not asked for a quiet one. The takeover's own sound is separate and
    /// unaffected.
    public static func warningPlaysSound(for reminder: Reminder, settings: Settings) -> Bool {
        settings.playsSound(for: .important) && reminder.warningIsSilent != true
    }

    /// The chime a warning plays when it plays one. A warning has its own
    /// sound rather than the reminder's: that belongs to the takeover.
    public static let defaultWarningSound = "Glass"

    /// The sound `reminder`'s warning plays, by name: the one chosen in the
    /// editor, or the default chime.
    public static func warningSound(for reminder: Reminder) -> String {
        reminder.warningSoundName ?? defaultWarningSound
    }

    /// The warning card's title, the same on every platform.
    public static func warningTitle(for reminder: Reminder) -> String {
        "Coming up: \(reminder.title)"
    }

    /// The warning card's text, naming the takeover's time rather than a
    /// countdown so it stays true however long it sits on screen.
    public static func warningMessage(takeoverAt: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.hour, .minute], from: takeoverAt)
        let time = Schedule.humanTime(hour: comps.hour ?? 0, minute: comps.minute ?? 0)
        return "Takes over your screen at \(time)."
    }
}

/// Divides the system's pending-notification budget across reminders.
///
/// iOS caps an app at 64 pending notification requests. Breadth-first
/// allocation guarantees the promise that matters: every reminder always has
/// at least its *next* fire scheduled before any reminder gets its second,
/// its second before any third, and so on — a 5-minute interval reminder can
/// never starve a daily one out of the budget.
public enum NotificationBudget {

    public struct Entry: Equatable, Sendable {
        public let reminderID: UUID
        /// For a warning, `fireDate` is when it is shown and `stampDate` the
        /// takeover it announces.
        public let fire: ProjectedFire
        public let isWarning: Bool

        public init(reminderID: UUID, fire: ProjectedFire, isWarning: Bool = false) {
            self.reminderID = reminderID
            self.fire = fire
            self.isWarning = isWarning
        }
    }

    /// Allocates up to `budget` slots across `projections`, layer by layer.
    /// Within a layer, sooner fires win; ties break on the reminder ID so the
    /// result is deterministic.
    ///
    /// Advance warnings take part as entries of their own, a reminder's next
    /// warning sitting in the same first layer as its next fire, so the
    /// heads-up is never the thing squeezed out.
    public static func allocate(
        projections: [(reminderID: UUID, fires: [ProjectedFire])],
        warnings: [(reminderID: UUID, warnings: [ReminderWarning])] = [],
        budget: Int
    ) -> [Entry] {
        guard budget > 0 else { return [] }
        // One flat sort by (depth, fire date, id) is the breadth-first order.
        // The ID string is computed once per reminder, not per comparison.
        struct Candidate {
            let depth: Int
            let key: String
            let entry: Entry
        }
        var candidates: [Candidate] = []
        for projection in projections {
            let key = projection.reminderID.uuidString
            for (depth, fire) in projection.fires.enumerated() {
                candidates.append(Candidate(
                    depth: depth, key: key,
                    entry: Entry(reminderID: projection.reminderID, fire: fire)
                ))
            }
        }
        for projection in warnings {
            let key = projection.reminderID.uuidString + "-warning"
            for (depth, warning) in projection.warnings.enumerated() {
                candidates.append(Candidate(
                    depth: depth, key: key,
                    entry: Entry(
                        reminderID: projection.reminderID,
                        fire: ProjectedFire(fireDate: warning.warnAt, stampDate: warning.takeoverAt),
                        isWarning: true
                    )
                ))
            }
        }
        candidates.sort {
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            if $0.entry.fire.fireDate != $1.entry.fire.fireDate {
                return $0.entry.fire.fireDate < $1.entry.fire.fireDate
            }
            return $0.key < $1.key
        }
        return candidates.prefix(budget).map(\.entry)
    }
}
