import Foundation

/// One step of a coached programme — a hold or a paced rep, a rest, or the
/// lead-in before an exercise — with its place on the session's clock and
/// the exercise it belongs to.
public struct ExercisePhase: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case getReady
        /// One held repetition of an exercise with a hold time.
        case hold
        /// One repetition of an exercise without a hold time, paced at
        /// `ExerciseTimeline.repSeconds` so the coach can count it.
        case rep
        case restBetweenReps
        case restBetweenSets
        /// The gap between one exercise finishing and the next one's lead-in
        /// when a whole programme runs in sequence. Belongs to the exercise
        /// that is coming up.
        case restBetweenExercises
    }

    public let kind: Kind
    /// The exercise this phase belongs to. For a rest between exercises, the
    /// one about to start.
    public let exerciseID: UUID
    public let exerciseName: String
    /// 1-based. For a rest between sets, the set just finished. 0 for the
    /// lead-in and for a rest between exercises.
    public let set: Int
    /// 1-based. The rep being performed, or — for a rest between reps — the
    /// rep just finished. 0 for the lead-in and for rests between sets or
    /// exercises.
    public let rep: Int
    /// Offset from the start of the session.
    public let start: TimeInterval
    public let duration: TimeInterval
    /// The spoken line for the start of this phase, composed when the
    /// timeline is built so it can mention the exercise before as well as
    /// the one at hand ("Pelvic tilts complete. Chin tucks. Get ready.").
    public let cue: String

    public var end: TimeInterval { start + duration }

    public init(
        kind: Kind,
        exerciseID: UUID,
        exerciseName: String,
        set: Int,
        rep: Int,
        start: TimeInterval,
        duration: TimeInterval,
        cue: String
    ) {
        self.kind = kind
        self.exerciseID = exerciseID
        self.exerciseName = exerciseName
        self.set = set
        self.rep = rep
        self.start = start
        self.duration = duration
        self.cue = cue
    }

    /// The headline while this phase runs: "Set 1 · Rep 3", "Set 1 done",
    /// "Up next".
    public var title: String {
        switch kind {
        case .getReady: return "Get ready"
        case .hold, .rep, .restBetweenReps: return "Set \(set) · Rep \(rep)"
        case .restBetweenSets: return "Set \(set) done"
        case .restBetweenExercises: return "Up next"
        }
    }

    /// What the countdown is counting: "Hold", "Go", "Rest".
    public var label: String {
        switch kind {
        case .getReady: return "Get ready"
        case .hold: return "Hold"
        case .rep: return "Go"
        case .restBetweenReps: return "Rest"
        case .restBetweenSets: return "Rest between sets"
        case .restBetweenExercises: return "Rest"
        }
    }
}

/// Something the coach says, at an offset on the session's clock.
public struct ExerciseCue: Equatable, Sendable {
    public let at: TimeInterval
    public let text: String

    public init(at: TimeInterval, text: String) {
        self.at = at
        self.text = text
    }
}

/// The whole coached programme for one exercise or a run of them, computed
/// once when Start is pressed: for each exercise a short lead-in, then for
/// every set and rep a hold (or a paced rep when there is no hold), with the
/// rests the exercise asks for in between; and between exercises the rest
/// the reminder asks for. Zero-length rests are not emitted.
///
/// Pure data, so the Mac, iOS and Windows coaches all run the same programme
/// and say the same things.
public struct ExerciseTimeline: Equatable, Sendable {
    /// Seconds between pressing Start and the first rep — long enough to get
    /// into position, short enough not to feel like waiting.
    public static let leadInSeconds: TimeInterval = 3
    /// Seconds allowed for one rep of an exercise with no hold time, so it
    /// can be counted through rather than left to the person.
    public static let repSeconds = 3
    /// Holds at least this long get a spoken "Three. Two. One." at the end.
    /// Shorter holds do not: the opening cue would still be being spoken.
    public static let countdownMinimumHold = 6

    /// One exercise's span on the clock: from its lead-in to the end of its
    /// last set. A rest between exercises falls between one entry's `end`
    /// and the next one's `start`.
    public struct Entry: Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let start: TimeInterval
        public let end: TimeInterval

        public init(id: UUID, name: String, start: TimeInterval, end: TimeInterval) {
            self.id = id
            self.name = name
            self.start = start
            self.end = end
        }
    }

    /// The exercises in the order they run.
    public let entries: [Entry]
    public let phases: [ExercisePhase]
    /// Sorted by `at`: one for the start of every phase, the countdown words
    /// inside long holds, and the closing line at `totalDuration`.
    public let cues: [ExerciseCue]

    public var totalDuration: TimeInterval { phases.last?.end ?? 0 }

    /// "Exercise complete" for one exercise, "All exercises complete" for a
    /// run of them: the panel's headline at the end, and the closing cue.
    public var completionTitle: String { Self.completionTitle(entryCount: entries.count) }

    private static func completionTitle(entryCount: Int) -> String {
        entryCount > 1 ? "All exercises complete" : "Exercise complete"
    }

    /// The programme for one exercise; `nil` when it has no sets or reps.
    public init?(exercise: Exercise) {
        self.init(exercises: [exercise])
    }

    /// The programme for `exercises` in order, with `restBetweenExercisesSeconds`
    /// between one finishing and the next one's lead-in. Exercises with no
    /// sets or reps are left out; `nil` when nothing is left.
    public init?(exercises: [Exercise], restBetweenExercisesSeconds: Int = 0) {
        let runnable = exercises.filter { $0.sets >= 1 && $0.reps >= 1 }
        guard !runnable.isEmpty else { return nil }

        var phases: [ExercisePhase] = []
        var entries: [Entry] = []
        var cursor: TimeInterval = 0

        for (index, exercise) in runnable.enumerated() {
            func append(_ kind: ExercisePhase.Kind, set: Int, rep: Int, seconds: Int, cue: String) {
                phases.append(ExercisePhase(
                    kind: kind, exerciseID: exercise.id, exerciseName: exercise.name,
                    set: set, rep: rep, start: cursor, duration: TimeInterval(seconds), cue: cue
                ))
                cursor += TimeInterval(seconds)
            }

            // The exercise before is signed off at the start of whatever
            // comes next, so its last rep is not talked over.
            var preamble = index > 0 ? "\(runnable[index - 1].name) complete. " : ""
            if index > 0, restBetweenExercisesSeconds > 0 {
                append(.restBetweenExercises, set: 0, rep: 0, seconds: restBetweenExercisesSeconds,
                       cue: preamble + "Rest for \(Self.seconds(restBetweenExercisesSeconds)). "
                           + "Next, \(exercise.name).")
                preamble = ""
            }

            let entryStart = cursor
            append(.getReady, set: 0, rep: 0, seconds: Int(Self.leadInSeconds),
                   cue: preamble + "\(exercise.name). Get ready.")

            for set in 1...exercise.sets {
                for rep in 1...exercise.reps {
                    if exercise.hasHold {
                        append(.hold, set: set, rep: rep, seconds: exercise.holdSeconds,
                               cue: rep == 1
                                   ? "Set \(set), rep 1. Hold for \(Self.seconds(exercise.holdSeconds))."
                                   : "Rep \(rep). Hold.")
                    } else {
                        append(.rep, set: set, rep: rep, seconds: Self.repSeconds,
                               cue: rep == 1 ? "Set \(set), rep 1." : "Rep \(rep).")
                    }
                    if rep < exercise.reps, exercise.restBetweenRepsSeconds > 0 {
                        append(.restBetweenReps, set: set, rep: rep,
                               seconds: exercise.restBetweenRepsSeconds, cue: "Rest.")
                    }
                }
                if set < exercise.sets, exercise.restBetweenSetsSeconds > 0 {
                    append(.restBetweenSets, set: set, rep: 0,
                           seconds: exercise.restBetweenSetsSeconds,
                           cue: "Set \(set) done. Rest for \(Self.seconds(exercise.restBetweenSetsSeconds)).")
                }
            }

            entries.append(Entry(id: exercise.id, name: exercise.name, start: entryStart, end: cursor))
        }

        self.entries = entries
        self.phases = phases
        cues = Self.cues(for: phases, closing: Self.completionTitle(entryCount: entries.count) + ".")
    }

    /// Index of the phase containing `offset`, treating each phase as
    /// half-open (`start ..< end`); `nil` at or past the end of the session.
    /// A negative offset counts as the start.
    public func phaseIndex(at offset: TimeInterval) -> Int? {
        guard offset < totalDuration else { return nil }
        let clamped = max(0, offset)
        return phases.lastIndex { $0.start <= clamped }
    }

    /// The exercises whose last set has run by `offset`, in programme order.
    public func finishedExerciseIDs(at offset: TimeInterval) -> [UUID] {
        entries.filter { offset >= $0.end }.map(\.id)
    }

    /// Where the exercise after `id` begins — its lead-in, past any rest
    /// between the two — or the end of the session when `id` is the last (or
    /// not in the programme). What cancelling the exercise being coached
    /// jumps to.
    public func startOfExercise(after id: UUID) -> TimeInterval {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              index + 1 < entries.count
        else { return totalDuration }
        return entries[index + 1].start
    }

    /// "1 second" / "5 seconds".
    public static func seconds(_ count: Int) -> String {
        count == 1 ? "1 second" : "\(count) seconds"
    }

    private static func cues(for phases: [ExercisePhase], closing: String) -> [ExerciseCue] {
        var cues: [ExerciseCue] = []
        for phase in phases {
            cues.append(ExerciseCue(at: phase.start, text: phase.cue))
            if phase.kind == .hold, Int(phase.duration) >= countdownMinimumHold {
                cues.append(ExerciseCue(at: phase.end - 3, text: "Three."))
                cues.append(ExerciseCue(at: phase.end - 2, text: "Two."))
                cues.append(ExerciseCue(at: phase.end - 1, text: "One."))
            }
        }
        if let last = phases.last {
            cues.append(ExerciseCue(at: last.end, text: closing))
        }
        return cues.sorted { $0.at < $1.at }
    }
}

/// A cursor over a timeline, driven entirely by the `now` passed in — never
/// by counting ticks — so a stalled timer, a busy display or a laptop lid
/// closing cannot make the coach drift from wall time. Mirrors how the
/// scheduler takes `now` rather than reading a clock.
///
/// A talking coach needs one more thing: the hold must not start counting
/// while "Hold for 5 seconds" is still being said. `beginAnnouncement`
/// freezes the clock at the start of the current phase and
/// `finishAnnouncement` lets it run, so the driver can wrap each spoken cue
/// in the two and the seconds on screen are the seconds the person gets.
public struct ExerciseSession: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running
        /// Frozen at the start of a phase while its cue is being spoken.
        case announcing
        case paused
        case completed
        case stopped
    }

    public enum Position: Equatable, Sendable {
        case phase(index: Int, remaining: TimeInterval, progress: Double)
        case complete
    }

    public let timeline: ExerciseTimeline
    public private(set) var state: State
    /// Session time accumulated by run segments that have ended.
    private var banked: TimeInterval
    /// When the current run segment began; `nil` unless running.
    private var runningSince: Date?

    public init(timeline: ExerciseTimeline, startedAt now: Date) {
        self.timeline = timeline
        state = .running
        banked = 0
        runningSince = now
    }

    /// Session time at `now`, clamped to the timeline's length. A clock set
    /// backwards never makes it shrink below what was banked.
    public func elapsed(at now: Date) -> TimeInterval {
        var value = banked
        if let since = runningSince {
            value += max(0, now.timeIntervalSince(since))
        }
        return min(value, timeline.totalDuration)
    }

    public func position(at now: Date) -> Position {
        let offset = elapsed(at: now)
        guard let index = timeline.phaseIndex(at: offset) else { return .complete }
        let phase = timeline.phases[index]
        let progress = phase.duration > 0 ? (offset - phase.start) / phase.duration : 1
        return .phase(index: index, remaining: phase.end - offset, progress: progress)
    }

    public func phase(at now: Date) -> ExercisePhase? {
        timeline.phaseIndex(at: elapsed(at: now)).map { timeline.phases[$0] }
    }

    /// How many cues have fallen due by `now`. A driver remembers the last
    /// count it acted on and speaks only the newest cue past it, so a clock
    /// that jumps (sleep, a stalled timer) yields one utterance, not a burst.
    public func cueCount(at now: Date) -> Int {
        let offset = elapsed(at: now)
        return timeline.cues.firstIndex { $0.at > offset } ?? timeline.cues.count
    }

    public func isFinished(at now: Date) -> Bool {
        elapsed(at: now) >= timeline.totalDuration
    }

    /// True when nothing of the current phase has run yet — the moment a
    /// cue is (re)spoken, so a resume from a pause that cut an announcement
    /// short can say it again.
    public func isAtPhaseStart(at now: Date) -> Bool {
        guard let phase = phase(at: now) else { return false }
        return elapsed(at: now) == phase.start
    }

    /// Rewinds to the start of the current phase and freezes there until
    /// `finishAnnouncement`. Rewinding rather than freezing in place means
    /// the driver's polling interval never eats into the hold.
    public mutating func beginAnnouncement(at now: Date) {
        guard state == .running, let phase = phase(at: now) else { return }
        banked = phase.start
        runningSince = nil
        state = .announcing
    }

    public mutating func finishAnnouncement(at now: Date) {
        guard state == .announcing else { return }
        runningSince = now
        state = .running
    }

    public mutating func pause(at now: Date) {
        guard state == .running || state == .announcing else { return }
        banked = elapsed(at: now)
        runningSince = nil
        state = .paused
    }

    public mutating func resume(at now: Date) {
        guard state == .paused else { return }
        runningSince = now
        state = .running
    }

    public mutating func togglePause(at now: Date) {
        switch state {
        case .running, .announcing: pause(at: now)
        case .paused: resume(at: now)
        case .completed, .stopped: break
        }
    }

    /// Jumps to the start of the next phase, or to the end from the last one.
    /// Keeps whichever of running, announcing and paused the session was in;
    /// an announcing driver will announce the new phase.
    public mutating func skip(at now: Date) {
        let offset = elapsed(at: now)
        jump(to: timeline.phaseIndex(at: offset).map { timeline.phases[$0].end }
            ?? timeline.totalDuration, at: now)
    }

    /// Moves the cursor to `offset` on the session's clock — the start of a
    /// later exercise, say — with the same rules as `skip`.
    public mutating func jump(to offset: TimeInterval, at now: Date) {
        guard isLive else { return }
        banked = min(max(0, offset), timeline.totalDuration)
        if state == .running { runningSince = now }
    }

    /// Ends the session where it is. Terminal.
    public mutating func stop(at now: Date) {
        guard isLive else { return }
        banked = elapsed(at: now)
        runningSince = nil
        state = .stopped
    }

    /// Running, announcing or paused: not yet over.
    public var isLive: Bool {
        state == .running || state == .announcing || state == .paused
    }

    /// Flips to `.completed` the first time the session has run its course;
    /// returns true only on that transition, so a driver's completion side
    /// effects (tick the exercise, play the chime) happen once.
    public mutating func markCompletedIfFinished(at now: Date) -> Bool {
        guard isLive, isFinished(at: now) else { return false }
        banked = timeline.totalDuration
        runningSince = nil
        state = .completed
        return true
    }
}
