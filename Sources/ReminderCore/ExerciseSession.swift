import Foundation

/// One step of a guided exercise — a hold, a rest, or the lead-in — with its
/// place on the session's clock.
public struct ExercisePhase: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case getReady
        case hold
        case restBetweenReps
        case restBetweenSets
    }

    public let kind: Kind
    /// 1-based. For a rest between sets, the set just finished.
    public let set: Int
    /// 1-based. The rep being held, or — for a rest between reps — the rep
    /// just finished. 0 for the lead-in and for a rest between sets.
    public let rep: Int
    /// Offset from the start of the session.
    public let start: TimeInterval
    public let duration: TimeInterval

    public var end: TimeInterval { start + duration }

    public init(kind: Kind, set: Int, rep: Int, start: TimeInterval, duration: TimeInterval) {
        self.kind = kind
        self.set = set
        self.rep = rep
        self.start = start
        self.duration = duration
    }

    /// The headline while this phase runs: "Set 1 · Rep 3", "Set 1 done".
    public var title: String {
        switch kind {
        case .getReady: return "Get ready"
        case .hold, .restBetweenReps: return "Set \(set) · Rep \(rep)"
        case .restBetweenSets: return "Set \(set) done"
        }
    }

    /// What the countdown is counting: "Hold", "Rest".
    public var label: String {
        switch kind {
        case .getReady: return "Get ready"
        case .hold: return "Hold"
        case .restBetweenReps: return "Rest"
        case .restBetweenSets: return "Rest between sets"
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

/// The whole guided programme for one exercise, computed once when Start is
/// pressed: a short lead-in, then for every set and rep a hold, with the
/// rests the exercise asks for in between. Zero-length rests are not emitted.
///
/// Pure data, so the Mac, iOS and Windows coaches all run the same programme
/// and say the same things.
public struct ExerciseTimeline: Equatable, Sendable {
    /// Seconds between pressing Start and the first hold — long enough to get
    /// into position, short enough not to feel like waiting.
    public static let leadInSeconds: TimeInterval = 3
    /// Holds at least this long get a spoken "Three. Two. One." at the end.
    /// Shorter holds do not: the opening cue would still be being spoken.
    public static let countdownMinimumHold = 6

    public let exerciseID: UUID
    public let exerciseName: String
    public let phases: [ExercisePhase]
    /// Sorted by `at`: one for the start of every phase, the countdown words
    /// inside long holds, and "Exercise complete." at `totalDuration`.
    public let cues: [ExerciseCue]

    public var totalDuration: TimeInterval { phases.last?.end ?? 0 }

    /// `nil` unless the exercise is guided (has a hold time).
    public init?(exercise: Exercise) {
        guard exercise.isGuided, exercise.sets >= 1, exercise.reps >= 1 else { return nil }

        var phases: [ExercisePhase] = []
        var cursor: TimeInterval = 0
        func append(_ kind: ExercisePhase.Kind, set: Int, rep: Int, seconds: Int) {
            phases.append(ExercisePhase(
                kind: kind, set: set, rep: rep, start: cursor, duration: TimeInterval(seconds)
            ))
            cursor += TimeInterval(seconds)
        }

        phases.append(ExercisePhase(
            kind: .getReady, set: 0, rep: 0, start: 0, duration: Self.leadInSeconds
        ))
        cursor = Self.leadInSeconds

        for set in 1...exercise.sets {
            for rep in 1...exercise.reps {
                append(.hold, set: set, rep: rep, seconds: exercise.holdSeconds)
                if rep < exercise.reps, exercise.restBetweenRepsSeconds > 0 {
                    append(.restBetweenReps, set: set, rep: rep,
                           seconds: exercise.restBetweenRepsSeconds)
                }
            }
            if set < exercise.sets, exercise.restBetweenSetsSeconds > 0 {
                append(.restBetweenSets, set: set, rep: 0,
                       seconds: exercise.restBetweenSetsSeconds)
            }
        }

        exerciseID = exercise.id
        exerciseName = exercise.name
        self.phases = phases
        cues = Self.cues(for: phases, exerciseName: exercise.name)
    }

    /// Index of the phase containing `offset`, treating each phase as
    /// half-open (`start ..< end`); `nil` at or past the end of the session.
    /// A negative offset counts as the start.
    public func phaseIndex(at offset: TimeInterval) -> Int? {
        guard offset < totalDuration else { return nil }
        let clamped = max(0, offset)
        return phases.lastIndex { $0.start <= clamped }
    }

    /// The spoken line for the start of `phase`.
    public static func cue(for phase: ExercisePhase, exerciseName: String) -> String {
        switch phase.kind {
        case .getReady:
            return "\(exerciseName). Get ready."
        case .hold where phase.rep == 1:
            return "Set \(phase.set), rep 1. Hold for \(seconds(Int(phase.duration)))."
        case .hold:
            return "Rep \(phase.rep). Hold."
        case .restBetweenReps:
            return "Rest."
        case .restBetweenSets:
            return "Set \(phase.set) done. Rest for \(seconds(Int(phase.duration)))."
        }
    }

    /// "1 second" / "5 seconds".
    public static func seconds(_ count: Int) -> String {
        count == 1 ? "1 second" : "\(count) seconds"
    }

    private static func cues(for phases: [ExercisePhase], exerciseName: String) -> [ExerciseCue] {
        var cues: [ExerciseCue] = []
        for phase in phases {
            cues.append(ExerciseCue(at: phase.start, text: cue(for: phase, exerciseName: exerciseName)))
            if phase.kind == .hold, Int(phase.duration) >= countdownMinimumHold {
                cues.append(ExerciseCue(at: phase.end - 3, text: "Three."))
                cues.append(ExerciseCue(at: phase.end - 2, text: "Two."))
                cues.append(ExerciseCue(at: phase.end - 1, text: "One."))
            }
        }
        if let last = phases.last {
            cues.append(ExerciseCue(at: last.end, text: "Exercise complete."))
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
        guard isLive else { return }
        let offset = elapsed(at: now)
        banked = timeline.phaseIndex(at: offset).map { timeline.phases[$0].end }
            ?? timeline.totalDuration
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
