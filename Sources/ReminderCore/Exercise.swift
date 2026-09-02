import Foundation

/// One item in an exercise reminder's list: what to do, and how many sets of
/// how many repetitions. Typed by hand in the editor.
///
/// A reminder carrying at least one of these is an "exercise reminder". It is
/// always delivered as the critical, full-screen takeover, which lists the
/// exercises with a tick box each so the programme is in front of the person
/// while they work through it. The ticks are working memory for that
/// session; nothing about them is stored.
public struct Exercise: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// Stable identity for the editor's rows and the takeover's tick boxes.
    public var id: UUID
    public var name: String
    /// Multi-line free text. Stored with "\n" line endings only, so the same
    /// exercise serializes identically whichever platform typed it — see
    /// `normalized(_:)`.
    public var instructions: String
    public var sets: Int
    public var reps: Int

    public init(
        id: UUID = UUID(),
        name: String,
        instructions: String = "",
        sets: Int = 3,
        reps: Int = 10
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.sets = sets
        self.reps = reps
    }

    /// "3 × 10" — sets by reps, as the takeover shows it.
    public var summary: String { "\(sets) × \(reps)" }

    /// A name to show and at least one set of at least one rep.
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && sets >= 1
            && reps >= 1
    }

    /// "3 exercises · 9 sets" for list rows, where the full list will not fit;
    /// `nil` for an empty list.
    public static func summary(of exercises: [Exercise]) -> String? {
        guard !exercises.isEmpty else { return nil }
        let sets = exercises.reduce(0) { $0 + $1.sets }
        let exerciseWord = exercises.count == 1 ? "exercise" : "exercises"
        let setWord = sets == 1 ? "set" : "sets"
        return "\(exercises.count) \(exerciseWord) · \(sets) \(setWord)"
    }

    /// What the editor stores: names and instructions trimmed, Windows line
    /// endings folded to "\n", rows that cannot be performed dropped, and an
    /// empty result collapsed to `nil` so an ordinary reminder never carries an
    /// empty `exercises` array on disk.
    public static func normalized(_ exercises: [Exercise]) -> [Exercise]? {
        let kept = exercises
            .map { exercise -> Exercise in
                var copy = exercise
                copy.name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
                copy.instructions = exercise.instructions
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return copy
            }
            .filter(\.isValid)
        return kept.isEmpty ? nil : kept
    }
}

public extension Reminder {
    /// True when the reminder carries at least one exercise.
    var isExercise: Bool { exercises?.isEmpty == false }

    /// `Exercise.summary(of:)` for this reminder's list; `nil` for an ordinary
    /// reminder.
    var exerciseSummary: String? {
        exercises.flatMap(Exercise.summary(of:))
    }

    /// The list-row subtitle: the schedule, plus the exercise summary for an
    /// exercise reminder ("Every 2 hours · 3 exercises · 9 sets"). One place
    /// composes it so every platform's rows read the same.
    var scheduleLine: String {
        exerciseSummary.map { "\(schedule.summary) · \($0)" } ?? schedule.summary
    }
}
