import Foundation
import Combine

/// Something that can present a reminder to the user.
///
/// The engine never touches AppKit directly; it hands fired reminders to a
/// presenter. Tests substitute a recording presenter to assert exactly what
/// would have been shown.
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
        for index in reminders.indices {
            let reminder = reminders[index]
            guard Scheduler.isDue(
                reminder, now: current, settings: settings, calendar: calendar
            ) else { continue }

            reminders[index].lastFiredAt = current
            reminders[index].snoozedUntil = nil
            fired.append(reminders[index])
        }

        if !fired.isEmpty {
            // Highest priority first, so a critical overlay is the last thing
            // presented and therefore the thing sitting in front of the user.
            let ordered = fired.sorted { $0.priority < $1.priority }
            for reminder in ordered {
                record(.fired, for: reminder, at: current)
                presenter?.present(reminder, settings: settings)
            }
            persist()
        }

        refreshNextUp()
        return fired
    }

    private func expireTimedPauseIfNeeded(at date: Date) {
        if let until = settings.pausedUntil, date >= until {
            settings.pausedUntil = nil
            settings.isPaused = false
            persist()
        }
    }

    private func refreshNextUp() {
        let candidates = reminders.filter { reminder in
            reminder.isEnabled && !Scheduler.isSuppressedByQuietHours(
                priority: reminder.priority,
                settings: settings,
                now: now,
                calendar: calendar
            )
        }
        nextUp = Scheduler.nextUpcoming(among: candidates, now: now, calendar: calendar)
    }

    // MARK: - User responses

    public func complete(id: UUID) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        let current = now
        reminders[index].lastAcknowledgedAt = current
        reminders[index].lastFiredAt = current
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
        if paused { presenter?.dismissAll() }
        persist()
        refreshNextUp()
    }

    public func pause(forMinutes minutes: Int) {
        settings.isPaused = true
        settings.pausedUntil = now.addingTimeInterval(TimeInterval(minutes * 60))
        presenter?.dismissAll()
        persist()
        refreshNextUp()
    }

    public func resume() {
        settings.isPaused = false
        settings.pausedUntil = nil
        // Re-anchor interval reminders so a long pause does not dump every
        // missed reminder on the user the instant they come back.
        let current = now
        for index in reminders.indices {
            if case .interval = reminders[index].schedule {
                reminders[index].lastFiredAt = current
            }
        }
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
        let fired = counts[.fired] ?? 0
        guard fired > 0 else { return nil }
        let completed = counts[.completed] ?? 0
        return min(1.0, Double(completed) / Double(fired))
    }
}
