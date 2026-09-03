namespace Pauselet.Core;

/// <summary>
/// One item in an exercise reminder's list: what to do, how many sets of how
/// many repetitions, and — optionally — how long each rep is held and how long
/// to rest. Typed by hand in the editor. (Mirrors Exercise.swift.)
///
/// An exercise with a hold time is "guided": the takeover can coach it set by
/// set and rep by rep. One without a hold is untimed and only has its tick box.
/// </summary>
public sealed record Exercise
{
    /// <summary>
    /// Stable identity for the editor's rows and the overlay's tick boxes.
    /// </summary>
    public Guid Id { get; init; } = Guid.NewGuid();
    public required string Name { get; init; }
    /// <summary>
    /// Multi-line free text. Stored with "\n" line endings only, so the same
    /// exercise serializes identically whichever platform typed it — see
    /// <see cref="Normalized"/>.
    /// </summary>
    public string Instructions { get; init; } = "";
    public int Sets { get; init; } = 3;
    public int Reps { get; init; } = 10;
    /// <summary>
    /// Seconds each rep is held. 0 means untimed: the overlay shows a plain
    /// tick box and the coach leaves the exercise alone.
    /// </summary>
    public int HoldSeconds { get; init; }
    /// <summary>Seconds of rest after every rep except the last of a set. 0 = none.</summary>
    public int RestBetweenRepsSeconds { get; init; }
    /// <summary>Seconds of rest after every set except the last. 0 = none.</summary>
    public int RestBetweenSetsSeconds { get; init; }

    /// <summary>Editor bounds for the timing fields; the same on every platform.</summary>
    public const int MaxHoldSeconds = 300;
    public const int MaxRestSeconds = 600;

    /// <summary>True when the exercise has a hold time, so the overlay can coach it.</summary>
    public bool IsGuided => HoldSeconds > 0;

    /// <summary>
    /// "3 × 10" — sets by reps, as the overlay shows it; "3 × 10 · hold 5 s"
    /// when the exercise is guided.
    /// </summary>
    public string Summary => IsGuided ? $"{Sets} × {Reps} · hold {HoldSeconds} s" : $"{Sets} × {Reps}";

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
        var sets = exercises.Sum(exercise => exercise.Sets);
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
                HoldSeconds = Math.Clamp(exercise.HoldSeconds, 0, MaxHoldSeconds),
                RestBetweenRepsSeconds = Math.Clamp(exercise.RestBetweenRepsSeconds, 0, MaxRestSeconds),
                RestBetweenSetsSeconds = Math.Clamp(exercise.RestBetweenSetsSeconds, 0, MaxRestSeconds),
            })
            .Where(exercise => exercise.IsValid)
            .ToList();
        return kept.Count == 0 ? null : kept;
    }
}
