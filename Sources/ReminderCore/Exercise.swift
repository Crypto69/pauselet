import Foundation

/// One item in an exercise reminder's list: what to do, how many sets of how
/// many repetitions, and — optionally — how long each rep is held and how long
/// to rest. Typed by hand in the editor.
///
/// A reminder carrying at least one of these is an "exercise reminder". It is
/// always delivered as the critical, full-screen takeover, which lists the
/// exercises with a tick box each so the programme is in front of the person
/// while they work through it. The ticks are working memory for that
/// session; nothing about them is stored.
///
/// An exercise with a hold time is "guided": the takeover offers to coach it
/// set by set and rep by rep (`ExerciseTimeline`). One without a hold is
/// untimed and only has its tick box.
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
    /// Seconds each rep is held. 0 means untimed: the takeover shows a plain
    /// tick box and the coach leaves the exercise alone.
    public var holdSeconds: Int
    /// Seconds of rest after every rep except the last of a set. 0 = none.
    public var restBetweenRepsSeconds: Int
    /// Seconds of rest after every set except the last. 0 = none.
    public var restBetweenSetsSeconds: Int

    /// Editor bounds for the timing fields; one place so every platform's
    /// editor and the Windows mirror agree.
    public static let holdRange: ClosedRange<Int> = 0...300
    public static let restRange: ClosedRange<Int> = 0...600

    public init(
        id: UUID = UUID(),
        name: String,
        instructions: String = "",
        sets: Int = 3,
        reps: Int = 10,
        holdSeconds: Int = 0,
        restBetweenRepsSeconds: Int = 0,
        restBetweenSetsSeconds: Int = 0
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.sets = sets
        self.reps = reps
        self.holdSeconds = holdSeconds
        self.restBetweenRepsSeconds = restBetweenRepsSeconds
        self.restBetweenSetsSeconds = restBetweenSetsSeconds
    }

    /// Decodes the timing fields as optional, so exercises written before
    /// they existed still load instead of throwing. `ReminderEngine` reacts
    /// to a decode failure by falling back to the starter set, which would
    /// silently wipe every reminder the user has. Encoding stays synthesized,
    /// so every key is always written.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        instructions = try container.decode(String.self, forKey: .instructions)
        sets = try container.decode(Int.self, forKey: .sets)
        reps = try container.decode(Int.self, forKey: .reps)
        holdSeconds = try container.decodeIfPresent(Int.self, forKey: .holdSeconds) ?? 0
        restBetweenRepsSeconds =
            try container.decodeIfPresent(Int.self, forKey: .restBetweenRepsSeconds) ?? 0
        restBetweenSetsSeconds =
            try container.decodeIfPresent(Int.self, forKey: .restBetweenSetsSeconds) ?? 0
    }

    /// True when the exercise has a hold time, so the takeover can coach it.
    public var isGuided: Bool { holdSeconds > 0 }

    /// "3 × 10" — sets by reps, as the takeover shows it; "3 × 10 · hold 5 s"
    /// when the exercise is guided.
    public var summary: String {
        isGuided ? "\(sets) × \(reps) · hold \(holdSeconds) s" : "\(sets) × \(reps)"
    }

    /// A name to show, at least one set of at least one rep, and no negative
    /// timing.
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && sets >= 1
            && reps >= 1
            && holdSeconds >= 0
            && restBetweenRepsSeconds >= 0
            && restBetweenSetsSeconds >= 0
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
    /// endings folded to "\n", timings clamped into their editor ranges, rows
    /// that cannot be performed dropped, and an empty result collapsed to
    /// `nil` so an ordinary reminder never carries an empty `exercises` array
    /// on disk.
    public static func normalized(_ exercises: [Exercise]) -> [Exercise]? {
        let kept = exercises
            .map { exercise -> Exercise in
                var copy = exercise
                copy.name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
                copy.instructions = exercise.instructions
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                copy.holdSeconds = holdRange.clamping(exercise.holdSeconds)
                copy.restBetweenRepsSeconds = restRange.clamping(exercise.restBetweenRepsSeconds)
                copy.restBetweenSetsSeconds = restRange.clamping(exercise.restBetweenSetsSeconds)
                return copy
            }
            .filter(\.isValid)
        return kept.isEmpty ? nil : kept
    }
}

private extension ClosedRange where Bound == Int {
    func clamping(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
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
