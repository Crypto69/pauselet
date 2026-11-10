using NodaTime;
using Pauselet.Core;

namespace Pauselet.Core.Tests;

internal static class TestDates
{
    /// <summary>
    /// A local wall-clock moment in <paramref name="zone"/> as an instant.
    /// Mirrors the Swift tests' <c>date(...)</c> helper built on
    /// <c>DateComponents</c>.
    /// </summary>
    public static Instant At(
        DateTimeZone zone, int year, int month, int day,
        int hour = 0, int minute = 0, int second = 0) =>
        zone.AtLeniently(new LocalDateTime(year, month, day, hour, minute, second))
            .ToInstant();

    public static DateTimeZone Zone(string id) => DateTimeZoneProviders.Tzdb[id];
}

/// <summary>
/// Records what the engine asked to present, so tests can assert on
/// user-visible behaviour rather than internal state alone.
/// </summary>
public sealed class RecordingPresenter : IReminderPresenting
{
    public List<Reminder> Presented { get; } = [];
    public int DismissAllCount { get; private set; }

    /// <summary>Advance warnings, as (reminder title, takeover moment).</summary>
    public List<(string Title, Instant TakeoverAt)> Warnings { get; } = [];

    public void Present(Reminder reminder, Settings settings)
    {
        Presented.Add(reminder);
    }

    public void PresentWarning(Reminder reminder, Instant takeoverAt, Settings settings)
    {
        Warnings.Add((reminder.Title, takeoverAt));
    }

    public void DismissAll()
    {
        DismissAllCount += 1;
    }
}
