import XCTest
@testable import ReminderApp

/// The locked takeover's emergency exit: a held Escape, measured by the
/// clock, that fires once and only when held for the whole time.
@MainActor
final class EscapeHoldTests: XCTestCase {
    func testAFullHoldFiresOnce() {
        let hold = EscapeHold(holdSeconds: 0.3)
        var fired = 0
        hold.onComplete = { fired += 1 }
        hold.began()
        hold.began()  // key repeat: must not restart the clock
        XCTAssertTrue(hold.isHolding)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(fired, 1)
        XCTAssertFalse(hold.isHolding, "the exit resets the hold")
        XCTAssertEqual(hold.progress, 0)
    }

    func testLettingGoEarlyFiresNothingAndResets() {
        let hold = EscapeHold(holdSeconds: 0.3)
        var fired = 0
        hold.onComplete = { fired += 1 }
        hold.began()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertGreaterThan(hold.progress, 0)
        hold.ended()
        XCTAssertEqual(hold.progress, 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(fired, 0)
    }

    func testProgressFillsWithTheClock() {
        let hold = EscapeHold(holdSeconds: 1)
        hold.began()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertGreaterThan(hold.progress, 0.3)
        XCTAssertLessThan(hold.progress, 0.8)
        hold.ended()
    }
}
