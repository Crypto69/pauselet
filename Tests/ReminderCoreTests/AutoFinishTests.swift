import XCTest
@testable import ReminderCore

/// A takeover that closes itself when its countdown ends.
final class AutoFinishTests: XCTestCase {
    private func critical(countdown: Int? = 300, autoFinish: Bool? = nil) -> Reminder {
        Reminder(
            title: "Tilt back",
            schedule: .interval(minutes: 60),
            priority: .critical,
            activityDurationSeconds: countdown,
            autoFinish: autoFinish,
            createdAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
    }

    func testWaitsForDoneByDefault() {
        XCTAssertFalse(Scheduler.finishesAutomatically(critical()))
    }

    func testFinishesItselfWhenAskedAndThereIsACountdown() {
        XCTAssertTrue(Scheduler.finishesAutomatically(critical(autoFinish: true)))
    }

    /// Without a countdown there is no zero to reach; a hand-edited file
    /// must not produce a takeover that closes at once.
    func testNeverWithoutACountdown() {
        XCTAssertFalse(Scheduler.finishesAutomatically(critical(countdown: nil, autoFinish: true)))
        XCTAssertFalse(Scheduler.finishesAutomatically(critical(countdown: 0, autoFinish: true)))
    }

    func testPersistsAndTheDefaultIsNotWritten() throws {
        let waiting = try JSONEncoder().encode(critical())
        XCTAssertFalse(String(decoding: waiting, as: UTF8.self).contains("autoFinish"),
                       "the default encodes exactly as before the option existed")
        XCTAssertNil(try JSONDecoder().decode(Reminder.self, from: waiting).autoFinish)

        let automatic = try JSONEncoder().encode(critical(autoFinish: true))
        XCTAssertEqual(try JSONDecoder().decode(Reminder.self, from: automatic).autoFinish, true)
    }

    func testTheFinishedStateIsShownBeforeTheScreenGoes() {
        XCTAssertGreaterThanOrEqual(Scheduler.autoFinishDelay, 1)
        XCTAssertLessThanOrEqual(Scheduler.autoFinishDelay, 3)
    }
}
