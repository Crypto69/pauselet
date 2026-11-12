import Foundation

/// The "when" column of the History list.
///
/// A static string relative to a moment the caller supplies — "2 min. ago",
/// "yesterday" — rather than SwiftUI's live relative text, which redraws
/// every second. History is a record, not a stopwatch: the views refresh
/// these labels once a minute, and a test can pin them against a fixed
/// `now`.
public enum HistoryTime {
    /// `date` relative to `now`, abbreviated so it fits a narrow column.
    ///
    /// Never in the future: the views pass the last minute tick as `now`,
    /// and an event recorded since then would otherwise read "in 40 sec."
    /// until the next tick.
    public static func label(for date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        formatter(for: locale).localizedString(for: min(date, now), relativeTo: now)
    }

    /// The exact moment, for a tooltip or an accessibility value, so the
    /// abbreviation never hides when something actually happened.
    public static func exact(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
        )
    }

    /// One formatter per locale: building one is the expensive part of
    /// formatting, and the list formats up to 200 rows per redraw.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var formatters: [Locale: RelativeDateTimeFormatter] = [:]

    private static func formatter(for locale: Locale) -> RelativeDateTimeFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[locale] { return cached }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        formatters[locale] = formatter
        return formatter
    }
}
