import XCTest
@testable import ReminderCore

/// `.timedInterval`: a repeat interval pinned to the clock ("every 50 minutes
/// from 05:40, Mon–Fri, until 13:00") rather than to the last fire, so it can
/// stay in step with another app's breaks.
@MainActor
final class TimedIntervalTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
        calendar: Calendar? = nil
    ) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        return (calendar ?? self.calendar).date(from: comps)!
    }

    /// The customer's timetable. 9 Mar 2026 is a Monday.
    private let weekdaysMonFri: Set<Int> = [2, 3, 4, 5, 6]
    private var customer: Schedule {
        .timedInterval(
            minutes: 50, startHour: 5, startMinute: 40,
            endHour: 13, endMinute: 0, weekdays: weekdaysMonFri
        )
    }

    private func reminder(
        _ schedule: Schedule, createdAt: Date, lastFiredAt: Date? = nil
    ) -> Reminder {
        var reminder = Reminder(title: "Break soon", schedule: schedule, createdAt: createdAt)
        reminder.lastFiredAt = lastFiredAt
        return reminder
    }

    /// Steps the schedule's own slots forward from the reminder's anchor.
    private func slots(_ reminder: Reminder, count: Int, calendar: Calendar? = nil) -> [Date] {
        var sim = reminder
        var result: [Date] = []
        for _ in 0..<count {
            guard let slot = Scheduler.nextScheduleSlot(
                for: sim, calendar: calendar ?? self.calendar
            ) else { break }
            result.append(slot)
            sim.lastFiredAt = slot
        }
        return result
    }

    // MARK: - The grid

    func testCustomerTimetableRunsFromStartToEndThenNextDay() {
        let r = reminder(customer, createdAt: date(2026, 3, 9, 5, 0))
        let expected = [
            (5, 40), (6, 30), (7, 20), (8, 10), (9, 0), (9, 50), (10, 40), (11, 30), (12, 20),
        ].map { date(2026, 3, 9, $0.0, $0.1) } + [date(2026, 3, 10, 5, 40)]
        XCTAssertEqual(slots(r, count: 10), expected)
    }

    func testEndTimeIsInclusive() {
        let schedule = Schedule.timedInterval(
            minutes: 50, startHour: 5, startMinute: 40,
            endHour: 12, endMinute: 20, weekdays: weekdaysMonFri
        )
        let r = reminder(schedule, createdAt: date(2026, 3, 9, 12, 0))
        XCTAssertEqual(slots(r, count: 2), [date(2026, 3, 9, 12, 20), date(2026, 3, 10, 5, 40)])
    }

    func testAfterFridaysLastSlotTheNextIsMonday() {
        let r = reminder(
            customer, createdAt: date(2026, 3, 9), lastFiredAt: date(2026, 3, 13, 12, 20)
        )
        XCTAssertEqual(
            Scheduler.nextScheduleSlot(for: r, calendar: calendar), date(2026, 3, 16, 5, 40)
        )
    }

    func testWithoutAnEndTheGridRunsToMidnight() {
        let schedule = Schedule.timedInterval(
            minutes: 50, startHour: 22, startMinute: 0,
            endHour: nil, endMinute: nil, weekdays: Set(1...7)
        )
        let r = reminder(schedule, createdAt: date(2026, 3, 9, 21, 0))
        XCTAssertEqual(slots(r, count: 4), [
            date(2026, 3, 9, 22, 0), date(2026, 3, 9, 22, 50), date(2026, 3, 9, 23, 40),
            date(2026, 3, 10, 22, 0),
        ])
    }

    func testAReminderCreatedMidMorningJoinsTheGrid() {
        let r = reminder(customer, createdAt: date(2026, 3, 9, 9, 5))
        XCTAssertEqual(
            Scheduler.nextScheduleSlot(for: r, calendar: calendar), date(2026, 3, 9, 9, 50)
        )
    }

    func testNoWeekdaysNeverFires() {
        let schedule = Schedule.timedInterval(
            minutes: 30, startHour: 9, startMinute: 0,
            endHour: nil, endMinute: nil, weekdays: []
        )
        let r = reminder(schedule, createdAt: date(2026, 3, 9))
        XCTAssertNil(Scheduler.nextScheduleSlot(for: r, calendar: calendar))
        XCTAssertNil(Scheduler.nextFireDate(for: r, now: date(2026, 3, 9), calendar: calendar))
    }

    func testSlotsKeepTheirClockTimesAcrossDST() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        // Clocks go forward at 02:00 on Sunday 8 Mar 2026.
        let schedule = Schedule.timedInterval(
            minutes: 120, startHour: 1, startMinute: 0,
            endHour: 5, endMinute: 0, weekdays: Set(1...7)
        )
        let r = reminder(schedule, createdAt: date(2026, 3, 7, 23, 0, calendar: newYork))
        let fired = slots(r, count: 3, calendar: newYork)
        XCTAssertEqual(fired, [
            date(2026, 3, 8, 1, 0, calendar: newYork),
            date(2026, 3, 8, 3, 0, calendar: newYork),
            date(2026, 3, 8, 5, 0, calendar: newYork),
        ])
        // 01:00 → 03:00 on the clock is one real hour that night.
        XCTAssertEqual(fired[1].timeIntervalSince(fired[0]), 3600)
    }

    func testLatestElapsedSlotAfterAGap() {
        let r = reminder(
            customer, createdAt: date(2026, 3, 9), lastFiredAt: date(2026, 3, 9, 6, 30)
        )
        XCTAssertEqual(
            Scheduler.latestElapsedSlot(for: r, now: date(2026, 3, 9, 9, 15), calendar: calendar),
            date(2026, 3, 9, 9, 0)
        )
        // Over a weekend the latest elapsed slot is Friday's last one.
        XCTAssertEqual(
            Scheduler.latestElapsedSlot(for: r, now: date(2026, 3, 15, 9, 0), calendar: calendar),
            date(2026, 3, 13, 12, 20)
        )
        // Nothing elapsed since the anchor.
        XCTAssertNil(
            Scheduler.latestElapsedSlot(for: r, now: date(2026, 3, 9, 7, 0), calendar: calendar)
        )
    }

    // MARK: - Firing through the engine

    private func makeEngine(
        reminders: [Reminder], settings: Settings = Settings(), now: Date
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

    func testFiresOnEachSlotAndNotBetween() {
        let r = reminder(
            customer, createdAt: date(2026, 3, 9), lastFiredAt: date(2026, 3, 9, 6, 30)
        )
        let (engine, clock, presenter) = makeEngine(
            reminders: [r], now: date(2026, 3, 9, 7, 19, 55)
        )
        XCTAssertTrue(engine.tick().isEmpty)
        clock.set(date(2026, 3, 9, 7, 20, 4))
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(engine.reminders[0].lastFiredAt, date(2026, 3, 9, 7, 20))
        clock.set(date(2026, 3, 9, 8, 9, 0))
        XCTAssertTrue(engine.tick().isEmpty)
        clock.set(date(2026, 3, 9, 8, 10, 3))
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(presenter.presented.count, 2)
    }

    /// Asleep through a slot, woken less than half an interval later: the
    /// slot is still worth delivering.
    func testASlotMissedByLessThanHalfAnIntervalIsDeliveredLate() {
        let r = reminder(
            customer, createdAt: date(2026, 3, 9), lastFiredAt: date(2026, 3, 9, 6, 30)
        )
        let (engine, _, presenter) = makeEngine(reminders: [r], now: date(2026, 3, 9, 7, 40))
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(presenter.presented.count, 1)
        XCTAssertEqual(engine.reminders[0].lastFiredAt, date(2026, 3, 9, 7, 20))
    }

    /// Woken more than half an interval after the slot: it is recorded as
    /// missed, and the next slot fires on time.
    func testASlotMissedByMoreThanHalfAnIntervalIsSkipped() {
        let r = reminder(
            customer, createdAt: date(2026, 3, 9), lastFiredAt: date(2026, 3, 9, 6, 30)
        )
        let (engine, clock, presenter) = makeEngine(
            reminders: [r], now: date(2026, 3, 9, 7, 50)
        )
        XCTAssertTrue(engine.tick().isEmpty)
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertEqual(engine.reminders[0].lastFiredAt, date(2026, 3, 9, 7, 20))
        XCTAssertEqual(engine.events.last?.outcome, .missed)

        clock.set(date(2026, 3, 9, 8, 10, 3))
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testASlotInsideQuietHoursIsSkipped() {
        var settings = Settings()
        settings.quietHours = QuietHours(
            isEnabled: true, startHour: 12, startMinute: 0, endHour: 14, endMinute: 0
        )
        let r = reminder(
            customer, createdAt: date(2026, 3, 9), lastFiredAt: date(2026, 3, 9, 11, 30)
        )
        let (engine, clock, presenter) = makeEngine(
            reminders: [r], settings: settings, now: date(2026, 3, 9, 12, 20, 3)
        )
        XCTAssertTrue(engine.tick().isEmpty)
        clock.set(date(2026, 3, 9, 14, 0, 3))
        XCTAssertTrue(engine.tick().isEmpty)
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertEqual(engine.events.last?.outcome, .missed)
        XCTAssertEqual(
            Scheduler.nextScheduleSlot(for: engine.reminders[0], calendar: calendar),
            date(2026, 3, 10, 5, 40)
        )
    }

    func testCompletingAheadOfASlotConsumesIt() {
        var r = reminder(
            customer, createdAt: date(2026, 3, 9), lastFiredAt: date(2026, 3, 9, 6, 30)
        )
        r.lastAcknowledgedAt = date(2026, 3, 9, 6, 31)
        let (engine, _, _) = makeEngine(reminders: [r], now: date(2026, 3, 9, 7, 0))
        engine.complete(id: r.id)
        XCTAssertEqual(engine.reminders[0].lastFiredAt, date(2026, 3, 9, 7, 20))
        XCTAssertEqual(
            Scheduler.nextScheduleSlot(for: engine.reminders[0], calendar: calendar),
            date(2026, 3, 9, 8, 10)
        )
    }

    func testSnoozeFiresOnceAndTheGridStaysPut() {
        let r = reminder(
            customer, createdAt: date(2026, 3, 9), lastFiredAt: date(2026, 3, 9, 6, 30)
        )
        let (engine, clock, presenter) = makeEngine(
            reminders: [r], now: date(2026, 3, 9, 7, 20, 3)
        )
        XCTAssertEqual(engine.tick().count, 1)
        engine.snooze(id: r.id, minutes: 5)
        clock.set(date(2026, 3, 9, 7, 25, 3))
        XCTAssertEqual(engine.tick().count, 1)
        XCTAssertEqual(presenter.presented.count, 2)
        XCTAssertEqual(engine.reminders[0].lastFiredAt, date(2026, 3, 9, 7, 20))
        XCTAssertEqual(
            Scheduler.nextScheduleSlot(for: engine.reminders[0], calendar: calendar),
            date(2026, 3, 9, 8, 10)
        )
    }

    func testProjectionFollowsTheGrid() {
        let r = reminder(customer, createdAt: date(2026, 3, 13, 12, 0))
        let fires = Scheduler.projectedFires(
            for: r, from: date(2026, 3, 13, 12, 0), limit: 2,
            settings: Settings(), calendar: calendar
        )
        XCTAssertEqual(fires.map(\.fireDate), [date(2026, 3, 13, 12, 20), date(2026, 3, 16, 5, 40)])
        XCTAssertEqual(fires.map(\.stampDate), fires.map(\.fireDate))
    }

    // MARK: - Editor helpers and persistence

    func testSilencedSlotCount() {
        var settings = Settings()
        settings.quietHours = QuietHours(
            isEnabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0
        )
        let counts = Scheduler.timedIntervalSilencedSlots(
            customer, priority: .normal, settings: settings
        )
        XCTAssertEqual(counts.silenced, 2) // 05:40, 06:30
        XCTAssertEqual(counts.total, 9)
        XCTAssertEqual(
            Scheduler.timedIntervalQuietHoursWarning(customer, priority: .normal, settings: settings),
            "2 of the 9 daily times fall inside quiet hours (22:00–07:00) and will be skipped."
        )
        XCTAssertNil(
            Scheduler.timedIntervalQuietHoursWarning(customer, priority: .normal, settings: Settings())
        )
    }

    func testSummary() {
        XCTAssertEqual(customer.summary, "Every 50 min, 05:40–13:00, Mon, Tue, Wed, Thu, Fri")
        let open = Schedule.timedInterval(
            minutes: 90, startHour: 8, startMinute: 0,
            endHour: nil, endMinute: nil, weekdays: [1, 7]
        )
        XCTAssertEqual(open.summary, "Every 1h 30m from 08:00, Sun, Sat")
        XCTAssertTrue(customer.isWallClock)
    }

    /// The wire format Windows reads and writes too; see
    /// `Pauselet.Core.Tests` for the same strings.
    func testJSONShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // One weekday: a Set encodes in no particular order.
        let monday = Schedule.timedInterval(
            minutes: 50, startHour: 5, startMinute: 40,
            endHour: 13, endMinute: 0, weekdays: [2]
        )
        XCTAssertEqual(
            String(data: try encoder.encode(monday), encoding: .utf8),
            #"{"timedInterval":{"endHour":13,"endMinute":0,"minutes":50,"#
                + #""startHour":5,"startMinute":40,"weekdays":[2]}}"#
        )
        XCTAssertEqual(
            try JSONDecoder().decode(Schedule.self, from: encoder.encode(customer)), customer
        )
        let open = Schedule.timedInterval(
            minutes: 30, startHour: 9, startMinute: 0,
            endHour: nil, endMinute: nil, weekdays: [2]
        )
        let withoutEnd = try encoder.encode(open)
        XCTAssertEqual(
            String(data: withoutEnd, encoding: .utf8),
            #"{"timedInterval":{"minutes":30,"startHour":9,"startMinute":0,"weekdays":[2]}}"#
        )
        XCTAssertEqual(try JSONDecoder().decode(Schedule.self, from: withoutEnd), open)
    }
}
