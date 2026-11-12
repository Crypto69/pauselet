import XCTest
@testable import ReminderCore

/// The History list's "when" labels, pinned against a fixed `now` — which
/// is the point of computing them rather than letting SwiftUI tick them.
final class HistoryTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)
    private let en = Locale(identifier: "en_US")

    private func label(secondsAgo: TimeInterval) -> String {
        HistoryTime.label(for: now.addingTimeInterval(-secondsAgo), now: now, locale: en)
    }

    /// The exact abbreviation is the OS's ("5 min. ago" on one release,
    /// "5m ago" on another), so the shape is pinned rather than the spelling:
    /// the count, the unit's first letter, "ago", and short enough for the
    /// column.
    func testLabelsAreRelativeAndAbbreviated() {
        let cases: [(TimeInterval, String, Character)] = [
            (30, "30", "s"), (5 * 60, "5", "m"), (23 * 3600, "23", "h"), (2 * 86_400, "2", "d"),
        ]
        for (ago, count, unit) in cases {
            let label = label(secondsAgo: ago)
            XCTAssertTrue(label.hasPrefix(count), label)
            XCTAssertTrue(label.hasSuffix("ago"), label)
            XCTAssertEqual(label.dropFirst(count.count).first { $0 != " " }, unit, label)
            XCTAssertLessThanOrEqual(label.count, 12, label)
        }
    }

    func testTheNamedStyleSaysYesterdayAndNow() {
        XCTAssertEqual(label(secondsAgo: 86_400), "yesterday")
        XCTAssertEqual(label(secondsAgo: 0), "now")
    }

    /// The same date gives the same label for the same `now`: nothing in
    /// the formatter reads the wall clock, so the view's minute refresh is
    /// the only thing that moves it.
    func testLabelIsAFunctionOfNowAlone() {
        let date = now.addingTimeInterval(-90)
        XCTAssertEqual(
            HistoryTime.label(for: date, now: now, locale: en),
            HistoryTime.label(for: date, now: now, locale: en)
        )
        XCTAssertNotEqual(
            HistoryTime.label(for: date, now: now, locale: en),
            HistoryTime.label(for: date, now: now.addingTimeInterval(3600), locale: en)
        )
    }

    func testExactMomentForTheTooltip() {
        let exact = HistoryTime.exact(now, locale: en)
        XCTAssertTrue(exact.contains("2026"), exact)
        XCTAssertTrue(exact.contains(":"), "carries the time of day: \(exact)")
    }
}
