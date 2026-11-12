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
    public static func label(for date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The exact moment, for a tooltip or an accessibility value, so the
    /// abbreviation never hides when something actually happened.
    public static func exact(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
        )
    }
}
