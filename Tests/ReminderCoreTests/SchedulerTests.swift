import XCTest
@testable import ReminderCore

/// Tests for the pure scheduling logic. Every case pins "now" to a fixed date
/// so results are deterministic regardless of when the suite runs.
final class SchedulerTests: XCTestCase {

    /// A fixed calendar in UTC keeps wall-clock assertions stable on any machine.
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

    func testIntervalFirstFireIsOneIntervalAfterCreation() {
        let created = date(2026, 3, 10, 9, 0)
        let reminder = Reminder(
            title: "Weight Shift",
            schedule: .interval(minutes: 20),
            createdAt: created
        )
        let next = Scheduler.nextFireDate(for: reminder, now: created, calendar: calendar)
        XCTAssertEqual(next, date(2026, 3, 10, 9, 20))
    }

    func testIntervalFiresFromLastFiredNotCreation() {
        let created = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Tilt Back",
            schedule: .interval(minutes: 60),
            createdAt: created
        )
        reminder.lastFiredAt = date(2026, 3, 10, 11, 30)
        let next = Scheduler.nextFireDate(
            for: reminder, now: date(2026, 3, 10, 11, 45), calendar: calendar
        )
        XCTAssertEqual(next, date(2026, 3, 10, 12, 30))
    }

    /// If the Mac slept for hours we want a single catch-up fire, not a burst of
    /// every interval that elapsed while it was away.
    func testOverdueIntervalCollapsesToNowRatherThanReplaying() {
        let created = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Weight Shift",
            schedule: .interval(minutes: 20),
            createdAt: created
        )
        reminder.lastFiredAt = date(2026, 3, 10, 9, 0)
        let now = date(2026, 3, 10, 15, 0) // 6 hours later = 18 missed intervals
        let next = Scheduler.nextFireDate(for: reminder, now: now, calendar: calendar)
        XCTAssertEqual(next, now, "An overdue interval should fire once, immediately")
    }

    func testDisabledReminderNeverFires() {
        var reminder = Reminder(
            title: "Off", schedule: .interval(minutes: 5), createdAt: date(2026, 3, 10, 9, 0)
        )
        reminder.isEnabled = false
        XCTAssertNil(
            Scheduler.nextFireDate(
                for: reminder, now: date(2026, 3, 10, 12, 0), calendar: calendar
            )
        )
    }

    func testZeroOrNegativeIntervalIsClampedToOneMinute() {
        let created = date(2026, 3, 10, 9, 0)
        for badInterval in [0, -5] {
            let reminder = Reminder(
                title: "Bad", schedule: .interval(minutes: badInterval), createdAt: created
            )
            let next = Scheduler.nextFireDate(for: reminder, now: created, calendar: calendar)
            XCTAssertEqual(
                next, date(2026, 3, 10, 9, 1),
                "Interval \(badInterval) should clamp to 1 minute, not spin"
            )
        }
    }

    // MARK: - Snooze

    func testSnoozePushesFireDateOut() {
        let created = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Tilt Back", schedule: .interval(minutes: 60), createdAt: created
        )
        reminder.lastFiredAt = created
        reminder.snoozedUntil = date(2026, 3, 10, 10, 15)
        let next = Scheduler.nextFireDate(
            for: reminder, now: date(2026, 3, 10, 10, 5), calendar: calendar
        )
        XCTAssertEqual(next, date(2026, 3, 10, 10, 15))
    }

    /// A snooze whose moment passed between two ticks must still fire, late,
    /// rather than silently evaporating. The engine clears `snoozedUntil` as
    /// soon as it honours it, so a stale snooze cannot fire twice.
    func testElapsedSnoozeStillFiresRatherThanBeingSkipped() {
        let created = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Tilt Back", schedule: .interval(minutes: 60), createdAt: created
        )
        reminder.lastFiredAt = date(2026, 3, 10, 10, 0)
        reminder.snoozedUntil = date(2026, 3, 10, 10, 2)
        let now = date(2026, 3, 10, 10, 5) // tick landed 3 minutes late
        let next = Scheduler.nextFireDate(for: reminder, now: now, calendar: calendar)

        XCTAssertEqual(next, date(2026, 3, 10, 10, 2))
        XCTAssertTrue(
            Scheduler.isDue(reminder, now: now, settings: Settings(), calendar: calendar),
            "An elapsed snooze should be due immediately"
        )
    }

    /// Snoozing an already-overdue reminder must actually delay it. Without
    /// this, the catch-up "fire now" path would override the snooze and the
    /// reminder would reappear on the very next tick.
    func testSnoozingAnOverdueReminderHonoursTheSnooze() {
        let created = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Shift", schedule: .interval(minutes: 20), createdAt: created
        )
        reminder.lastFiredAt = date(2026, 3, 10, 9, 0) // long overdue
        reminder.snoozedUntil = date(2026, 3, 10, 10, 15)
        let now = date(2026, 3, 10, 10, 5)

        XCTAssertEqual(
            Scheduler.nextFireDate(for: reminder, now: now, calendar: calendar),
            date(2026, 3, 10, 10, 15)
        )
        XCTAssertFalse(
            Scheduler.isDue(reminder, now: now, settings: Settings(), calendar: calendar)
        )
    }

    // MARK: - Daily / multi-day schedules

    func testDailyFiresTodayWhenSlotStillAhead() {
        let created = date(2026, 3, 10, 8, 0)
        let reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1),
            createdAt: created
        )
        let next = Scheduler.nextFireDate(
            for: reminder, now: date(2026, 3, 10, 9, 0), calendar: calendar
        )
        XCTAssertEqual(next, date(2026, 3, 10, 17, 0))
    }

    func testDailyRollsToTomorrowWhenSlotHasPassed() {
        let created = date(2026, 3, 10, 8, 0)
        let reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1),
            createdAt: created
        )
        let next = Scheduler.nextFireDate(
            for: reminder, now: date(2026, 3, 10, 18, 0), calendar: calendar
        )
        XCTAssertEqual(next, date(2026, 3, 11, 17, 0))
    }

    /// "Every 2 days" must stay in phase with the last fire rather than drifting
    /// or collapsing to daily.
    func testEveryTwoDaysStaysInPhaseWithLastFire() {
        let created = date(2026, 3, 1, 8, 0)
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 2),
            createdAt: created
        )
        reminder.lastFiredAt = date(2026, 3, 10, 17, 0)
        let next = Scheduler.nextFireDate(
            for: reminder, now: date(2026, 3, 10, 18, 0), calendar: calendar
        )
        XCTAssertEqual(next, date(2026, 3, 12, 17, 0), "Should skip the 11th")
    }

    /// Even after missing several cycles, the next fire lands on the cycle grid.
    func testEveryTwoDaysAfterLongGapLandsOnCycleGrid() {
        let created = date(2026, 3, 1, 8, 0)
        var reminder = Reminder(
            title: "Physio",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 2),
            createdAt: created
        )
        reminder.lastFiredAt = date(2026, 3, 2, 17, 0)
        let next = Scheduler.nextFireDate(
            for: reminder, now: date(2026, 3, 9, 12, 0), calendar: calendar
        )
        // Grid from Mar 2: 4, 6, 8, 10 -> first slot after Mar 9 noon is Mar 10.
        XCTAssertEqual(next, date(2026, 3, 10, 17, 0))
    }

    // MARK: - Weekly schedules

    func testWeeklyPicksNextSelectedWeekday() {
        let created = date(2026, 3, 9, 8, 0) // Monday
        // Weekday numbering: 1 = Sunday ... 7 = Saturday. Wed = 4, Fri = 6.
        let reminder = Reminder(
            title: "Call Mum",
            schedule: .weeklyAt(hour: 10, minute: 30, weekdays: [4, 6]),
            createdAt: created
        )
        let next = Scheduler.nextFireDate(
            for: reminder, now: date(2026, 3, 9, 9, 0), calendar: calendar
        )
        XCTAssertEqual(next, date(2026, 3, 11, 10, 30), "Next Wednesday")
    }

    func testWeeklyWrapsToNextWeek() {
        let created = date(2026, 3, 9, 8, 0)
        let reminder = Reminder(
            title: "Call Mum",
            schedule: .weeklyAt(hour: 10, minute: 30, weekdays: [2]), // Monday only
            createdAt: created
        )
        // Monday 11:00, past the 10:30 slot -> next Monday.
        let next = Scheduler.nextFireDate(
            for: reminder, now: date(2026, 3, 9, 11, 0), calendar: calendar
        )
        XCTAssertEqual(next, date(2026, 3, 16, 10, 30))
    }

    func testWeeklyWithNoWeekdaysNeverFires() {
        let reminder = Reminder(
            title: "Nothing",
            schedule: .weeklyAt(hour: 10, minute: 0, weekdays: []),
            createdAt: date(2026, 3, 9, 8, 0)
        )
        XCTAssertNil(
            Scheduler.nextFireDate(
                for: reminder, now: date(2026, 3, 9, 9, 0), calendar: calendar
            )
        )
    }

    // MARK: - Quiet hours

    func testQuietHoursWrappingMidnightContainsLateNightAndEarlyMorning() {
        let quiet = QuietHours(
            isEnabled: true, startHour: 22, startMinute: 0, endHour: 7, endMinute: 0
        )
        XCTAssertTrue(quiet.contains(date(2026, 3, 10, 23, 30), calendar: calendar))
        XCTAssertTrue(quiet.contains(date(2026, 3, 10, 2, 0), calendar: calendar))
        XCTAssertFalse(quiet.contains(date(2026, 3, 10, 12, 0), calendar: calendar))
        XCTAssertFalse(quiet.contains(date(2026, 3, 10, 7, 0), calendar: calendar),
                       "End of the window is exclusive")
        XCTAssertTrue(quiet.contains(date(2026, 3, 10, 22, 0), calendar: calendar),
                      "Start of the window is inclusive")
    }

    func testQuietHoursSameDayWindow() {
        let quiet = QuietHours(
            isEnabled: true, startHour: 13, startMinute: 0, endHour: 14, endMinute: 0
        )
        XCTAssertTrue(quiet.contains(date(2026, 3, 10, 13, 30), calendar: calendar))
        XCTAssertFalse(quiet.contains(date(2026, 3, 10, 12, 59), calendar: calendar))
        XCTAssertFalse(quiet.contains(date(2026, 3, 10, 23, 0), calendar: calendar))
    }

    func testDisabledQuietHoursNeverContains() {
        let quiet = QuietHours(isEnabled: false, startHour: 0, startMinute: 0,
                               endHour: 23, endMinute: 59)
        XCTAssertFalse(quiet.contains(date(2026, 3, 10, 12, 0), calendar: calendar))
    }

    /// Pressure-relief reminders are medically necessary, so critical is allowed
    /// to pierce quiet hours when the user opts in.
    func testCriticalPiercesQuietHoursWhenAllowed() {
        var settings = Settings()
        settings.quietHours = QuietHours(
            isEnabled: true, startHour: 22, startMinute: 0,
            endHour: 7, endMinute: 0, allowsCritical: true
        )
        let night = date(2026, 3, 10, 23, 0)
        XCTAssertFalse(
            Scheduler.isSuppressedByQuietHours(
                priority: .critical, settings: settings, now: night, calendar: calendar
            )
        )
        XCTAssertTrue(
            Scheduler.isSuppressedByQuietHours(
                priority: .important, settings: settings, now: night, calendar: calendar
            )
        )
    }

    func testCriticalSuppressedWhenNotAllowed() {
        var settings = Settings()
        settings.quietHours = QuietHours(
            isEnabled: true, startHour: 22, startMinute: 0,
            endHour: 7, endMinute: 0, allowsCritical: false
        )
        XCTAssertTrue(
            Scheduler.isSuppressedByQuietHours(
                priority: .critical, settings: settings,
                now: date(2026, 3, 10, 23, 0), calendar: calendar
            )
        )
    }

    // MARK: - Due / pause

    func testIsDueRespectsPause() {
        var settings = Settings()
        settings.isPaused = true
        var reminder = Reminder(
            title: "Tilt", schedule: .interval(minutes: 60),
            createdAt: date(2026, 3, 10, 9, 0)
        )
        reminder.lastFiredAt = date(2026, 3, 10, 9, 0)
        XCTAssertFalse(
            Scheduler.isDue(
                reminder, now: date(2026, 3, 10, 11, 0),
                settings: settings, calendar: calendar
            )
        )
    }

    func testTimedPauseExpires() {
        var settings = Settings()
        settings.isPaused = true
        settings.pausedUntil = date(2026, 3, 10, 10, 0)
        XCTAssertTrue(Scheduler.isPaused(settings: settings, now: date(2026, 3, 10, 9, 59)))
        XCTAssertFalse(Scheduler.isPaused(settings: settings, now: date(2026, 3, 10, 10, 1)))
    }

    // MARK: - Next upcoming

    func testNextUpcomingPicksSoonest() {
        let created = date(2026, 3, 10, 9, 0)
        var hourly = Reminder(
            title: "Tilt", schedule: .interval(minutes: 60), createdAt: created
        )
        hourly.lastFiredAt = created
        var frequent = Reminder(
            title: "Shift", schedule: .interval(minutes: 20), createdAt: created
        )
        frequent.lastFiredAt = created

        let result = Scheduler.nextUpcoming(
            among: [hourly, frequent], now: date(2026, 3, 10, 9, 5), calendar: calendar
        )
        XCTAssertEqual(result?.reminder.title, "Shift")
        XCTAssertEqual(result?.date, date(2026, 3, 10, 9, 20))
    }

    func testNextUpcomingBreaksTiesByPriority() {
        let created = date(2026, 3, 10, 9, 0)
        var low = Reminder(
            title: "Low", schedule: .interval(minutes: 30),
            priority: .subtle, createdAt: created
        )
        low.lastFiredAt = created
        var high = Reminder(
            title: "High", schedule: .interval(minutes: 30),
            priority: .critical, createdAt: created
        )
        high.lastFiredAt = created

        let result = Scheduler.nextUpcoming(
            among: [low, high], now: date(2026, 3, 10, 9, 5), calendar: calendar
        )
        XCTAssertEqual(result?.reminder.title, "High")
    }

    func testNextUpcomingWithNoCandidatesIsNil() {
        XCTAssertNil(Scheduler.nextUpcoming(among: [], now: Date(), calendar: calendar))
    }

    // MARK: - Countdown formatting

    func testCountdownText() {
        let now = date(2026, 3, 10, 9, 0)
        XCTAssertEqual(Scheduler.countdownText(from: now, to: now), "now")
        XCTAssertEqual(
            Scheduler.countdownText(from: now, to: now.addingTimeInterval(-60)), "now"
        )
        XCTAssertEqual(
            Scheduler.countdownText(from: now, to: now.addingTimeInterval(30)), "<1 min"
        )
        XCTAssertEqual(
            Scheduler.countdownText(from: now, to: now.addingTimeInterval(20 * 60)), "20 min"
        )
        XCTAssertEqual(
            Scheduler.countdownText(from: now, to: now.addingTimeInterval(60 * 60)), "1h"
        )
        XCTAssertEqual(
            Scheduler.countdownText(from: now, to: now.addingTimeInterval(130 * 60)), "2h 10m"
        )
    }

    // MARK: - Priority ordering

    func testPriorityOrdering() {
        XCTAssertTrue(Priority.subtle < Priority.normal)
        XCTAssertTrue(Priority.normal < Priority.important)
        XCTAssertTrue(Priority.important < Priority.critical)
        XCTAssertEqual(
            Priority.allCases.sorted(),
            [.subtle, .normal, .important, .critical]
        )
    }

    // MARK: - Schedule summaries

    func testScheduleSummaries() {
        XCTAssertEqual(Schedule.interval(minutes: 20).summary, "Every 20 min")
        XCTAssertEqual(Schedule.interval(minutes: 60).summary, "Every hour")
        XCTAssertEqual(Schedule.interval(minutes: 120).summary, "Every 2 hours")
        XCTAssertEqual(Schedule.interval(minutes: 90).summary, "Every 1h 30m")
        XCTAssertEqual(
            Schedule.dailyAt(hour: 17, minute: 0, dayInterval: 1).summary, "Daily at 17:00"
        )
        XCTAssertEqual(
            Schedule.dailyAt(hour: 9, minute: 5, dayInterval: 2).summary,
            "Every 2 days at 09:05"
        )
        XCTAssertEqual(
            Schedule.weeklyAt(hour: 10, minute: 30, weekdays: [2, 4]).summary,
            "Mon, Wed at 10:30"
        )
    }
}
