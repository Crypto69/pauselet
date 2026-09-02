import XCTest
@testable import ReminderCore

/// Tests for the fire-date projection that pre-scheduled delivery (iOS) is
/// built on. The projection must agree with what the live engine would have
/// done tick by tick — snooze first, quiet hours resolved at fire time, pause
/// re-anchoring — because on iOS there is no tick to correct it later.
final class ProjectionTests: XCTestCase {

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

    // MARK: - Interval schedules

    func testIntervalProjectsSuccessiveFires() {
        let created = date(2026, 3, 10, 9, 0)
        let reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 60), createdAt: created
        )
        let fires = Scheduler.projectedFires(
            for: reminder, from: created, limit: 3, settings: Settings(), calendar: calendar
        )
        XCTAssertEqual(fires.map(\.fireDate), [
            date(2026, 3, 10, 10, 0), date(2026, 3, 10, 11, 0), date(2026, 3, 10, 12, 0),
        ])
        // Interval fires stamp their delivery time.
        XCTAssertEqual(fires.map(\.stampDate), fires.map(\.fireDate))
    }

    func testOverdueIntervalProjectsNowFirstThenReanchors() {
        let created = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 20), createdAt: created
        )
        reminder.lastFiredAt = date(2026, 3, 10, 9, 0)
        let now = date(2026, 3, 10, 15, 0)
        let fires = Scheduler.projectedFires(
            for: reminder, from: now, limit: 2, settings: Settings(), calendar: calendar
        )
        XCTAssertEqual(fires.map(\.fireDate), [now, date(2026, 3, 10, 15, 20)])
    }

    func testSnoozeWinsFirstThenScheduleResumes() {
        let created = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Tilt", schedule: .interval(minutes: 60), createdAt: created
        )
        reminder.lastFiredAt = date(2026, 3, 10, 9, 30)
        reminder.snoozedUntil = date(2026, 3, 10, 9, 40)
        let fires = Scheduler.projectedFires(
            for: reminder, from: date(2026, 3, 10, 9, 35), limit: 2,
            settings: Settings(), calendar: calendar
        )
        // The snooze fires once, and the interval restarts from its delivery.
        XCTAssertEqual(fires.map(\.fireDate), [
            date(2026, 3, 10, 9, 40), date(2026, 3, 10, 10, 40),
        ])
    }

    func testDisabledReminderProjectsNothing() {
        var reminder = Reminder(
            title: "Off", schedule: .interval(minutes: 5), createdAt: date(2026, 3, 10, 9, 0)
        )
        reminder.isEnabled = false
        XCTAssertTrue(
            Scheduler.projectedFires(
                for: reminder, from: date(2026, 3, 10, 12, 0), limit: 5,
                settings: Settings(), calendar: calendar
            ).isEmpty
        )
    }

    // MARK: - Wall-clock schedules

    func testDailyProjectsSuccessiveSlotsWithSlotStamps() {
        let created = date(2026, 3, 10, 9, 0)
        let reminder = Reminder(
            title: "Stretch",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1),
            createdAt: created
        )
        let fires = Scheduler.projectedFires(
            for: reminder, from: created, limit: 3, settings: Settings(), calendar: calendar
        )
        XCTAssertEqual(fires.map(\.fireDate), [
            date(2026, 3, 10, 17, 0), date(2026, 3, 11, 17, 0), date(2026, 3, 12, 17, 0),
        ])
        XCTAssertEqual(fires.map(\.stampDate), fires.map(\.fireDate))
    }

    func testEveryTwoDaysStaysOnItsGrid() {
        let created = date(2026, 3, 10, 9, 0)
        let reminder = Reminder(
            title: "Stretch",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 2),
            createdAt: created
        )
        let fires = Scheduler.projectedFires(
            for: reminder, from: created, limit: 3, settings: Settings(), calendar: calendar
        )
        XCTAssertEqual(fires.map(\.fireDate), [
            date(2026, 3, 10, 17, 0), date(2026, 3, 12, 17, 0), date(2026, 3, 14, 17, 0),
        ])
    }

    func testWeeklyProjectsSelectedWeekdaysOnly() {
        // 2026-03-10 is a Tuesday.
        let created = date(2026, 3, 10, 9, 0)
        let reminder = Reminder(
            title: "Call",
            schedule: .weeklyAt(hour: 18, minute: 30, weekdays: [2, 6]), // Mon, Fri
            createdAt: created
        )
        let fires = Scheduler.projectedFires(
            for: reminder, from: created, limit: 3, settings: Settings(), calendar: calendar
        )
        XCTAssertEqual(fires.map(\.fireDate), [
            date(2026, 3, 13, 18, 30), // Friday
            date(2026, 3, 16, 18, 30), // Monday
            date(2026, 3, 20, 18, 30), // Friday
        ])
    }

    func testWeeklyWithNoWeekdaysProjectsNothing() {
        let reminder = Reminder(
            title: "Never",
            schedule: .weeklyAt(hour: 9, minute: 0, weekdays: []),
            createdAt: date(2026, 3, 10, 9, 0)
        )
        XCTAssertTrue(
            Scheduler.projectedFires(
                for: reminder, from: date(2026, 3, 10, 10, 0), limit: 5,
                settings: Settings(), calendar: calendar
            ).isEmpty
        )
    }

    func testOverdueDailySlotStampsTheSlotNotDeliveryTime() {
        let created = date(2026, 3, 10, 9, 0)
        let reminder = Reminder(
            title: "Stretch",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1),
            createdAt: created
        )
        // The 17:00 slot elapsed unheard; projection from 18:00 delivers a
        // catch-up now, stamped with the slot it honours.
        let now = date(2026, 3, 10, 18, 0)
        let fires = Scheduler.projectedFires(
            for: reminder, from: now, limit: 2, settings: Settings(), calendar: calendar
        )
        XCTAssertEqual(fires[0].fireDate, now)
        XCTAssertEqual(fires[0].stampDate, date(2026, 3, 10, 17, 0))
        XCTAssertEqual(fires[1].fireDate, date(2026, 3, 11, 17, 0))
    }

    // MARK: - Quiet hours

    private func quietSettings(
        start: (Int, Int), end: (Int, Int), allowsCritical: Bool = true
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

    func testIntervalFireInsideQuietHoursWaitsForWindowEnd() {
        let created = date(2026, 3, 10, 21, 30)
        let reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 60), createdAt: created
        )
        let settings = quietSettings(start: (22, 0), end: (7, 0))
        let fires = Scheduler.projectedFires(
            for: reminder, from: created, limit: 2, settings: settings, calendar: calendar
        )
        // 22:30 falls inside the window; it delivers at 07:00, and the next
        // interval runs from that delivery.
        XCTAssertEqual(fires.map(\.fireDate), [
            date(2026, 3, 11, 7, 0), date(2026, 3, 11, 8, 0),
        ])
    }

    func testWallClockSlotInsideQuietHoursIsSkippedNotDelayed() {
        let created = date(2026, 3, 10, 9, 0)
        let reminder = Reminder(
            title: "Late stretch",
            schedule: .dailyAt(hour: 23, minute: 0, dayInterval: 1),
            createdAt: created
        )
        let settings = quietSettings(start: (22, 0), end: (7, 0))
        let fires = Scheduler.projectedFires(
            for: reminder, from: created, limit: 3, settings: settings, calendar: calendar
        )
        // Every 23:00 slot lives inside the window, so nothing is ever
        // delivered — and the projection terminates rather than spinning.
        XCTAssertTrue(fires.isEmpty)
    }

    func testCriticalPiercesQuietHoursWhenAllowed() {
        let created = date(2026, 3, 10, 21, 30)
        let reminder = Reminder(
            title: "Pressure relief",
            schedule: .interval(minutes: 60),
            priority: .critical,
            createdAt: created
        )
        let settings = quietSettings(start: (22, 0), end: (7, 0), allowsCritical: true)
        let fires = Scheduler.projectedFires(
            for: reminder, from: created, limit: 1, settings: settings, calendar: calendar
        )
        XCTAssertEqual(fires.map(\.fireDate), [date(2026, 3, 10, 22, 30)])
    }

    func testCriticalRespectsQuietHoursWhenNotAllowed() {
        let created = date(2026, 3, 10, 21, 30)
        let reminder = Reminder(
            title: "Pressure relief",
            schedule: .interval(minutes: 60),
            priority: .critical,
            createdAt: created
        )
        let settings = quietSettings(start: (22, 0), end: (7, 0), allowsCritical: false)
        let fires = Scheduler.projectedFires(
            for: reminder, from: created, limit: 1, settings: settings, calendar: calendar
        )
        XCTAssertEqual(fires.map(\.fireDate), [date(2026, 3, 11, 7, 0)])
    }

    // MARK: - Pause

    func testIndefinitePauseProjectsNothing() {
        var settings = Settings()
        settings.isPaused = true
        let reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 30), createdAt: date(2026, 3, 10, 9, 0)
        )
        XCTAssertTrue(
            Scheduler.projectedFires(
                for: reminder, from: date(2026, 3, 10, 10, 0), limit: 5,
                settings: settings, calendar: calendar
            ).isEmpty
        )
    }

    func testTimedPauseReanchorsIntervalsToItsEnd() {
        var settings = Settings()
        settings.isPaused = true
        settings.pausedUntil = date(2026, 3, 10, 12, 0)
        var reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 30), createdAt: date(2026, 3, 10, 9, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 10, 9, 30)
        let fires = Scheduler.projectedFires(
            for: reminder, from: date(2026, 3, 10, 10, 0), limit: 2,
            settings: settings, calendar: calendar
        )
        // Not 10:00 (the natural overdue fire): the pause absorbs it and the
        // interval restarts from the pause's end, exactly as resume() does.
        XCTAssertEqual(fires.map(\.fireDate), [
            date(2026, 3, 10, 12, 30), date(2026, 3, 10, 13, 0),
        ])
    }

    func testTimedPauseDeliversElapsedWallClockSlotAtItsEnd() {
        var settings = Settings()
        settings.isPaused = true
        settings.pausedUntil = date(2026, 3, 10, 18, 0)
        let reminder = Reminder(
            title: "Stretch",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1),
            createdAt: date(2026, 3, 10, 9, 0)
        )
        let fires = Scheduler.projectedFires(
            for: reminder, from: date(2026, 3, 10, 16, 0), limit: 2,
            settings: settings, calendar: calendar
        )
        // The 17:00 slot elapses during the pause and surfaces once at 18:00,
        // stamped with the slot it honours.
        XCTAssertEqual(fires[0].fireDate, date(2026, 3, 10, 18, 0))
        XCTAssertEqual(fires[0].stampDate, date(2026, 3, 10, 17, 0))
        XCTAssertEqual(fires[1].fireDate, date(2026, 3, 11, 17, 0))
    }

    // MARK: - DST

    func testDailySlotStaysOnLocalTimeAcrossSpringForward() {
        var nyCalendar = Calendar(identifier: .gregorian)
        nyCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 7; comps.hour = 9
        let created = nyCalendar.date(from: comps)!
        let reminder = Reminder(
            title: "Meds",
            schedule: .dailyAt(hour: 12, minute: 0, dayInterval: 1),
            createdAt: created
        )
        // Spring forward is 2026-03-08 in New York.
        let fires = Scheduler.projectedFires(
            for: reminder, from: created, limit: 3, settings: Settings(), calendar: nyCalendar
        )
        for (offset, fire) in fires.enumerated() {
            let hour = nyCalendar.component(.hour, from: fire.fireDate)
            let day = nyCalendar.component(.day, from: fire.fireDate)
            XCTAssertEqual(hour, 12, "Slot must stay 12:00 local across DST")
            XCTAssertEqual(day, 7 + offset)
        }
    }
}

/// Tests for the 64-request budget allocator.
final class NotificationBudgetTests: XCTestCase {

    private func fire(_ minutesFromNow: Int) -> ProjectedFire {
        let date = Date(timeIntervalSinceReferenceDate: TimeInterval(minutesFromNow * 60))
        return ProjectedFire(fireDate: date, stampDate: date)
    }

    func testEveryReminderGetsItsFirstFireBeforeAnySecond() {
        let frequent = UUID()
        let daily = UUID()
        let projections: [(reminderID: UUID, fires: [ProjectedFire])] = [
            (frequent, [fire(5), fire(10), fire(15), fire(20)]),
            (daily, [fire(600)]),
        ]
        let entries = NotificationBudget.allocate(projections: projections, budget: 2)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.reminderID)), [frequent, daily],
                       "The daily reminder must not be starved by the frequent one")
    }

    func testWithinALayerSoonerFiresWin() {
        let a = UUID(), b = UUID(), c = UUID()
        let projections: [(reminderID: UUID, fires: [ProjectedFire])] = [
            (a, [fire(30)]), (b, [fire(10)]), (c, [fire(20)]),
        ]
        let entries = NotificationBudget.allocate(projections: projections, budget: 2)
        XCTAssertEqual(entries.map(\.fire.fireDate), [fire(10).fireDate, fire(20).fireDate])
    }

    func testBudgetLargerThanSupplyReturnsEverything() {
        let a = UUID(), b = UUID()
        let projections: [(reminderID: UUID, fires: [ProjectedFire])] = [
            (a, [fire(5), fire(10)]), (b, [fire(7)]),
        ]
        let entries = NotificationBudget.allocate(projections: projections, budget: 64)
        XCTAssertEqual(entries.count, 3)
    }

    func testZeroBudgetReturnsNothing() {
        let projections: [(reminderID: UUID, fires: [ProjectedFire])] = [
            (UUID(), [fire(5)]),
        ]
        XCTAssertTrue(
            NotificationBudget.allocate(projections: projections, budget: 0).isEmpty
        )
    }

    func testAllocationIsDeterministic() {
        let a = UUID(), b = UUID()
        let projections: [(reminderID: UUID, fires: [ProjectedFire])] = [
            (a, [fire(5)]), (b, [fire(5)]),
        ]
        let first = NotificationBudget.allocate(projections: projections, budget: 1)
        let second = NotificationBudget.allocate(projections: projections, budget: 1)
        XCTAssertEqual(first, second)
    }
}
