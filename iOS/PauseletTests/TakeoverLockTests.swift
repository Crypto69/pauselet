import XCTest
import ReminderCore
@testable import Pauselet

/// The lock as the model judges it for the Lock Screen's answers: the same
/// rules as the takeover's buttons, against a clock that started when the
/// takeover went up.
@MainActor
final class TakeoverLockTests: XCTestCase {
    private func critical(dismissal: TakeoverDismissal?, countdown: Int? = 300) -> Reminder {
        Reminder(
            title: "Tilt back", schedule: .interval(minutes: 60), priority: .critical,
            activityDurationSeconds: countdown, dismissal: dismissal
        )
    }

    func testAnyTimePermitsBoth() {
        let item = AppModel.TakeoverItem(reminder: critical(dismissal: nil), isPreview: false)
        XCTAssertTrue(item.permits(.complete))
        XCTAssertTrue(item.permits(.snooze))
    }

    func testSnoozeOnlyHoldsDoneWhileTheClockRuns() {
        let item = AppModel.TakeoverItem(reminder: critical(dismissal: .snoozeOnly), isPreview: false)
        XCTAssertFalse(item.permits(.complete))
        XCTAssertTrue(item.permits(.snooze))
        XCTAssertGreaterThan(item.remainingSeconds, 290)
    }

    func testLockedHoldsBoth() {
        let item = AppModel.TakeoverItem(reminder: critical(dismissal: .locked), isPreview: false)
        XCTAssertFalse(item.permits(.complete))
        XCTAssertFalse(item.permits(.snooze))
    }

    func testAPreviewIsNeverHeld() {
        let item = AppModel.TakeoverItem(reminder: critical(dismissal: .locked), isPreview: true)
        XCTAssertTrue(item.permits(.complete))
    }

    func testNoCountdownMeansNoLock() {
        let item = AppModel.TakeoverItem(
            reminder: critical(dismissal: .locked, countdown: nil), isPreview: false
        )
        XCTAssertEqual(item.remainingSeconds, 0)
        XCTAssertTrue(item.permits(.complete))
    }
}
