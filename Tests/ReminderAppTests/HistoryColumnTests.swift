import AppKit
import XCTest
@testable import ReminderApp
import ReminderCore

/// The History tab's "when" column is 96pt wide and was sized for SwiftUI's
/// live relative text ("2 min"). The static labels that replaced it say a
/// little more ("2 min. ago"), so every label the column can show is
/// measured here at the row's font, rather than trusted to fit.
final class HistoryColumnTests: XCTestCase {
    func testEveryLabelFitsTheColumn() {
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let en = Locale(identifier: "en_US")
        let font = NSFont.systemFont(ofSize: 11)
        // Every unit the formatter can pick inside the 30-day window, at the
        // widest count it can show for that unit.
        let agos: [TimeInterval] = [
            0, 59, 60, 59 * 60, 3600, 23 * 3600, 86_400, 6 * 86_400, 7 * 86_400,
            13 * 86_400, 27 * 86_400, 30 * 86_400,
        ]
        for ago in agos {
            let label = HistoryTime.label(for: now.addingTimeInterval(-ago), now: now, locale: en)
            let width = NSAttributedString(string: label, attributes: [.font: font]).size().width
            XCTAssertLessThanOrEqual(width, 96, "\"\(label)\" is \(width)pt wide")
        }
    }
}
