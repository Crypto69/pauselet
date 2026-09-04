namespace Pauselet.Core;

/// <summary>
/// The fixed choices the reminder editor offers, shared by every platform's
/// editor so the Mac, iOS, and Windows apps cannot quietly drift apart on
/// which icons, intervals, or day order the user is shown.
/// (Mirrors Catalog.swift.)
/// </summary>
public static class EditorCatalog
{
    /// <summary>
    /// SF Symbols relevant to health and routine reminders. The names are the
    /// Apple ones because that is what the data file stores on every platform;
    /// Windows renders them through SymbolMap.
    /// </summary>
    public static readonly IReadOnlyList<string> Symbols =
    [
        "bell", "figure.seated.side", "arrow.up.and.down.circle", "drop.fill",
        "figure.flexibility", "figure.walk", "pills.fill", "heart.fill",
        "lungs.fill", "eye.fill", "hand.raised.fill", "fork.knife",
        "moon.fill", "sun.max.fill", "phone.fill", "book.fill",
        "cross.case.fill", "dumbbell.fill", "timer", "wind",
    ];

    /// <summary>Common intervals, in minutes, offered as presets before "Custom".</summary>
    public static readonly IReadOnlyList<int> IntervalPresets =
        [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240];

    /// <summary>A weekday as the picker shows it.</summary>
    /// <param name="Number">Calendar numbering: 1 = Sunday … 7 = Saturday.</param>
    /// <param name="Label">The one-letter button label.</param>
    /// <param name="Name">The full name, for accessibility.</param>
    public sealed record Weekday(int Number, string Label, string Name);

    /// <summary>Monday-first, the order the picker lays the buttons out in.</summary>
    public static readonly IReadOnlyList<Weekday> Weekdays =
    [
        new(2, "M", "Monday"),
        new(3, "T", "Tuesday"),
        new(4, "W", "Wednesday"),
        new(5, "T", "Thursday"),
        new(6, "F", "Friday"),
        new(7, "S", "Saturday"),
        new(1, "S", "Sunday"),
    ];
}
