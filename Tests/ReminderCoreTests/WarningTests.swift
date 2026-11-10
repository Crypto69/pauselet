import XCTest
@testable import ReminderCore

/// Advance warnings before a Critical takeover: when they come, when they do
/// not, and that the engine shows each one once.
@MainActor
final class WarningTests: XCTestCase {

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

    /// The screen breaks: every 50 minutes from 05:45, Mon–Fri. 9 Mar 2026
    /// is a Monday.
    private let breaks = Schedule.timedInterval(
        minutes: 50, startHour: 5, startMinute: 45,
        endHour: 13, endMinute: 0, weekdays: [2, 3, 4, 5, 6]
    )

    private func critical(
        _ schedule: Schedule,
        warning: Int? = 5,
        createdAt: Date,
        lastFiredAt: Date? = nil,
        snoozedUntil: Date? = nil,
        priority: Priority = .critical
    ) -> Reminder {
        Reminder(
            title: "Screen break", schedule: schedule, priority: priority,
            warningMinutes: warning, lastFiredAt: lastFiredAt,
            snoozedUntil: snoozedUntil, createdAt: createdAt
        )
    }

    private func warnings(
        _ reminder: Reminder, from now: Date, limit: Int = 3, settings: Settings = Settings()
    ) -> [ReminderWarning] {
        Scheduler.projectedWarnings(
            for: reminder, from: now, limit: limit, settings: settings, calendar: calendar
        )
    }

    // MARK: - When warnings come

    func testWarnsTheLeadAheadOfEachTakeover() {
        let r = critical(breaks, createdAt: date(2026, 3, 9, 5, 0))
        XCTAssertEqual(warnings(r, from: date(2026, 3, 9, 5, 0)), [
            ReminderWarning(warnAt: date(2026, 3, 9, 5, 40), takeoverAt: date(2026, 3, 9, 5, 45)),
            ReminderWarning(warnAt: date(2026, 3, 9, 6, 30), takeoverAt: date(2026, 3, 9, 6, 35)),
            ReminderWarning(warnAt: date(2026, 3, 9, 7, 20), takeoverAt: date(2026, 3, 9, 7, 25)),
        ])
    }

    func testIntervalReminderWarnsBeforeItsNextFire() {
        let r = critical(
            .interval(minutes: 60), warning: 10,
            createdAt: date(2026, 3, 9), lastFiredAt: date(2026, 3, 9, 9, 0)
        )
        XCTAssertEqual(
            warnings(r, from: date(2026, 3, 9, 9, 5), limit: 1),
            [ReminderWarning(warnAt: date(2026, 3, 9, 9, 50), takeoverAt: date(2026, 3, 9, 10, 0))]
        )
    }

    /// Already inside the window: still warned, since the takeover is ahead.
    func testAWarningWhoseMomentPassedIsStillDueBeforeTheTakeover() {
        let r = critical(breaks, createdAt: date(2026, 3, 9, 5, 0))
        XCTAssertEqual(
            warnings(r, from: date(2026, 3, 9, 5, 43), limit: 1).first?.takeoverAt,
            date(2026, 3, 9, 5, 45)
        )
    }

    // MARK: - When they do not

    func testALeadAsLongAsTheIntervalCannotWarn() {
        let r = critical(
            .interval(minutes: 10), warning: 10,
            createdAt: date(2026, 3, 9), lastFiredAt: date(2026, 3, 9, 9, 0)
        )
        XCTAssertTrue(warnings(r, from: date(2026, 3, 9, 9, 1)).isEmpty)
    }

    func testASnoozeComingBackIsNotWarnedButTheNextTakeoverIs() {
        let r = critical(
            .interval(minutes: 60), createdAt: date(2026, 3, 9),
            lastFiredAt: date(2026, 3, 9, 9, 0), snoozedUntil: date(2026, 3, 9, 9, 20)
        )
        XCTAssertEqual(
            warnings(r, from: date(2026, 3, 9, 9, 10), limit: 1),
            [ReminderWarning(warnAt: date(2026, 3, 9, 10, 15), takeoverAt: date(2026, 3, 9, 10, 20))]
        )
    }

    func testAWarningInsideATimedPauseIsDropped() {
        var settings = Settings()
        settings.pausedUntil = date(2026, 3, 9, 9, 58)
        settings.pausedAt = date(2026, 3, 9, 9, 0)
        let r = critical(
            .dailyAt(hour: 10, minute: 0, dayInterval: 1),
            createdAt: date(2026, 3, 8), lastFiredAt: date(2026, 3, 8, 10, 0)
        )
        XCTAssertEqual(
            warnings(r, from: date(2026, 3, 9, 9, 30), limit: 1, settings: settings),
            [ReminderWarning(warnAt: date(2026, 3, 10, 9, 55), takeoverAt: date(2026, 3, 10, 10, 0))]
        )
    }

    func testQuietHoursTheTakeoverRespectsSilenceItsWarning() {
        var settings = Settings()
        settings.quietHours = QuietHours(
            isEnabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0,
            allowsCritical: false
        )
        let r = critical(
            .dailyAt(hour: 7, minute: 2, dayInterval: 1), createdAt: date(2026, 3, 9)
        )
        XCTAssertTrue(warnings(r, from: date(2026, 3, 9), settings: settings).isEmpty)

        // When critical may pierce quiet hours, so may its warning.
        settings.quietHours.allowsCritical = true
        XCTAssertEqual(
            warnings(r, from: date(2026, 3, 9), limit: 1, settings: settings).first?.warnAt,
            date(2026, 3, 9, 6, 57)
        )
    }

    func testAnIndefinitePauseWarnsOfNothing() {
        var settings = Settings()
        settings.isPaused = true
        let r = critical(breaks, createdAt: date(2026, 3, 9, 5, 0))
        XCTAssertTrue(warnings(r, from: date(2026, 3, 9, 5, 0), settings: settings).isEmpty)
    }

    func testOnlyCriticalRemindersWarn() {
        let r = critical(breaks, createdAt: date(2026, 3, 9, 5, 0), priority: .important)
        XCTAssertTrue(warnings(r, from: date(2026, 3, 9, 5, 0)).isEmpty)
        let off = critical(breaks, warning: nil, createdAt: date(2026, 3, 9, 5, 0))
        XCTAssertTrue(warnings(off, from: date(2026, 3, 9, 5, 0)).isEmpty)
    }

    // MARK: - Through the engine

    private func makeEngine(
        reminders: [Reminder], now: Date
    ) -> (ReminderEngine, MutableDateProvider, RecordingPresenter) {
        let store = InMemoryDataStore(
            data: AppData(reminders: reminders, settings: Settings(), events: [])
        )
        let clock = MutableDateProvider(now: now)
        let presenter = RecordingPresenter()
        let engine = ReminderEngine(
            store: store, dateProvider: clock, presenter: presenter, calendar: calendar
        )
        return (engine, clock, presenter)
    }

    func testTheEngineWarnsOnceThenTakesOver() {
        let r = critical(breaks, createdAt: date(2026, 3, 9, 5, 0))
        let (engine, clock, presenter) = makeEngine(
            reminders: [r], now: date(2026, 3, 9, 5, 39, 58)
        )
        _ = engine.tick()
        XCTAssertTrue(presenter.warnings.isEmpty)

        clock.set(date(2026, 3, 9, 5, 40, 3))
        _ = engine.tick()
        XCTAssertEqual(presenter.warnings.map(\.takeoverAt), [date(2026, 3, 9, 5, 45)])
        XCTAssertEqual(presenter.warnings.first?.title, "Screen break")

        for _ in 0..<5 {
            clock.advance(by: 5)
            _ = engine.tick()
        }
        XCTAssertEqual(presenter.warnings.count, 1, "Shown once, not every tick")
        XCTAssertTrue(presenter.presented.isEmpty, "The warning is not the reminder")
        XCTAssertTrue(engine.events.isEmpty, "Nor is it history")

        clock.set(date(2026, 3, 9, 5, 45, 3))
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(presenter.presented.count, 1)
        XCTAssertEqual(presenter.warnings.count, 1)

        clock.set(date(2026, 3, 9, 6, 30, 2))
        _ = engine.tick()
        XCTAssertEqual(presenter.warnings.map(\.takeoverAt).last, date(2026, 3, 9, 6, 35))
    }

    func testStartingInsideTheWindowWarnsAtOnce() {
        let r = critical(breaks, createdAt: date(2026, 3, 9, 5, 0))
        let (engine, _, presenter) = makeEngine(reminders: [r], now: date(2026, 3, 9, 5, 43))
        _ = engine.tick()
        XCTAssertEqual(presenter.warnings.map(\.takeoverAt), [date(2026, 3, 9, 5, 45)])
    }

    func testATakeoverAlreadyDueIsNotWarnedAbout() {
        let r = critical(breaks, createdAt: date(2026, 3, 9, 5, 0))
        let (engine, _, presenter) = makeEngine(reminders: [r], now: date(2026, 3, 9, 5, 46))
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertTrue(presenter.warnings.isEmpty)
    }

    // MARK: - Text and persistence

    func testWarningText() {
        let r = critical(breaks, createdAt: date(2026, 3, 9))
        XCTAssertEqual(Scheduler.warningTitle(for: r), "Coming up: Screen break")
        XCTAssertEqual(
            Scheduler.warningMessage(takeoverAt: date(2026, 3, 9, 5, 45), calendar: calendar),
            "Takes over your screen at 05:45."
        )
    }

    func testWarningMinutesPersistAndOldFilesLoadWithout() throws {
        let r = critical(breaks, warning: 15, createdAt: date(2026, 3, 9))
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(Reminder.self, from: data).warningMinutes, 15)

        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "warningMinutes")
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(Reminder.self, from: old).warningMinutes)
    }
}
