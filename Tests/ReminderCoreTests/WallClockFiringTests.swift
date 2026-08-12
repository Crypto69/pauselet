import XCTest
@testable import ReminderCore

/// Regression tests for wall-clock (daily/weekly) schedules firing through the
/// engine's tick loop.
///
/// These exist because the original due-check compared "the next *future*
/// slot" against now — a comparison that can never be true — so daily and
/// weekly reminders never fired at all, and no test noticed: every engine test
/// used intervals, and every daily/weekly test only asserted display dates.
@MainActor
final class WallClockFiringTests: XCTestCase {

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

    // MARK: - The headline regression

    /// A daily reminder must actually fire when a tick lands just after its
    /// slot. This is the core promise of the schedule kind.
    func testDailyReminderFiresWhenATickCrossesItsSlot() {
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1),
            createdAt: date(2026, 3, 9, 8, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 9, 17, 0)
        let (engine, clock, presenter) = makeEngine(
            reminders: [reminder], now: date(2026, 3, 10, 16, 59, 55)
        )

        XCTAssertTrue(engine.tick().isEmpty, "Not due a few seconds early")

        // The tick timer lands a few seconds past the slot, as it does live.
        clock.set(date(2026, 3, 10, 17, 0, 4))
        XCTAssertEqual(engine.tick().count, 1, "Fires at its slot")
        XCTAssertEqual(presenter.presented.map(\.title), ["Physio"])

        // Repeated ticks in the same window must not re-fire.
        for _ in 0..<5 {
            clock.advance(by: 5)
            XCTAssertTrue(engine.tick().isEmpty)
        }

        // And the next day it fires again.
        clock.set(date(2026, 3, 11, 17, 0, 3))
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(presenter.presented.count, 2)
    }

    func testWeeklyReminderFiresOnItsSelectedWeekday() {
        // Weekday numbering: 1 = Sunday ... 7 = Saturday. 11 Mar 2026 is a Wed.
        var reminder = Reminder(
            title: "Call Mum",
            schedule: .weeklyAt(hour: 10, minute: 30, weekdays: [4]),
            createdAt: date(2026, 3, 2, 8, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 4, 10, 30)
        let (engine, clock, presenter) = makeEngine(
            reminders: [reminder], now: date(2026, 3, 11, 10, 29)
        )

        XCTAssertTrue(engine.tick().isEmpty)

        clock.set(date(2026, 3, 11, 10, 30, 5))
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(presenter.presented.map(\.title), ["Call Mum"])

        // Fired, so the rest of the day stays quiet.
        clock.set(date(2026, 3, 11, 18, 0))
        XCTAssertTrue(engine.tick().isEmpty)

        // Next Wednesday it comes back.
        clock.set(date(2026, 3, 18, 10, 30, 2))
        XCTAssertEqual(engine.tick().count, 1)
    }

    /// A brand-new daily reminder added in the morning fires the same day.
    func testNewlyAddedDailyReminderFiresAtItsFirstSlot() {
        let start = date(2026, 3, 10, 9, 0)
        let (engine, clock, presenter) = makeEngine(reminders: [], now: start)

        engine.add(
            Reminder(
                title: "Physio",
                schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1)
            )
        )
        XCTAssertTrue(engine.tick().isEmpty, "Not due before the slot")

        clock.set(date(2026, 3, 10, 17, 0, 4))
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(presenter.presented.map(\.title), ["Physio"])
    }

    // MARK: - Catch-up and grid phase

    /// Slots missed while the Mac was off collapse to one catch-up fire, and
    /// the "every 2 days" grid stays in phase afterwards.
    func testMissedSlotsFireOnceAndKeepTheCycleGrid() {
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 2),
            createdAt: date(2026, 3, 1, 8, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 2, 17, 0)
        // Grid: Mar 4, 6, 8, 10... The Mac was off for a week.
        let (engine, clock, presenter) = makeEngine(
            reminders: [reminder], now: date(2026, 3, 9, 12, 0)
        )

        XCTAssertEqual(engine.tick().count, 1, "One catch-up fire, not three")
        XCTAssertEqual(presenter.presented.count, 1)

        clock.advance(by: 60)
        XCTAssertTrue(engine.tick().isEmpty, "The catch-up consumed the backlog")

        // The next fire lands on the original grid: Mar 10, not Mar 11.
        clock.set(date(2026, 3, 10, 17, 0, 4))
        XCTAssertEqual(engine.tick().count, 1)
    }

    // MARK: - Quiet hours

    /// A wall-clock slot that passes inside quiet hours is skipped and recorded
    /// as missed — "daily at 23:00" must not arrive at 07:00.
    func testWallClockSlotInsideQuietHoursIsSkippedNotDeliveredLate() {
        var settings = Settings()
        settings.quietHours = QuietHours(
            isEnabled: true, startHour: 22, startMinute: 0,
            endHour: 7, endMinute: 0, allowsCritical: true
        )
        var reminder = Reminder(
            title: "Evening Pills",
            schedule: .dailyAt(hour: 23, minute: 0, dayInterval: 1),
            priority: .normal,
            createdAt: date(2026, 3, 8, 8, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 9, 23, 0)
        let (engine, clock, presenter) = makeEngine(
            reminders: [reminder], settings: settings, now: date(2026, 3, 10, 21, 0)
        )

        // Through the night: suppressed, nothing fires.
        for hour in [23, 24, 26, 30] { // 23:00, 00:00, 02:00, 06:00
            clock.set(date(2026, 3, 10, 21, 0).addingTimeInterval(
                TimeInterval((hour - 21) * 3600) + 5
            ))
            XCTAssertTrue(engine.tick().isEmpty)
        }

        // Quiet hours end at 07:00: the slot is skipped, not delivered.
        clock.set(date(2026, 3, 11, 7, 0, 5))
        XCTAssertTrue(engine.tick().isEmpty, "The 23:00 slot must not fire at 07:00")
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertEqual(
            engine.events.map(\.outcome), [.missed],
            "The skipped slot is recorded so history shows what happened"
        )

        // And tonight's slot is the next one up.
        let next = Scheduler.nextFireDate(
            for: engine.reminders[0], now: clock.now, calendar: calendar
        )
        XCTAssertEqual(next, date(2026, 3, 11, 23, 0))
    }

    /// Critical reminders opt out of quiet-hours suppression, so their slots
    /// fire on time even at night.
    func testCriticalWallClockSlotPiercesQuietHours() {
        var settings = Settings()
        settings.quietHours = QuietHours(
            isEnabled: true, startHour: 22, startMinute: 0,
            endHour: 7, endMinute: 0, allowsCritical: true
        )
        var reminder = Reminder(
            title: "Pressure Relief",
            schedule: .dailyAt(hour: 23, minute: 0, dayInterval: 1),
            priority: .critical,
            createdAt: date(2026, 3, 8, 8, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 9, 23, 0)
        let (engine, clock, presenter) = makeEngine(
            reminders: [reminder], settings: settings, now: date(2026, 3, 10, 22, 30)
        )

        clock.set(date(2026, 3, 10, 23, 0, 5))
        XCTAssertEqual(engine.tick().count, 1, "Critical fires despite quiet hours")
        XCTAssertEqual(presenter.presented.map(\.title), ["Pressure Relief"])
    }

    // MARK: - Enable / complete interactions

    /// Toggling a daily reminder off and back on in the morning must not skip
    /// that day's slot.
    func testReenablingDailyBeforeItsSlotStillFiresThatDay() {
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1),
            createdAt: date(2026, 3, 1, 8, 0)
        )
        reminder.isEnabled = false
        reminder.lastFiredAt = date(2026, 3, 5, 17, 0) // stale
        let (engine, clock, presenter) = makeEngine(
            reminders: [reminder], now: date(2026, 3, 10, 10, 0)
        )

        engine.setEnabled(true, for: reminder.id)
        XCTAssertTrue(engine.tick().isEmpty, "Must not fire instantly from stale state")

        clock.set(date(2026, 3, 10, 17, 0, 4))
        XCTAssertEqual(engine.tick().count, 1, "Today's slot still fires")
        XCTAssertEqual(presenter.presented.count, 1)
    }

    /// Completing a daily reminder ahead of its slot ("I already did it")
    /// consumes that slot rather than firing it a few hours later.
    func testEarlyCompleteConsumesTheUpcomingSlot() {
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1),
            createdAt: date(2026, 3, 8, 8, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 9, 17, 0)
        reminder.lastAcknowledgedAt = date(2026, 3, 9, 17, 2)
        let (engine, clock, presenter) = makeEngine(
            reminders: [reminder], now: date(2026, 3, 10, 10, 0)
        )

        engine.complete(id: reminder.id)

        clock.set(date(2026, 3, 10, 17, 0, 5))
        XCTAssertTrue(engine.tick().isEmpty, "The completed slot must not fire")
        XCTAssertTrue(presenter.presented.isEmpty)

        // Tomorrow is unaffected.
        clock.set(date(2026, 3, 11, 17, 0, 5))
        XCTAssertEqual(engine.tick().count, 1)
    }

    /// Acknowledging a fire that just happened must not eat the next slot.
    func testAcknowledgingAFireDoesNotConsumeTheNextSlot() {
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1),
            createdAt: date(2026, 3, 8, 8, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 9, 17, 0)
        let (engine, clock, _) = makeEngine(
            reminders: [reminder], now: date(2026, 3, 10, 16, 59)
        )

        clock.set(date(2026, 3, 10, 17, 0, 4))
        XCTAssertEqual(engine.tick().count, 1)

        // The user clicks Done on the overlay a couple of minutes later.
        clock.advance(by: 120)
        engine.complete(id: reminder.id)

        clock.set(date(2026, 3, 11, 17, 0, 4))
        XCTAssertEqual(engine.tick().count, 1, "Tomorrow's slot still fires")
    }

    /// Snoozing a fired daily reminder brings it back at the snooze time, and
    /// the schedule then resumes normally.
    func testSnoozedDailyReminderComesBackAndResumesSchedule() {
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1),
            createdAt: date(2026, 3, 8, 8, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 9, 17, 0)
        let (engine, clock, presenter) = makeEngine(
            reminders: [reminder], now: date(2026, 3, 10, 16, 59)
        )

        clock.set(date(2026, 3, 10, 17, 0, 4))
        XCTAssertEqual(engine.tick().count, 1)
        engine.snooze(id: reminder.id, minutes: 10)

        clock.advance(by: 9 * 60)
        XCTAssertTrue(engine.tick().isEmpty, "Still snoozed")

        clock.advance(by: 2 * 60)
        XCTAssertEqual(engine.tick().count, 1, "Comes back after the snooze")
        XCTAssertEqual(presenter.presented.count, 2)

        // The snooze fire does not disturb tomorrow's slot.
        clock.set(date(2026, 3, 11, 17, 0, 4))
        XCTAssertEqual(engine.tick().count, 1)
    }

    // MARK: - Menu bar countdown around quiet hours

    /// During quiet hours the countdown shows the reminder's real next audible
    /// fire rather than hiding it or counting to a suppressed slot.
    func testNextUpDuringQuietHoursShowsTheAudibleFire() {
        var settings = Settings()
        settings.quietHours = QuietHours(
            isEnabled: true, startHour: 22, startMinute: 0,
            endHour: 7, endMinute: 0, allowsCritical: true
        )
        var water = Reminder(
            title: "Water",
            schedule: .interval(minutes: 60),
            priority: .normal,
            createdAt: date(2026, 3, 10, 22, 30)
        )
        water.lastFiredAt = date(2026, 3, 10, 22, 30)
        let (engine, clock, _) = makeEngine(
            reminders: [water], settings: settings, now: date(2026, 3, 10, 22, 30)
        )

        // 23:30: the hourly slot lands at 23:30, inside the window, so the
        // real next fire is 07:00 when the window ends.
        clock.set(date(2026, 3, 10, 23, 0))
        engine.tick()
        XCTAssertEqual(engine.nextUp?.reminder.title, "Water")
        XCTAssertEqual(engine.nextUp?.date, date(2026, 3, 11, 7, 0))
    }
}
