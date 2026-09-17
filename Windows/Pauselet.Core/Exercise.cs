namespace Pauselet.Core;

/// <summary>
/// One item in an exercise reminder's list: what to do, how many sets of how
/// many repetitions, and — optionally — how long each rep is held and how long
/// to rest. Typed by hand in the editor. (Mirrors Exercise.swift.)
///
/// Every exercise can be coached set by set and rep by rep. One with a hold
/// time counts each rep down; one without is paced at a fixed tempo instead,
/// so a whole programme can run through in sequence without anyone pressing
/// Start between exercises.
/// </summary>
public sealed record Exercise
{
    /// <summary>
    /// Stable identity for the editor's rows and the overlay's rows.
    /// </summary>
    public Guid Id { get; init; } = Guid.NewGuid();
    public required string Name { get; init; }
    /// <summary>
    /// Multi-line free text. Stored with "\n" line endings only, so the same
    /// exercise serializes identically whichever platform typed it — see
    /// <see cref="Normalized"/>.
    /// </summary>
    public string Instructions { get; init; } = "";
    public int Sets { get; init; } = 1;
    public int Reps { get; init; } = 10;
    /// <summary>
    /// Seconds each rep is held. 0 means the rep is not held: the coach paces
    /// it at <see cref="ExerciseTimeline.RepSeconds"/> rather than counting a hold.
    /// </summary>
    public int HoldSeconds { get; init; }
    /// <summary>Seconds of rest after every rep except the last of a set. 0 = none.</summary>
    public int RestBetweenRepsSeconds { get; init; }
    /// <summary>Seconds of rest after every set except the last. 0 = none.</summary>
    public int RestBetweenSetsSeconds { get; init; }

    /// <summary>Editor bounds for the timing fields; the same on every platform.</summary>
    public const int MaxHoldSeconds = 300;
    public const int MaxRestSeconds = 600;
    /// <summary>
    /// Bounds for the counts. A pasted or model-supplied "99999999999 reps"
    /// must not become a timeline with that many phases.
    /// </summary>
    public const int MinSets = 1, MaxSets = 20;
    public const int MinReps = 1, MaxReps = 100;

    /// <summary>
    /// True when each rep is held for a time, so the coach counts the hold
    /// down rather than pacing the rep.
    /// </summary>
    public bool HasHold => HoldSeconds > 0;

    /// <summary>
    /// "3 × 10" — sets by reps, as the overlay shows it; "3 × 10 · hold 5 s"
    /// when the reps are held.
    /// </summary>
    public string Summary => HasHold ? $"{Sets} × {Reps} · hold {HoldSeconds} s" : $"{Sets} × {Reps}";

    /// <summary>
    /// A name to show, at least one set of at least one rep, and no negative timing.
    /// </summary>
    public bool IsValid =>
        Name.Trim().Length > 0 && Sets >= 1 && Reps >= 1
        && HoldSeconds >= 0 && RestBetweenRepsSeconds >= 0 && RestBetweenSetsSeconds >= 0;

    /// <summary>
    /// "3 exercises · 9 sets" for list rows, where the full list will not
    /// fit; <c>null</c> for an empty list.
    /// </summary>
    public static string? SummaryOf(IReadOnlyList<Exercise>? exercises)
    {
        if (exercises is not { Count: > 0 }) return null;
        // Counts are clamped by Normalized, but a hand-edited file is not; an
        // absurd total must not overflow the list row.
        var sets = exercises.Sum(exercise => (long)Math.Clamp(exercise.Sets, MinSets, MaxSets));
        var exerciseWord = exercises.Count == 1 ? "exercise" : "exercises";
        var setWord = sets == 1 ? "set" : "sets";
        return $"{exercises.Count} {exerciseWord} · {sets} {setWord}";
    }

    /// <summary>
    /// What the editor stores: names and instructions trimmed, Windows line
    /// endings folded to "\n", timings clamped into their editor ranges, rows
    /// that cannot be performed dropped, and an empty result collapsed to
    /// <c>null</c> so an ordinary reminder never carries an empty
    /// <c>exercises</c> array on disk.
    /// </summary>
    public static IReadOnlyList<Exercise>? Normalized(IEnumerable<Exercise> exercises)
    {
        var kept = exercises
            .Select(exercise => exercise with
            {
                Name = exercise.Name.Trim(),
                Instructions = exercise.Instructions
                    .Replace("\r\n", "\n")
                    .Replace("\r", "\n")
                    .Trim(),
                // Only the top is clamped: a row with no sets or reps is not
                // performable and is dropped below rather than promoted to one.
                Sets = Math.Min(exercise.Sets, MaxSets),
                Reps = Math.Min(exercise.Reps, MaxReps),
                HoldSeconds = Math.Clamp(exercise.HoldSeconds, 0, MaxHoldSeconds),
                RestBetweenRepsSeconds = Math.Clamp(exercise.RestBetweenRepsSeconds, 0, MaxRestSeconds),
                RestBetweenSetsSeconds = Math.Clamp(exercise.RestBetweenSetsSeconds, 0, MaxRestSeconds),
            })
            .Where(exercise => exercise.IsValid)
            .ToList();
        return kept.Count == 0 ? null : kept;
    }
}
