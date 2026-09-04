import XCTest
import ReminderCore
@testable import Pauselet

/// Pins the contract the iOS import sheet is built on: the shared parser turns
/// a physiotherapist's paragraph into the rows the sheet previews, and every
/// row it produces is one the Add button will accept.
@MainActor
final class ImportSheetContractTests: XCTestCase {

    /// The paragraph a physiotherapist actually writes.
    private static let sample = """
        3 sets of 10 chin tucks, hold 5 seconds, rest 30 seconds between sets. \
        Then wall slides 3 x 15.
        """

    /// The sheet is a thin shell over `ExerciseImporter.parse`; this pins the
    /// contract the iOS UI relies on, on the iOS destination.
    func testTheSharedParserProducesTheRowsTheSheetPreviews() {
        let parsed = ExerciseImporter.parse(Self.sample)

        XCTAssertEqual(parsed.map(\.name), ["Chin tucks", "Wall slides"])
        XCTAssertEqual(parsed[0].sets, 3)
        XCTAssertEqual(parsed[0].reps, 10)
        XCTAssertEqual(parsed[0].holdSeconds, 5)
        XCTAssertEqual(parsed[0].restBetweenSetsSeconds, 30)
        XCTAssertEqual(parsed[1].sets, 3)
        XCTAssertEqual(parsed[1].reps, 15)
        // Every parsed row must survive the editor's own validity check, or
        // the Add button would be disabled on a good parse.
        XCTAssertTrue(parsed.allSatisfy(\.isValid))
    }
}
