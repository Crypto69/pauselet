import XCTest
import ReminderCore
import ReminderAI
@testable import Pauselet

/// Tests for the iOS side of AI import: the key's life in the secret store,
/// and the guarantee that no request is made without one. The OpenAI client
/// and its parsing are covered by `ReminderAITests`; nothing here reaches the
/// network.
@MainActor
final class AIImportControllerTests: XCTestCase {

    private struct StubInterpreter: ExerciseInterpreting {
        let result: [Exercise]
        func interpret(_ text: String) async throws -> [Exercise] { result }
    }

    private struct FailingInterpreter: ExerciseInterpreting {
        let error: AIImportError
        func interpret(_ text: String) async throws -> [Exercise] { throw error }
    }

    /// Refuses every write, standing in for a keychain the app cannot reach.
    private struct UnwritableStore: SecretStoring {
        struct Denied: LocalizedError {
            var errorDescription: String? { "Could not reach the keychain." }
        }
        func read(account: String) throws -> String? { nil }
        func write(_ value: String?, account: String) throws { throw Denied() }
    }

    private func controller(
        secrets: SecretStoring = InMemorySecretStore(),
        interpreter: ExerciseInterpreting = StubInterpreter(result: [])
    ) -> AIImportController {
        AIImportController(secrets: secrets, makeInterpreter: { _, _ in interpreter })
    }

    // MARK: - The key

    func testStartsUnconfiguredWithNoStoredKey() {
        XCTAssertFalse(controller().isConfigured)
    }

    func testStoringAKeyConfiguresIt() {
        let ai = controller()

        XCTAssertNil(ai.store(key: "sk-test"))

        XCTAssertTrue(ai.isConfigured)
    }

    func testStoredKeyIsTrimmed() throws {
        let secrets = InMemorySecretStore()
        let ai = controller(secrets: secrets)

        ai.store(key: "  sk-test\n")

        XCTAssertEqual(try secrets.read(account: aiImportKeyAccount), "sk-test")
    }

    func testStoringNilRemovesTheKey() {
        let ai = controller(secrets: InMemorySecretStore([aiImportKeyAccount: "sk-test"]))
        XCTAssertTrue(ai.isConfigured)

        ai.store(key: nil)

        XCTAssertFalse(ai.isConfigured)
    }

    func testABlankKeyCountsAsNoKey() {
        let ai = controller()

        ai.store(key: "   ")

        XCTAssertFalse(ai.isConfigured)
    }

    /// A keychain that cannot be written to is worth saying out loud rather
    /// than silently losing what the user typed.
    func testAnUnwritableStoreReturnsAnError() {
        let ai = controller(secrets: UnwritableStore())

        let error = ai.store(key: "sk-test")

        XCTAssertNotNil(error)
        XCTAssertFalse(ai.isConfigured)
    }

    func testStoringAKeyClearsTheLastTestResult() {
        let ai = controller()
        ai.testResult = .failure("stale")

        ai.store(key: "sk-test")

        XCTAssertNil(ai.testResult)
    }

    // MARK: - Interpreting

    func testInterpretingWithoutAKeyThrowsRatherThanCallingOut() async {
        let ai = controller(
            interpreter: StubInterpreter(result: [Exercise(name: "Should not happen")])
        )

        do {
            _ = try await ai.interpret("3 sets of 10 squats")
            XCTFail("expected missingKey")
        } catch {
            XCTAssertEqual(error as? AIImportError, .missingKey)
        }
    }

    func testInterpretingWithAKeyReturnsTheInterpretedExercises() async throws {
        let ai = controller(
            secrets: InMemorySecretStore([aiImportKeyAccount: "sk-test"]),
            interpreter: StubInterpreter(result: [Exercise(name: "Squats", sets: 3, reps: 10)])
        )

        let exercises = try await ai.interpret("3 sets of 10 squats")

        XCTAssertEqual(exercises.map(\.name), ["Squats"])
    }

    // MARK: - Testing the key

    func testTestKeySucceedsWhenTheInterpreterAnswers() async {
        let ai = controller(
            secrets: InMemorySecretStore([aiImportKeyAccount: "sk-test"]),
            interpreter: StubInterpreter(result: [Exercise(name: "Squats")])
        )

        ai.testKey()
        await settle(ai)

        XCTAssertEqual(ai.testResult, .success)
    }

    /// The key and the model worked; the model just found nothing in a
    /// deliberately trivial phrase. That is still a pass.
    func testNothingFoundStillCountsAsAWorkingKey() async {
        let ai = controller(
            secrets: InMemorySecretStore([aiImportKeyAccount: "sk-test"]),
            interpreter: FailingInterpreter(error: .nothingFound)
        )

        ai.testKey()
        await settle(ai)

        XCTAssertEqual(ai.testResult, .success)
    }

    func testABadKeyReportsTheFailure() async {
        let ai = controller(
            secrets: InMemorySecretStore([aiImportKeyAccount: "sk-bad"]),
            interpreter: FailingInterpreter(error: .unauthorized)
        )

        ai.testKey()
        await settle(ai)

        guard case .failure = ai.testResult else {
            return XCTFail("expected a failure, got \(String(describing: ai.testResult))")
        }
    }

    /// `testKey` runs its work in a Task; wait for it to report finished
    /// rather than sleeping for a fixed time. `isTesting` is the completion
    /// signal — `testResult` is nil both before the work starts and, briefly,
    /// while it runs, so polling that instead races the failure path.
    private func settle(
        _ ai: AIImportController, file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<1000 where ai.isTesting {
            await Task.yield()
        }
        XCTAssertFalse(ai.isTesting, "testKey never finished", file: file, line: line)
    }
}
