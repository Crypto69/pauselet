import XCTest
@testable import ReminderCore

/// Records what the engine asked to present, so tests can assert on user-visible
/// behaviour rather than internal state alone.
final class RecordingPresenter: ReminderPresenting {
    var presented: [Reminder] = []
    var dismissAllCount = 0

    func present(_ reminder: Reminder, settings: Settings) {
        presented.append(reminder)
    }

    func dismissAll() {
        dismissAllCount += 1
    }
}

@MainActor
final class ReminderEngineTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0
    ) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = 0
        return calendar.date(from: comps)!
    }

    /// Builds an engine with a controllable clock and no reminders.
    private func makeEngine(
        reminders: [Reminder] = [],
        settings: Settings = Settings(),
        now: Date
    ) -> (ReminderEngine, MutableDateProvider, RecordingPresenter, InMemoryDataStore) {
        let store = InMemoryDataStore(
            data: AppData(reminders: reminders, settings: settings, events: [])
        )
        let clock = MutableDateProvider(now: now)
        let presenter = RecordingPresenter()
        let engine = ReminderEngine(
            store: store, dateProvider: clock, presenter: presenter, calendar: calendar
        )
        return (engine, clock, presenter, store)
    }

    // MARK: - Firing

    func testTickFiresDueReminderAndPresentsIt() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Weight Shift", schedule: .interval(minutes: 20),
            priority: .subtle, createdAt: start
        )
        reminder.lastFiredAt = start
        let (engine, clock, presenter, _) = makeEngine(reminders: [reminder], now: start)

        XCTAssertTrue(engine.tick().isEmpty, "Nothing is due yet")
        XCTAssertTrue(presenter.presented.isEmpty)

        clock.advance(by: 20 * 60)
        let fired = engine.tick()
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(presenter.presented.map(\.title), ["Weight Shift"])
    }

    /// The critical bug this guards: repeated ticks in the same due window must
    /// not re-fire and spam the user.
    func testRepeatedTicksDoNotRefireSameWindow() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Tilt Back", schedule: .interval(minutes: 60), createdAt: start
        )
        reminder.lastFiredAt = start
        let (engine, clock, presenter, _) = makeEngine(reminders: [reminder], now: start)

        clock.advance(by: 60 * 60)
        XCTAssertEqual(engine.tick().count, 1)
        // Several more ticks a few seconds apart.
        for _ in 0..<5 {
            clock.advance(by: 5)
            XCTAssertTrue(engine.tick().isEmpty)
        }
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testHigherPriorityPresentedLastSoItSitsInFront() {
        let start = date(2026, 3, 10, 9, 0)
        var subtle = Reminder(
            title: "Shift", schedule: .interval(minutes: 20),
            priority: .subtle, createdAt: start
        )
        subtle.lastFiredAt = start
        var critical = Reminder(
            title: "Tilt", schedule: .interval(minutes: 20),
            priority: .critical, createdAt: start
        )
        critical.lastFiredAt = start

        let (engine, clock, presenter, _) = makeEngine(
            reminders: [subtle, critical], now: start
        )
        clock.advance(by: 20 * 60)
        engine.tick()

        XCTAssertEqual(presenter.presented.map(\.title), ["Shift", "Tilt"])
    }

    func testDisabledReminderDoesNotFire() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Off", schedule: .interval(minutes: 10), createdAt: start
        )
        reminder.isEnabled = false
        reminder.lastFiredAt = start
        let (engine, clock, presenter, _) = makeEngine(reminders: [reminder], now: start)

        clock.advance(by: 60 * 60)
        XCTAssertTrue(engine.tick().isEmpty)
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    // MARK: - Pause

    func testPausedEngineFiresNothing() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Tilt", schedule: .interval(minutes: 20), createdAt: start
        )
        reminder.lastFiredAt = start
        let (engine, clock, presenter, _) = makeEngine(reminders: [reminder], now: start)

        engine.setPaused(true)
        clock.advance(by: 60 * 60)
        XCTAssertTrue(engine.tick().isEmpty)
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertEqual(presenter.dismissAllCount, 1, "Pausing clears anything on screen")
    }

    func testTimedPauseExpiresAndResumesFiring() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Tilt", schedule: .interval(minutes: 20), createdAt: start
        )
        reminder.lastFiredAt = start
        let (engine, clock, presenter, _) = makeEngine(reminders: [reminder], now: start)

        engine.pause(forMinutes: 30)
        clock.advance(by: 20 * 60)
        XCTAssertTrue(engine.tick().isEmpty, "Still paused")

        clock.advance(by: 15 * 60) // 35 min total, pause has expired
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertFalse(engine.settings.isPaused, "Pause auto-clears on expiry")
        XCTAssertNil(engine.settings.pausedUntil)
        XCTAssertEqual(presenter.presented.count, 1)
    }

    /// Coming back from a long pause should not dump a backlog on the user.
    func testResumeReanchorsIntervalRemindersSoNoBacklogFires() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Shift", schedule: .interval(minutes: 20), createdAt: start
        )
        reminder.lastFiredAt = start
        let (engine, clock, presenter, _) = makeEngine(reminders: [reminder], now: start)

        engine.setPaused(true)
        clock.advance(by: 4 * 60 * 60) // paused for 4 hours
        engine.resume()

        XCTAssertTrue(engine.tick().isEmpty, "Nothing should fire the instant we resume")
        clock.advance(by: 20 * 60)
        XCTAssertEqual(engine.tick().count, 1, "Next fire is a full interval after resume")
        XCTAssertEqual(presenter.presented.count, 1)
    }

    // MARK: - Quiet hours

    func testQuietHoursSuppressNonCriticalButAllowCritical() {
        let night = date(2026, 3, 10, 23, 0)
        var settings = Settings()
        settings.quietHours = QuietHours(
            isEnabled: true, startHour: 22, startMinute: 0,
            endHour: 7, endMinute: 0, allowsCritical: true
        )
        var normal = Reminder(
            title: "Water", schedule: .interval(minutes: 20),
            priority: .normal, createdAt: night
        )
        normal.lastFiredAt = night
        var critical = Reminder(
            title: "Tilt", schedule: .interval(minutes: 20),
            priority: .critical, createdAt: night
        )
        critical.lastFiredAt = night

        let (engine, clock, presenter, _) = makeEngine(
            reminders: [normal, critical], settings: settings, now: night
        )
        clock.advance(by: 20 * 60)
        let fired = engine.tick()

        XCTAssertEqual(fired.map(\.title), ["Tilt"])
        XCTAssertEqual(presenter.presented.map(\.title), ["Tilt"])
    }

    // MARK: - User responses

    func testCompleteResetsTheIntervalAndRecordsHistory() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Tilt", schedule: .interval(minutes: 60), createdAt: start
        )
        reminder.lastFiredAt = start
        let (engine, clock, _, _) = makeEngine(reminders: [reminder], now: start)

        clock.advance(by: 60 * 60)
        engine.tick()
        clock.advance(by: 5 * 60)
        engine.complete(id: reminder.id)

        let stored = engine.reminder(withID: reminder.id)
        XCTAssertEqual(stored?.lastFiredAt, clock.now)
        XCTAssertEqual(stored?.lastAcknowledgedAt, clock.now)
        XCTAssertEqual(
            engine.events.map(\.outcome), [.fired, .completed]
        )

        // The next fire is a full hour after completion, not after the original fire.
        clock.advance(by: 58 * 60)
        XCTAssertTrue(engine.tick().isEmpty)
        clock.advance(by: 3 * 60)
        XCTAssertEqual(engine.tick().count, 1)
    }

    func testSnoozeDelaysNextFireByConfiguredMinutes() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Tilt", schedule: .interval(minutes: 60), createdAt: start
        )
        reminder.lastFiredAt = start
        var settings = Settings()
        settings.snoozeMinutes = 10
        let (engine, clock, presenter, _) = makeEngine(
            reminders: [reminder], settings: settings, now: start
        )

        clock.advance(by: 60 * 60)
        engine.tick()
        engine.snooze(id: reminder.id)

        clock.advance(by: 9 * 60)
        XCTAssertTrue(engine.tick().isEmpty, "Still snoozed")
        clock.advance(by: 2 * 60)
        XCTAssertEqual(engine.tick().count, 1, "Fires again after the snooze")
        XCTAssertEqual(presenter.presented.count, 2)
    }

    func testSnoozeWithExplicitMinutesOverridesSetting() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Tilt", schedule: .interval(minutes: 60), createdAt: start
        )
        reminder.lastFiredAt = start
        let (engine, clock, _, _) = makeEngine(reminders: [reminder], now: start)

        clock.advance(by: 60 * 60)
        engine.tick()
        engine.snooze(id: reminder.id, minutes: 2)

        clock.advance(by: 60)
        XCTAssertTrue(engine.tick().isEmpty)
        clock.advance(by: 90)
        XCTAssertEqual(engine.tick().count, 1)
    }

    func testDismissRecordsHistoryWithoutResettingSchedule() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 60), createdAt: start
        )
        reminder.lastFiredAt = start
        let (engine, clock, _, _) = makeEngine(reminders: [reminder], now: start)

        clock.advance(by: 60 * 60)
        engine.tick()
        let firedAt = engine.reminder(withID: reminder.id)?.lastFiredAt
        clock.advance(by: 60)
        engine.dismiss(id: reminder.id)

        XCTAssertEqual(engine.reminder(withID: reminder.id)?.lastFiredAt, firedAt)
        XCTAssertEqual(engine.events.map(\.outcome), [.fired, .dismissed])
    }

    // MARK: - CRUD

    func testAddedReminderDoesNotFireImmediately() {
        let start = date(2026, 3, 10, 9, 0)
        let (engine, clock, _, _) = makeEngine(now: start)

        engine.add(
            Reminder(
                title: "New", schedule: .interval(minutes: 15),
                createdAt: date(2020, 1, 1) // deliberately stale
            )
        )
        XCTAssertTrue(engine.tick().isEmpty, "Add re-anchors creation to now")

        clock.advance(by: 15 * 60)
        XCTAssertEqual(engine.tick().count, 1)
    }

    func testReenablingReminderReanchorsSoItDoesNotFireInstantly() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Shift", schedule: .interval(minutes: 20), createdAt: start
        )
        reminder.isEnabled = false
        reminder.lastFiredAt = date(2020, 1, 1)
        let (engine, clock, _, _) = makeEngine(reminders: [reminder], now: start)

        engine.setEnabled(true, for: reminder.id)
        XCTAssertTrue(engine.tick().isEmpty, "Should not fire from a stale timestamp")

        clock.advance(by: 20 * 60)
        XCTAssertEqual(engine.tick().count, 1)
    }

    func testDeleteRemovesReminder() {
        let start = date(2026, 3, 10, 9, 0)
        let reminder = Reminder(
            title: "Gone", schedule: .interval(minutes: 10), createdAt: start
        )
        let (engine, clock, _, _) = makeEngine(reminders: [reminder], now: start)

        engine.delete(id: reminder.id)
        XCTAssertTrue(engine.reminders.isEmpty)
        clock.advance(by: 60 * 60)
        XCTAssertTrue(engine.tick().isEmpty)
    }

    func testUpdateChangesScheduleInPlace() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Shift", schedule: .interval(minutes: 60), createdAt: start
        )
        reminder.lastFiredAt = start
        let (engine, clock, _, _) = makeEngine(reminders: [reminder], now: start)

        reminder.schedule = .interval(minutes: 10)
        engine.update(reminder)

        clock.advance(by: 10 * 60)
        XCTAssertEqual(engine.tick().count, 1)
    }

    // MARK: - Persistence

    func testChangesArePersistedToStore() {
        let start = date(2026, 3, 10, 9, 0)
        let (engine, _, _, store) = makeEngine(now: start)

        engine.add(Reminder(title: "Persisted", schedule: .interval(minutes: 30)))

        XCTAssertEqual(store.data.reminders.map(\.title), ["Persisted"])
        XCTAssertGreaterThan(store.saveCount, 0)
    }

    func testEngineLoadsExistingDataFromStore() {
        let start = date(2026, 3, 10, 9, 0)
        let existing = Reminder(title: "Loaded", schedule: .interval(minutes: 45))
        let (engine, _, _, _) = makeEngine(reminders: [existing], now: start)
        XCTAssertEqual(engine.reminders.map(\.title), ["Loaded"])
    }

    // MARK: - History and stats

    func testHistoryIsCappedToAvoidUnboundedGrowth() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Chatty", schedule: .interval(minutes: 1), createdAt: start
        )
        reminder.lastFiredAt = start
        let (engine, clock, _, _) = makeEngine(reminders: [reminder], now: start)

        // Fire well past the cap.
        for _ in 0..<(ReminderEngine.maxStoredEvents + 50) {
            clock.advance(by: 60)
            engine.tick()
        }
        XCTAssertLessThanOrEqual(engine.events.count, ReminderEngine.maxStoredEvents)
    }

    func testAdherenceReflectsCompletionRate() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Tilt", schedule: .interval(minutes: 60), createdAt: start
        )
        reminder.lastFiredAt = start
        let (engine, clock, _, _) = makeEngine(reminders: [reminder], now: start)

        // Fire four times, complete two of them.
        for index in 0..<4 {
            clock.advance(by: 60 * 60)
            engine.tick()
            if index % 2 == 0 { engine.complete(id: reminder.id) }
        }

        let adherence = engine.adherence(for: reminder.id, since: start)
        XCTAssertEqual(adherence ?? 0, 0.5, accuracy: 0.001)
    }

    func testAdherenceIsNilWhenNothingFired() {
        let start = date(2026, 3, 10, 9, 0)
        let reminder = Reminder(title: "Quiet", schedule: .interval(minutes: 60))
        let (engine, _, _, _) = makeEngine(reminders: [reminder], now: start)
        XCTAssertNil(engine.adherence(for: reminder.id, since: start))
    }

    func testClearHistoryEmptiesEvents() {
        let start = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Tilt", schedule: .interval(minutes: 10), createdAt: start
        )
        reminder.lastFiredAt = start
        let (engine, clock, _, _) = makeEngine(reminders: [reminder], now: start)

        clock.advance(by: 10 * 60)
        engine.tick()
        XCTAssertFalse(engine.events.isEmpty)

        engine.clearHistory()
        XCTAssertTrue(engine.events.isEmpty)
    }

    // MARK: - Next up

    func testNextUpTracksSoonestEnabledReminder() {
        let start = date(2026, 3, 10, 9, 0)
        var hourly = Reminder(
            title: "Tilt", schedule: .interval(minutes: 60), createdAt: start
        )
        hourly.lastFiredAt = start
        var frequent = Reminder(
            title: "Shift", schedule: .interval(minutes: 20), createdAt: start
        )
        frequent.lastFiredAt = start
        let (engine, _, _, _) = makeEngine(reminders: [hourly, frequent], now: start)

        XCTAssertEqual(engine.nextUp?.reminder.title, "Shift")

        engine.setEnabled(false, for: frequent.id)
        XCTAssertEqual(engine.nextUp?.reminder.title, "Tilt")
    }
}

