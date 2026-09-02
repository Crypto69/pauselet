import XCTest
@testable import ReminderCore

/// Tests for `recordExternalFire`, the reconciliation entry point used on iOS
/// where the system delivers pre-scheduled notifications and alarms while the
/// app is not running. It must produce the state a live `tick()` would have,
/// and it must be safe to call repeatedly with the same facts.
@MainActor
final class ExternalFireTests: XCTestCase {

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

    private func makeEngine(
        reminders: [Reminder],
        now: Date
    ) -> (ReminderEngine, MutableDateProvider) {
        let store = InMemoryDataStore(
            data: AppData(reminders: reminders, settings: Settings(), events: [])
        )
        let clock = MutableDateProvider(now: now)
        let engine = ReminderEngine(
            store: store, dateProvider: clock, presenter: nil, calendar: calendar
        )
        return (engine, clock)
    }

    func testStampsAnchorAndRecordsFiredEvent() {
        let created = date(2026, 3, 10, 9, 0)
        let reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 60), createdAt: created
        )
        let (engine, _) = makeEngine(reminders: [reminder], now: date(2026, 3, 10, 11, 0))

        let stamp = date(2026, 3, 10, 10, 0)
        engine.recordExternalFire(id: reminder.id, at: stamp)

        XCTAssertEqual(engine.reminder(withID: reminder.id)?.lastFiredAt, stamp)
        XCTAssertEqual(engine.events.filter { $0.outcome == .fired }.count, 1)
        XCTAssertEqual(engine.events.first?.date, stamp)
    }

    func testRepeatedReconciliationDoesNotDuplicate() {
        let created = date(2026, 3, 10, 9, 0)
        let reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 60), createdAt: created
        )
        let (engine, _) = makeEngine(reminders: [reminder], now: date(2026, 3, 10, 11, 0))

        let stamp = date(2026, 3, 10, 10, 0)
        engine.recordExternalFire(id: reminder.id, at: stamp)
        engine.recordExternalFire(id: reminder.id, at: stamp)
        engine.recordExternalFire(id: reminder.id, at: stamp)

        XCTAssertEqual(engine.events.filter { $0.outcome == .fired }.count, 1)
    }

    func testOlderStampThanExistingAnchorIsIgnored() {
        let created = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 60), createdAt: created
        )
        reminder.lastFiredAt = date(2026, 3, 10, 11, 0)
        let (engine, _) = makeEngine(reminders: [reminder], now: date(2026, 3, 10, 11, 30))

        engine.recordExternalFire(id: reminder.id, at: date(2026, 3, 10, 10, 0))

        XCTAssertEqual(
            engine.reminder(withID: reminder.id)?.lastFiredAt, date(2026, 3, 10, 11, 0),
            "An anchor must never move backwards"
        )
        XCTAssertTrue(engine.events.isEmpty)
    }

    func testElapsedSnoozeIsConsumedByTheFireThatHonouredIt() {
        let created = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Tilt", schedule: .interval(minutes: 60), createdAt: created
        )
        reminder.snoozedUntil = date(2026, 3, 10, 9, 40)
        let (engine, _) = makeEngine(reminders: [reminder], now: date(2026, 3, 10, 10, 0))

        engine.recordExternalFire(id: reminder.id, at: date(2026, 3, 10, 9, 40))

        XCTAssertNil(engine.reminder(withID: reminder.id)?.snoozedUntil)
        XCTAssertEqual(
            engine.reminder(withID: reminder.id)?.lastFiredAt, date(2026, 3, 10, 9, 40)
        )
    }

    func testFutureSnoozeSurvivesAnEarlierExternalFire() {
        let created = date(2026, 3, 10, 9, 0)
        var reminder = Reminder(
            title: "Tilt", schedule: .interval(minutes: 60), createdAt: created
        )
        // The user snoozed *after* the notification was delivered; the snooze
        // is a promise about the future and must not be consumed by the past
        // fire being reconciled.
        reminder.snoozedUntil = date(2026, 3, 10, 12, 0)
        let (engine, _) = makeEngine(reminders: [reminder], now: date(2026, 3, 10, 10, 30))

        engine.recordExternalFire(id: reminder.id, at: date(2026, 3, 10, 10, 0))

        XCTAssertEqual(
            engine.reminder(withID: reminder.id)?.snoozedUntil, date(2026, 3, 10, 12, 0)
        )
    }

    func testUnknownReminderIsANoOp() {
        let (engine, _) = makeEngine(reminders: [], now: date(2026, 3, 10, 10, 0))
        engine.recordExternalFire(id: UUID(), at: date(2026, 3, 10, 9, 0))
        XCTAssertTrue(engine.events.isEmpty)
    }

    func testReconciledFireCountsTowardAdherence() {
        let created = date(2026, 3, 10, 9, 0)
        let reminder = Reminder(
            title: "Water", schedule: .interval(minutes: 60), createdAt: created
        )
        let (engine, _) = makeEngine(reminders: [reminder], now: date(2026, 3, 10, 11, 0))

        engine.recordExternalFire(id: reminder.id, at: date(2026, 3, 10, 10, 0))
        engine.complete(id: reminder.id)

        XCTAssertEqual(
            engine.adherence(for: reminder.id, since: created), 1.0
        )
    }
}
