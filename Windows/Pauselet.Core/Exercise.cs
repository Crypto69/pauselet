namespace Pauselet.Core;

/// <summary>
/// One item in an exercise reminder's list: what to do, and how many sets of
/// how many repetitions. Typed by hand in the editor. (Mirrors Exercise.swift.)
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

    /// <summary>"3 × 10" — sets by reps, as the overlay shows it.</summary>
    public string Summary => $"{Sets} × {Reps}";

    /// <summary>A name to show and at least one set of at least one rep.</summary>
    public bool IsValid => Name.Trim().Length > 0 && Sets >= 1 && Reps >= 1;

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
    /// endings folded to "\n", rows that cannot be performed dropped, and an
    /// empty result collapsed to <c>null</c> so an ordinary reminder never
    /// carries an empty <c>exercises</c> array on disk.
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
            })
            .Where(exercise => exercise.IsValid)
            .ToList();
        return kept.Count == 0 ? null : kept;
    }
}
