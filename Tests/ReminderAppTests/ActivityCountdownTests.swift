import XCTest
@testable import ReminderApp

/// The takeover's activity clock, which drives the automatic finish: it must
/// report zero exactly once, and never after being stopped.
@MainActor
final class ActivityCountdownTests: XCTestCase {
    func testReportsTheFinishOnceWhenTheClockReachesZero() {
        let countdown = ActivityCountdown(seconds: 1, playsChime: false)
        let finished = expectation(description: "finished")
        var finishes = 0
        countdown.onFinish = {
            finishes += 1
            finished.fulfill()
        }
        XCTAssertFalse(countdown.hasStarted)
        countdown.start()
        XCTAssertTrue(countdown.hasStarted)
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(countdown.remaining, 0)
        // A further second of ticking must not report it again.
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(finishes, 1)
    }

    func testAStoppedClockNeverFinishes() {
        let countdown = ActivityCountdown(seconds: 1, playsChime: false)
        var finishes = 0
        countdown.onFinish = { finishes += 1 }
        countdown.start()
        countdown.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(finishes, 0)
    }

    func testAClockWithoutADurationNeverStartsOrFinishes() {
        let countdown = ActivityCountdown(seconds: 0, playsChime: false)
        var finishes = 0
        countdown.onFinish = { finishes += 1 }
        countdown.start()
        XCTAssertFalse(countdown.hasStarted)
        XCTAssertFalse(countdown.isAvailable)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(finishes, 0)
    }
}
