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
        public let fire: ProjectedFire

        public init(reminderID: UUID, fire: ProjectedFire) {
            self.reminderID = reminderID
            self.fire = fire
        }
    }

    /// Allocates up to `budget` slots across `projections`, layer by layer.
    /// Within a layer, sooner fires win; ties break on the reminder ID so the
    /// result is deterministic.
    public static func allocate(
        projections: [(reminderID: UUID, fires: [ProjectedFire])],
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
