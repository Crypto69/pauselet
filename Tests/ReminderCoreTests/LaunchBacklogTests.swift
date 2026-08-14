import XCTest
@testable import ReminderCore

/// Tests for what happens when the app is opened after a spell of not running.
///
/// These exist because of a real incident: the app was left closed for a day
/// and a half, and the moment it opened it delivered the whole backlog at once
/// — last night's wall-clock reminder, plus every interval reminder, one of
/// them a critical full-screen overlay that started playing music. Nothing here
/// was due; it was all owed to sessions that had already ended.
@MainActor
final class LaunchBacklogTests: XCTestCase {

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

    /// Launching after the app was closed for a day and a half — the reported
    /// bug, with the reminders and times taken from the data file that produced
    /// it. Nothing may reach the screen.
    func testOpeningAfterADayAwayPresentsNothing() {
        var leanBack = Reminder(
            title: "Lean Back", schedule: .interval(minutes: 60),
            priority: .critical, music: .defaultPlaylist,
            createdAt: date(2026, 8, 11, 21, 47)
        )
        leanBack.lastFiredAt = date(2026, 8, 12, 20, 57)

        var weightShift = Reminder(
            title: "Weight Shift", schedule: .interval(minutes: 20),
            priority: .subtle, createdAt: date(2026, 8, 11, 21, 47)
        )
        weightShift.lastFiredAt = date(2026, 8, 12, 20, 41)

        var windDown = Reminder(
            title: "Wind Down",
            schedule: .dailyAt(hour: 20, minute: 59, dayInterval: 1),
            priority: .critical, createdAt: date(2026, 8, 11, 22, 8)
        )
        windDown.lastFiredAt = date(2026, 8, 12, 20, 59)

        let launch = date(2026, 8, 14, 12, 37)
        let (engine, clock, presenter) = makeEngine(
            reminders: [leanBack, weightShift, windDown], now: launch
        )

        let absorbed = engine.absorbBacklogFromDowntime()
        XCTAssertEqual(absorbed.count, 3)
        XCTAssertTrue(engine.tick().isEmpty, "Launching must not replay the backlog")
        XCTAssertTrue(presenter.presented.isEmpty, "No overlay, no notification, no music")

        // Each schedule picks up from the launch rather than from its arrears.
        clock.advance(by: 19 * 60)
        XCTAssertTrue(engine.tick().isEmpty)
        clock.advance(by: 2 * 60)
        XCTAssertEqual(engine.tick().map(\.title), ["Weight Shift"], "20 min after launch")
    }

    /// Absorbing is not the same as firing: the reminders are consumed, not
    /// delivered, and the history says so.
    func testAbsorbedBacklogIsRecordedAsMissedNotFired() {
        var reminder = Reminder(
            title: "Drink Water", schedule: .interval(minutes: 60),
            createdAt: date(2026, 8, 11, 9, 0)
        )
        reminder.lastFiredAt = date(2026, 8, 12, 20, 1)
        let (engine, _, _) = makeEngine(
            reminders: [reminder], now: date(2026, 8, 14, 12, 37)
        )

        engine.absorbBacklogFromDowntime()

        XCTAssertEqual(engine.events.map(\.outcome), [.missed])
    }

    /// Yesterday's daily slot is consumed rather than delivered, and the next
    /// one lands at its usual time today.
    func testYesterdaysDailySlotIsConsumedAndTodaysStillFires() {
        var reminder = Reminder(
            title: "Wind Down",
            schedule: .dailyAt(hour: 20, minute: 59, dayInterval: 1),
            priority: .critical, createdAt: date(2026, 8, 11, 22, 8)
        )
        reminder.lastFiredAt = date(2026, 8, 12, 20, 59)
        let (engine, clock, presenter) = makeEngine(
            reminders: [reminder], now: date(2026, 8, 14, 12, 37)
        )

        engine.absorbBacklogFromDowntime()
        XCTAssertEqual(
            engine.reminders[0].lastFiredAt, date(2026, 8, 13, 20, 59),
            "The last elapsed slot is stamped, so the daily grid stays in phase"
        )

        clock.set(date(2026, 8, 14, 20, 59, 4))
        XCTAssertEqual(engine.tick().count, 1, "Tonight's slot is unaffected")
        XCTAssertEqual(presenter.presented.count, 1)
    }

    /// An "every 2 days" grid keeps its phase across the absorbed gap rather
    /// than re-basing itself on the launch.
    func testAbsorbingKeepsAnEveryTwoDaysGridInPhase() {
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 2),
            createdAt: date(2026, 3, 1, 8, 0)
        )
        // Grid: Mar 4, 6, 8, 10 — the app was closed for a week.
        reminder.lastFiredAt = date(2026, 3, 2, 17, 0)
        let (engine, clock, presenter) = makeEngine(
            reminders: [reminder], now: date(2026, 3, 9, 12, 0)
        )

        engine.absorbBacklogFromDowntime()
        XCTAssertTrue(engine.tick().isEmpty)

        clock.set(date(2026, 3, 10, 17, 0, 4))
        XCTAssertEqual(engine.tick().count, 1, "Next fire is Mar 10, not Mar 11")
        XCTAssertEqual(presenter.presented.count, 1)
    }

    /// Quitting and relaunching — to install an update — must not swallow a
    /// reminder that came due seconds ago.
    func testAReminderDueWithinTheGraceWindowStillFires() {
        let launch = date(2026, 8, 14, 12, 37)
        var reminder = Reminder(
            title: "Weight Shift", schedule: .interval(minutes: 20),
            createdAt: date(2026, 8, 14, 9, 0)
        )
        // Came due 30 seconds before the app was reopened.
        reminder.lastFiredAt = launch.addingTimeInterval(-20 * 60 - 30)
        let (engine, _, presenter) = makeEngine(reminders: [reminder], now: launch)

        XCTAssertTrue(engine.absorbBacklogFromDowntime().isEmpty)
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(presenter.presented.map(\.title), ["Weight Shift"])
    }

    /// A daily slot that passed moments before launch is delivered even when
    /// older slots from the downtime are being absorbed alongside it.
    func testDailySlotThatJustPassedIsStillDeliveredAfterALongGap() {
        let launch = date(2026, 8, 14, 12, 37, 30)
        var reminder = Reminder(
            title: "Midday Check",
            schedule: .dailyAt(hour: 12, minute: 37, dayInterval: 1),
            createdAt: date(2026, 8, 10, 8, 0)
        )
        reminder.lastFiredAt = date(2026, 8, 11, 12, 37)
        let (engine, _, presenter) = makeEngine(reminders: [reminder], now: launch)

        XCTAssertTrue(engine.absorbBacklogFromDowntime().isEmpty)
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(presenter.presented.count, 1)
    }

    /// A snooze is a promise made by a session that has since ended. Reopening
    /// the app a day later must not honour it.
    func testStaleSnoozeIsDroppedRatherThanFiredOnLaunch() {
        var reminder = Reminder(
            title: "Lean Back", schedule: .interval(minutes: 60),
            priority: .critical, createdAt: date(2026, 8, 12, 9, 0)
        )
        reminder.lastFiredAt = date(2026, 8, 12, 20, 57)
        reminder.snoozedUntil = date(2026, 8, 12, 21, 2)
        let launch = date(2026, 8, 14, 12, 37)
        let (engine, clock, presenter) = makeEngine(reminders: [reminder], now: launch)

        engine.absorbBacklogFromDowntime()
        XCTAssertNil(engine.reminders[0].snoozedUntil)
        XCTAssertTrue(engine.tick().isEmpty)
        XCTAssertTrue(presenter.presented.isEmpty)

        // And the interval restarts from the launch.
        clock.advance(by: 60 * 60 + 5)
        XCTAssertEqual(engine.tick().count, 1)
    }

    /// A snooze set a moment before the app was restarted is still owed.
    func testFreshSnoozeSurvivesARestart() {
        let launch = date(2026, 8, 14, 12, 37)
        var reminder = Reminder(
            title: "Lean Back", schedule: .interval(minutes: 60),
            createdAt: date(2026, 8, 14, 9, 0)
        )
        reminder.lastFiredAt = date(2026, 8, 14, 12, 30)
        reminder.snoozedUntil = launch.addingTimeInterval(60)
        let (engine, clock, presenter) = makeEngine(reminders: [reminder], now: launch)

        XCTAssertTrue(engine.absorbBacklogFromDowntime().isEmpty)
        XCTAssertEqual(engine.reminders[0].snoozedUntil, launch.addingTimeInterval(60))

        clock.advance(by: 65)
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(presenter.presented.map(\.title), ["Lean Back"])
    }

    /// A disabled reminder has nothing to absorb, and absorbing must not
    /// quietly re-anchor it — enabling it later still starts a fresh interval.
    func testDisabledReminderIsUntouched() {
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 2),
            isEnabled: false, createdAt: date(2026, 3, 1, 8, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 2, 17, 0)
        let (engine, _, _) = makeEngine(
            reminders: [reminder], now: date(2026, 3, 9, 12, 0)
        )

        XCTAssertTrue(engine.absorbBacklogFromDowntime().isEmpty)
        XCTAssertEqual(engine.reminders[0].lastFiredAt, date(2026, 3, 2, 17, 0))
        XCTAssertTrue(engine.events.isEmpty)
    }

    /// A brand new install has no backlog to absorb, so its starter reminders
    /// keep their anchors and simply run from the first launch.
    func testFirstLaunchOfAFreshInstallAbsorbsNothing() {
        let start = date(2026, 8, 14, 9, 0)
        let (engine, _, presenter) = makeEngine(
            reminders: DefaultReminders.starterSet(now: start), now: start
        )

        XCTAssertTrue(engine.absorbBacklogFromDowntime().isEmpty)
        XCTAssertTrue(engine.tick().isEmpty)
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    /// The absorbed state is written out, so a crash straight after launch
    /// cannot resurrect the backlog on the next open.
    func testAbsorbedStateIsPersisted() {
        var reminder = Reminder(
            title: "Drink Water", schedule: .interval(minutes: 60),
            createdAt: date(2026, 8, 11, 9, 0)
        )
        reminder.lastFiredAt = date(2026, 8, 12, 20, 1)
        let store = InMemoryDataStore(data: AppData(reminders: [reminder]))
        let clock = MutableDateProvider(now: date(2026, 8, 14, 12, 37))
        let engine = ReminderEngine(
            store: store, dateProvider: clock, presenter: RecordingPresenter(),
            calendar: calendar
        )

        engine.absorbBacklogFromDowntime()

        XCTAssertEqual(
            store.data.reminders[0].lastFiredAt, date(2026, 8, 14, 12, 37)
        )
    }

    /// Sleep is a separate case: the app is running and the user may be sitting
    /// right there, so a nap keeps its single catch-up fire.
    func testSleepCatchUpIsUnaffected() {
        let start = date(2026, 8, 14, 9, 0)
        var reminder = Reminder(
            title: "Weight Shift", schedule: .interval(minutes: 20), createdAt: start
        )
        reminder.lastFiredAt = start
        let (engine, clock, _) = makeEngine(reminders: [reminder], now: start)

        XCTAssertTrue(engine.absorbBacklogFromDowntime().isEmpty)
        clock.advance(by: 3 * 60 * 60)
        XCTAssertEqual(engine.tick().count, 1, "One catch-up fire on wake")
    }
}
