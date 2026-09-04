import Foundation
import Combine

/// Something that can present a reminder to the user.
///
/// The engine never touches AppKit directly; it hands fired reminders to a
/// presenter. Tests substitute a recording presenter to assert exactly what
/// would have been shown.
@MainActor
public protocol ReminderPresenting: AnyObject {
    func present(_ reminder: Reminder, settings: Settings)
    /// Called when a subtle/normal reminder should be taken off screen because
    /// the engine was paused or the reminder was disabled.
    func dismissAll()
}

/// Supplies "now". Injected so tests can drive time by hand.
public protocol DateProviding: Sendable {
    var now: Date { get }
}

public struct SystemDateProvider: DateProviding {
    public init() {}
    public var now: Date { Date() }
}

/// A clock the tests control directly.
public final class MutableDateProvider: DateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    public init(now: Date) { self._now = now }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }

    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        _now = date
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(interval)
    }
}

/// Owns the reminder list, decides what fires, and records history.
///
/// The engine is deliberately UI-agnostic: `tick()` is the single entry point
/// that advances the world, and it is safe to call as often as you like.
@MainActor
public final class ReminderEngine: ObservableObject {
    @Published public private(set) var reminders: [Reminder] = []
    @Published public var settings: Settings = Settings()
    @Published public private(set) var events: [ReminderEvent] = []

    /// The most recent tick's view of what fires next, for the menu bar.
    @Published public private(set) var nextUp: (reminder: Reminder, date: Date)?

    private let store: DataStoring
    private let dateProvider: DateProviding
    private weak var presenter: ReminderPresenting?
    private let calendar: Calendar

    /// History is capped so the file cannot grow without bound over years of use.
    public static let maxStoredEvents = 2000

    /// How recently a reminder must have fallen due to still be delivered
    /// late: by `absorbBacklogFromDowntime()` at launch, and by the
    /// presenter's queue when an acknowledgment finally arrives (see
    /// `shouldPresentQueued`).
    ///
    /// Long enough that quitting and relaunching — to install an update, say —
    /// does not swallow a reminder that genuinely came due in the meantime, and
    /// short enough that nothing from an earlier session survives it.
    public static let downtimeGrace: TimeInterval = 120

    public init(
        store: DataStoring,
        dateProvider: DateProviding = SystemDateProvider(),
        presenter: ReminderPresenting? = nil,
        calendar: Calendar = .current
    ) {
        self.store = store
        self.dateProvider = dateProvider
        self.presenter = presenter
        self.calendar = calendar
        loadFromStore()
    }

    public func setPresenter(_ presenter: ReminderPresenting?) {
        self.presenter = presenter
    }

    private var now: Date { dateProvider.now }

    // MARK: - Persistence

    private func loadFromStore() {
        do {
            let data = try store.load()
            reminders = data.reminders
            settings = data.settings
            events = data.events
            // A first launch loads the starter set from a file that does not
            // exist yet. Write it out straight away, so the reminders' timing
            // anchors survive a restart instead of being reseeded to "now"
            // every time the app opens.
            if !store.hasPersistedData {
                persist()
            }
        } catch {
            // A corrupt or unreadable file must not prevent the app from
            // starting; fall back to defaults rather than crashing on launch.
            reminders = DefaultReminders.starterSet(now: now)
            settings = Settings()
            events = []
        }
        refreshNextUp()
    }

    public func persist() {
        let data = AppData(
            reminders: reminders,
            settings: settings,
            events: Array(events.suffix(Self.maxStoredEvents))
        )
        try? store.save(data)
        // Adopt the stored precision in memory. Dates are written at
        // whole-second precision, so without this the in-memory values would
        // differ from disk by a fraction of a second and comparisons against a
        // reloaded reminder would fail.
        let normalized = FileDataStore.normalizingDates(data)
        reminders = normalized.reminders
        settings = normalized.settings
        events = normalized.events
    }

    // MARK: - CRUD

    public func add(_ reminder: Reminder) {
        var new = reminder
        // Anchor a new interval reminder to now so its first fire is a full
        // interval away rather than immediate.
        if new.lastFiredAt == nil { new.createdAt = now }
        reminders.append(new)
        persist()
        refreshNextUp()
    }

    public func update(_ reminder: Reminder) {
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else { return }
        reminders[index] = reminder
        persist()
        refreshNextUp()
    }

    public func delete(id: UUID) {
        reminders.removeAll { $0.id == id }
        persist()
        refreshNextUp()
    }

    public func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].isEnabled = enabled
        // Re-anchor so re-enabling does not fire instantly from a stale timestamp.
        if enabled {
            reminders[index].lastFiredAt = now
            reminders[index].snoozedUntil = nil
        }
        persist()
        refreshNextUp()
    }

    public func reminder(withID id: UUID) -> Reminder? {
        reminders.first { $0.id == id }
    }

    // MARK: - Ticking

    /// Consumes everything that fell due while the app was not running, without
    /// presenting any of it. Call once at launch, before the first `tick()`.
    ///
    /// A reminder is a request to be interrupted *at a moment*, not a debt that
    /// accrues while nobody is listening. Without this, opening the app after a
    /// day away replays the backlog in one burst: every interval reminder is
    /// overdue by design, and last night's wall-clock slot arrives at lunchtime
    /// — complete with its overlay and its music. That is not a late reminder,
    /// it is noise, and for a critical tier it is a full-screen takeover the
    /// user did nothing to deserve.
    ///
    /// Anything that came due within `downtimeGrace` is left alone, so a quick
    /// relaunch still delivers a reminder that is genuinely current.
    ///
    /// Sleep is deliberately not treated this way: the app *is* running, the
    /// user may well be sitting at a Mac that idled out, and a pressure-relief
    /// prompt still applies. See `tick()`'s catch-up path.
    @discardableResult
    public func absorbBacklogFromDowntime() -> [Reminder] {
        let current = now
        let cutoff = current.addingTimeInterval(-Self.downtimeGrace)
        var absorbed: [Reminder] = []

        // "Stale" means the running engine would have acted on it before the
        // cutoff. That is judged through `Scheduler.deliveryMoment`, so a fire
        // that merely fell due inside quiet hours — which the live engine
        // holds until the window ends, and would still deliver — is left
        // alone rather than being written off as missed.
        func isStale(_ due: Date, priority: Priority) -> Bool {
            guard let moment = Scheduler.deliveryMoment(
                for: due, priority: priority, settings: settings, calendar: calendar
            ) else { return due <= cutoff }
            return moment <= cutoff
        }

        // Stagger slots for the interval reminders that went fully overdue
        // while the machine was asleep, so they come back spread out and in
        // their original order rather than stacked on one instant. `cutoff`
        // stands in for when the engine stopped honouring fires.
        let staggered = Scheduler.reanchorAllForDowntime(
            reminders, downtimeStart: cutoff, resumeDate: current,
            includeReminder: { reminder in
                guard reminder.isEnabled, reminder.snoozedUntil == nil,
                      case .interval = reminder.schedule else { return false }
                guard let pending = Scheduler.pendingFireDate(
                    for: reminder, calendar: calendar
                ) else { return false }
                return isStale(pending, priority: reminder.priority)
            }
        )

        for index in reminders.indices where reminders[index].isEnabled {
            var didAbsorb = false
            let priority = reminders[index].priority

            // A snooze belongs to the session that set it: "remind me in five
            // minutes" said two days ago is not still owed.
            if let snoozedUntil = reminders[index].snoozedUntil,
               isStale(snoozedUntil, priority: priority) {
                reminders[index].snoozedUntil = nil
                didAbsorb = true
            }

            if reminders[index].snoozedUntil == nil {
                switch reminders[index].schedule {
                case .interval:
                    // An interval measures time spent working, and nothing was
                    // measuring it. Restart the clock, exactly as `resume()`
                    // does after a pause — each reminder getting a slot of its
                    // own so a set of them does not come back welded together.
                    if let pending = Scheduler.pendingFireDate(
                        for: reminders[index], calendar: calendar
                    ), isStale(pending, priority: priority) {
                        reminders[index].lastFiredAt =
                            staggered[reminders[index].id] ?? current
                        didAbsorb = true
                    }

                case .dailyAt, .weeklyAt:
                    // Stamping the elapsed slot consumes the whole backlog at
                    // once while keeping an "every N days" grid in phase. A
                    // slot inside the grace window is left for `tick()`.
                    if let slot = Scheduler.latestElapsedSlot(
                        for: reminders[index], now: current, calendar: calendar
                    ), isStale(slot, priority: priority) {
                        reminders[index].lastFiredAt = slot
                        didAbsorb = true
                    }
                }
            }

            if didAbsorb {
                record(.missed, for: reminders[index], at: current)
                absorbed.append(reminders[index])
            }
        }

        if !absorbed.isEmpty { persist() }
        refreshNextUp()
        return absorbed
    }

    /// Whether a presentation that has been waiting off-screen since `queuedAt`
    /// should still be shown once the user acknowledges reminder
    /// `acknowledgedID` at `now`.
    ///
    /// While a critical takeover sits unacknowledged the engine keeps ticking,
    /// so reminders that fall due fire into the presenter and queue behind the
    /// occupied screen. When the user finally responds hours later — they fell
    /// asleep, or walked away — replaying that queue means acknowledging one
    /// overlay only to be handed the next, and the next. The same principle as
    /// `absorbBacklogFromDowntime()` applies: a reminder is a request to be
    /// interrupted at a moment, and the moment of anything queued more than
    /// `downtimeGrace` ago has passed.
    ///
    /// A queued duplicate of the acknowledged reminder is dropped however
    /// fresh: the user has just said "done" (or "not now") to that reminder,
    /// and re-presenting it immediately would contradict them.
    public static func shouldPresentQueued(
        reminderID: UUID,
        queuedAt: Date,
        acknowledgedID: UUID,
        now: Date
    ) -> Bool {
        guard reminderID != acknowledgedID else { return false }
        return queuedAt > now.addingTimeInterval(-downtimeGrace)
    }

    /// A reminder fire the system delivered while the app was not running: a
    /// pre-scheduled notification or a system alarm (iOS).
    public struct ExternalFire: Equatable, Sendable {
        public let reminderID: UUID
        /// The `stampDate` the fire was scheduled with (see `ProjectedFire`).
        public let stampDate: Date
        /// When it reached the user. Defaults to the stamp, which is the
        /// delivery moment for every fire except a wall-clock catch-up.
        public let deliveredAt: Date

        public init(reminderID: UUID, stampDate: Date, deliveredAt: Date? = nil) {
            self.reminderID = reminderID
            self.stampDate = stampDate
            self.deliveredAt = max(stampDate, deliveredAt ?? stampDate)
        }
    }

    /// Records that `id` fired *outside* the running app. See
    /// `recordExternalFires(_:)`; this is the single-fire convenience.
    public func recordExternalFire(id: UUID, at stamp: Date, deliveredAt: Date? = nil) {
        recordExternalFires([
            ExternalFire(reminderID: id, stampDate: stamp, deliveredAt: deliveredAt)
        ])
    }

    /// Folds fires the system delivered on the app's behalf into engine
    /// state, so it matches what a live `tick()` would have produced: the
    /// anchor moves to the fire's stamp, a snooze the fire honoured is
    /// consumed, and history records the fire at the moment it reached the
    /// user — the same moment `tick()` records its own fires at.
    ///
    /// Idempotent: reconciliation runs on every foreground pass and must not
    /// duplicate history or move anchors backwards, so a fire that is already
    /// accounted for — by a previous pass, or because the app was running and
    /// ticked it — is left alone. A stamp at or before the reminder's anchor
    /// is a fire the engine could never have produced (an alarm rule's
    /// occurrence from before the reminder existed, say) and is ignored too.
    ///
    /// One persist for the whole batch: the first frame after days away can
    /// have dozens of these.
    public func recordExternalFires(_ fires: [ExternalFire]) {
        var changed = false
        for fire in fires.sorted(by: { $0.deliveredAt < $1.deliveredAt }) {
            guard let index = reminders.firstIndex(where: { $0.id == fire.reminderID })
            else { continue }
            let stamp = fire.stampDate.roundedToSecond
            let delivered = fire.deliveredAt.roundedToSecond
            let anchor = reminders[index].lastFiredAt ?? reminders[index].createdAt
            guard stamp > anchor else { continue }
            // Defence in depth against a rewound anchor (an edit saved from a
            // stale copy): the delivery moment is fixed for a given fire, so
            // an event already dated there means this fire is on record.
            if events.contains(where: {
                $0.reminderID == fire.reminderID && $0.outcome == .fired
                    && $0.date == delivered
            }) {
                continue
            }
            reminders[index].lastFiredAt = stamp
            // The fire that honoured a snooze consumes it. Deliberately
            // stricter than tick()'s unconditional clear: a snooze set *after*
            // this fire was delivered is a promise about the future, and the
            // past fire being reconciled must not eat it.
            if let snoozed = reminders[index].snoozedUntil, snoozed <= stamp {
                reminders[index].snoozedUntil = nil
            }
            record(.fired, for: reminders[index], at: delivered)
            changed = true
        }
        guard changed else { return }
        persist()
        refreshNextUp()
    }

    /// Records queued presentations the presenter dropped unshown (see
    /// `shouldPresentQueued`), so history still shows what happened to them.
    public func recordMissedPresentations(_ dropped: [Reminder]) {
        guard !dropped.isEmpty else { return }
        let current = now
        for reminder in dropped {
            record(.missed, for: reminder, at: current)
        }
        persist()
    }

    /// Advances the engine. Fires everything that is due and returns what fired.
    ///
    /// Safe to call at any frequency; a reminder cannot fire twice for the same
    /// due window because firing stamps `lastFiredAt`.
    @discardableResult
    public func tick() -> [Reminder] {
        let current = now
        expireTimedPauseIfNeeded(at: current)

        guard !Scheduler.isPaused(settings: settings, now: current) else {
            refreshNextUp()
            return []
        }

        var fired: [Reminder] = []
        var skippedAny = false
        for index in reminders.indices {
            // The whole firing policy — what the stamp is, whether a slot that
            // passed inside quiet hours is skipped, how a snooze is consumed —
            // lives in `Scheduler.nextStep`. The tick only asks whether the
            // step's moment has arrived and then applies it.
            guard let step = Scheduler.nextStep(
                for: reminders[index], from: current, settings: settings, calendar: calendar
            ), step.fireDate <= current else { continue }

            step.apply(to: &reminders[index])
            switch step.outcome {
            case .skip:
                record(.missed, for: reminders[index], at: current)
                skippedAny = true
            case .deliver:
                fired.append(reminders[index])
            }
        }

        if !fired.isEmpty {
            // Highest priority first, so a critical overlay is the last thing
            // presented and therefore the thing sitting in front of the user.
            let ordered = fired.sorted { $0.priority < $1.priority }
            for reminder in ordered {
                record(.fired, for: reminder, at: current)
                presenter?.present(reminder, settings: settings)
            }
        }
        if !fired.isEmpty || skippedAny {
            persist()
        }

        refreshNextUp()
        return fired
    }

    /// Re-anchors every interval reminder after a stretch of downtime,
    /// preserving how far apart they were.
    ///
    /// The policy itself lives in `Scheduler.reanchorForDowntime` so the
    /// projection (which must predict this without running the engine) and
    /// the live engine cannot drift apart.
    private func reanchorIntervals(downtimeStart: Date, resumeDate: Date) {
        let anchors = Scheduler.reanchorAllForDowntime(
            reminders, downtimeStart: downtimeStart, resumeDate: resumeDate
        )
        guard !anchors.isEmpty else { return }
        for index in reminders.indices {
            if let anchor = anchors[reminders[index].id] {
                reminders[index].lastFiredAt = anchor
            }
        }
    }

    /// A timed pause that has run out lifts itself, and re-anchors interval
    /// reminders to the moment it ended — the same thing `resume()` does by
    /// hand, and what the projection assumed while the pause was running —
    /// so a long pause never dumps an overdue fire on the user the instant it
    /// lifts. Anchors already past the pause's end are left alone.
    private func expireTimedPauseIfNeeded(at date: Date) {
        guard let until = settings.pausedUntil, date >= until else { return }
        let pausedAt = settings.pausedAt
        settings.pausedUntil = nil
        settings.isPaused = false
        settings.pausedAt = nil
        reanchorIntervals(downtimeStart: pausedAt ?? until, resumeDate: until)
        persist()
    }

    private func refreshNextUp() {
        // The countdown shows when a reminder will actually reach the user:
        // the projection's first delivery, which judges quiet hours at each
        // candidate's fire time and looks past a timed pause. During quiet
        // hours the true next fire is the 07:00 one, and a slot that lands
        // inside the window will not really fire then.
        let current = now
        var best: (reminder: Reminder, date: Date)?
        for reminder in reminders where reminder.isEnabled {
            guard let date = Scheduler.projectedFires(
                for: reminder, from: current, limit: 1,
                settings: settings, calendar: calendar
            ).first?.fireDate else { continue }
            if let currentBest = best {
                if date < currentBest.date
                    || (date == currentBest.date
                        && reminder.priority > currentBest.reminder.priority) {
                    best = (reminder, date)
                }
            } else {
                best = (reminder, date)
            }
        }
        nextUp = best
    }

    // MARK: - User responses

    public func complete(id: UUID) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        let current = now
        let reminder = reminders[index]

        switch reminder.schedule {
        case .interval:
            // The interval restarts from the completion, so "done" always buys
            // a full interval of peace.
            reminders[index].lastFiredAt = current

        case .dailyAt, .weeklyAt:
            // Distinguish acknowledging a fire that just happened from marking
            // the task done ahead of its slot. A fire newer than the last
            // acknowledgement means this is the acknowledgement — keep the fire
            // stamp so the next slot stays on schedule. Otherwise the user did
            // the task early, so consume the upcoming slot rather than firing
            // it a few hours after they said "done".
            let awaitingAck: Bool = {
                guard let firedAt = reminder.lastFiredAt else { return false }
                guard let ackedAt = reminder.lastAcknowledgedAt else { return true }
                return firedAt > ackedAt
            }()
            if !awaitingAck {
                if let upcoming = Scheduler.nextScheduleSlot(
                    for: reminder, calendar: calendar
                ), upcoming > current {
                    reminders[index].lastFiredAt = upcoming
                } else {
                    // The slot already elapsed without firing (sleep, quiet
                    // hours): completing consumes that elapsed slot too.
                    reminders[index].lastFiredAt = Scheduler.latestElapsedSlot(
                        for: reminder, now: current, calendar: calendar
                    ) ?? current
                }
            }
        }

        reminders[index].lastAcknowledgedAt = current
        reminders[index].snoozedUntil = nil
        record(.completed, for: reminders[index], at: current)
        persist()
        refreshNextUp()
    }

    public func snooze(id: UUID, minutes: Int? = nil) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        let current = now
        let delay = max(1, minutes ?? settings.snoozeMinutes)
        reminders[index].snoozedUntil = current.addingTimeInterval(TimeInterval(delay * 60))
        record(.snoozed, for: reminders[index], at: current)
        persist()
        refreshNextUp()
    }

    public func dismiss(id: UUID) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        let current = now
        reminders[index].lastAcknowledgedAt = current
        record(.dismissed, for: reminders[index], at: current)
        persist()
        refreshNextUp()
    }

    // MARK: - Global controls

    public func setPaused(_ paused: Bool) {
        settings.isPaused = paused
        settings.pausedUntil = nil
        settings.pausedAt = paused ? now : nil
        if paused { presenter?.dismissAll() }
        persist()
        refreshNextUp()
    }

    public func pause(forMinutes minutes: Int) {
        settings.isPaused = true
        settings.pausedAt = now
        settings.pausedUntil = now.addingTimeInterval(TimeInterval(minutes * 60))
        presenter?.dismissAll()
        persist()
        refreshNextUp()
    }

    public func resume() {
        let pausedAt = settings.pausedAt
        settings.isPaused = false
        settings.pausedUntil = nil
        settings.pausedAt = nil
        // Re-anchor interval reminders so a long pause does not dump every
        // missed reminder on the user the instant they come back — while
        // preserving how far apart they were. Stamping them all with `now`
        // (which this used to do) welds every reminder sharing an interval
        // onto the same second, permanently.
        let current = now
        reanchorIntervals(downtimeStart: pausedAt ?? current, resumeDate: current)
        persist()
        refreshNextUp()
    }

    public func updateSettings(_ newSettings: Settings) {
        settings = newSettings
        persist()
        refreshNextUp()
    }

    // MARK: - History

    private func record(_ outcome: ReminderEvent.Outcome, for reminder: Reminder, at date: Date) {
        events.append(
            ReminderEvent(
                reminderID: reminder.id,
                reminderTitle: reminder.title,
                date: date,
                outcome: outcome
            )
        )
        if events.count > Self.maxStoredEvents {
            events.removeFirst(events.count - Self.maxStoredEvents)
        }
    }

    public func clearHistory() {
        events.removeAll()
        persist()
    }

    /// Counts of each outcome for `reminderID` since `date`, for the stats view.
    public func stats(for reminderID: UUID, since date: Date) -> [ReminderEvent.Outcome: Int] {
        var counts: [ReminderEvent.Outcome: Int] = [:]
        for event in events where event.reminderID == reminderID && event.date >= date {
            counts[event.outcome, default: 0] += 1
        }
        return counts
    }

    /// Adherence for `reminderID`: completed ÷ fired, over the given window.
    /// Returns `nil` when nothing fired in the window.
    public func adherence(for reminderID: UUID, since date: Date) -> Double? {
        let counts = stats(for: reminderID, since: date)
        return Self.adherence(fired: counts[.fired] ?? 0, completed: counts[.completed] ?? 0)
    }

    /// Adherence for every reminder that fired in the window, in one pass over
    /// history — the history screen asks for all of them at once.
    public func adherence(since date: Date) -> [UUID: Double] {
        var fired: [UUID: Int] = [:]
        var completed: [UUID: Int] = [:]
        for event in events where event.date >= date {
            switch event.outcome {
            case .fired: fired[event.reminderID, default: 0] += 1
            case .completed: completed[event.reminderID, default: 0] += 1
            default: break
            }
        }
        var result: [UUID: Double] = [:]
        for (id, count) in fired {
            if let value = Self.adherence(fired: count, completed: completed[id] ?? 0) {
                result[id] = value
            }
        }
        return result
    }

    private static func adherence(fired: Int, completed: Int) -> Double? {
        guard fired > 0 else { return nil }
        return min(1.0, Double(completed) / Double(fired))
    }
}
