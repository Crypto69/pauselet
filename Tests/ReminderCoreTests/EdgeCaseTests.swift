import XCTest
@testable import ReminderCore

/// Tests for the awkward real-world situations a long-running background app
/// actually meets: the Mac sleeping, clocks going forward, months ending, and
/// reminders being edited while they are due.
@MainActor
final class EdgeCaseTests: XCTestCase {

    private var utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// A calendar in a zone that observes daylight saving, for the DST cases.
    private var sydney: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return cal
    }()

    private func date(
        _ calendar: Calendar,
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0
    ) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = 0
        return calendar.date(from: comps)!
    }

    // MARK: - Sleep and wake

    /// The timer does not fire while the Mac is asleep. On wake, a reminder that
    /// came due during the nap must fire once — not once per missed interval,
    /// and not never.
    func testReminderDueDuringSleepFiresExactlyOnceOnWake() {
        let start = date(utc, 2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Weight Shift", schedule: .interval(minutes: 20), createdAt: start
        )
        reminder.lastFiredAt = start

        let store = InMemoryDataStore(data: AppData(reminders: [reminder]))
        let clock = MutableDateProvider(now: start)
        let presenter = RecordingPresenter()
        let engine = ReminderEngine(
            store: store, dateProvider: clock, presenter: presenter, calendar: utc
        )

        // Asleep for three hours — nine intervals missed.
        clock.advance(by: 3 * 60 * 60)
        XCTAssertEqual(engine.tick().count, 1, "One catch-up fire, not nine")

        // The next one is a full interval after the catch-up.
        clock.advance(by: 19 * 60)
        XCTAssertTrue(engine.tick().isEmpty)
        clock.advance(by: 2 * 60)
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(presenter.presented.count, 2)
    }

    /// Several reminders all overdue after a long sleep should each fire once,
    /// with the critical one presented last so it ends up in front.
    func testMultipleOverdueRemindersEachFireOnceOrderedByPriority() {
        let start = date(utc, 2026, 3, 10, 9, 0)
        let makeReminder = { (title: String, priority: Priority) -> Reminder in
            var reminder = Reminder(
                title: title, schedule: .interval(minutes: 30),
                priority: priority, createdAt: start
            )
            reminder.lastFiredAt = start
            return reminder
        }
        let reminders = [
            makeReminder("Water", .normal),
            makeReminder("Tilt", .critical),
            makeReminder("Shift", .subtle),
        ]

        let store = InMemoryDataStore(data: AppData(reminders: reminders))
        let clock = MutableDateProvider(now: start)
        let presenter = RecordingPresenter()
        let engine = ReminderEngine(
            store: store, dateProvider: clock, presenter: presenter, calendar: utc
        )

        clock.advance(by: 5 * 60 * 60)
        XCTAssertEqual(engine.tick().count, 3)
        XCTAssertEqual(
            presenter.presented.map(\.title), ["Shift", "Water", "Tilt"],
            "Presented lowest priority first, so critical ends up on top"
        )
    }

    // MARK: - Daylight saving

    /// When the clocks go forward, a daily reminder should still fire at its
    /// wall-clock time rather than sliding by an hour.
    func testDailyReminderKeepsWallClockTimeAcrossDSTStart() {
        // Sydney moves to daylight time on 4 October 2026: 02:00 -> 03:00.
        let beforeChange = date(sydney, 2026, 10, 3, 12, 0)
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 9, minute: 0, dayInterval: 1),
            createdAt: beforeChange
        )
        reminder.lastFiredAt = date(sydney, 2026, 10, 3, 9, 0)

        let next = Scheduler.nextFireDate(
            for: reminder, now: beforeChange, calendar: sydney
        )

        // Still 09:00 local on the following day, despite the day being 23h long.
        let components = sydney.dateComponents([.year, .month, .day, .hour, .minute], from: next!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 10)
        XCTAssertEqual(components.day, 4)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 0)
    }

    /// The same when the clocks go back and the day is 25 hours long.
    func testDailyReminderKeepsWallClockTimeAcrossDSTEnd() {
        // Sydney returns to standard time on 5 April 2026: 03:00 -> 02:00.
        let beforeChange = date(sydney, 2026, 4, 4, 12, 0)
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 9, minute: 0, dayInterval: 1),
            createdAt: beforeChange
        )
        reminder.lastFiredAt = date(sydney, 2026, 4, 4, 9, 0)

        let next = Scheduler.nextFireDate(
            for: reminder, now: beforeChange, calendar: sydney
        )
        let components = sydney.dateComponents([.day, .hour, .minute], from: next!)
        XCTAssertEqual(components.day, 5)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 0)
    }

    /// An interval reminder is a pure duration, so an hour lost to DST simply
    /// means the wall-clock time it lands on shifts. It must not skip or double.
    func testIntervalReminderIsUnaffectedByDSTBoundary() {
        // 01:30 Sydney, half an hour before the clocks jump to 03:00.
        let start = date(sydney, 2026, 10, 4, 1, 30)
        var reminder = Reminder(
            title: "Shift", schedule: .interval(minutes: 60), createdAt: start
        )
        reminder.lastFiredAt = start

        let next = Scheduler.nextFireDate(
            for: reminder, now: start, calendar: sydney
        )
        XCTAssertEqual(
            next, start.addingTimeInterval(3600),
            "An interval is a duration; it stays exactly one hour"
        )
    }

    // MARK: - Month and year boundaries

    func testEveryTwoDaysCrossesMonthEndCorrectly() {
        let created = date(utc, 2026, 1, 1, 8, 0)
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 10, minute: 0, dayInterval: 2),
            createdAt: created
        )
        reminder.lastFiredAt = date(utc, 2026, 1, 31, 10, 0)

        let next = Scheduler.nextFireDate(
            for: reminder, now: date(utc, 2026, 1, 31, 11, 0), calendar: utc
        )
        XCTAssertEqual(next, date(utc, 2026, 2, 2, 10, 0))
    }

    func testDailyReminderCrossesYearEnd() {
        let created = date(utc, 2026, 12, 30, 8, 0)
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 9, minute: 0, dayInterval: 1),
            createdAt: created
        )
        reminder.lastFiredAt = date(utc, 2026, 12, 31, 9, 0)

        let next = Scheduler.nextFireDate(
            for: reminder, now: date(utc, 2026, 12, 31, 10, 0), calendar: utc
        )
        XCTAssertEqual(next, date(utc, 2027, 1, 1, 9, 0))
    }

    func testEveryTwoDaysHandlesLeapDay() {
        let created = date(utc, 2028, 2, 1, 8, 0)
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 10, minute: 0, dayInterval: 2),
            createdAt: created
        )
        // 2028 is a leap year, so the 29th exists.
        reminder.lastFiredAt = date(utc, 2028, 2, 27, 10, 0)

        let next = Scheduler.nextFireDate(
            for: reminder, now: date(utc, 2028, 2, 27, 11, 0), calendar: utc
        )
        XCTAssertEqual(next, date(utc, 2028, 2, 29, 10, 0))
    }

    func testWeeklyReminderWrapsAcrossYearEnd() {
        // 31 December 2026 is a Thursday; the next Monday is 4 January 2027.
        let created = date(utc, 2026, 12, 28, 8, 0)
        var reminder = Reminder(
            title: "Call Mum",
            schedule: .weeklyAt(hour: 18, minute: 0, weekdays: [2]),
            createdAt: created
        )
        // Monday the 28th's slot already fired, so the next is across the year.
        reminder.lastFiredAt = date(utc, 2026, 12, 28, 18, 0)

        let next = Scheduler.nextFireDate(
            for: reminder, now: date(utc, 2026, 12, 31, 12, 0), calendar: utc
        )
        XCTAssertEqual(next, date(utc, 2027, 1, 4, 18, 0))
    }

    // MARK: - Editing a live reminder

    /// Changing the schedule of a reminder that is currently overdue should take
    /// effect immediately rather than firing on the old schedule once more.
    func testEditingScheduleWhileOverdueAppliesImmediately() {
        let start = date(utc, 2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Shift", schedule: .interval(minutes: 20), createdAt: start
        )
        reminder.lastFiredAt = start

        let store = InMemoryDataStore(data: AppData(reminders: [reminder]))
        let clock = MutableDateProvider(now: start)
        let presenter = RecordingPresenter()
        let engine = ReminderEngine(
            store: store, dateProvider: clock, presenter: presenter, calendar: utc
        )

        // Overdue by 40 minutes, then the user stretches the interval to 2 hours.
        clock.advance(by: 60 * 60)
        var edited = engine.reminders[0]
        edited.schedule = .interval(minutes: 120)
        edited.lastFiredAt = clock.now
        engine.update(edited)

        XCTAssertTrue(engine.tick().isEmpty, "The new interval applies at once")
        clock.advance(by: 2 * 60 * 60)
        XCTAssertEqual(engine.tick().count, 1)
    }

    /// Deleting a reminder while it is on screen must not leave the engine
    /// trying to act on it.
    func testCompletingADeletedReminderIsHarmless() {
        let start = date(utc, 2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Gone", schedule: .interval(minutes: 10), createdAt: start
        )
        reminder.lastFiredAt = start

        let store = InMemoryDataStore(data: AppData(reminders: [reminder]))
        let clock = MutableDateProvider(now: start)
        let engine = ReminderEngine(store: store, dateProvider: clock, calendar: utc)

        clock.advance(by: 10 * 60)
        engine.tick()
        let id = reminder.id
        engine.delete(id: id)

        // The overlay is still up and the user clicks Done.
        engine.complete(id: id)
        engine.snooze(id: id)
        engine.dismiss(id: id)

        XCTAssertTrue(engine.reminders.isEmpty)
    }

    // MARK: - Quiet hours boundaries

    /// A reminder suppressed by quiet hours should fire once they end, rather
    /// than being lost or firing repeatedly through the night.
    func testSuppressedReminderFiresAfterQuietHoursEnd() {
        let night = date(utc, 2026, 3, 10, 23, 0)
        var settings = Settings()
        settings.quietHours = QuietHours(
            isEnabled: true, startHour: 22, startMinute: 0,
            endHour: 7, endMinute: 0, allowsCritical: false
        )
        var reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 60),
            priority: .normal, createdAt: night
        )
        reminder.lastFiredAt = night

        let store = InMemoryDataStore(
            data: AppData(reminders: [reminder], settings: settings)
        )
        let clock = MutableDateProvider(now: night)
        let presenter = RecordingPresenter()
        let engine = ReminderEngine(
            store: store, dateProvider: clock, presenter: presenter, calendar: utc
        )

        // Tick hourly from 23:00 through to 06:00. Every one of those is inside
        // the 22:00–07:00 window, so nothing may fire.
        for hour in 1...7 {
            clock.advance(by: 60 * 60)
            XCTAssertTrue(
                engine.tick().isEmpty,
                "Should stay silent at \((23 + hour) % 24):00"
            )
        }

        // The next tick lands at 07:00, when the window has closed.
        clock.advance(by: 60 * 60)
        XCTAssertEqual(engine.tick().count, 1, "Fires once quiet hours end")
        XCTAssertEqual(presenter.presented.count, 1)
    }

    /// Quiet hours that start and end at the same time are a no-op rather than
    /// silencing the app for 24 hours a day.
    func testQuietHoursWithIdenticalStartAndEndSuppressNothing() {
        let quiet = QuietHours(
            isEnabled: true, startHour: 9, startMinute: 0, endHour: 9, endMinute: 0
        )
        XCTAssertFalse(quiet.contains(date(utc, 2026, 3, 10, 9, 0), calendar: utc))
        XCTAssertFalse(quiet.contains(date(utc, 2026, 3, 10, 15, 0), calendar: utc))
    }

    // MARK: - Persistence round trip through the engine

    /// The whole point of storing anything: what the user set up must come back
    /// after a restart.
    func testEngineStateSurvivesARestart() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReminderRestart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data.json")

        let custom = Reminder(
            title: "Physiotherapy",
            message: "Full routine.",
            schedule: .weeklyAt(hour: 16, minute: 30, weekdays: [3, 5]),
            priority: .important,
            symbolName: "figure.flexibility",
            activityDurationSeconds: 20 * 60
        )

        // First run: add a reminder and change a setting.
        do {
            let engine = ReminderEngine(store: FileDataStore(fileURL: url), calendar: utc)
            engine.add(custom)
            var settings = engine.settings
            settings.snoozeMinutes = 17
            settings.quietHours.isEnabled = true
            engine.updateSettings(settings)
        }

        // Second run: everything should be exactly as it was left.
        let reloaded = ReminderEngine(store: FileDataStore(fileURL: url), calendar: utc)
        let restored = reloaded.reminders.first { $0.id == custom.id }

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.title, "Physiotherapy")
        XCTAssertEqual(
            restored?.schedule, .weeklyAt(hour: 16, minute: 30, weekdays: [3, 5])
        )
        XCTAssertEqual(restored?.priority, .important)
        XCTAssertEqual(restored?.activityDurationSeconds, 20 * 60)
        XCTAssertEqual(reloaded.settings.snoozeMinutes, 17)
        XCTAssertTrue(reloaded.settings.quietHours.isEnabled)
    }
}
