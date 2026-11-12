import XCTest
@testable import ReminderCore

/// How firmly a Critical takeover holds the screen while its countdown runs.
final class DismissalTests: XCTestCase {
    private func critical(countdown: Int? = 300, dismissal: TakeoverDismissal? = nil) -> Reminder {
        Reminder(
            title: "Tilt back",
            schedule: .interval(minutes: 60),
            priority: .critical,
            activityDurationSeconds: countdown,
            dismissal: dismissal,
            createdAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
    }

    func testAnyTimeByDefault() {
        XCTAssertEqual(Scheduler.dismissal(for: critical()), .anytime)
    }

    func testTheChosenLevelAppliesWithACountdown() {
        XCTAssertEqual(Scheduler.dismissal(for: critical(dismissal: .snoozeOnly)), .snoozeOnly)
        XCTAssertEqual(Scheduler.dismissal(for: critical(dismissal: .locked)), .locked)
    }

    /// Without a countdown there is no moment to unlock at: a hand-edited
    /// file must not produce a screen that can never be dismissed.
    func testNoLevelWithoutACountdown() {
        XCTAssertEqual(Scheduler.dismissal(for: critical(countdown: nil, dismissal: .locked)), .anytime)
        XCTAssertEqual(Scheduler.dismissal(for: critical(countdown: 0, dismissal: .locked)), .anytime)
    }

    func testAnyTimeAllowsBothThroughout() {
        XCTAssertTrue(Scheduler.canFinish(.anytime, remaining: 299))
        XCTAssertTrue(Scheduler.canSnooze(.anytime, remaining: 299))
    }

    func testSnoozeOnlyHoldsDoneUntilTheTimerEnds() {
        XCTAssertFalse(Scheduler.canFinish(.snoozeOnly, remaining: 1))
        XCTAssertTrue(Scheduler.canSnooze(.snoozeOnly, remaining: 1))
        XCTAssertTrue(Scheduler.canFinish(.snoozeOnly, remaining: 0))
    }

    func testLockedHoldsBothUntilTheTimerEnds() {
        XCTAssertFalse(Scheduler.canFinish(.locked, remaining: 1))
        XCTAssertFalse(Scheduler.canSnooze(.locked, remaining: 1))
        XCTAssertTrue(Scheduler.canFinish(.locked, remaining: 0))
        XCTAssertTrue(Scheduler.canSnooze(.locked, remaining: 0))
    }

    func testTheEmergencyExitTakesADeliberateHold() {
        XCTAssertGreaterThanOrEqual(Scheduler.emergencyExitHoldSeconds, 3)
        XCTAssertLessThanOrEqual(Scheduler.emergencyExitHoldSeconds, 10)
    }

    func testPersistsAndTheDefaultIsNotWritten() throws {
        let open = try JSONEncoder().encode(critical())
        XCTAssertFalse(String(decoding: open, as: UTF8.self).contains("dismissal"),
                       "the default encodes exactly as before the option existed")
        XCTAssertNil(try JSONDecoder().decode(Reminder.self, from: open).dismissal)

        let locked = try JSONEncoder().encode(critical(dismissal: .locked))
        XCTAssertTrue(String(decoding: locked, as: UTF8.self).contains("\"dismissal\":\"locked\""))
        XCTAssertEqual(try JSONDecoder().decode(Reminder.self, from: locked).dismissal, .locked)
    }

    /// A level this build does not know — written by a newer one — reads as
    /// unset. The alternative is a decode failure, which costs the user
    /// every reminder in the file.
    func testAnUnknownLevelReadsAsUnset() throws {
        let data = try JSONEncoder().encode(critical(dismissal: .locked))
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["dismissal"] = "handcuffed"
        let newer = try JSONSerialization.data(withJSONObject: object)
        let reminder = try JSONDecoder().decode(Reminder.self, from: newer)
        XCTAssertNil(reminder.dismissal)
        XCTAssertEqual(reminder.title, "Tilt back")
    }

    func testEveryLevelHasATitle() {
        for level in TakeoverDismissal.allCases {
            XCTAssertFalse(level.title.isEmpty)
        }
    }
}
