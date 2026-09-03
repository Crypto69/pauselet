import Foundation
import ReminderCore
import ReminderAI

/// Owns the API key and the state of any request in flight, so the settings
/// section and the import sheet share one view of whether AI import is
/// available.
///
/// The key is read from the secret store on demand rather than held as a
/// published property: a `@Published` secret ends up in view diffs and
/// snapshots, and nothing in the UI ever needs its value — only whether one
/// exists. Mirrors how `MusicPlayer` and `SpeechCoach` wrap their side effects.
@MainActor
final class AIImportController: ObservableObject {
    /// True when a key is stored, so callers can show or hide the AI path
    /// without reading the key itself.
    @Published private(set) var isConfigured = false
    /// The result of the last "Test key", cleared when the key changes.
    @Published var testResult: TestResult?
    @Published private(set) var isTesting = false

    enum TestResult: Equatable {
        case success
        case failure(String)
    }

    private let secrets: SecretStoring
    private let makeInterpreter: (String, AIImportModel) -> ExerciseInterpreting

    /// - Parameter makeInterpreter: injected so tests and previews can supply
    ///   a stub instead of reaching OpenAI.
    init(
        secrets: SecretStoring = KeychainSecretStore(),
        makeInterpreter: @escaping (String, AIImportModel) -> ExerciseInterpreting = {
            OpenAIExerciseInterpreter(apiKey: $0, model: $1)
        }
    ) {
        self.secrets = secrets
        self.makeInterpreter = makeInterpreter
        refresh()
    }

    /// The model chosen in settings, injected by the views that have the
    /// engine to hand.
    var model: AIImportModel = .default

    // MARK: - The key

    func refresh() {
        isConfigured = (try? secrets.read(account: aiImportKeyAccount))?.isEmpty == false
    }

    /// Stores a key, or removes it when `key` is nil or blank.
    ///
    /// Returns the error to show, or `nil` on success — a keychain that cannot
    /// be written to is worth telling the user about rather than silently
    /// losing what they typed.
    @discardableResult
    func store(key: String?) -> String? {
        testResult = nil
        do {
            try secrets.write(key?.trimmingCharacters(in: .whitespacesAndNewlines),
                              account: aiImportKeyAccount)
            refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Using it

    func interpret(_ text: String) async throws -> [Exercise] {
        guard let key = try? secrets.read(account: aiImportKeyAccount), !key.isEmpty else {
            throw AIImportError.missingKey
        }
        return try await makeInterpreter(key, model).interpret(text)
    }

    /// Proves the whole path works — key, model, network — on a scrap of text,
    /// so a bad key is discovered in Settings rather than mid-import.
    func testKey() {
        guard !isTesting else { return }
        isTesting = true
        testResult = nil
        Task {
            defer { isTesting = false }
            do {
                _ = try await interpret(Self.testPhrase)
                testResult = .success
            } catch AIImportError.nothingFound {
                // The key and the model worked; the model just found nothing
                // in a deliberately trivial phrase. That is still a pass.
                testResult = .success
            } catch {
                testResult = .failure(error.localizedDescription)
            }
        }
    }

    private static let testPhrase = "3 sets of 10 squats"
}
