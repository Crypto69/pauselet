import XCTest
@testable import ReminderCore

/// Pausing and resuming used to weld interval reminders together.
///
/// The old re-anchor stamped every interval reminder with the same `now`, and
/// since the next fire is `anchor + interval`, every reminder sharing an
/// interval then fired at the same second — and stayed that way forever. The
/// user-visible symptom was three "Every hour" reminders all counting down
/// "58 min" in the menu bar, with unrelated exercises arriving at once.
///
/// These tests pin the spacing that must survive a pause, a timed pause, and
/// a machine sleeping.
@MainActor
final class SpacingPreservationTests: XCTestCase {

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

    /// Three hourly reminders, deliberately staggered 20 minutes apart, as a
    /// user would set up over a morning.
    private func staggeredHourlyTrio(start: Date) -> [Reminder] {
        let offsets = [0, 20, 40]
        return zip(["Lean Back", "Drink Water", "Chin Tuck"], offsets).map { title, offset in
            var reminder = Reminder(
                title: title, schedule: .interval(minutes: 60), createdAt: start
            )
            reminder.lastFiredAt = start.addingTimeInterval(TimeInterval(offset * 60))
            return reminder
        }
    }

    private func nextFires(_ engine: ReminderEngine, at now: Date) -> [Date] {
        engine.reminders.map {
            Scheduler.nextFireDate(for: $0, now: now, calendar: calendar)!
        }
    }

    // MARK: - The reported bug

    /// The screenshot: three hourly reminders that were 20 minutes apart must
    /// still be 20 minutes apart after an indefinite pause is lifted.
    func testResumeKeepsHourlyRemindersSpacedApart() {
        let start = date(2026, 3, 10, 9, 0)
        let reminders = staggeredHourlyTrio(start: start)
        let (engine, clock, _) = makeEngine(reminders: reminders, now: date(2026, 3, 10, 9, 50))

        engine.setPaused(true)
        clock.advance(by: 30 * 60) // resume at 10:20, all still mid-interval
        engine.resume()

        let fires = nextFires(engine, at: clock.now)
        let gaps = zip(fires, fires.dropFirst()).map { $1.timeIntervalSince($0) / 60 }
        XCTAssertEqual(gaps, [20, 20], "The original 20-minute spacing must survive a pause")
        XCTAssertEqual(Set(fires).count, 3, "No two reminders may share a fire time")
    }

    /// The precise regression: identical fire times are what the user saw.
    func testResumeDoesNotCollapseRemindersOntoOneInstant() {
        let start = date(2026, 3, 10, 9, 0)
        let (engine, clock, _) = makeEngine(
            reminders: staggeredHourlyTrio(start: start), now: date(2026, 3, 10, 9, 50)
        )

        engine.setPaused(true)
        clock.advance(by: 45 * 60)
        engine.resume()

        let countdowns = nextFires(engine, at: clock.now).map {
            Scheduler.countdownText(from: clock.now, to: $0)
        }
        XCTAssertEqual(
            Set(countdowns).count, 3,
            "Three hourly reminders must not all read the same countdown"
        )
    }

    /// Phase is preserved exactly: a reminder with 50 minutes left comes back
    /// with 50 minutes left, not a fresh full hour.
    func testResumePreservesRemainingTimeExactly() {
        let start = date(2026, 3, 10, 9, 0)
        var water = Reminder(
            title: "Drink Water", schedule: .interval(minutes: 60), createdAt: start
        )
        water.lastFiredAt = date(2026, 3, 10, 9, 50) // 50 min left at 10:00
        var tuck = Reminder(
            title: "Chin Tuck", schedule: .interval(minutes: 60), createdAt: start
        )
        tuck.lastFiredAt = date(2026, 3, 10, 9, 12) // 12 min left at 10:00

        let (engine, clock, _) = makeEngine(
            reminders: [water, tuck], now: date(2026, 3, 10, 10, 0)
        )
        engine.setPaused(true)
        clock.advance(by: 4 * 60 * 60) // a long pause: resume at 14:00
        engine.resume()

        let fires = nextFires(engine, at: clock.now)
        XCTAssertEqual(fires[0], date(2026, 3, 10, 14, 50), "50 minutes left, still 50")
        XCTAssertEqual(fires[1], date(2026, 3, 10, 14, 12), "12 minutes left, still 12")
    }

    // MARK: - Overdue reminders are staggered, not stacked

    /// Reminders whose intervals fully elapsed during the pause have no phase
    /// left, so they are spread over the next few minutes instead of firing
    /// together — and in the order they were originally due.
    func testFullyOverdueRemindersComeBackStaggeredInOriginalOrder() {
        let start = date(2026, 3, 10, 9, 0)
        // Each has already gone past due by the time we pause.
        let titles = ["First", "Second", "Third"]
        let reminders = zip(titles, [0, 5, 10]).map { title, offset in
            var reminder = Reminder(
                title: title, schedule: .interval(minutes: 30), createdAt: start
            )
            reminder.lastFiredAt = start.addingTimeInterval(TimeInterval(offset * 60))
            return reminder
        }
        let (engine, clock, _) = makeEngine(reminders: reminders, now: date(2026, 3, 10, 10, 30))

        engine.setPaused(true)
        clock.advance(by: 2 * 60 * 60)
        engine.resume()

        let fires = nextFires(engine, at: clock.now)
        XCTAssertEqual(Set(fires).count, 3, "Overdue reminders must not stack on one instant")
        XCTAssertEqual(
            fires, fires.sorted(),
            "They come back in the order they were originally due"
        )
        let spread = fires.max()!.timeIntervalSince(fires.min()!)
        XCTAssertLessThanOrEqual(spread, 10 * 60, "The whole backlog lands within minutes")
    }

    /// Staggering must not reintroduce the burst the old code avoided: nothing
    /// fires the instant the user comes back.
    func testNothingFiresImmediatelyOnResume() {
        let start = date(2026, 3, 10, 9, 0)
        let (engine, clock, presenter) = makeEngine(
            reminders: staggeredHourlyTrio(start: start), now: date(2026, 3, 10, 9, 50)
        )

        engine.setPaused(true)
        clock.advance(by: 6 * 60 * 60)
        engine.resume()

        XCTAssertTrue(engine.tick().isEmpty, "A resume must never dump a backlog")
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    // MARK: - Timed pause

    func testTimedPauseExpiryKeepsSpacing() {
        let start = date(2026, 3, 10, 9, 0)
        let (engine, clock, _) = makeEngine(
            reminders: staggeredHourlyTrio(start: start), now: date(2026, 3, 10, 9, 50)
        )

        engine.pause(forMinutes: 60) // paused 09:50 -> 10:50
        clock.set(date(2026, 3, 10, 10, 50))
        XCTAssertTrue(engine.tick().isEmpty, "The pause absorbs the overdue fire")

        let fires = nextFires(engine, at: clock.now)
        XCTAssertEqual(Set(fires).count, 3, "A timed pause must not collapse them either")
        let gaps = zip(fires.sorted(), fires.sorted().dropFirst()).map {
            $1.timeIntervalSince($0) / 60
        }
        XCTAssertEqual(gaps, [20, 20], "Spacing survives a timed pause")
    }

    /// The projection drives pre-scheduled delivery on iOS, so it must predict
    /// the same spacing the live engine produces.
    func testProjectionAgreesWithTheEngineDuringATimedPause() {
        let start = date(2026, 3, 10, 9, 0)
        let reminders = staggeredHourlyTrio(start: start)
        let now = date(2026, 3, 10, 9, 50)
        var settings = Settings()
        settings.isPaused = true
        settings.pausedAt = now
        settings.pausedUntil = date(2026, 3, 10, 10, 50)

        let projected = reminders.map { reminder in
            Scheduler.projectedFires(
                for: reminder, from: now, limit: 1, settings: settings, calendar: calendar
            )[0].fireDate
        }
        XCTAssertEqual(
            Set(projected).count, 3,
            "The projection must not schedule three notifications for the same second"
        )

        // And it matches what the engine actually does when the pause expires.
        let (engine, clock, _) = makeEngine(reminders: reminders, settings: settings, now: now)
        clock.set(date(2026, 3, 10, 10, 50))
        engine.tick()
        XCTAssertEqual(nextFires(engine, at: clock.now).sorted(), projected.sorted())
    }

    // MARK: - Machine sleep

    func testWakingFromSleepKeepsRemindersApart() {
        let start = date(2026, 3, 10, 9, 0)
        let (engine, clock, _) = makeEngine(
            reminders: staggeredHourlyTrio(start: start), now: date(2026, 3, 10, 9, 50)
        )

        // The machine sleeps for hours; every interval lapses unmeasured.
        clock.set(date(2026, 3, 10, 17, 0))
        engine.absorbBacklogFromDowntime()

        let fires = nextFires(engine, at: clock.now)
        XCTAssertEqual(Set(fires).count, 3, "Waking up must not weld them together")
        XCTAssertEqual(fires, fires.sorted(), "Original order is kept")
    }

    // MARK: - Wall-clock schedules are untouched

    /// A daily reminder is anchored to the clock, not to the downtime. Resume
    /// must leave its grid alone.
    func testResumeDoesNotMoveWallClockReminders() {
        let reminder = Reminder(
            title: "Wind Down",
            schedule: .dailyAt(hour: 20, minute: 59, dayInterval: 1),
            createdAt: date(2026, 3, 10, 9, 0)
        )
        let (engine, clock, _) = makeEngine(reminders: [reminder], now: date(2026, 3, 10, 10, 0))

        engine.setPaused(true)
        clock.advance(by: 3 * 60 * 60)
        engine.resume()

        XCTAssertNil(
            engine.reminders[0].lastFiredAt,
            "A daily schedule keeps its clock anchor across a pause"
        )
        XCTAssertEqual(
            Scheduler.nextFireDate(for: engine.reminders[0], now: clock.now, calendar: calendar),
            date(2026, 3, 10, 20, 59)
        )
    }

    /// A pause shorter than the gap between two reminders cannot make them
    /// converge, no matter how many times it happens. This is the property the
    /// old code violated: repeated pausing dragged everything together.
    func testRepeatedPausingNeverConvergesReminders() {
        let start = date(2026, 3, 10, 9, 0)
        let (engine, clock, _) = makeEngine(
            reminders: staggeredHourlyTrio(start: start), now: date(2026, 3, 10, 9, 45)
        )

        for _ in 0..<12 {
            engine.setPaused(true)
            clock.advance(by: 7 * 60)
            engine.resume()
            clock.advance(by: 3 * 60)
            engine.tick()
        }

        let fires = nextFires(engine, at: clock.now)
        XCTAssertEqual(
            Set(fires).count, 3,
            "Twelve pause cycles must still leave three distinct fire times"
        )
        let spread = fires.max()!.timeIntervalSince(fires.min()!)
        XCTAssertGreaterThan(spread, 20 * 60, "They stay meaningfully spread out")
    }
}
