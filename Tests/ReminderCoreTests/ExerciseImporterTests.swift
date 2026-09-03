import XCTest
@testable import ReminderCore

/// What a person can paste from a physiotherapist's handout and get back as
/// exercises: the phrasings that must be understood, the ones that must be
/// left alone, and the guarantee that whatever comes out is something the
/// editor would have accepted if it had been typed by hand.
final class ExerciseImporterTests: XCTestCase {

    // MARK: - Helpers

    /// One exercise from text, unwrapped — most cases parse a single line.
    private func parseOne(_ text: String) throws -> Exercise {
        let exercises = ExerciseImporter.parse(text)
        XCTAssertEqual(exercises.count, 1, "Expected exactly one exercise from: \(text)")
        return try XCTUnwrap(exercises.first)
    }

    /// "name | sets × reps | hold | rest reps | rest sets" — the whole parse in
    /// one line, so a table of cases diffs like a table.
    private func describe(_ exercise: Exercise) -> String {
        "\(exercise.name) | \(exercise.sets)×\(exercise.reps) | \(exercise.holdSeconds) | "
            + "\(exercise.restBetweenRepsSeconds) | \(exercise.restBetweenSetsSeconds)"
    }

    // MARK: - Sets and reps

    func testParsesTheCommonSetsAndRepsPhrasings() {
        let cases = [
            "3 sets of 10 chin tucks",
            "chin tucks 3 x 10",
            "chin tucks 3 × 10",
            "chin tucks, 3 sets of 10 reps",
            "chin tucks: 10 reps, 3 sets",
            "three sets of ten chin tucks",
        ]
        let parsed = cases.map { text -> String in
            guard let exercise = ExerciseImporter.parse(text).first else { return "\(text) → nothing" }
            return "\(exercise.sets)×\(exercise.reps)"
        }
        XCTAssertEqual(parsed, ["3×10", "3×10", "3×10", "3×10", "3×10", "3×10"])
    }

    func testUnstatedCountsKeepTheEditorDefaults() throws {
        let exercise = try parseOne("Shoulder rolls")
        XCTAssertEqual(exercise.sets, 3, "The Exercise initializer's default")
        XCTAssertEqual(exercise.reps, 10, "The Exercise initializer's default")
        XCTAssertEqual(exercise.holdSeconds, 0, "Nothing said to hold, so untimed")
    }

    // MARK: - Hold

    func testParsesHoldPhrasings() {
        let cases = [
            "Chin tucks 3 x 10, hold 5 seconds",
            "Chin tucks 3 x 10, hold for 5 seconds",
            "Chin tucks 3 x 10, hold 5s",
            "Chin tucks 3 x 10, hold 5 sec",
            "Chin tucks 3 x 10, 5 second hold",
            "Chin tucks 3 x 10, hold five seconds",
        ]
        let parsed = cases.map { ExerciseImporter.parse($0).first?.holdSeconds ?? -1 }
        XCTAssertEqual(parsed, [5, 5, 5, 5, 5, 5])
    }

    func testABareHoldNumberMeansSeconds() throws {
        XCTAssertEqual(try parseOne("Chin tucks 3 x 10, hold 5").holdSeconds, 5)
    }

    func testMinutesConvertToSeconds() throws {
        XCTAssertEqual(try parseOne("Plank 1 x 1, hold 2 minutes").holdSeconds, 120)
        XCTAssertEqual(try parseOne("Plank 1 x 1, hold 2 min").holdSeconds, 120)
    }

    func testAHoldMakesTheExerciseGuided() throws {
        XCTAssertTrue(try parseOne("Chin tucks 3 x 10 hold 5 seconds").isGuided)
        XCTAssertFalse(try parseOne("Shoulder rolls 3 x 10").isGuided)
    }

    // MARK: - Rest

    func testParsesRestBetweenSets() throws {
        let exercise = try parseOne("Squats 3 x 10, rest 30 seconds between sets")
        XCTAssertEqual(exercise.restBetweenSetsSeconds, 30)
        XCTAssertEqual(exercise.restBetweenRepsSeconds, 0, "Only the set rest was stated")
    }

    func testParsesRestBetweenReps() throws {
        let exercise = try parseOne("Squats 3 x 10, rest 10 seconds between reps")
        XCTAssertEqual(exercise.restBetweenRepsSeconds, 10)
        XCTAssertEqual(exercise.restBetweenSetsSeconds, 0, "Only the rep rest was stated")
    }

    /// The set rest must be claimed first; the looser rep pattern would
    /// otherwise swallow "rest 30 seconds between sets".
    func testParsesBothRestsInOneLine() throws {
        let exercise = try parseOne(
            "Squats 3 x 10, rest 10 seconds between reps and 30 seconds between sets"
        )
        XCTAssertEqual(exercise.restBetweenRepsSeconds, 10)
        XCTAssertEqual(exercise.restBetweenSetsSeconds, 30)
    }

    // MARK: - The whole table

    func testRealisticPhysioLines() {
        let cases = [
            "3 sets of 10 chin tucks, hold 5 seconds, rest 30 seconds between sets",
            "Wall slides 3 x 15",
            "Bird dog: 2 sets of 8 each side, hold 10 seconds",
            "Glute bridges 4 x 12, rest 45 seconds between sets",
        ]
        let parsed = cases.compactMap { ExerciseImporter.parse($0).first }.map(describe)
        XCTAssertEqual(parsed, [
            "Chin tucks | 3×10 | 5 | 0 | 30",
            "Wall slides | 3×15 | 0 | 0 | 0",
            "Bird dog | 2×8 | 10 | 0 | 0",
            "Glute bridges | 4×12 | 0 | 0 | 45",
        ])
    }

    // MARK: - Multiple exercises

    func testParsesABulletedList() {
        let text = """
        - Chin tucks 3 x 10, hold 5 seconds
        - Wall slides 3 x 15
        - Glute bridges 4 x 12
        """
        let parsed = ExerciseImporter.parse(text).map(describe)
        XCTAssertEqual(parsed, [
            "Chin tucks | 3×10 | 5 | 0 | 0",
            "Wall slides | 3×15 | 0 | 0 | 0",
            "Glute bridges | 4×12 | 0 | 0 | 0",
        ])
    }

    func testParsesANumberedList() {
        let text = """
        1. Chin tucks 3 x 10
        2. Wall slides 3 x 15
        """
        XCTAssertEqual(ExerciseImporter.parse(text).map(\.name), ["Chin tucks", "Wall slides"])
    }

    /// A numbered marker must not be mistaken for the exercise's set count.
    func testANumberedMarkerIsNotReadAsACount() throws {
        let parsed = ExerciseImporter.parse("2. Wall slides 3 x 15")
        XCTAssertEqual(parsed.first?.sets, 3)
        XCTAssertEqual(parsed.first?.reps, 15)
    }

    func testParsesBlankLineSeparatedParagraphs() {
        let text = """
        Chin tucks 3 x 10, hold 5 seconds

        Wall slides 3 x 15
        """
        XCTAssertEqual(ExerciseImporter.parse(text).map(\.name), ["Chin tucks", "Wall slides"])
    }

    func testInstructionsKeepTheProseAfterTheName() throws {
        let text = "Chin tucks 3 x 10\nKeep your chin level and your shoulders relaxed."
        let exercise = try parseOne(text)
        XCTAssertEqual(exercise.name, "Chin tucks")
        XCTAssertEqual(exercise.instructions, "Keep your chin level and your shoulders relaxed.")
    }

    // MARK: - Continuous prose

    /// A handout is often one flowing paragraph with no bullets and no blank
    /// lines. Before this was handled the whole thing parsed as a single
    /// exercise called "Chin tucks,, then", with the rest swept into its
    /// instructions.
    func testParsesAParagraphThatRunsExercisesTogether() {
        let text = "3 sets of 10 chin tucks, holding for 5 seconds, then resting 30 "
            + "seconds between sets. Then perform wall slides 3 times for 15 seconds, "
            + "followed by 30 seconds of rest. Finally, perform bicep curls mimicking "
            + "hand-to-mouth movements: 3 sets of 10 reps, with 30 seconds of rest "
            + "between each rep."
        let parsed = ExerciseImporter.parse(text)
        XCTAssertEqual(parsed.count, 3, "One exercise per clause, not one for the paragraph")
        XCTAssertEqual(
            parsed.map(\.name),
            ["Chin tucks", "Wall slides", "Bicep curls mimicking hand-to-mouth movements"]
        )
        XCTAssertEqual(parsed[0].holdSeconds, 5)
        XCTAssertEqual(parsed[0].restBetweenSetsSeconds, 30)
        XCTAssertEqual(parsed[1].holdSeconds, 15, "\"3 times for 15 seconds\" is a held rep")
        XCTAssertEqual(parsed[2].restBetweenRepsSeconds, 30)
    }

    /// The hand-over word only splits when another exercise follows it, so an
    /// instruction that merely contains "then" stays in one piece.
    func testThenInsideAnInstructionDoesNotSplit() {
        let parsed = ExerciseImporter.parse("Chin tucks 3 x 10. Hold, then release slowly.")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "Chin tucks")
    }

    func testAnImperativeIsNotPartOfTheName() {
        XCTAssertEqual(
            ExerciseImporter.parse("Perform wall slides 3 x 15").first?.name, "Wall slides"
        )
    }

    func testTimesForIsARepCountWithAHold() throws {
        let exercise = try parseOne("Wall slides 3 times for 15 seconds")
        XCTAssertEqual(exercise.reps, 3, "\"3 times\" counts repetitions")
        XCTAssertEqual(exercise.holdSeconds, 15)
        XCTAssertEqual(exercise.sets, 3, "No set count was stated, so the default stands")
    }

    // MARK: - Nothing to import

    func testEmptyTextParsesToNothing() {
        XCTAssertEqual(ExerciseImporter.parse("").count, 0)
        XCTAssertEqual(ExerciseImporter.parse("   \n\n  ").count, 0)
    }

    func testTextWithNoNameParsesToNothing() {
        XCTAssertEqual(ExerciseImporter.parse("3 x 10").count, 0, "A count with nothing to call it")
    }

    // MARK: - The output is always editor-legal

    func testEveryParsedExerciseIsValid() {
        let text = """
        - Chin tucks 3 x 10, hold 5 seconds
        - Wall slides 3 x 15
        - 3 x 10
        """
        let parsed = ExerciseImporter.parse(text)
        XCTAssertTrue(parsed.allSatisfy(\.isValid), "Invalid rows must be dropped, not returned")
        XCTAssertEqual(parsed.count, 2, "The nameless row is dropped")
    }

    func testParsingIsIdempotentThroughNormalization() {
        let parsed = ExerciseImporter.parse("Chin tucks 3 x 10, hold 5 seconds")
        XCTAssertEqual(Exercise.normalized(parsed), parsed, "parse already returns normalized rows")
    }

    func testOutOfRangeTimingIsClampedNotRejected() throws {
        let exercise = try parseOne("Plank 1 x 1, hold 60 minutes")
        XCTAssertEqual(
            exercise.holdSeconds, Exercise.holdRange.upperBound,
            "3600 s clamps to the editor's ceiling rather than dropping the exercise"
        )
    }

    func testWindowsLineEndingsParseTheSame() {
        let parsed = ExerciseImporter.parse("- Chin tucks 3 x 10\r\n- Wall slides 3 x 15")
        XCTAssertEqual(parsed.map(\.name), ["Chin tucks", "Wall slides"])
    }
}
