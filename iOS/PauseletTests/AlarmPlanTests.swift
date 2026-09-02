import XCTest
import ReminderCore
@testable import Pauselet

/// Tests for the mapping from critical reminders onto AlarmKit's two schedule
/// shapes — the §3.3 rules: weekly and daily recur natively; intervals,
/// grids, snoozes, pauses, and respected quiet hours become one-shot
/// fixed-date alarms that get re-armed.
final class AlarmPlanTests: XCTestCase {

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

    private func critical(
        schedule: Schedule,
        snoozedUntil: Date? = nil,
        createdAt: Date
    ) -> Reminder {
        Reminder(
            title: "Tilt Back", schedule: schedule, priority: .critical,
            snoozedUntil: snoozedUntil, createdAt: createdAt
        )
    }

    func testOnlyCriticalRemindersGetAlarms() {
        let now = date(2026, 3, 10, 9, 0)
        let normal = Reminder(
            title: "Water", schedule: .interval(minutes: 60), priority: .normal,
            createdAt: now
        )
        let specs = AlarmPlan.specs(
            for: [normal], settings: Settings(), now: now, calendar: calendar
        )
        XCTAssertTrue(specs.isEmpty)
    }

    func testWeeklyMapsToRelativeRecurrence() {
        let now = date(2026, 3, 10, 9, 0)
        let reminder = critical(
            schedule: .weeklyAt(hour: 7, minute: 30, weekdays: [2, 4, 6]),
            createdAt: now
        )
        let specs = AlarmPlan.specs(
            for: [reminder], settings: Settings(), now: now, calendar: calendar
        )
        XCTAssertEqual(
            specs.first?.kind,
            .relativeWeekly(hour: 7, minute: 30, weekdays: [2, 4, 6])
        )
    }

    func testDailyMapsToRelativeAllWeek() {
        let now = date(2026, 3, 10, 9, 0)
        let reminder = critical(
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1),
            createdAt: now
        )
        let specs = AlarmPlan.specs(
            for: [reminder], settings: Settings(), now: now, calendar: calendar
        )
        XCTAssertEqual(
            specs.first?.kind,
            .relativeWeekly(hour: 17, minute: 0, weekdays: Set(1...7))
        )
    }

    func testIntervalMapsToFixedDateAtNextProjectedFire() {
        let now = date(2026, 3, 10, 9, 0)
        var reminder = critical(schedule: .interval(minutes: 60), createdAt: now)
        reminder.lastFiredAt = date(2026, 3, 10, 8, 30)
        let specs = AlarmPlan.specs(
            for: [reminder], settings: Settings(), now: now, calendar: calendar
        )
        XCTAssertEqual(
            specs.first?.kind,
            .fixed(fireDate: date(2026, 3, 10, 9, 30), stampDate: date(2026, 3, 10, 9, 30))
        )
    }

    func testEveryTwoDaysGridMapsToFixedDate() {
        let now = date(2026, 3, 10, 9, 0)
        let reminder = critical(
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 2), createdAt: now
        )
        let specs = AlarmPlan.specs(
            for: [reminder], settings: Settings(), now: now, calendar: calendar
        )
        XCTAssertEqual(
            specs.first?.kind,
            .fixed(fireDate: date(2026, 3, 10, 17, 0), stampDate: date(2026, 3, 10, 17, 0))
        )
    }

    func testSnoozeForcesAFixedDateAlarmAtTheSnooze() {
        let now = date(2026, 3, 10, 9, 0)
        let snoozed = date(2026, 3, 10, 9, 5)
        let reminder = critical(
            schedule: .weeklyAt(hour: 7, minute: 30, weekdays: [2]),
            snoozedUntil: snoozed,
            createdAt: now
        )
        let specs = AlarmPlan.specs(
            for: [reminder], settings: Settings(), now: now, calendar: calendar
        )
        // The snooze is authoritative: the relative recurrence would ignore
        // it, so the alarm must be the one-shot snooze fire.
        XCTAssertEqual(
            specs.first?.kind, .fixed(fireDate: snoozed, stampDate: snoozed)
        )
    }

    func testQuietHoursThatCriticalRespectsForceFixedDates() {
        let now = date(2026, 3, 10, 9, 0)
        var settings = Settings()
        settings.quietHours = QuietHours(
            isEnabled: true, startHour: 22, startMinute: 0,
            endHour: 7, endMinute: 0, allowsCritical: false
        )
        // Daily at 23:00 — every slot is inside quiet hours, and critical is
        // not allowed to pierce: nothing may be scheduled at all.
        let suppressed = critical(
            schedule: .dailyAt(hour: 23, minute: 0, dayInterval: 1), createdAt: now
        )
        // Daily at 17:00 — outside the window, but the recurrence still may
        // not be handed to the system while quiet hours could suppress a
        // future slot; it becomes a fixed date.
        let daily = critical(
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1), createdAt: now
        )
        let specs = AlarmPlan.specs(
            for: [suppressed, daily], settings: settings, now: now, calendar: calendar
        )
        XCTAssertFalse(specs.contains { $0.reminderID == suppressed.id })
        XCTAssertEqual(
            specs.first { $0.reminderID == daily.id }?.kind,
            .fixed(fireDate: date(2026, 3, 10, 17, 0), stampDate: date(2026, 3, 10, 17, 0))
        )
    }

    func testQuietHoursThatAllowCriticalKeepRelativeRecurrence() {
        let now = date(2026, 3, 10, 9, 0)
        var settings = Settings()
        settings.quietHours = QuietHours(
            isEnabled: true, startHour: 22, startMinute: 0,
            endHour: 7, endMinute: 0, allowsCritical: true
        )
        let reminder = critical(
            schedule: .dailyAt(hour: 23, minute: 0, dayInterval: 1), createdAt: now
        )
        let specs = AlarmPlan.specs(
            for: [reminder], settings: settings, now: now, calendar: calendar
        )
        XCTAssertEqual(
            specs.first?.kind,
            .relativeWeekly(hour: 23, minute: 0, weekdays: Set(1...7))
        )
    }

    func testIndefinitePauseSchedulesNoAlarms() {
        let now = date(2026, 3, 10, 9, 0)
        var settings = Settings()
        settings.isPaused = true
        let reminder = critical(schedule: .interval(minutes: 60), createdAt: now)
        XCTAssertTrue(
            AlarmPlan.specs(
                for: [reminder], settings: settings, now: now, calendar: calendar
            ).isEmpty
        )
    }

    func testTimedPauseForcesFixedDateAfterItEnds() {
        let now = date(2026, 3, 10, 9, 0)
        var settings = Settings()
        settings.isPaused = true
        settings.pausedUntil = date(2026, 3, 10, 12, 0)
        let reminder = critical(
            schedule: .dailyAt(hour: 10, minute: 0, dayInterval: 1), createdAt: now
        )
        let specs = AlarmPlan.specs(
            for: [reminder], settings: settings, now: now, calendar: calendar
        )
        guard case .fixed(let fireDate, _)? = specs.first?.kind else {
            return XCTFail("Expected a fixed-date alarm during a timed pause")
        }
        XCTAssertGreaterThanOrEqual(
            fireDate, date(2026, 3, 10, 12, 0),
            "Nothing may fire before the pause ends"
        )
    }

    func testDisabledReminderGetsNoAlarm() {
        let now = date(2026, 3, 10, 9, 0)
        var reminder = critical(schedule: .interval(minutes: 60), createdAt: now)
        reminder.isEnabled = false
        XCTAssertTrue(
            AlarmPlan.specs(
                for: [reminder], settings: Settings(), now: now, calendar: calendar
            ).isEmpty
        )
    }

    /// Completing a daily reminder early stamps `lastFiredAt` with the
    /// upcoming slot. A relative alarm would still ring at that slot, so the
    /// reminder drops to a fixed alarm at its next real fire.
    func testEarlyCompletionForcesAFixedDateAlarmPastTheConsumedSlot() {
        let now = date(2026, 3, 10, 9, 0)
        var reminder = critical(
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1), createdAt: now
        )
        reminder.lastFiredAt = date(2026, 3, 10, 17, 0) // consumed by an early "done"
        let specs = AlarmPlan.specs(
            for: [reminder], settings: Settings(), now: now, calendar: calendar
        )
        XCTAssertEqual(
            specs.first?.kind,
            .fixed(fireDate: date(2026, 3, 11, 17, 0), stampDate: date(2026, 3, 11, 17, 0))
        )
    }

    /// The spec carries everything the alarm bakes in, so editing the title,
    /// message, icon, or sound changes it — and the next sync replaces the
    /// alarm instead of skipping it as unchanged.
    func testSpecReflectsContentEdits() {
        let now = date(2026, 3, 10, 9, 0)
        let original = critical(schedule: .interval(minutes: 60), createdAt: now)
        func spec(_ r: Reminder) -> AlarmPlan.Spec? {
            AlarmPlan.specs(for: [r], settings: Settings(), now: now, calendar: calendar).first
        }
        var renamed = original
        renamed.title = "Tilt back now"
        var resounded = original
        resounded.soundName = "Chime"
        var macOnlySound = original
        macOnlySound.soundName = "Funk"

        XCTAssertNotEqual(spec(original), spec(renamed))
        XCTAssertNotEqual(spec(original), spec(resounded))
        XCTAssertEqual(spec(resounded)?.soundName, "Chime")
        XCTAssertEqual(
            spec(macOnlySound)?.soundName, Sounds.criticalDefault,
            "A sound iOS does not bundle falls back to the critical default"
        )
        XCTAssertEqual(spec(original)?.soundName, Sounds.criticalDefault)
    }

    // MARK: - Occurrences of a relative rule

    func testLatestOccurrenceFindsTheMostRecentSelectedSlot() {
        // 2026-03-10 is a Tuesday.
        let occurrence = AlarmPlan.latestOccurrence(
            hour: 9, minute: 0, weekdays: [2, 4], // Mon, Wed
            atOrBefore: date(2026, 3, 10, 12, 0), calendar: calendar
        )
        XCTAssertEqual(occurrence, date(2026, 3, 9, 9, 0), "Monday's slot")

        let sameDay = AlarmPlan.latestOccurrence(
            hour: 9, minute: 0, weekdays: Set(1...7),
            atOrBefore: date(2026, 3, 10, 9, 0), calendar: calendar
        )
        XCTAssertEqual(sameDay, date(2026, 3, 10, 9, 0), "At the slot counts")

        let beforeSlot = AlarmPlan.latestOccurrence(
            hour: 9, minute: 0, weekdays: Set(1...7),
            atOrBefore: date(2026, 3, 10, 8, 59), calendar: calendar
        )
        XCTAssertEqual(beforeSlot, date(2026, 3, 9, 9, 0))

        XCTAssertNil(AlarmPlan.latestOccurrence(
            hour: 9, minute: 0, weekdays: [], atOrBefore: date(2026, 3, 10, 12, 0),
            calendar: calendar
        ))
    }

    /// A daily alarm left running for days: each acknowledgment is attributed
    /// to the occurrence that actually rang, not to the one cached when the
    /// alarm was scheduled.
    func testRelativeRegistryEntryReportsTheOccurrenceBeingAcknowledged() {
        let scheduledAt = date(2026, 3, 8, 12, 0)
        let entry = CriticalAlarmController.RegistryEntry(
            spec: AlarmPlan.Spec(
                reminderID: UUID(), title: "Tilt", message: "", symbolName: "bell",
                soundName: Sounds.criticalDefault,
                kind: .relativeWeekly(hour: 9, minute: 0, weekdays: Set(1...7))
            ),
            scheduledAt: scheduledAt
        )
        let monday = CriticalAlarmController.expectedFire(
            for: entry, at: date(2026, 3, 9, 9, 0, 30), calendar: calendar
        )
        XCTAssertEqual(monday?.fireDate, date(2026, 3, 9, 9, 0))
        XCTAssertEqual(monday?.stampDate, date(2026, 3, 9, 9, 0))

        let tuesday = CriticalAlarmController.expectedFire(
            for: entry, at: date(2026, 3, 10, 9, 5), calendar: calendar
        )
        XCTAssertEqual(tuesday?.fireDate, date(2026, 3, 10, 9, 0), "Tuesday's ring is Tuesday's")

        XCTAssertNil(
            CriticalAlarmController.expectedFire(
                for: entry, at: date(2026, 3, 8, 15, 0), calendar: calendar
            ),
            "The 09:00 before the alarm was scheduled never rang"
        )
    }

    func testFixedRegistryEntryReportsItsFireOnlyOnceDue() {
        let fire = date(2026, 3, 10, 9, 30)
        let entry = CriticalAlarmController.RegistryEntry(
            spec: AlarmPlan.Spec(
                reminderID: UUID(), title: "Tilt", message: "", symbolName: "bell",
                soundName: Sounds.criticalDefault,
                kind: .fixed(fireDate: fire, stampDate: fire)
            ),
            scheduledAt: date(2026, 3, 10, 8, 30)
        )
        XCTAssertNil(CriticalAlarmController.expectedFire(
            for: entry, at: date(2026, 3, 10, 9, 29), calendar: calendar
        ))
        XCTAssertEqual(
            CriticalAlarmController.expectedFire(
                for: entry, at: date(2026, 3, 10, 9, 31), calendar: calendar
            )?.stampDate,
            fire
        )
    }

    func testRegistryEntrySurvivesARoundTrip() throws {
        let entry = CriticalAlarmController.RegistryEntry(
            spec: AlarmPlan.Spec(
                reminderID: UUID(), title: "Tilt", message: "Lean back", symbolName: "bell",
                soundName: "Chime",
                kind: .relativeWeekly(hour: 7, minute: 30, weekdays: [2, 4, 6])
            ),
            scheduledAt: date(2026, 3, 8, 12, 0)
        )
        let data = try JSONEncoder().encode([entry.spec.reminderID: entry])
        let decoded = try JSONDecoder().decode(
            [UUID: CriticalAlarmController.RegistryEntry].self, from: data
        )
        XCTAssertEqual(decoded[entry.spec.reminderID], entry)
    }

    func testWeekdayNumberingConversion() {
        // Calendar numbering (1 = Sunday … 7 = Saturday) → Locale.Weekday.
        XCTAssertEqual(
            CriticalAlarmController.localeWeekdays(from: [1, 2, 7]),
            [.sunday, .monday, .saturday]
        )
        XCTAssertEqual(
            CriticalAlarmController.localeWeekdays(from: Set(1...7)).count, 7
        )
    }
}
