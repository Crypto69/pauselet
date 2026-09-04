using NodaTime;

namespace Pauselet.Core;

/// <summary>
/// One step of a guided exercise — a hold, a rest, or the lead-in — with its
/// place on the session's clock. (Mirrors ExerciseSession.swift.)
/// </summary>
public sealed record ExercisePhase
{
    public enum Kind
    {
        GetReady,
        Hold,
        RestBetweenReps,
        RestBetweenSets,
    }

    public required Kind PhaseKind { get; init; }
    /// <summary>1-based. For a rest between sets, the set just finished.</summary>
    public required int Set { get; init; }
    /// <summary>
    /// 1-based. The rep being held, or — for a rest between reps — the rep
    /// just finished. 0 for the lead-in and for a rest between sets.
    /// </summary>
    public required int Rep { get; init; }
    /// <summary>Offset from the start of the session, in seconds.</summary>
    public required double Start { get; init; }
    public required double Duration { get; init; }

    public double End => Start + Duration;

    /// <summary>The headline while this phase runs: "Set 1 · Rep 3", "Set 1 done".</summary>
    public string Title => PhaseKind switch
    {
        Kind.GetReady => "Get ready",
        Kind.Hold or Kind.RestBetweenReps => $"Set {Set} · Rep {Rep}",
        _ => $"Set {Set} done",
    };

    /// <summary>What the countdown is counting: "Hold", "Rest".</summary>
    public string Label => PhaseKind switch
    {
        Kind.GetReady => "Get ready",
        Kind.Hold => "Hold",
        Kind.RestBetweenReps => "Rest",
        _ => "Rest between sets",
    };

    /// <summary>The Swift enum's raw value, which the phase tests compare against.</summary>
    public string KindName => PhaseKind switch
    {
        Kind.GetReady => "getReady",
        Kind.Hold => "hold",
        Kind.RestBetweenReps => "restBetweenReps",
        _ => "restBetweenSets",
    };
}

/// <summary>Something the coach says, at an offset on the session's clock.</summary>
public sealed record ExerciseCue(double At, string Text);

/// <summary>
/// The whole guided programme for one exercise, computed once when Start is
/// pressed: a short lead-in, then for every set and rep a hold, with the
/// rests the exercise asks for in between. Zero-length rests are not emitted.
///
/// Pure data, so the Mac, iOS and Windows coaches all run the same programme
/// and say the same things.
/// </summary>
public sealed class ExerciseTimeline
{
    /// <summary>
    /// Seconds between pressing Start and the first hold — long enough to get
    /// into position, short enough not to feel like waiting.
    /// </summary>
    public const double LeadInSeconds = 3;
    /// <summary>
    /// Holds at least this long get a spoken "Three. Two. One." at the end.
    /// Shorter holds do not: the opening cue would still be being spoken.
    /// </summary>
    public const int CountdownMinimumHold = 6;

    public Guid ExerciseId { get; }
    public string ExerciseName { get; }
    public IReadOnlyList<ExercisePhase> Phases { get; }
    /// <summary>
    /// Sorted by <see cref="ExerciseCue.At"/>: one for the start of every
    /// phase, the countdown words inside long holds, and "Exercise complete."
    /// at <see cref="TotalDuration"/>.
    /// </summary>
    public IReadOnlyList<ExerciseCue> Cues { get; }

    public double TotalDuration => Phases.Count == 0 ? 0 : Phases[^1].End;

    private ExerciseTimeline(
        Guid exerciseId, string exerciseName, IReadOnlyList<ExercisePhase> phases)
    {
        ExerciseId = exerciseId;
        ExerciseName = exerciseName;
        Phases = phases;
        Cues = BuildCues(phases, exerciseName);
    }

    /// <summary><c>null</c> unless the exercise is guided (has a hold time).</summary>
    public static ExerciseTimeline? For(Exercise exercise)
    {
        if (!exercise.IsGuided || exercise.Sets < 1 || exercise.Reps < 1) return null;

        var phases = new List<ExercisePhase>();
        var cursor = 0.0;
        void Append(ExercisePhase.Kind kind, int set, int rep, int seconds)
        {
            phases.Add(new ExercisePhase
            {
                PhaseKind = kind, Set = set, Rep = rep, Start = cursor, Duration = seconds,
            });
            cursor += seconds;
        }

        phases.Add(new ExercisePhase
        {
            PhaseKind = ExercisePhase.Kind.GetReady,
            Set = 0, Rep = 0, Start = 0, Duration = LeadInSeconds,
        });
        cursor = LeadInSeconds;

        for (var set = 1; set <= exercise.Sets; set++)
        {
            for (var rep = 1; rep <= exercise.Reps; rep++)
            {
                Append(ExercisePhase.Kind.Hold, set, rep, exercise.HoldSeconds);
                if (rep < exercise.Reps && exercise.RestBetweenRepsSeconds > 0)
                {
                    Append(
                        ExercisePhase.Kind.RestBetweenReps, set, rep,
                        exercise.RestBetweenRepsSeconds);
                }
            }
            if (set < exercise.Sets && exercise.RestBetweenSetsSeconds > 0)
            {
                Append(
                    ExercisePhase.Kind.RestBetweenSets, set, 0,
                    exercise.RestBetweenSetsSeconds);
            }
        }

        return new ExerciseTimeline(exercise.Id, exercise.Name, phases);
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

    /// <summary>The spoken line for the start of <paramref name="phase"/>.</summary>
    public static string Cue(ExercisePhase phase, string exerciseName) => phase.PhaseKind switch
    {
        ExercisePhase.Kind.GetReady => $"{exerciseName}. Get ready.",
        ExercisePhase.Kind.Hold when phase.Rep == 1 =>
            $"Set {phase.Set}, rep 1. Hold for {Seconds((int)phase.Duration)}.",
        ExercisePhase.Kind.Hold => $"Rep {phase.Rep}. Hold.",
        ExercisePhase.Kind.RestBetweenReps => "Rest.",
        _ => $"Set {phase.Set} done. Rest for {Seconds((int)phase.Duration)}.",
    };

    /// <summary>"1 second" / "5 seconds".</summary>
    public static string Seconds(int count) => count == 1 ? "1 second" : $"{count} seconds";

    private static IReadOnlyList<ExerciseCue> BuildCues(
        IReadOnlyList<ExercisePhase> phases, string exerciseName)
    {
        var cues = new List<ExerciseCue>();
        foreach (var phase in phases)
        {
            cues.Add(new ExerciseCue(phase.Start, Cue(phase, exerciseName)));
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
            cues.Add(new ExerciseCue(phases[^1].End, "Exercise complete."));
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
        if (!IsLive) return;
        var offset = Elapsed(now);
        _banked = Timeline.PhaseIndexAt(offset) is { } index
            ? Timeline.Phases[index].End
            : Timeline.TotalDuration;
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
