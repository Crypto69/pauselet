import XCTest
@testable import ReminderCore

/// Tests for `Scheduler.nextStep` — the one firing decision that `tick()`
/// applies once and the projection loops — and for the places that must agree
/// with it: the live engine, launch absorption, and the next-up countdown.
///
/// The projection used to be a second hand-maintained copy of tick()'s
/// policy, and it drifted twice (quiet hours judged at delivery instead of at
/// the slot; a timed pause re-anchoring intervals on one path but not the
/// other). These tests pin the cases that drifted and, more importantly, run
/// the two side by side over days of simulated time.
@MainActor
final class AdvanceStepTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0
    ) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        return calendar.date(from: comps)!
    }

    private func quietSettings(
        start: (Int, Int) = (22, 0), end: (Int, Int) = (7, 0), allowsCritical: Bool = true
    ) -> Settings {
        var settings = Settings()
        settings.quietHours = QuietHours(
            isEnabled: true,
            startHour: start.0, startMinute: start.1,
            endHour: end.0, endMinute: end.1,
            allowsCritical: allowsCritical
        )
        return settings
    }

    private func makeEngine(
        reminders: [Reminder],
        settings: Settings = Settings(),
        now: Date
    ) -> (ReminderEngine, MutableDateProvider, RecordingPresenter) {
        let store = InMemoryDataStore(
            data: AppData(reminders: reminders, settings: settings, events: [])
        )
        let clock = MutableDateProvider(now: now)
        let presenter = RecordingPresenter()
        let engine = ReminderEngine(
            store: store, dateProvider: clock, presenter: presenter, calendar: calendar
        )
        return (engine, clock, presenter)
    }

    // MARK: - Quiet hours are judged at the slot, on both sides

    /// A 17:00 slot that elapsed *outside* quiet hours while the app was
    /// paused into the window is delivered when the window ends — the
    /// projection used to consume it as a skip, so an iOS user never got it.
    func testSlotThatPassedOutsideQuietHoursIsDeliveredAfterTheWindow() {
        var settings = quietSettings()
        settings.isPaused = true
        settings.pausedUntil = date(2026, 3, 10, 23, 0)
        var reminder = Reminder(
            title: "Stretch",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1),
            createdAt: date(2026, 3, 9, 9, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 9, 17, 0)

        let fires = Scheduler.projectedFires(
            for: reminder, from: date(2026, 3, 10, 16, 0), limit: 2,
            settings: settings, calendar: calendar
        )
        XCTAssertEqual(fires.first?.fireDate, date(2026, 3, 11, 7, 0))
        XCTAssertEqual(fires.first?.stampDate, date(2026, 3, 10, 17, 0))
        XCTAssertEqual(fires.dropFirst().first?.fireDate, date(2026, 3, 11, 17, 0))

        // And the live engine does the same.
        let (engine, clock, presenter) = makeEngine(
            reminders: [reminder], settings: settings, now: date(2026, 3, 10, 16, 0)
        )
        clock.set(date(2026, 3, 10, 23, 0, 5))
        XCTAssertTrue(engine.tick().isEmpty, "Inside quiet hours")
        clock.set(date(2026, 3, 11, 7, 0, 5))
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(presenter.presented.map(\.title), ["Stretch"])
        XCTAssertEqual(engine.reminders[0].lastFiredAt, date(2026, 3, 10, 17, 0))
    }

    /// A 23:00 slot that passed *inside* quiet hours is skipped even when the
    /// first chance to deliver it (a pause ending at 07:30) is outside the
    /// window — the projection used to deliver it at 07:30.
    func testSlotThatPassedInsideQuietHoursIsSkippedEvenWhenDeliveryWouldBeOutside() {
        var settings = quietSettings()
        settings.isPaused = true
        settings.pausedUntil = date(2026, 3, 11, 7, 30)
        var reminder = Reminder(
            title: "Late pills",
            schedule: .dailyAt(hour: 23, minute: 0, dayInterval: 1),
            createdAt: date(2026, 3, 9, 9, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 9, 23, 0)

        let fires = Scheduler.projectedFires(
            for: reminder, from: date(2026, 3, 10, 21, 0), limit: 1,
            settings: settings, calendar: calendar
        )
        XCTAssertTrue(fires.isEmpty, "Every 23:00 slot is inside the window")

        let step = Scheduler.nextStep(
            for: reminder, from: date(2026, 3, 10, 21, 0), settings: settings, calendar: calendar
        )
        XCTAssertEqual(step?.outcome, .skip)
        XCTAssertEqual(step?.stampDate, date(2026, 3, 10, 23, 0))
        XCTAssertEqual(step?.fireDate, date(2026, 3, 11, 7, 30), "Noticed when the pause lifts")

        let (engine, clock, presenter) = makeEngine(
            reminders: [reminder], settings: settings, now: date(2026, 3, 10, 21, 0)
        )
        clock.set(date(2026, 3, 11, 7, 30, 5))
        XCTAssertTrue(engine.tick().isEmpty)
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertEqual(engine.events.map(\.outcome), [.missed])
        XCTAssertEqual(engine.reminders[0].lastFiredAt, date(2026, 3, 10, 23, 0))
    }

    // MARK: - Timed pause: one behaviour

    /// The projection made while a timed pause runs must describe exactly
    /// what the engine does once the pause expires on its own.
    func testProjectionDuringTimedPauseMatchesEngineAfterExpiry() {
        var settings = Settings()
        settings.isPaused = true
        settings.pausedUntil = date(2026, 3, 10, 12, 0)
        var reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 30), createdAt: date(2026, 3, 10, 9, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 10, 9, 30)

        let projected = Scheduler.projectedFires(
            for: reminder, from: date(2026, 3, 10, 10, 0), limit: 2,
            settings: settings, calendar: calendar
        )
        XCTAssertEqual(projected.map(\.fireDate), [
            date(2026, 3, 10, 12, 30), date(2026, 3, 10, 13, 0),
        ])

        let (engine, clock, _) = makeEngine(
            reminders: [reminder], settings: settings, now: date(2026, 3, 10, 10, 0)
        )
        var fired: [Date] = []
        var cursor = date(2026, 3, 10, 10, 0)
        while cursor <= date(2026, 3, 10, 13, 0) {
            clock.set(cursor)
            if !engine.tick().isEmpty { fired.append(cursor) }
            cursor = cursor.addingTimeInterval(60)
        }
        XCTAssertEqual(fired, projected.map(\.fireDate))
    }

    func testNextUpDuringTimedPauseLooksPastThePause() {
        var reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 30), createdAt: date(2026, 3, 10, 9, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 10, 9, 30)
        let (engine, _, _) = makeEngine(reminders: [reminder], now: date(2026, 3, 10, 10, 0))

        engine.pause(forMinutes: 120)
        XCTAssertEqual(engine.nextUp?.date, date(2026, 3, 10, 12, 30))

        engine.setPaused(true)
        XCTAssertNil(engine.nextUp, "An indefinite pause schedules nothing")
    }

    // MARK: - Absorption respects quiet hours

    /// An interval fire that fell due inside quiet hours is not a missed
    /// reminder: the live engine holds it until the window ends. Opening the
    /// app at 06:00 must leave it to fire at 07:00.
    func testAbsorbLeavesAFireHeldByQuietHours() {
        let settings = quietSettings()
        var reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 60), createdAt: date(2026, 3, 10, 20, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 10, 22, 30)
        let (engine, clock, presenter) = makeEngine(
            reminders: [reminder], settings: settings, now: date(2026, 3, 11, 6, 0)
        )

        XCTAssertTrue(engine.absorbBacklogFromDowntime().isEmpty)
        XCTAssertTrue(engine.events.isEmpty, "No false 'missed' entry")
        XCTAssertEqual(engine.reminders[0].lastFiredAt, date(2026, 3, 10, 22, 30))

        clock.set(date(2026, 3, 11, 7, 0, 5))
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(presenter.presented.map(\.title), ["Water"])
    }

    func testAbsorbLeavesASnoozeHeldByQuietHours() {
        let settings = quietSettings()
        var reminder = Reminder(
            title: "Tilt", schedule: .interval(minutes: 60), createdAt: date(2026, 3, 10, 20, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 10, 21, 0)
        reminder.snoozedUntil = date(2026, 3, 10, 23, 30)
        let (engine, _, _) = makeEngine(
            reminders: [reminder], settings: settings, now: date(2026, 3, 11, 6, 0)
        )

        XCTAssertTrue(engine.absorbBacklogFromDowntime().isEmpty)
        XCTAssertEqual(engine.reminders[0].snoozedUntil, date(2026, 3, 10, 23, 30))
    }

    /// Once the window that held a fire has ended and the grace has passed,
    /// it really was missed.
    func testAbsorbConsumesAFireWhoseQuietWindowEndedLongAgo() {
        let settings = quietSettings()
        var reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 60), createdAt: date(2026, 3, 10, 20, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 10, 22, 30)
        let (engine, _, _) = makeEngine(
            reminders: [reminder], settings: settings, now: date(2026, 3, 11, 9, 0)
        )

        XCTAssertEqual(engine.absorbBacklogFromDowntime().count, 1)
        XCTAssertEqual(engine.events.map(\.outcome), [.missed])
        XCTAssertEqual(engine.reminders[0].lastFiredAt, date(2026, 3, 11, 9, 0))
    }

    // MARK: - External fires

    /// History dates a fire at the moment it reached the user, whichever path
    /// noticed it: an external wall-clock catch-up delivered at 07:00 for the
    /// 17:00 slot is a 07:00 event, exactly as tick() would have recorded it.
    func testExternalFireIsRecordedAtDeliveryTimeAndAnchoredAtTheStamp() {
        let reminder = Reminder(
            title: "Stretch",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1),
            createdAt: date(2026, 3, 10, 9, 0)
        )
        let (engine, _, _) = makeEngine(reminders: [reminder], now: date(2026, 3, 11, 8, 0))

        engine.recordExternalFire(
            id: reminder.id, at: date(2026, 3, 10, 17, 0), deliveredAt: date(2026, 3, 11, 7, 0)
        )

        XCTAssertEqual(engine.reminders[0].lastFiredAt, date(2026, 3, 10, 17, 0))
        XCTAssertEqual(engine.events.map(\.date), [date(2026, 3, 11, 7, 0)])
        XCTAssertEqual(engine.events.map(\.outcome), [.fired])
    }

    /// A relative alarm rule has occurrences from before the reminder
    /// existed; recording one of those would invent a fire.
    func testExternalFireBeforeTheReminderExistedIsIgnored() {
        let reminder = Reminder(
            title: "Meds",
            schedule: .dailyAt(hour: 9, minute: 0, dayInterval: 1),
            createdAt: date(2026, 3, 10, 10, 0)
        )
        let (engine, _, _) = makeEngine(reminders: [reminder], now: date(2026, 3, 10, 10, 5))

        engine.recordExternalFire(id: reminder.id, at: date(2026, 3, 10, 9, 0))

        XCTAssertNil(engine.reminders[0].lastFiredAt)
        XCTAssertTrue(engine.events.isEmpty)
    }

    func testBatchOfExternalFiresPersistsOnce() {
        let a = Reminder(
            title: "A", schedule: .interval(minutes: 60), createdAt: date(2026, 3, 10, 9, 0)
        )
        let b = Reminder(
            title: "B", schedule: .interval(minutes: 60), createdAt: date(2026, 3, 10, 9, 0)
        )
        let store = CountingStore(data: AppData(reminders: [a, b]))
        let engine = ReminderEngine(
            store: store, dateProvider: MutableDateProvider(now: date(2026, 3, 10, 12, 0)),
            presenter: nil, calendar: calendar
        )
        let before = store.saveCount

        engine.recordExternalFires([
            .init(reminderID: a.id, stampDate: date(2026, 3, 10, 10, 0)),
            .init(reminderID: b.id, stampDate: date(2026, 3, 10, 10, 0)),
            .init(reminderID: a.id, stampDate: date(2026, 3, 10, 11, 0)),
        ])

        XCTAssertEqual(store.saveCount - before, 1)
        XCTAssertEqual(engine.events.filter { $0.outcome == .fired }.count, 3)
        XCTAssertEqual(engine.reminders.first { $0.id == a.id }?.lastFiredAt, date(2026, 3, 10, 11, 0))
    }

    // MARK: - The engine and the projection never disagree

    /// Runs the live engine minute by minute for three days over a mixed set
    /// of reminders with quiet hours, and checks that every fire it produces
    /// is exactly the next one the projection predicted from the start —
    /// same reminder, same moment, same stamp.
    func testEngineTicksReproduceTheProjectionOverThreeDays() {
        let start = date(2026, 3, 10, 8, 0)
        let settings = quietSettings(start: (22, 0), end: (7, 0), allowsCritical: false)

        var water = Reminder(
            title: "Water", schedule: .interval(minutes: 95), priority: .normal, createdAt: start
        )
        water.lastFiredAt = start
        let stretch = Reminder(
            title: "Stretch",
            schedule: .dailyAt(hour: 21, minute: 30, dayInterval: 1),
            priority: .important, createdAt: start
        )
        let night = Reminder(
            title: "Night check",
            schedule: .dailyAt(hour: 23, minute: 15, dayInterval: 2),
            priority: .critical, createdAt: start
        )
        let call = Reminder(
            title: "Call",
            schedule: .weeklyAt(hour: 6, minute: 45, weekdays: [3, 4, 5]), // Tue–Thu
            priority: .normal, createdAt: start
        )
        var snoozed = Reminder(
            title: "Tilt", schedule: .interval(minutes: 240), priority: .critical, createdAt: start
        )
        snoozed.snoozedUntil = start.addingTimeInterval(20 * 60)

        let reminders = [water, stretch, night, call, snoozed]
        let expected = Dictionary(uniqueKeysWithValues: reminders.map { reminder in
            (reminder.id, Scheduler.projectedFires(
                for: reminder, from: start, limit: 64, settings: settings, calendar: calendar
            ))
        })

        // Ticks land every five minutes, so a fire is delivered by the first
        // tick at or after its projected moment.
        let tickInterval: TimeInterval = 5 * 60
        func tickAtOrAfter(_ date: Date) -> Date {
            let elapsed = date.timeIntervalSince(start)
            return start.addingTimeInterval((elapsed / tickInterval).rounded(.up) * tickInterval)
        }

        let (engine, clock, _) = makeEngine(reminders: reminders, settings: settings, now: start)
        var seen: [UUID: [(fireDate: Date, stampDate: Date)]] = [:]
        var cursor = start
        let end = start.addingTimeInterval(3 * 24 * 3600)
        while cursor <= end {
            clock.set(cursor)
            for fired in engine.tick() {
                seen[fired.id, default: []].append((cursor, fired.lastFiredAt!))
            }
            cursor = cursor.addingTimeInterval(tickInterval)
        }

        for reminder in reminders {
            let predicted = expected[reminder.id]!.filter { $0.fireDate <= end }
            let actual = seen[reminder.id] ?? []
            XCTAssertEqual(
                actual.map(\.fireDate), predicted.map { tickAtOrAfter($0.fireDate) },
                "\(reminder.title): fire moments"
            )
            XCTAssertEqual(
                actual.map(\.stampDate), predicted.map(\.stampDate),
                "\(reminder.title): stamps"
            )
        }
        XCTAssertFalse(seen.isEmpty)
    }
}

/// A store that counts writes, for asserting batch persistence.
private final class CountingStore: DataStoring {
    var data: AppData
    private(set) var saveCount = 0
    var hasPersistedData: Bool { true }

    init(data: AppData) { self.data = data }

    func load() throws -> AppData { data }

    func save(_ data: AppData) throws {
        self.data = data
        saveCount += 1
    }
}
