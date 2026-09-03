import XCTest
@testable import ReminderAI
import ReminderCore

/// Decoding a model's reply: the shapes OpenAI actually returns, and — the
/// part that matters — that nothing the model says can produce an exercise the
/// editor would have refused.
final class ExerciseInterpreterTests: XCTestCase {

    // MARK: - Model choice

    /// The default is chosen for responsiveness, not unit price: measured on a
    /// three-exercise paragraph, nano took 31 s against Luna's 6 s, and a
    /// 30-second wait defeats the point of pasting instead of typing.
    func testTheDefaultModelIsLuna() {
        XCTAssertEqual(AIImportModel.default, .luna)
        XCTAssertEqual(AIImportModel.luna.rawValue, "gpt-5.6-luna")
    }

    func testEveryOfferedModelIdIsSpelledCorrectly() {
        XCTAssertEqual(
            AIImportModel.allCases.map(\.rawValue),
            ["gpt-5-nano", "gpt-5.6-luna", "gpt-5-mini"],
            "A typo here reaches the user as an opaque API error"
        )
    }

    func testAnUnsetOrRetiredModelFallsBackToTheDefault() {
        XCTAssertEqual(AIImportModel.resolve(nil), .default, "Never chosen")
        XCTAssertEqual(AIImportModel.resolve("gpt-5-mini"), .mini)
        XCTAssertEqual(AIImportModel.resolve("gpt-5.6-luna"), .luna)
        XCTAssertEqual(
            AIImportModel.resolve("gpt-4.1-mini"), .default,
            "A model dropped from the list falls back rather than erroring"
        )
        XCTAssertEqual(
            AIImportModel.resolve("gpt-3-imaginary"), .default,
            "A model that no longer exists must not become an opaque API error"
        )
    }

    // MARK: - Reading the envelope

    func testReadsTheOutputTextConvenienceField() throws {
        let body = #"{"output_text": "{\"exercises\":[]}"}"#
        let text = try OpenAIExerciseInterpreter.structuredText(in: Data(body.utf8))
        XCTAssertEqual(String(decoding: text, as: UTF8.self), #"{"exercises":[]}"#)
    }

    func testFallsBackToWalkingTheOutputArray() throws {
        let body = #"""
        {"output": [{"content": [{"type": "output_text", "text": "{\"exercises\":[]}"}]}]}
        """#
        let text = try OpenAIExerciseInterpreter.structuredText(in: Data(body.utf8))
        XCTAssertEqual(String(decoding: text, as: UTF8.self), #"{"exercises":[]}"#)
    }

    func testAnUnrecognisableEnvelopeThrows() {
        XCTAssertThrowsError(try OpenAIExerciseInterpreter.structuredText(in: Data("nonsense".utf8)))
    }

    func testReadsTheErrorMessageFromAFailureBody() {
        let body = #"{"error": {"message": "Incorrect API key provided."}}"#
        XCTAssertEqual(
            OpenAIExerciseInterpreter.message(in: Data(body.utf8)),
            "Incorrect API key provided."
        )
    }

    // MARK: - Decoding exercises

    func testDecodesAWellFormedReply() throws {
        let payload = #"""
        {"exercises": [
          {"name": "Chin tucks", "instructions": "Keep your chin level.",
           "sets": 3, "reps": 10, "holdSeconds": 5,
           "restBetweenRepsSeconds": 0, "restBetweenSetsSeconds": 30}
        ]}
        """#
        let decoded = try OpenAIExerciseInterpreter.decode(Data(payload.utf8))
        let exercise = try XCTUnwrap(decoded.first)
        XCTAssertEqual(exercise.name, "Chin tucks")
        XCTAssertEqual(exercise.instructions, "Keep your chin level.")
        XCTAssertEqual(exercise.sets, 3)
        XCTAssertEqual(exercise.reps, 10)
        XCTAssertEqual(exercise.holdSeconds, 5)
        XCTAssertEqual(exercise.restBetweenSetsSeconds, 30)
    }

    func testCountsQuotedAsStringsStillDecode() throws {
        let payload = #"{"exercises": [{"name": "Squats", "sets": "4", "reps": "12"}]}"#
        let decoded = try OpenAIExerciseInterpreter.decode(Data(payload.utf8))
        XCTAssertEqual(decoded.first?.sets, 4)
        XCTAssertEqual(decoded.first?.reps, 12)
    }

    func testMissingFieldsFallBackToTheEditorDefaults() throws {
        let payload = #"{"exercises": [{"name": "Squats"}]}"#
        let exercise = try XCTUnwrap(try OpenAIExerciseInterpreter.decode(Data(payload.utf8)).first)
        XCTAssertEqual(exercise.sets, 3)
        XCTAssertEqual(exercise.reps, 10)
        XCTAssertEqual(exercise.holdSeconds, 0)
    }

    /// The model does not send an id and must not be able to: identity is the
    /// app's to assign, or two imports could collide in the editor.
    func testEachDecodedExerciseGetsAFreshIdentity() throws {
        let payload = #"{"exercises": [{"name": "A"}, {"name": "B"}]}"#
        let decoded = try OpenAIExerciseInterpreter.decode(Data(payload.utf8))
        XCTAssertEqual(Set(decoded.map(\.id)).count, 2)
    }

    // MARK: - Never trust the model

    /// A reply with impossible numbers must be clamped or dropped by
    /// `Exercise.normalized`, never handed to the editor as-is.
    func testHostileValuesAreClampedOrDropped() throws {
        let payload = #"""
        {"exercises": [
          {"name": "Overlong hold", "sets": 3, "reps": 10, "holdSeconds": 99999},
          {"name": "Negative rest", "sets": 3, "reps": 10, "restBetweenSetsSeconds": -5},
          {"name": "   ", "sets": 3, "reps": 10},
          {"name": "No sets", "sets": 0, "reps": 10}
        ]}
        """#
        let decoded = try OpenAIExerciseInterpreter.decode(Data(payload.utf8))
        let normalized = Exercise.normalized(decoded) ?? []

        XCTAssertEqual(
            normalized.map(\.name), ["Overlong hold", "Negative rest"],
            "The nameless and zero-set rows are dropped"
        )
        XCTAssertEqual(normalized[0].holdSeconds, Exercise.holdRange.upperBound, "Clamped")
        XCTAssertEqual(normalized[1].restBetweenSetsSeconds, 0, "Negative rest clamped to zero")
        XCTAssertTrue(normalized.allSatisfy(\.isValid))
    }

    func testAnEmptyExerciseListDecodesToNothing() throws {
        let decoded = try OpenAIExerciseInterpreter.decode(Data(#"{"exercises": []}"#.utf8))
        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: - Guardrails before the network

    func testAnEmptyKeyIsRefusedWithoutCallingOut() async {
        let interpreter = OpenAIExerciseInterpreter(apiKey: "")
        do {
            _ = try await interpreter.interpret("3 x 10 squats")
            XCTFail("Expected a missing-key error")
        } catch {
            XCTAssertEqual(error as? AIImportError, .missingKey)
        }
    }

    func testEmptyTextIsRefusedWithoutCallingOut() async {
        let interpreter = OpenAIExerciseInterpreter(apiKey: "sk-test")
        do {
            _ = try await interpreter.interpret("   ")
            XCTFail("Expected a nothing-found error")
        } catch {
            XCTAssertEqual(error as? AIImportError, .nothingFound)
        }
    }

    /// A slow answer is not a missing network. Reasoning models regularly take
    /// over 30 seconds on a full programme, and reporting that as "check your
    /// connection" sends people to debug a network that was never broken.
    func testATimeoutIsNotReportedAsBeingOffline() {
        XCTAssertNotEqual(AIImportError.timedOut, .offline)
        XCTAssertEqual(
            AIImportError.timedOut.errorDescription,
            "OpenAI took too long to answer. Try again, or use Read Text."
        )
        XCTAssertFalse(
            AIImportError.timedOut.errorDescription?.lowercased().contains("connection") ?? true,
            "The timeout message must not blame the user's network"
        )
    }

    /// The prompt is what stops the model inventing a hold time nobody
    /// prescribed, so its key instruction is worth pinning.
    func testThePromptForbidsInventingTimings() {
        XCTAssertTrue(OpenAIExerciseInterpreter.systemPrompt.contains("Never invent"))
    }
}

/// The secret store contract, exercised against the in-memory implementation
/// the app uses in tests and previews.
final class SecretStoreTests: XCTestCase {

    func testWriteThenReadReturnsTheSecret() throws {
        let store = InMemorySecretStore()
        try store.write("sk-abc", account: aiImportKeyAccount)
        XCTAssertEqual(try store.read(account: aiImportKeyAccount), "sk-abc")
    }

    func testReadingAnUnsetAccountReturnsNil() throws {
        XCTAssertNil(try InMemorySecretStore().read(account: aiImportKeyAccount))
    }

    func testWritingNilRemovesTheSecret() throws {
        let store = InMemorySecretStore([aiImportKeyAccount: "sk-abc"])
        try store.write(nil, account: aiImportKeyAccount)
        XCTAssertNil(try store.read(account: aiImportKeyAccount))
    }

    func testWritingAnEmptyStringRemovesTheSecret() throws {
        let store = InMemorySecretStore([aiImportKeyAccount: "sk-abc"])
        try store.write("", account: aiImportKeyAccount)
        XCTAssertNil(try store.read(account: aiImportKeyAccount), "Clearing the field removes the key")
    }
}
