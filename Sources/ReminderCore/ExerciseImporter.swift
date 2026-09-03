import Foundation

/// Turns the text a physiotherapist hands someone — "3 sets of 10 chin tucks,
/// hold 5 seconds, rest 30 seconds between sets" — into `Exercise` rows, so a
/// programme can be pasted into the editor instead of typed field by field.
///
/// Deliberately lenient: anything it cannot recognise is left at the `Exercise`
/// initializer's defaults rather than guessed at, and every result goes through
/// `Exercise.normalized(_:)` before it is returned, so a sloppy parse cannot
/// produce an exercise the editor would reject. The import UI shows what was
/// understood and lets the person fix it before it becomes a reminder, so being
/// wrong here costs an edit, not a bad reminder.
///
/// The patterns are `NSRegularExpression` rather than Swift `Regex` literals
/// because `Windows/Pauselet.Core` mirrors this file in C#, and ICU patterns
/// re-express in .NET; `Regex` builders do not.
public enum ExerciseImporter {

    /// Parses free text into exercises, in the order they appear.
    ///
    /// Returns an empty array when nothing usable is found — the caller shows
    /// "nothing recognised" rather than an empty row.
    public static func parse(_ text: String) -> [Exercise] {
        let chunks = split(text)
        let parsed = chunks.compactMap(exercise(from:))
        return Exercise.normalized(parsed) ?? []
    }

    // MARK: - Splitting

    /// Breaks the text into one chunk per exercise.
    ///
    /// Two shapes are common on a physio handout and both are handled: a
    /// bulleted or numbered list, where every marker starts an exercise, and
    /// prose paragraphs separated by blank lines. When the text has bullets we
    /// trust them; otherwise a blank line is the separator, and text with
    /// neither is treated as a single exercise.
    static func split(_ text: String) -> [String] {
        let unified = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = unified.components(separatedBy: "\n")

        // A leading "-", "*", "•", "1." or "1)" marks a new exercise.
        let isMarker = { (line: String) -> Bool in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            return matches(trimmed, pattern: #"^([-*•]|\d+[.)])\s+"#)
        }

        if lines.contains(where: isMarker) {
            var chunks: [String] = []
            var current: [String] = []
            for line in lines {
                if isMarker(line) {
                    if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
                    current = [stripMarker(line)]
                } else if !current.isEmpty {
                    current.append(line)
                }
            }
            if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
            return chunks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        let paragraphs = unified
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // A handout is often one flowing paragraph — "... then perform wall
        // slides ... Finally, do bicep curls ..." — with no bullet or blank
        // line to split on. Sequence words are the only boundary such text
        // has, so each paragraph is split again on them.
        return paragraphs.flatMap(splitOnSequenceWords)
    }

    /// Splits continuous prose where one exercise hands over to the next.
    ///
    /// Only splits at a word that starts a clause *and* is followed by
    /// something that looks like another exercise, so "hold, then release"
    /// inside a single instruction does not fracture it.
    static func splitOnSequenceWords(_ paragraph: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: sequenceBoundaryPattern, options: [.caseInsensitive]
        ) else { return [paragraph] }

        let range = NSRange(paragraph.startIndex..., in: paragraph)
        let matches = regex.matches(in: paragraph, range: range)
        guard !matches.isEmpty else { return [paragraph] }

        var chunks: [String] = []
        var cursor = paragraph.startIndex
        for match in matches {
            guard let boundary = Range(match.range, in: paragraph) else { continue }
            // The boundary word itself belongs to neither side.
            let head = String(paragraph[cursor..<boundary.lowerBound])
            if !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(head)
            }
            cursor = boundary.upperBound
        }
        let tail = String(paragraph[cursor...])
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(tail)
        }
        return chunks.isEmpty ? [paragraph] : chunks
    }

    /// A sentence break or comma, then a hand-over word, then a verb that
    /// introduces the next exercise. Requiring the verb is what keeps
    /// "hold for 5 seconds, then rest" in one piece.
    private static let sequenceBoundaryPattern =
        #"(?:[.;]\s*|,\s*)(?:then|next|after\s+that|followed\s+by|finally|lastly|and\s+then)\s*,?\s*(?=(?:perform|do|complete|repeat)\b)"#
        + #"|(?:[.;]\s*)(?:then|next|after\s+that|finally|lastly)\s*,?\s+"#

    private static func stripMarker(_ line: String) -> String {
        replacing(line.trimmingCharacters(in: .whitespaces), pattern: #"^([-*•]|\d+[.)])\s+"#, with: "")
    }

    // MARK: - One exercise

    /// Pulls the numbers out of one chunk, then treats what is left as the
    /// name and instructions. `nil` when there is no name to show.
    static func exercise(from chunk: String) -> Exercise? {
        let text = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var remainder = text
        var sets: Int?
        var reps: Int?

        // "3 times for 15 seconds" — a count of held repetitions, which
        // would otherwise read as a bare rep count and lose the hold.
        var holdFromTimes: Int?
        if let match = firstMatch(remainder, pattern: timesForPattern) {
            reps = number(match.1)
            holdFromTimes = seconds(match.2, unit: nil)
            remainder = remove(match.0, from: remainder)
        }

        // "3 sets of 10", "3 sets x 10 reps". Skipped entirely when the
        // "times for" form already supplied the rep count: its number has been
        // consumed, and re-reading it as a set count double-counts it.
        if reps != nil {
            // Nothing further to read.
        } else if let match = firstMatch(remainder, pattern: setsOfRepsPattern) {
            sets = number(match.1)
            reps = number(match.2)
            remainder = remove(match.0, from: remainder)
        // "3 x 10", "3 × 10" — only when it is not part of a longer phrase.
        } else if let match = firstMatch(remainder, pattern: crossPattern) {
            sets = number(match.1)
            reps = number(match.2)
            remainder = remove(match.0, from: remainder)
        } else {
            // "10 reps" and "3 sets" written separately, in either order.
            if let match = firstMatch(remainder, pattern: repsOnlyPattern) {
                reps = number(match.1)
                remainder = remove(match.0, from: remainder)
            }
            if let match = firstMatch(remainder, pattern: setsOnlyPattern) {
                sets = number(match.1)
                remainder = remove(match.0, from: remainder)
            }
        }

        // Rest between sets before rest between reps: "rest 30s between sets"
        // must not be claimed by the looser rep pattern.
        var restBetweenSets: Int?
        if let match = firstMatch(remainder, pattern: restBetweenSetsPattern) {
            restBetweenSets = seconds(match.1, unit: match.2)
            remainder = remove(match.0, from: remainder)
        }

        var restBetweenReps: Int?
        if let match = firstMatch(remainder, pattern: restBetweenRepsPattern) {
            restBetweenReps = seconds(match.1, unit: match.2)
            remainder = remove(match.0, from: remainder)
        }

        var hold: Int? = holdFromTimes
        if let match = firstMatch(remainder, pattern: holdPattern) {
            hold = seconds(match.1, unit: match.2)
            remainder = remove(match.0, from: remainder)
        }

        let (name, instructions) = nameAndInstructions(from: remainder)
        guard !name.isEmpty else { return nil }

        return Exercise(
            name: name,
            instructions: instructions,
            sets: sets ?? 3,
            reps: reps ?? 10,
            holdSeconds: hold ?? 0,
            restBetweenRepsSeconds: restBetweenReps ?? 0,
            restBetweenSetsSeconds: restBetweenSets ?? 0
        )
    }

    // MARK: - Patterns

    /// Spelled-out numbers appear as often as digits in dictated text, so both
    /// forms are accepted everywhere a count is expected.
    private static let numberWord = #"(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|sixty)"#
    private static let unit = #"(seconds?|secs?|s|minutes?|mins?|m)"#

    private static let setsOfRepsPattern =
        #"\#(numberWord)\s*(?:sets?|rounds?)\s*(?:of|x|×|\*)?\s*\#(numberWord)\s*(?:reps?|repetitions?|times)?"#
    private static let crossPattern =
        #"\#(numberWord)\s*(?:x|×|\*)\s*\#(numberWord)"#
    private static let repsOnlyPattern =
        #"\#(numberWord)\s*(?:reps?|repetitions?|times)"#
    /// "3 times for 15 seconds" / "10 times holding 3 s".
    private static let timesForPattern =
        #"\#(numberWord)\s*times?\s*(?:for|holding|hold)\s*\#(numberWord)\s*(?:seconds?|secs?|s)\b"#
    private static let setsOnlyPattern =
        #"\#(numberWord)\s*(?:sets?|rounds?)"#
    private static let holdPattern =
        #"(?:hold(?:ing)?(?:\s+(?:it|for|each))*\s*\#(numberWord)\s*\#(unit)?|\#(numberWord)\s*\#(unit)\s*hold)"#
    /// The rest verb is optional so the second half of "rest 10s between reps
    /// and 30s between sets" is still recognised once the first clause has
    /// been removed.
    private static let restBetweenSetsPattern =
        #"(?:(?:rest|break|pause)\w*\s*)?(?:for\s*)?\#(numberWord)\s*\#(unit)?\s*(?:of\s*rest\s*)?between\s*(?:each\s*)?sets?"#
    private static let restBetweenRepsPattern =
        #"(?:(?:rest|break|pause)\w*\s*(?:for\s*)?\#(numberWord)\s*\#(unit)?(?:\s*(?:of\s*rest\s*)?between\s*(?:each\s*)?(?:reps?|repetitions?))?|\#(numberWord)\s*\#(unit)?\s*(?:of\s*rest\s*)?between\s*(?:each\s*)?(?:reps?|repetitions?))"#

    // MARK: - Name and instructions

    /// What is left after the numbers are removed. The first sentence or line
    /// is the exercise's name; anything after it is instructions.
    ///
    /// Leading connectives ("of", "for", "then") are stripped because removing
    /// a matched clause from the middle of a sentence tends to leave one
    /// behind: "3 sets of chin tucks" → "of chin tucks".
    static func nameAndInstructions(from remainder: String) -> (String, String) {
        // Split before tidying: tidy collapses newlines, and a line break is
        // the strongest signal that the name has ended.
        let separators: [String] = ["\n", ". ", "; ", ": ", " - ", " — ", ", "]
        for separator in separators {
            guard let range = remainder.range(of: separator) else { continue }
            let head = tidy(String(remainder[remainder.startIndex..<range.lowerBound]))
            let tail = tidy(String(remainder[range.upperBound...]))
            // Only split when the head is a plausible name; otherwise fall
            // through and treat the whole string as one.
            if head.count >= 3 {
                return (capitalizedName(head), tail)
            }
        }
        let cleaned = tidy(remainder)
        guard !cleaned.isEmpty else { return ("", "") }
        return (capitalizedName(cleaned), "")
    }

    /// Collapses the whitespace and stray punctuation left behind by removing
    /// matched clauses.
    private static func tidy(_ text: String) -> String {
        var result = replacing(text, pattern: #"\s+"#, with: " ")
        result = replacing(result, pattern: #"^[\s,;:.\-–—]+"#, with: "")
        result = replacing(result, pattern: #"[\s,;:\-–—]+$"#, with: "")
        result = replacing(result, pattern: #"^(?i)(of|for|then|and|with|at)\b\s*"#, with: "")
        // "Perform wall slides" is an instruction to the reader, not a name.
        result = replacing(
            result, pattern: #"^(?i)(perform|do|complete|repeat|practise|practice)\b\s*"#, with: ""
        )
        // Punctuation stranded at the front by removing a clause. Trailing
        // punctuation is left alone here: instructions are whole sentences and
        // keep their full stop; `capitalizedName` trims it for names.
        result = replacing(result, pattern: #"^[\s,;:.\-–—]+"#, with: "")
        result = replacing(result, pattern: #"\s+([,;.])"#, with: "$1")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Upper-cases the first letter only — the rest of the name is left as
    /// typed, so "single-leg RDL" keeps its capitals.
    private static func capitalizedName(_ name: String) -> String {
        // A name is a label, not a sentence, so it carries no end punctuation.
        let trimmed = replacing(name, pattern: #"[\s,;:.\-–—]+$"#, with: "")
        guard let first = trimmed.first else { return trimmed }
        return String(first).uppercased() + String(trimmed.dropFirst())
    }

    // MARK: - Numbers

    private static let words: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "sixty": 60,
    ]

    static func number(_ text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(),
              !text.isEmpty else { return nil }
        if let value = Int(text) { return value }
        return words[text]
    }

    /// A count plus its unit as seconds. A bare number means seconds, which is
    /// what "hold 5" means on a physio sheet.
    static func seconds(_ value: String?, unit: String?) -> Int? {
        guard let count = number(value) else { return nil }
        let unit = unit?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let isMinutes = unit.hasPrefix("m") && !unit.hasPrefix("s")
        return isMinutes ? count * 60 : count
    }

    // MARK: - Regex helpers

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = regex(pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    /// The whole match plus its first two capture groups — enough for every
    /// pattern here, which capture at most a count and a unit.
    ///
    /// Patterns with alternatives leave the unused branch's groups empty, so
    /// the first *non-empty* groups are returned rather than groups 1 and 2.
    private static func firstMatch(
        _ text: String, pattern: String
    ) -> (String, String?, String?)? {
        guard let regex = regex(pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let whole = Range(match.range, in: text) else { return nil }

        var captures: [String] = []
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) {
                let value = String(text[range])
                if !value.isEmpty { captures.append(value) }
            }
        }
        return (
            String(text[whole]),
            captures.first,
            captures.count > 1 ? captures[1] : nil
        )
    }

    /// Removes the first occurrence of an already-matched substring.
    private static func remove(_ substring: String, from text: String) -> String {
        guard let range = text.range(of: substring) else { return text }
        return text.replacingCharacters(in: range, with: " ")
    }

    private static func replacing(
        _ text: String, pattern: String, with template: String
    ) -> String {
        guard let regex = regex(pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: template
        )
    }
}
