using System.Text.RegularExpressions;

namespace Pauselet.Core;

/// <summary>
/// Turns the text a physiotherapist hands someone — "3 sets of 10 chin tucks,
/// hold 5 seconds, rest 30 seconds between sets" — into <see cref="Exercise"/>
/// rows, so a programme can be pasted into the editor instead of typed field
/// by field. (Mirrors ExerciseImporter.swift.)
///
/// Deliberately lenient: anything it cannot recognise is left at the
/// <see cref="Exercise"/> defaults rather than guessed at, and every result
/// goes through <see cref="Exercise.Normalized"/> before it is returned, so a
/// sloppy parse cannot produce an exercise the editor would reject. The import
/// UI shows what was understood and lets the person fix it before it becomes a
/// reminder, so being wrong here costs an edit, not a bad reminder.
///
/// The Swift original uses NSRegularExpression with ICU patterns rather than
/// Swift Regex builders precisely so the patterns re-express here unchanged.
/// </summary>
public static class ExerciseImporter
{
    /// <summary>
    /// Parses free text into exercises, in the order they appear. Returns an
    /// empty list when nothing usable is found — the caller shows "nothing
    /// recognised" rather than an empty row.
    /// </summary>
    public static IReadOnlyList<Exercise> Parse(string text)
    {
        var parsed = Split(text)
            .Select(ExerciseFrom)
            .Where(exercise => exercise is not null)
            .Select(exercise => exercise!)
            .ToList();
        return Exercise.Normalized(parsed) ?? [];
    }

    // MARK: - Splitting

    private const RegexOptions Options = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;

    /// <summary>A leading "-", "*", "•", "1." or "1)" marks a new exercise.</summary>
    private static readonly Regex MarkerPattern = new(@"^([-*•]|\d+[.)])\s+", Options);

    /// <summary>
    /// Breaks the text into one chunk per exercise.
    ///
    /// Two shapes are common on a physio handout and both are handled: a
    /// bulleted or numbered list, where every marker starts an exercise, and
    /// prose paragraphs separated by blank lines. When the text has bullets we
    /// trust them; otherwise a blank line is the separator, and text with
    /// neither is treated as a single exercise.
    /// </summary>
    internal static IReadOnlyList<string> Split(string text)
    {
        var unified = text.Replace("\r\n", "\n").Replace("\r", "\n");
        var lines = unified.Split('\n');

        static bool IsMarker(string line)
        {
            var trimmed = line.Trim(' ', '\t');
            return trimmed.Length > 0 && MarkerPattern.IsMatch(trimmed);
        }

        if (lines.Any(IsMarker))
        {
            var chunks = new List<string>();
            var current = new List<string>();
            foreach (var line in lines)
            {
                if (IsMarker(line))
                {
                    if (current.Count > 0) chunks.Add(string.Join("\n", current));
                    current = [StripMarker(line)];
                }
                else if (current.Count > 0)
                {
                    current.Add(line);
                }
            }
            if (current.Count > 0) chunks.Add(string.Join("\n", current));
            return chunks.Where(chunk => chunk.Trim().Length > 0).ToList();
        }

        var paragraphs = unified
            .Split("\n\n")
            .Where(paragraph => paragraph.Trim().Length > 0);

        // A handout is often one flowing paragraph — "... then perform wall
        // slides ... Finally, do bicep curls ..." — with no bullet or blank
        // line to split on. Sequence words are the only boundary such text
        // has, so each paragraph is split again on them.
        return paragraphs.SelectMany(SplitOnSequenceWords).ToList();
    }

    /// <summary>
    /// A sentence break or comma, then a hand-over word, then a verb that
    /// introduces the next exercise. Requiring the verb is what keeps
    /// "hold for 5 seconds, then rest" in one piece.
    /// </summary>
    private static readonly Regex SequenceBoundaryPattern = new(
        @"(?:[.;]\s*|,\s*)(?:then|next|after\s+that|followed\s+by|finally|lastly|and\s+then)\s*,?\s*(?=(?:perform|do|complete|repeat)\b)"
        + @"|(?:[.;]\s*)(?:then|next|after\s+that|finally|lastly)\s*,?\s+",
        Options);

    /// <summary>
    /// Splits continuous prose where one exercise hands over to the next.
    ///
    /// Only splits at a word that starts a clause <em>and</em> is followed by
    /// something that looks like another exercise, so "hold, then release"
    /// inside a single instruction does not fracture it.
    /// </summary>
    internal static IReadOnlyList<string> SplitOnSequenceWords(string paragraph)
    {
        var matches = SequenceBoundaryPattern.Matches(paragraph);
        if (matches.Count == 0) return [paragraph];

        var chunks = new List<string>();
        var cursor = 0;
        foreach (Match match in matches)
        {
            // The boundary word itself belongs to neither side.
            var head = paragraph[cursor..match.Index];
            if (head.Trim().Length > 0) chunks.Add(head);
            cursor = match.Index + match.Length;
        }
        var tail = paragraph[cursor..];
        if (tail.Trim().Length > 0) chunks.Add(tail);
        return chunks.Count == 0 ? [paragraph] : chunks;
    }

    private static string StripMarker(string line) =>
        MarkerPattern.Replace(line.Trim(' ', '\t'), "", 1);

    // MARK: - One exercise

    /// <summary>
    /// Pulls the numbers out of one chunk, then treats what is left as the
    /// name and instructions. <c>null</c> when there is no name to show.
    /// </summary>
    internal static Exercise? ExerciseFrom(string chunk)
    {
        var text = chunk.Trim();
        if (text.Length == 0) return null;

        var remainder = text;
        int? sets = null;
        int? reps = null;

        // "3 times for 15 seconds" — a count of held repetitions, which
        // would otherwise read as a bare rep count and lose the hold.
        int? holdFromTimes = null;
        if (FirstMatch(remainder, TimesForPattern) is { } timesFor)
        {
            reps = Number(timesFor.First);
            holdFromTimes = Seconds(timesFor.Second, null);
            remainder = Remove(timesFor.Whole, remainder);
        }

        // "3 sets of 10", "3 sets x 10 reps". Skipped entirely when the
        // "times for" form already supplied the rep count: its number has been
        // consumed, and re-reading it as a set count double-counts it.
        if (reps is not null)
        {
            // Nothing further to read.
        }
        else if (FirstMatch(remainder, SetsOfRepsPattern) is { } setsOfReps)
        {
            sets = Number(setsOfReps.First);
            reps = Number(setsOfReps.Second);
            remainder = Remove(setsOfReps.Whole, remainder);
        }
        // "3 x 10", "3 × 10" — only when it is not part of a longer phrase.
        else if (FirstMatch(remainder, CrossPattern) is { } cross)
        {
            sets = Number(cross.First);
            reps = Number(cross.Second);
            remainder = Remove(cross.Whole, remainder);
        }
        else
        {
            // "10 reps" and "3 sets" written separately, in either order.
            if (FirstMatch(remainder, RepsOnlyPattern) is { } repsOnly)
            {
                reps = Number(repsOnly.First);
                remainder = Remove(repsOnly.Whole, remainder);
            }
            if (FirstMatch(remainder, SetsOnlyPattern) is { } setsOnly)
            {
                sets = Number(setsOnly.First);
                remainder = Remove(setsOnly.Whole, remainder);
            }
        }

        // Rest between sets before rest between reps: "rest 30s between sets"
        // must not be claimed by the looser rep pattern.
        int? restBetweenSets = null;
        if (FirstMatch(remainder, RestBetweenSetsPattern) is { } setRest)
        {
            restBetweenSets = Seconds(setRest.First, setRest.Second);
            remainder = Remove(setRest.Whole, remainder);
        }

        int? restBetweenReps = null;
        if (FirstMatch(remainder, RestBetweenRepsPattern) is { } repRest)
        {
            restBetweenReps = Seconds(repRest.First, repRest.Second);
            remainder = Remove(repRest.Whole, remainder);
        }

        var hold = holdFromTimes;
        if (FirstMatch(remainder, HoldPattern) is { } holdMatch)
        {
            hold = Seconds(holdMatch.First, holdMatch.Second);
            remainder = Remove(holdMatch.Whole, remainder);
        }

        var (name, instructions) = NameAndInstructions(remainder);
        if (name.Length == 0) return null;

        return new Exercise
        {
            Name = name,
            Instructions = instructions,
            Sets = sets ?? 3,
            Reps = reps ?? 10,
            HoldSeconds = hold ?? 0,
            RestBetweenRepsSeconds = restBetweenReps ?? 0,
            RestBetweenSetsSeconds = restBetweenSets ?? 0,
        };
    }

    // MARK: - Patterns

    /// <summary>
    /// Spelled-out numbers appear as often as digits in dictated text, so both
    /// forms are accepted everywhere a count is expected.
    /// </summary>
    private const string NumberWord =
        @"(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|sixty)";
    private const string Unit = @"(seconds?|secs?|s|minutes?|mins?|m)";

    private static readonly Regex SetsOfRepsPattern = new(
        $@"{NumberWord}\s*(?:sets?|rounds?)\s*(?:of|x|×|\*)?\s*{NumberWord}\s*(?:reps?|repetitions?|times)?",
        Options);
    private static readonly Regex CrossPattern = new(
        $@"{NumberWord}\s*(?:x|×|\*)\s*{NumberWord}", Options);
    private static readonly Regex RepsOnlyPattern = new(
        $@"{NumberWord}\s*(?:reps?|repetitions?|times)", Options);
    /// <summary>"3 times for 15 seconds" / "10 times holding 3 s".</summary>
    private static readonly Regex TimesForPattern = new(
        $@"{NumberWord}\s*times?\s*(?:for|holding|hold)\s*{NumberWord}\s*(?:seconds?|secs?|s)\b",
        Options);
    private static readonly Regex SetsOnlyPattern = new(
        $@"{NumberWord}\s*(?:sets?|rounds?)", Options);
    private static readonly Regex HoldPattern = new(
        $@"(?:hold(?:ing)?(?:\s+(?:it|for|each))*\s*{NumberWord}\s*{Unit}?|{NumberWord}\s*{Unit}\s*hold)",
        Options);
    /// <summary>
    /// The rest verb is optional so the second half of "rest 10s between reps
    /// and 30s between sets" is still recognised once the first clause has
    /// been removed.
    /// </summary>
    private static readonly Regex RestBetweenSetsPattern = new(
        $@"(?:(?:rest|break|pause)\w*\s*)?(?:for\s*)?{NumberWord}\s*{Unit}?\s*(?:of\s*rest\s*)?between\s*(?:each\s*)?sets?",
        Options);
    private static readonly Regex RestBetweenRepsPattern = new(
        $@"(?:(?:rest|break|pause)\w*\s*(?:for\s*)?{NumberWord}\s*{Unit}?(?:\s*(?:of\s*rest\s*)?between\s*(?:each\s*)?(?:reps?|repetitions?))?|{NumberWord}\s*{Unit}?\s*(?:of\s*rest\s*)?between\s*(?:each\s*)?(?:reps?|repetitions?))",
        Options);

    // MARK: - Name and instructions

    /// <summary>
    /// What is left after the numbers are removed. The first sentence or line
    /// is the exercise's name; anything after it is instructions.
    ///
    /// Leading connectives ("of", "for", "then") are stripped because removing
    /// a matched clause from the middle of a sentence tends to leave one
    /// behind: "3 sets of chin tucks" → "of chin tucks".
    /// </summary>
    internal static (string Name, string Instructions) NameAndInstructions(string remainder)
    {
        // Split before tidying: tidy collapses newlines, and a line break is
        // the strongest signal that the name has ended.
        string[] separators = ["\n", ". ", "; ", ": ", " - ", " — ", ", "];
        foreach (var separator in separators)
        {
            var index = remainder.IndexOf(separator, StringComparison.Ordinal);
            if (index < 0) continue;
            var head = Tidy(remainder[..index]);
            var tail = Tidy(remainder[(index + separator.Length)..]);
            // Only split when the head is a plausible name; otherwise fall
            // through and treat the whole string as one.
            if (head.Length >= 3) return (CapitalizedName(head), tail);
        }
        var cleaned = Tidy(remainder);
        return cleaned.Length == 0 ? ("", "") : (CapitalizedName(cleaned), "");
    }

    private static readonly Regex WhitespaceRun = new(@"\s+", Options);
    private static readonly Regex LeadingPunctuation = new(@"^[\s,;:.\-–—]+", Options);
    private static readonly Regex TrailingPunctuation = new(@"[\s,;:\-–—]+$", Options);
    private static readonly Regex TrailingNamePunctuation = new(@"[\s,;:.\-–—]+$", Options);
    private static readonly Regex LeadingConnective = new(@"^(of|for|then|and|with|at)\b\s*", Options);
    private static readonly Regex LeadingImperative = new(
        @"^(perform|do|complete|repeat|practise|practice)\b\s*", Options);
    private static readonly Regex SpaceBeforePunctuation = new(@"\s+([,;.])", Options);

    /// <summary>
    /// Collapses the whitespace and stray punctuation left behind by removing
    /// matched clauses.
    /// </summary>
    private static string Tidy(string text)
    {
        var result = WhitespaceRun.Replace(text, " ");
        result = LeadingPunctuation.Replace(result, "");
        result = TrailingPunctuation.Replace(result, "");
        result = LeadingConnective.Replace(result, "");
        // "Perform wall slides" is an instruction to the reader, not a name.
        result = LeadingImperative.Replace(result, "");
        // Punctuation stranded at the front by removing a clause. Trailing
        // punctuation is left alone here: instructions are whole sentences and
        // keep their full stop; CapitalizedName trims it for names.
        result = LeadingPunctuation.Replace(result, "");
        result = SpaceBeforePunctuation.Replace(result, "$1");
        return result.Trim();
    }

    /// <summary>
    /// Upper-cases the first letter only — the rest of the name is left as
    /// typed, so "single-leg RDL" keeps its capitals.
    /// </summary>
    private static string CapitalizedName(string name)
    {
        // A name is a label, not a sentence, so it carries no end punctuation.
        var trimmed = TrailingNamePunctuation.Replace(name, "");
        if (trimmed.Length == 0) return trimmed;
        return char.ToUpperInvariant(trimmed[0]) + trimmed[1..];
    }

    // MARK: - Numbers

    private static readonly Dictionary<string, int> Words = new()
    {
        ["one"] = 1, ["two"] = 2, ["three"] = 3, ["four"] = 4, ["five"] = 5,
        ["six"] = 6, ["seven"] = 7, ["eight"] = 8, ["nine"] = 9, ["ten"] = 10,
        ["eleven"] = 11, ["twelve"] = 12, ["fifteen"] = 15, ["twenty"] = 20,
        ["thirty"] = 30, ["sixty"] = 60,
    };

    internal static int? Number(string? text)
    {
        var value = text?.Trim(' ', '\t').ToLowerInvariant();
        if (string.IsNullOrEmpty(value)) return null;
        if (int.TryParse(value, out var digits)) return digits;
        return Words.TryGetValue(value, out var word) ? word : null;
    }

    /// <summary>
    /// A count plus its unit as seconds. A bare number means seconds, which is
    /// what "hold 5" means on a physio sheet.
    /// </summary>
    internal static int? Seconds(string? value, string? unit)
    {
        if (Number(value) is not { } count) return null;
        var suffix = unit?.Trim(' ', '\t').ToLowerInvariant() ?? "";
        var isMinutes = suffix.StartsWith('m') && !suffix.StartsWith('s');
        return isMinutes ? count * 60 : count;
    }

    // MARK: - Regex helpers

    /// <summary>
    /// The whole match plus its first two non-empty capture groups — enough
    /// for every pattern here, which capture at most a count and a unit.
    ///
    /// Patterns with alternatives leave the unused branch's groups empty, so
    /// the first <em>non-empty</em> groups are returned rather than groups 1 and 2.
    /// </summary>
    private static (string Whole, string? First, string? Second)? FirstMatch(
        string text, Regex pattern)
    {
        var match = pattern.Match(text);
        if (!match.Success) return null;

        var captures = new List<string>();
        for (var index = 1; index < match.Groups.Count; index++)
        {
            var group = match.Groups[index];
            if (group.Success && group.Value.Length > 0) captures.Add(group.Value);
        }
        return (
            match.Value,
            captures.Count > 0 ? captures[0] : null,
            captures.Count > 1 ? captures[1] : null
        );
    }

    /// <summary>Removes the first occurrence of an already-matched substring.</summary>
    private static string Remove(string substring, string text)
    {
        var index = text.IndexOf(substring, StringComparison.Ordinal);
        return index < 0 ? text : string.Concat(text.AsSpan(0, index), " ", text.AsSpan(index + substring.Length));
    }
}
