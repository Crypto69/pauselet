using NodaTime;

namespace Pauselet.Core;

/// <summary>
/// One step of a coached programme — a hold or a paced rep, a rest, or the
/// lead-in before an exercise — with its place on the session's clock and
/// the exercise it belongs to. (Mirrors ExerciseSession.swift.)
/// </summary>
public sealed record ExercisePhase
{
    public enum Kind
    {
        GetReady,
        /// <summary>One held repetition of an exercise with a hold time.</summary>
        Hold,
        /// <summary>
        /// One repetition of an exercise without a hold time, paced at
        /// <see cref="ExerciseTimeline.RepSeconds"/> so the coach can count it.
        /// </summary>
        Rep,
        RestBetweenReps,
        RestBetweenSets,
        /// <summary>
        /// The gap between one exercise finishing and the next one's lead-in
        /// when a whole programme runs in sequence. Belongs to the exercise
        /// that is coming up.
        /// </summary>
        RestBetweenExercises,
    }

    public required Kind PhaseKind { get; init; }
    /// <summary>
    /// The exercise this phase belongs to. For a rest between exercises, the
    /// one about to start.
    /// </summary>
    public required Guid ExerciseId { get; init; }
    public required string ExerciseName { get; init; }
    /// <summary>
    /// 1-based. For a rest between sets, the set just finished. 0 for the
    /// lead-in and for a rest between exercises.
    /// </summary>
    public required int Set { get; init; }
    /// <summary>
    /// 1-based. The rep being performed, or — for a rest between reps — the
    /// rep just finished. 0 for the lead-in and for rests between sets or
    /// exercises.
    /// </summary>
    public required int Rep { get; init; }
    /// <summary>Offset from the start of the session, in seconds.</summary>
    public required double Start { get; init; }
    public required double Duration { get; init; }
    /// <summary>
    /// The spoken line for the start of this phase, composed when the
    /// timeline is built so it can mention the exercise before as well as the
    /// one at hand ("Pelvic tilts complete. Chin tucks. Get ready.").
    /// </summary>
    public required string Cue { get; init; }

    public double End => Start + Duration;

    /// <summary>The headline while this phase runs: "Set 1 · Rep 3", "Set 1 done", "Up next".</summary>
    public string Title => PhaseKind switch
    {
        Kind.GetReady => "Get ready",
        Kind.Hold or Kind.Rep or Kind.RestBetweenReps => $"Set {Set} · Rep {Rep}",
        Kind.RestBetweenSets => $"Set {Set} done",
        _ => "Up next",
    };

    /// <summary>What the countdown is counting: "Hold", "Go", "Rest".</summary>
    public string Label => PhaseKind switch
    {
        Kind.GetReady => "Get ready",
        Kind.Hold => "Hold",
        Kind.Rep => "Go",
        Kind.RestBetweenReps => "Rest",
        Kind.RestBetweenSets => "Rest between sets",
        _ => "Rest",
    };

    /// <summary>The Swift enum's raw value, which the phase tests compare against.</summary>
    public string KindName => PhaseKind switch
    {
        Kind.GetReady => "getReady",
        Kind.Hold => "hold",
        Kind.Rep => "rep",
        Kind.RestBetweenReps => "restBetweenReps",
        Kind.RestBetweenSets => "restBetweenSets",
        _ => "restBetweenExercises",
    };
}

/// <summary>Something the coach says, at an offset on the session's clock.</summary>
public sealed record ExerciseCue(double At, string Text);

/// <summary>
/// The whole coached programme for one exercise or a run of them, computed
/// once when Start is pressed: for each exercise a short lead-in, then for
/// every set and rep a hold (or a paced rep when there is no hold), with the
/// rests the exercise asks for in between; and between exercises the rest
/// the reminder asks for. Zero-length rests are not emitted.
///
/// Pure data, so the Mac, iOS and Windows coaches all run the same programme
/// and say the same things.
/// </summary>
public sealed class ExerciseTimeline
{
    /// <summary>
    /// Seconds between pressing Start and the first rep — long enough to get
    /// into position, short enough not to feel like waiting.
    /// </summary>
    public const double LeadInSeconds = 3;
    /// <summary>
    /// Seconds allowed for one rep of an exercise with no hold time, so it
    /// can be counted through rather than left to the person.
    /// </summary>
    public const int RepSeconds = 3;
    /// <summary>
    /// Holds at least this long get a spoken "Three. Two. One." at the end.
    /// Shorter holds do not: the opening cue would still be being spoken.
    /// </summary>
    public const int CountdownMinimumHold = 6;

    /// <summary>
    /// One exercise's span on the clock: from its lead-in to the end of its
    /// last set. A rest between exercises falls between one entry's
    /// <see cref="End"/> and the next one's <see cref="Start"/>.
    /// </summary>
    public sealed record Entry(Guid Id, string Name, double Start, double End);

    /// <summary>The exercises in the order they run.</summary>
    public IReadOnlyList<Entry> Entries { get; }
    public IReadOnlyList<ExercisePhase> Phases { get; }
    /// <summary>
    /// Sorted by <see cref="ExerciseCue.At"/>: one for the start of every
    /// phase, the countdown words inside long holds, and the closing line at
    /// <see cref="TotalDuration"/>.
    /// </summary>
    public IReadOnlyList<ExerciseCue> Cues { get; }

    public double TotalDuration => Phases.Count == 0 ? 0 : Phases[^1].End;

    /// <summary>
    /// "Exercise complete" for one exercise, "All exercises complete" for a
    /// run of them: the panel's headline at the end, and the closing cue.
    /// </summary>
    public string CompletionTitle =>
        Entries.Count > 1 ? "All exercises complete" : "Exercise complete";

    private ExerciseTimeline(IReadOnlyList<Entry> entries, IReadOnlyList<ExercisePhase> phases)
    {
        Entries = entries;
        Phases = phases;
        Cues = BuildCues(phases, CompletionTitle + ".");
    }

    /// <summary>The programme for one exercise; <c>null</c> when it has no sets or reps.</summary>
    public static ExerciseTimeline? For(Exercise exercise) => For([exercise]);

    /// <summary>
    /// The programme for <paramref name="exercises"/> in order, with
    /// <paramref name="restBetweenExercisesSeconds"/> between one finishing
    /// and the next one's lead-in. Exercises with no sets or reps are left
    /// out; <c>null</c> when nothing is left.
    /// </summary>
    public static ExerciseTimeline? For(
        IReadOnlyList<Exercise> exercises, int restBetweenExercisesSeconds = 0)
    {
        var runnable = exercises.Where(exercise => exercise.Sets >= 1 && exercise.Reps >= 1).ToList();
        if (runnable.Count == 0) return null;

        var phases = new List<ExercisePhase>();
        var entries = new List<Entry>();
        var cursor = 0.0;

        for (var index = 0; index < runnable.Count; index++)
        {
            var exercise = runnable[index];
            void Append(ExercisePhase.Kind kind, int set, int rep, int seconds, string cue)
            {
                phases.Add(new ExercisePhase
                {
                    PhaseKind = kind, ExerciseId = exercise.Id, ExerciseName = exercise.Name,
                    Set = set, Rep = rep, Start = cursor, Duration = seconds, Cue = cue,
                });
                cursor += seconds;
            }

            // The exercise before is signed off at the start of whatever
            // comes next, so its last rep is not talked over.
            var preamble = index > 0 ? $"{runnable[index - 1].Name} complete. " : "";
            if (index > 0 && restBetweenExercisesSeconds > 0)
            {
                Append(
                    ExercisePhase.Kind.RestBetweenExercises, 0, 0, restBetweenExercisesSeconds,
                    preamble + $"Rest for {Seconds(restBetweenExercisesSeconds)}. Next, {exercise.Name}.");
                preamble = "";
            }

            var entryStart = cursor;
            Append(
                ExercisePhase.Kind.GetReady, 0, 0, (int)LeadInSeconds,
                preamble + $"{exercise.Name}. Get ready.");

            for (var set = 1; set <= exercise.Sets; set++)
            {
                for (var rep = 1; rep <= exercise.Reps; rep++)
                {
                    if (exercise.HasHold)
                    {
                        Append(
                            ExercisePhase.Kind.Hold, set, rep, exercise.HoldSeconds,
                            rep == 1
                                ? $"Set {set}, rep 1. Hold for {Seconds(exercise.HoldSeconds)}."
                                : $"Rep {rep}. Hold.");
                    }
                    else
                    {
                        Append(
                            ExercisePhase.Kind.Rep, set, rep, RepSeconds,
                            rep == 1 ? $"Set {set}, rep 1." : $"Rep {rep}.");
                    }
                    if (rep < exercise.Reps && exercise.RestBetweenRepsSeconds > 0)
                    {
                        Append(
                            ExercisePhase.Kind.RestBetweenReps, set, rep,
                            exercise.RestBetweenRepsSeconds, "Rest.");
                    }
                }
                if (set < exercise.Sets && exercise.RestBetweenSetsSeconds > 0)
                {
                    Append(
                        ExercisePhase.Kind.RestBetweenSets, set, 0,
                        exercise.RestBetweenSetsSeconds,
                        $"Set {set} done. Rest for {Seconds(exercise.RestBetweenSetsSeconds)}.");
                }
            }

            entries.Add(new Entry(exercise.Id, exercise.Name, entryStart, cursor));
        }

        return new ExerciseTimeline(entries, phases);
    }

    /// <summary>
    /// Index of the phase containing <paramref name="offset"/>, treating each
    /// phase as half-open (<c>start ..&lt; end</c>); <c>null</c> at or past the
    /// end of the session. A negative offset counts as the start.
    /// </summary>
    public int? PhaseIndexAt(double offset)
    {
        if (offset >= TotalDuration) return null;
        var clamped = Math.Max(0, offset);
        for (var index = Phases.Count - 1; index >= 0; index--)
        {
            if (Phases[index].Start <= clamped) return index;
        }
        return null;
    }

    /// <summary>The exercises whose last set has run by <paramref name="offset"/>, in programme order.</summary>
    public IReadOnlyList<Guid> FinishedExerciseIds(double offset) =>
        Entries.Where(entry => offset >= entry.End).Select(entry => entry.Id).ToList();

    /// <summary>
    /// Where the exercise after <paramref name="id"/> begins — its lead-in,
    /// past any rest between the two — or the end of the session when it is
    /// the last (or not in the programme). What cancelling the exercise being
    /// coached jumps to.
    /// </summary>
    public double StartOfExerciseAfter(Guid id)
    {
        for (var index = 0; index < Entries.Count; index++)
        {
            if (Entries[index].Id != id) continue;
            return index + 1 < Entries.Count ? Entries[index + 1].Start : TotalDuration;
        }
        return TotalDuration;
    }

    /// <summary>"1 second" / "5 seconds".</summary>
    public static string Seconds(int count) => count == 1 ? "1 second" : $"{count} seconds";

    private static IReadOnlyList<ExerciseCue> BuildCues(
        IReadOnlyList<ExercisePhase> phases, string closing)
    {
        var cues = new List<ExerciseCue>();
        foreach (var phase in phases)
        {
            cues.Add(new ExerciseCue(phase.Start, phase.Cue));
            if (phase.PhaseKind == ExercisePhase.Kind.Hold
                && (int)phase.Duration >= CountdownMinimumHold)
            {
                cues.Add(new ExerciseCue(phase.End - 3, "Three."));
                cues.Add(new ExerciseCue(phase.End - 2, "Two."));
                cues.Add(new ExerciseCue(phase.End - 1, "One."));
            }
        }
        if (phases.Count > 0)
        {
            cues.Add(new ExerciseCue(phases[^1].End, closing));
        }
        // A stable sort, so the countdown words keep their order and a cue on
        // a phase boundary stays ahead of the next phase's own cue.
        return cues.OrderBy(cue => cue.At).ToList();
    }
}

/// <summary>
/// A cursor over a timeline, driven entirely by the <c>now</c> passed in —
/// never by counting ticks — so a stalled timer, a busy display or a laptop
/// lid closing cannot make the coach drift from wall time. Mirrors how the
/// scheduler takes <c>now</c> rather than reading a clock.
///
/// A talking coach needs one more thing: the hold must not start counting
/// while "Hold for 5 seconds" is still being said.
/// <see cref="BeginAnnouncement"/> freezes the clock at the start of the
/// current phase and <see cref="FinishAnnouncement"/> lets it run, so the
/// driver can wrap each spoken cue in the two and the seconds on screen are
/// the seconds the person gets.
/// </summary>
public sealed class ExerciseSession
{
    public enum SessionState
    {
        Running,
        /// <summary>Frozen at the start of a phase while its cue is being spoken.</summary>
        Announcing,
        Paused,
        Completed,
        Stopped,
    }

    /// <summary>
    /// Where the cursor is: a phase with what is left of it, or past the end.
    /// <see cref="Index"/> and the rest are meaningless when
    /// <see cref="IsComplete"/>.
    /// </summary>
    public readonly record struct Position(
        bool IsComplete, int Index, double Remaining, double Progress)
    {
        public static readonly Position Complete = new(true, 0, 0, 0);
    }

    public ExerciseTimeline Timeline { get; }
    public SessionState State { get; private set; }
    /// <summary>Session time accumulated by run segments that have ended.</summary>
    private double _banked;
    /// <summary>When the current run segment began; <c>null</c> unless running.</summary>
    private Instant? _runningSince;

    public ExerciseSession(ExerciseTimeline timeline, Instant startedAt)
    {
        Timeline = timeline;
        State = SessionState.Running;
        _banked = 0;
        _runningSince = startedAt;
    }

    /// <summary>
    /// Session time at <paramref name="now"/>, clamped to the timeline's
    /// length. A clock set backwards never makes it shrink below what was
    /// banked.
    /// </summary>
    public double Elapsed(Instant now)
    {
        var value = _banked;
        if (_runningSince is { } since)
        {
            value += Math.Max(0, (now - since).TotalSeconds);
        }
        return Math.Min(value, Timeline.TotalDuration);
    }

    public Position PositionAt(Instant now)
    {
        var offset = Elapsed(now);
        if (Timeline.PhaseIndexAt(offset) is not { } index) return Position.Complete;
        var phase = Timeline.Phases[index];
        var progress = phase.Duration > 0 ? (offset - phase.Start) / phase.Duration : 1;
        return new Position(false, index, phase.End - offset, progress);
    }

    public ExercisePhase? PhaseAt(Instant now) =>
        Timeline.PhaseIndexAt(Elapsed(now)) is { } index ? Timeline.Phases[index] : null;

    /// <summary>
    /// How many cues have fallen due by <paramref name="now"/>. A driver
    /// remembers the last count it acted on and speaks only the newest cue
    /// past it, so a clock that jumps (sleep, a stalled timer) yields one
    /// utterance, not a burst.
    /// </summary>
    public int CueCount(Instant now)
    {
        var offset = Elapsed(now);
        for (var index = 0; index < Timeline.Cues.Count; index++)
        {
            if (Timeline.Cues[index].At > offset) return index;
        }
        return Timeline.Cues.Count;
    }

    public bool IsFinished(Instant now) => Elapsed(now) >= Timeline.TotalDuration;

    /// <summary>
    /// True when nothing of the current phase has run yet — the moment a cue
    /// is (re)spoken, so a resume from a pause that cut an announcement short
    /// can say it again.
    /// </summary>
    public bool IsAtPhaseStart(Instant now) =>
        PhaseAt(now) is { } phase && Elapsed(now) == phase.Start;

    /// <summary>
    /// Rewinds to the start of the current phase and freezes there until
    /// <see cref="FinishAnnouncement"/>. Rewinding rather than freezing in
    /// place means the driver's polling interval never eats into the hold.
    /// </summary>
    public void BeginAnnouncement(Instant now)
    {
        if (State != SessionState.Running || PhaseAt(now) is not { } phase) return;
        _banked = phase.Start;
        _runningSince = null;
        State = SessionState.Announcing;
    }

    public void FinishAnnouncement(Instant now)
    {
        if (State != SessionState.Announcing) return;
        _runningSince = now;
        State = SessionState.Running;
    }

    public void Pause(Instant now)
    {
        if (State != SessionState.Running && State != SessionState.Announcing) return;
        _banked = Elapsed(now);
        _runningSince = null;
        State = SessionState.Paused;
    }

    public void Resume(Instant now)
    {
        if (State != SessionState.Paused) return;
        _runningSince = now;
        State = SessionState.Running;
    }

    public void TogglePause(Instant now)
    {
        switch (State)
        {
            case SessionState.Running or SessionState.Announcing: Pause(now); break;
            case SessionState.Paused: Resume(now); break;
        }
    }

    /// <summary>
    /// Jumps to the start of the next phase, or to the end from the last one.
    /// Keeps whichever of running, announcing and paused the session was in;
    /// an announcing driver will announce the new phase.
    /// </summary>
    public void Skip(Instant now)
    {
        var offset = Elapsed(now);
        Jump(
            Timeline.PhaseIndexAt(offset) is { } index
                ? Timeline.Phases[index].End
                : Timeline.TotalDuration,
            now);
    }

    /// <summary>
    /// Moves the cursor to <paramref name="offset"/> on the session's clock —
    /// the start of a later exercise, say — with the same rules as
    /// <see cref="Skip"/>.
    /// </summary>
    public void Jump(double offset, Instant now)
    {
        if (!IsLive) return;
        _banked = Math.Min(Math.Max(0, offset), Timeline.TotalDuration);
        if (State == SessionState.Running) _runningSince = now;
    }

    /// <summary>Ends the session where it is. Terminal.</summary>
    public void Stop(Instant now)
    {
        if (!IsLive) return;
        _banked = Elapsed(now);
        _runningSince = null;
        State = SessionState.Stopped;
    }

    /// <summary>Running, announcing or paused: not yet over.</summary>
    public bool IsLive =>
        State is SessionState.Running or SessionState.Announcing or SessionState.Paused;

    /// <summary>
    /// Flips to <see cref="SessionState.Completed"/> the first time the
    /// session has run its course; returns true only on that transition, so a
    /// driver's completion side effects (tick the exercise, play the chime)
    /// happen once.
    /// </summary>
    public bool MarkCompletedIfFinished(Instant now)
    {
        if (!IsLive || !IsFinished(now)) return false;
        _banked = Timeline.TotalDuration;
        _runningSince = null;
        State = SessionState.Completed;
        return true;
    }
}
