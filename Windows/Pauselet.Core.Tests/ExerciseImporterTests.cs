using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// What a person can paste from a physiotherapist's handout and get back as
/// exercises: the phrasings that must be understood, the ones that must be
/// left alone, and the guarantee that whatever comes out is something the
/// editor would have accepted if it had been typed by hand.
/// (Mirrors ExerciseImporterTests.swift, case for case.)
/// </summary>
public class ExerciseImporterTests
{
    // MARK: - Helpers

    /// <summary>One exercise from text, unwrapped — most cases parse a single line.</summary>
    private static Exercise ParseOne(string text)
    {
        var exercises = ExerciseImporter.Parse(text);
        Assert.True(exercises.Count == 1, $"Expected exactly one exercise from: {text}");
        return exercises[0];
    }

    /// <summary>
    /// "name | sets × reps | hold | rest reps | rest sets" — the whole parse in
    /// one line, so a table of cases diffs like a table.
    /// </summary>
    private static string Describe(Exercise exercise) =>
        $"{exercise.Name} | {exercise.Sets}×{exercise.Reps} | {exercise.HoldSeconds} | "
        + $"{exercise.RestBetweenRepsSeconds} | {exercise.RestBetweenSetsSeconds}";

    // MARK: - Sets and reps

    [Fact]
    public void ParsesTheCommonSetsAndRepsPhrasings()
    {
        string[] cases =
        [
            "3 sets of 10 chin tucks",
            "chin tucks 3 x 10",
            "chin tucks 3 × 10",
            "chin tucks, 3 sets of 10 reps",
            "chin tucks: 10 reps, 3 sets",
            "three sets of ten chin tucks",
        ];
        var parsed = cases.Select(text =>
        {
            var exercise = ExerciseImporter.Parse(text).FirstOrDefault();
            return exercise is null ? $"{text} → nothing" : $"{exercise.Sets}×{exercise.Reps}";
        }).ToArray();
        Assert.Equal(["3×10", "3×10", "3×10", "3×10", "3×10", "3×10"], parsed);
    }

    [Fact]
    public void UnstatedCountsKeepTheEditorDefaults()
    {
        var exercise = ParseOne("Shoulder rolls");
        Assert.Equal(3, exercise.Sets);
        Assert.Equal(10, exercise.Reps);
        Assert.Equal(0, exercise.HoldSeconds);
    }

    // MARK: - Hold

    [Fact]
    public void ParsesHoldPhrasings()
    {
        string[] cases =
        [
            "Chin tucks 3 x 10, hold 5 seconds",
            "Chin tucks 3 x 10, hold for 5 seconds",
            "Chin tucks 3 x 10, hold 5s",
            "Chin tucks 3 x 10, hold 5 sec",
            "Chin tucks 3 x 10, 5 second hold",
            "Chin tucks 3 x 10, hold five seconds",
        ];
        var parsed = cases
            .Select(text => ExerciseImporter.Parse(text).FirstOrDefault()?.HoldSeconds ?? -1)
            .ToArray();
        Assert.Equal([5, 5, 5, 5, 5, 5], parsed);
    }

    [Fact]
    public void ABareHoldNumberMeansSeconds()
    {
        Assert.Equal(5, ParseOne("Chin tucks 3 x 10, hold 5").HoldSeconds);
    }

    [Fact]
    public void MinutesConvertToSeconds()
    {
        Assert.Equal(120, ParseOne("Plank 1 x 1, hold 2 minutes").HoldSeconds);
        Assert.Equal(120, ParseOne("Plank 1 x 1, hold 2 min").HoldSeconds);
    }

    [Fact]
    public void AHoldMakesTheExerciseGuided()
    {
        Assert.True(ParseOne("Chin tucks 3 x 10 hold 5 seconds").IsGuided);
        Assert.False(ParseOne("Shoulder rolls 3 x 10").IsGuided);
    }

    // MARK: - Rest

    [Fact]
    public void ParsesRestBetweenSets()
    {
        var exercise = ParseOne("Squats 3 x 10, rest 30 seconds between sets");
        Assert.Equal(30, exercise.RestBetweenSetsSeconds);
        Assert.Equal(0, exercise.RestBetweenRepsSeconds);
    }

    [Fact]
    public void ParsesRestBetweenReps()
    {
        var exercise = ParseOne("Squats 3 x 10, rest 10 seconds between reps");
        Assert.Equal(10, exercise.RestBetweenRepsSeconds);
        Assert.Equal(0, exercise.RestBetweenSetsSeconds);
    }

    /// <summary>
    /// The set rest must be claimed first; the looser rep pattern would
    /// otherwise swallow "rest 30 seconds between sets".
    /// </summary>
    [Fact]
    public void ParsesBothRestsInOneLine()
    {
        var exercise = ParseOne(
            "Squats 3 x 10, rest 10 seconds between reps and 30 seconds between sets");
        Assert.Equal(10, exercise.RestBetweenRepsSeconds);
        Assert.Equal(30, exercise.RestBetweenSetsSeconds);
    }

    // MARK: - The whole table

    [Fact]
    public void RealisticPhysioLines()
    {
        string[] cases =
        [
            "3 sets of 10 chin tucks, hold 5 seconds, rest 30 seconds between sets",
            "Wall slides 3 x 15",
            "Bird dog: 2 sets of 8 each side, hold 10 seconds",
            "Glute bridges 4 x 12, rest 45 seconds between sets",
        ];
        var parsed = cases
            .Select(text => ExerciseImporter.Parse(text).FirstOrDefault())
            .Where(exercise => exercise is not null)
            .Select(exercise => Describe(exercise!))
            .ToArray();
        Assert.Equal(
        [
            "Chin tucks | 3×10 | 5 | 0 | 30",
            "Wall slides | 3×15 | 0 | 0 | 0",
            "Bird dog | 2×8 | 10 | 0 | 0",
            "Glute bridges | 4×12 | 0 | 0 | 45",
        ], parsed);
    }

    // MARK: - Multiple exercises

    [Fact]
    public void ParsesABulletedList()
    {
        var text = """
        - Chin tucks 3 x 10, hold 5 seconds
        - Wall slides 3 x 15
        - Glute bridges 4 x 12
        """;
        var parsed = ExerciseImporter.Parse(text).Select(Describe).ToArray();
        Assert.Equal(
        [
            "Chin tucks | 3×10 | 5 | 0 | 0",
            "Wall slides | 3×15 | 0 | 0 | 0",
            "Glute bridges | 4×12 | 0 | 0 | 0",
        ], parsed);
    }

    [Fact]
    public void ParsesANumberedList()
    {
        var text = """
        1. Chin tucks 3 x 10
        2. Wall slides 3 x 15
        """;
        Assert.Equal(
            ["Chin tucks", "Wall slides"],
            ExerciseImporter.Parse(text).Select(exercise => exercise.Name).ToArray());
    }

    /// <summary>A numbered marker must not be mistaken for the exercise's set count.</summary>
    [Fact]
    public void ANumberedMarkerIsNotReadAsACount()
    {
        var parsed = ExerciseImporter.Parse("2. Wall slides 3 x 15");
        Assert.Equal(3, parsed.FirstOrDefault()?.Sets);
        Assert.Equal(15, parsed.FirstOrDefault()?.Reps);
    }

    [Fact]
    public void ParsesBlankLineSeparatedParagraphs()
    {
        var text = """
        Chin tucks 3 x 10, hold 5 seconds

        Wall slides 3 x 15
        """;
        Assert.Equal(
            ["Chin tucks", "Wall slides"],
            ExerciseImporter.Parse(text).Select(exercise => exercise.Name).ToArray());
    }

    [Fact]
    public void InstructionsKeepTheProseAfterTheName()
    {
        var text = "Chin tucks 3 x 10\nKeep your chin level and your shoulders relaxed.";
        var exercise = ParseOne(text);
        Assert.Equal("Chin tucks", exercise.Name);
        Assert.Equal("Keep your chin level and your shoulders relaxed.", exercise.Instructions);
    }

    // MARK: - Continuous prose

    /// <summary>
    /// A handout is often one flowing paragraph with no bullets and no blank
    /// lines. Before this was handled the whole thing parsed as a single
    /// exercise called "Chin tucks,, then", with the rest swept into its
    /// instructions.
    /// </summary>
    [Fact]
    public void ParsesAParagraphThatRunsExercisesTogether()
    {
        var text = "3 sets of 10 chin tucks, holding for 5 seconds, then resting 30 "
            + "seconds between sets. Then perform wall slides 3 times for 15 seconds, "
            + "followed by 30 seconds of rest. Finally, perform bicep curls mimicking "
            + "hand-to-mouth movements: 3 sets of 10 reps, with 30 seconds of rest "
            + "between each rep.";
        var parsed = ExerciseImporter.Parse(text);
        Assert.True(parsed.Count == 3, "One exercise per clause, not one for the paragraph");
        Assert.Equal(
            ["Chin tucks", "Wall slides", "Bicep curls mimicking hand-to-mouth movements"],
            parsed.Select(exercise => exercise.Name).ToArray());
        Assert.Equal(5, parsed[0].HoldSeconds);
        Assert.Equal(30, parsed[0].RestBetweenSetsSeconds);
        Assert.Equal(15, parsed[1].HoldSeconds);
        Assert.Equal(30, parsed[2].RestBetweenRepsSeconds);
    }

    /// <summary>
    /// The hand-over word only splits when another exercise follows it, so an
    /// instruction that merely contains "then" stays in one piece.
    /// </summary>
    [Fact]
    public void ThenInsideAnInstructionDoesNotSplit()
    {
        var parsed = ExerciseImporter.Parse("Chin tucks 3 x 10. Hold, then release slowly.");
        Assert.Single(parsed);
        Assert.Equal("Chin tucks", parsed.FirstOrDefault()?.Name);
    }

    [Fact]
    public void AnImperativeIsNotPartOfTheName()
    {
        Assert.Equal(
            "Wall slides",
            ExerciseImporter.Parse("Perform wall slides 3 x 15").FirstOrDefault()?.Name);
    }

    [Fact]
    public void TimesForIsARepCountWithAHold()
    {
        var exercise = ParseOne("Wall slides 3 times for 15 seconds");
        Assert.Equal(3, exercise.Reps);
        Assert.Equal(15, exercise.HoldSeconds);
        Assert.Equal(3, exercise.Sets);
    }

    // MARK: - Nothing to import

    [Fact]
    public void EmptyTextParsesToNothing()
    {
        Assert.Empty(ExerciseImporter.Parse(""));
        Assert.Empty(ExerciseImporter.Parse("   \n\n  "));
    }

    [Fact]
    public void TextWithNoNameParsesToNothing()
    {
        Assert.Empty(ExerciseImporter.Parse("3 x 10"));
    }

    // MARK: - The output is always editor-legal

    [Fact]
    public void EveryParsedExerciseIsValid()
    {
        var text = """
        - Chin tucks 3 x 10, hold 5 seconds
        - Wall slides 3 x 15
        - 3 x 10
        """;
        var parsed = ExerciseImporter.Parse(text);
        Assert.True(parsed.All(exercise => exercise.IsValid), "Invalid rows must be dropped, not returned");
        Assert.True(parsed.Count == 2, "The nameless row is dropped");
    }

    [Fact]
    public void ParsingIsIdempotentThroughNormalization()
    {
        var parsed = ExerciseImporter.Parse("Chin tucks 3 x 10, hold 5 seconds");
        Assert.Equal(parsed, Exercise.Normalized(parsed));
    }

    [Fact]
    public void OutOfRangeTimingIsClampedNotRejected()
    {
        var exercise = ParseOne("Plank 1 x 1, hold 60 minutes");
        Assert.Equal(Exercise.MaxHoldSeconds, exercise.HoldSeconds);
    }

    [Fact]
    public void WindowsLineEndingsParseTheSame()
    {
        var parsed = ExerciseImporter.Parse("- Chin tucks 3 x 10\r\n- Wall slides 3 x 15");
        Assert.Equal(
            ["Chin tucks", "Wall slides"],
            parsed.Select(exercise => exercise.Name).ToArray());
    }
}
