import XCTest
import ReminderCore
@testable import Pauselet

/// Tests for the pure planning layer that decides which notification requests
/// should be pending — the budget, the tier mapping, and the identifiers that
/// reconciliation later depends on.
final class NotificationPlanTests: XCTestCase {

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

    private func reminder(
        title: String = "Test",
        schedule: Schedule = .interval(minutes: 60),
        priority: Priority = .normal,
        soundName: String? = nil,
        enabled: Bool = true,
        createdAt: Date
    ) -> Reminder {
        Reminder(
            title: title, schedule: schedule, priority: priority,
            isEnabled: enabled, soundName: soundName, createdAt: createdAt
        )
    }

    func testStaysWithinBudget() {
        let now = date(2026, 3, 10, 9, 0)
        // 20 five-minute reminders project far more fires than the budget.
        let reminders = (0..<20).map { i in
            reminder(title: "R\(i)", schedule: .interval(minutes: 5), createdAt: now)
        }
        let plan = NotificationPlan.build(
            reminders: reminders, settings: Settings(), now: now,
            alarmsCarrying: [], calendar: calendar
        )
        XCTAssertLessThanOrEqual(plan.items.count, NotificationPlan.budget)
        XCTAssertEqual(plan.items.count, NotificationPlan.budget)
    }

    func testEveryReminderKeepsItsNextFireUnderPressure() {
        let now = date(2026, 3, 10, 9, 0)
        var reminders = (0..<30).map { i in
            reminder(title: "Fast\(i)", schedule: .interval(minutes: 5), createdAt: now)
        }
        let daily = reminder(
            title: "Daily",
            schedule: .dailyAt(hour: 20, minute: 0, dayInterval: 1),
            createdAt: now
        )
        reminders.append(daily)

        let plan = NotificationPlan.build(
            reminders: reminders, settings: Settings(), now: now,
            alarmsCarrying: [], calendar: calendar
        )
        XCTAssertTrue(
            plan.items.contains { $0.reminderID == daily.id },
            "A slow reminder must never be starved out of the budget"
        )
        // Every one of the 31 reminders has at least its next fire scheduled.
        XCTAssertEqual(Set(plan.items.map(\.reminderID)).count, 31)
    }

    func testCriticalExcludedWhenAlarmsCarryIt() {
        let now = date(2026, 3, 10, 9, 0)
        let critical = reminder(priority: .critical, createdAt: now)
        let normal = reminder(createdAt: now)
        let plan = NotificationPlan.build(
            reminders: [critical, normal], settings: Settings(), now: now,
            alarmsCarrying: [critical.id], calendar: calendar
        )
        XCTAssertFalse(plan.items.contains { $0.reminderID == critical.id })
        XCTAssertTrue(plan.items.contains { $0.reminderID == normal.id })
    }

    /// Alarms unavailable (authorization denied): every critical reminder is
    /// demoted to a time-sensitive notification.
    func testCriticalIncludedAsTimeSensitiveWhenAlarmsUnavailable() {
        let now = date(2026, 3, 10, 9, 0)
        let critical = reminder(priority: .critical, createdAt: now)
        let plan = NotificationPlan.build(
            reminders: [critical], settings: Settings(), now: now,
            alarmsCarrying: [], calendar: calendar
        )
        let item = plan.items.first { $0.reminderID == critical.id }
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.interruption, .timeSensitive)
    }

    /// One alarm failed to schedule while another succeeded: only the one
    /// alarms are not carrying falls back to a notification. Nothing is ever
    /// left with neither.
    func testOnlyCriticalRemindersAlarmsAreNotCarryingFallBack() {
        let now = date(2026, 3, 10, 9, 0)
        let carried = reminder(title: "Carried", priority: .critical, createdAt: now)
        let stranded = reminder(title: "Stranded", priority: .critical, createdAt: now)
        let plan = NotificationPlan.build(
            reminders: [carried, stranded], settings: Settings(), now: now,
            alarmsCarrying: [carried.id], calendar: calendar
        )
        XCTAssertFalse(plan.items.contains { $0.reminderID == carried.id })
        XCTAssertTrue(plan.items.contains { $0.reminderID == stranded.id })
    }

    func testInterruptionLevelsPerTier() {
        XCTAssertEqual(NotificationPlan.interruption(for: .subtle), .passive)
        XCTAssertEqual(NotificationPlan.interruption(for: .normal), .active)
        XCTAssertEqual(NotificationPlan.interruption(for: .important), .timeSensitive)
        XCTAssertEqual(NotificationPlan.interruption(for: .critical), .timeSensitive)
    }

    func testSoundOnlyForImportantAndAbove() {
        let now = date(2026, 3, 10, 9, 0)
        let subtle = reminder(priority: .subtle, createdAt: now)
        let normal = reminder(priority: .normal, createdAt: now)
        let important = reminder(priority: .important, createdAt: now)
        let plan = NotificationPlan.build(
            reminders: [subtle, normal, important], settings: Settings(), now: now,
            alarmsCarrying: [], calendar: calendar
        )
        XCTAssertEqual(sound(of: subtle, in: plan), false)
        XCTAssertEqual(sound(of: normal, in: plan), false)
        XCTAssertEqual(sound(of: important, in: plan), true)
    }

    func testGlobalSoundToggleSilencesEverything() {
        let now = date(2026, 3, 10, 9, 0)
        var settings = Settings()
        settings.soundEnabled = false
        let important = reminder(priority: .important, createdAt: now)
        let plan = NotificationPlan.build(
            reminders: [important], settings: settings, now: now,
            alarmsCarrying: [], calendar: calendar
        )
        XCTAssertEqual(sound(of: important, in: plan), false)
    }

    private func sound(of reminder: Reminder, in plan: NotificationPlan) -> Bool? {
        plan.items.first { $0.reminderID == reminder.id }?.playsSound
    }

    func testBundledSoundResolvedAndUnknownFallsBack() {
        let now = date(2026, 3, 10, 9, 0)
        let known = reminder(priority: .important, soundName: "Glass", createdAt: now)
        // "Funk" exists on macOS but is not bundled on iOS.
        let macOnly = reminder(priority: .important, soundName: "Funk", createdAt: now)
        let plan = NotificationPlan.build(
            reminders: [known, macOnly], settings: Settings(), now: now,
            alarmsCarrying: [], calendar: calendar
        )
        XCTAssertEqual(
            plan.items.first { $0.reminderID == known.id }?.soundName, "Glass"
        )
        XCTAssertNil(
            plan.items.first { $0.reminderID == macOnly.id }?.soundName ?? nil,
            "A macOS-only sound name must fall back to the default, not break"
        )
    }

    func testDisabledRemindersAreExcluded() {
        let now = date(2026, 3, 10, 9, 0)
        let off = reminder(enabled: false, createdAt: now)
        let plan = NotificationPlan.build(
            reminders: [off], settings: Settings(), now: now,
            alarmsCarrying: [], calendar: calendar
        )
        XCTAssertTrue(plan.items.isEmpty)
    }

    func testIdentifierEncodesReminderAndStampForReconciliation() {
        let now = date(2026, 3, 10, 9, 0)
        let r = reminder(createdAt: now)
        let plan = NotificationPlan.build(
            reminders: [r], settings: Settings(), now: now,
            alarmsCarrying: [], calendar: calendar
        )
        let item = plan.items.first!
        XCTAssertTrue(item.identifier.hasPrefix(NotificationPlan.identifierPrefix))
        XCTAssertTrue(item.identifier.contains(r.id.uuidString))
        XCTAssertTrue(
            item.identifier.contains("-\(Int(item.stampDate.timeIntervalSince1970))-")
        )
    }

    /// A refill decides whether a pending request is still right by its
    /// identifier alone, so anything baked into the request must change it.
    func testIdentifierChangesWhenContentChanges() {
        let now = date(2026, 3, 10, 9, 0)
        let original = reminder(title: "Water", createdAt: now)
        var renamed = original
        renamed.title = "Drink water"
        var chime = original
        chime.priority = .important
        chime.soundName = "Chime"

        func identifier(_ r: Reminder) -> String {
            NotificationPlan.build(
                reminders: [r], settings: Settings(), now: now,
                alarmsCarrying: [], calendar: calendar
            ).items.first!.identifier
        }
        let base = identifier(original)
        XCTAssertEqual(base, identifier(original), "Deterministic across builds")
        XCTAssertNotEqual(base, identifier(renamed))
        XCTAssertNotEqual(base, identifier(chime))
    }

    /// Wall-clock slots float with the device's time zone; interval, snooze,
    /// and catch-up fires are absolute moments.
    func testWallClockSlotsAreMarkedAndAbsoluteMomentsAreNot() {
        let now = date(2026, 3, 10, 9, 0)
        let hourly = reminder(schedule: .interval(minutes: 60), createdAt: now)
        let daily = reminder(
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 1), createdAt: now
        )
        var overdueDaily = reminder(
            title: "Overdue",
            schedule: .dailyAt(hour: 8, minute: 0, dayInterval: 1),
            createdAt: date(2026, 3, 9, 9, 0)
        )
        overdueDaily.lastFiredAt = date(2026, 3, 9, 8, 30)
        let plan = NotificationPlan.build(
            reminders: [hourly, daily, overdueDaily], settings: Settings(), now: now,
            alarmsCarrying: [], calendar: calendar
        )
        XCTAssertEqual(plan.items.first { $0.reminderID == hourly.id }?.isWallClockSlot, false)
        XCTAssertEqual(plan.items.first { $0.reminderID == daily.id }?.isWallClockSlot, true)
        let catchUp = plan.items.first { $0.reminderID == overdueDaily.id }
        XCTAssertEqual(catchUp?.fireDate, now)
        XCTAssertEqual(catchUp?.isWallClockSlot, false, "A catch-up is delivered now, wherever now is")
    }

    func testQuietHoursShapeTheScheduledFires() {
        let now = date(2026, 3, 10, 21, 30)
        var settings = Settings()
        settings.quietHours = QuietHours(
            isEnabled: true, startHour: 22, startMinute: 0,
            endHour: 7, endMinute: 0, allowsCritical: true
        )
        let hourly = reminder(schedule: .interval(minutes: 60), createdAt: now)
        let plan = NotificationPlan.build(
            reminders: [hourly], settings: settings, now: now,
            alarmsCarrying: [], calendar: calendar
        )
        // First fire would land at 22:30, inside the window: it must be
        // scheduled for 07:00, not suppressed at delivery time.
        XCTAssertEqual(plan.items.first?.fireDate, date(2026, 3, 11, 7, 0))
    }
}
