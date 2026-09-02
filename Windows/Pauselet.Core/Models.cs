using NodaTime;

namespace Pauselet.Core;

/// <summary>
/// How intrusive a reminder should be when it fires.
///
/// The tiers exist so a user can distinguish "you must stop what you are doing
/// right now" from "a gentle nudge you may ignore". This is the core of the
/// app's accessibility story: pressure-relief reminders are medically important
/// and need to interrupt, while a water reminder should not.
///
/// The numeric values are the priority rank; relational comparison of the enum
/// mirrors the Swift <c>Comparable</c> conformance.
/// </summary>
public enum Priority
{
    /// <summary>A quiet, self-dismissing hint. No sound. Used for frequent micro-nudges.</summary>
    Subtle = 0,
    /// <summary>A standard notification that stays in the notification list.</summary>
    Normal = 1,
    /// <summary>A notification with sound that persists until acknowledged.</summary>
    Important = 2,
    /// <summary>A full-screen overlay that takes over every display until acknowledged.</summary>
    Critical = 3,
}

public static class PriorityExtensions
{
    public static string DisplayName(this Priority priority) => priority switch
    {
        Priority.Subtle => "Subtle",
        Priority.Normal => "Normal",
        Priority.Important => "Important",
        Priority.Critical => "Critical",
        _ => throw new ArgumentOutOfRangeException(nameof(priority)),
    };

    public static string Explanation(this Priority priority) => priority switch
    {
        Priority.Subtle => "Brief silent hint near the system tray",
        Priority.Normal => "Standard notification",
        Priority.Important => "Notification with sound, stays until dismissed",
        Priority.Critical => "Full-screen overlay on every display",
        _ => throw new ArgumentOutOfRangeException(nameof(priority)),
    };

    /// <summary>
    /// Symbol used to represent the tier in the UI. The names are SF Symbol
    /// names — they are persisted user data shared with the Mac app, and the
    /// Windows UI maps them to Fluent icons at the edge.
    /// </summary>
    public static string SymbolName(this Priority priority) => priority switch
    {
        Priority.Subtle => "circle.dotted",
        Priority.Normal => "bell",
        Priority.Important => "bell.badge",
        Priority.Critical => "exclamationmark.triangle.fill",
        _ => throw new ArgumentOutOfRangeException(nameof(priority)),
    };
}

/// <summary>Describes when a reminder recurs.</summary>
public abstract record Schedule
{
    private Schedule() { }

    /// <summary>Fires every <c>Minutes</c> minutes, measured from the last time it fired.</summary>
    public sealed record Interval(int Minutes) : Schedule;

    /// <summary>
    /// Fires at a fixed wall-clock time, every <c>DayInterval</c> days.
    /// <c>DayInterval == 1</c> means daily; <c>2</c> means every second day.
    /// </summary>
    public sealed record DailyAt(int Hour, int Minute, int DayInterval) : Schedule;

    /// <summary>
    /// Fires at a fixed wall-clock time on specific weekdays.
    /// Weekdays use Apple <c>Calendar</c> numbering — 1 = Sunday ... 7 =
    /// Saturday — because the values are persisted data shared with the Mac app.
    /// </summary>
    public sealed record WeeklyAt : Schedule
    {
        public int Hour { get; init; }
        public int Minute { get; init; }
        public IReadOnlySet<int> Weekdays { get; init; }

        public WeeklyAt(int hour, int minute, IReadOnlySet<int> weekdays)
        {
            Hour = hour;
            Minute = minute;
            Weekdays = weekdays;
        }

        // Set-valued property: structural equality has to compare contents,
        // which the synthesized record equality (reference equality for sets)
        // would not.
        public bool Equals(WeeklyAt? other) =>
            other is not null
            && Hour == other.Hour
            && Minute == other.Minute
            && Weekdays.Count == other.Weekdays.Count
            && Weekdays.SetEquals(other.Weekdays);

        public override int GetHashCode()
        {
            var contents = 0;
            foreach (var day in Weekdays) contents ^= day * 31;
            return HashCode.Combine(Hour, Minute, Weekdays.Count, contents);
        }
    }

    public string Summary => this switch
    {
        Interval interval => $"Every {HumanDuration(interval.Minutes)}",
        DailyAt daily when daily.DayInterval <= 1 =>
            $"Daily at {HumanTime(daily.Hour, daily.Minute)}",
        DailyAt daily =>
            $"Every {daily.DayInterval} days at {HumanTime(daily.Hour, daily.Minute)}",
        WeeklyAt weekly =>
            string.Join(", ", weekly.Weekdays.OrderBy(d => d).Select(WeekdayName))
            + $" at {HumanTime(weekly.Hour, weekly.Minute)}",
        _ => throw new InvalidOperationException(),
    };

    /// <summary>
    /// Whether this schedule fires at fixed wall-clock moments (daily/weekly)
    /// rather than a rolling interval. Wall-clock slots that pass unheard
    /// inside quiet hours are skipped; interval reminders are delivered once
    /// the window ends.
    /// </summary>
    public bool IsWallClock => this is not Interval;

    public static string HumanDuration(int minutes)
    {
        if (minutes < 60) return $"{minutes} min";
        if (minutes % 60 == 0)
        {
            var hours = minutes / 60;
            return hours == 1 ? "hour" : $"{hours} hours";
        }
        return $"{minutes / 60}h {minutes % 60}m";
    }

    internal static string HumanTime(int hour, int minute) => $"{hour:D2}:{minute:D2}";

    internal static string WeekdayName(int weekday)
    {
        string[] names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
        var index = weekday - 1;
        if (index < 0 || index >= names.Length) return "?";
        return names[index];
    }
}

/// <summary>A single user-defined recurring reminder.</summary>
public sealed record Reminder
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public required string Title { get; init; }
    /// <summary>Longer text shown in the notification body / overlay.</summary>
    public string Message { get; init; } = "";
    public required Schedule Schedule { get; init; }
    public Priority Priority { get; init; } = Priority.Normal;
    public bool IsEnabled { get; init; } = true;
    /// <summary>
    /// Symbol shown alongside the reminder. SF Symbol names in the data for
    /// cross-platform file compatibility; mapped to Fluent icons in the UI.
    /// </summary>
    public string SymbolName { get; init; } = "bell";
    /// <summary>
    /// For reminders describing a timed activity (e.g. "tilt back for 5 minutes"),
    /// the overlay shows a countdown of this length. <c>null</c> means no countdown.
    /// </summary>
    public int? ActivityDurationSeconds { get; init; }
    /// <summary>Optional sound played when the reminder fires. <c>null</c> uses the tier default.</summary>
    public string? SoundName { get; init; }
    /// <summary>
    /// How long a subtle card stays on screen, in seconds. <c>null</c> uses the
    /// global setting.
    ///
    /// Only applies to the subtle tier: Normal and Important are system
    /// notifications, whose on-screen time the system controls, and Critical
    /// stays until acknowledged.
    /// </summary>
    public int? DisplaySeconds { get; init; }
    /// <summary>
    /// What music this reminder starts when it fires.
    ///
    /// Decoded leniently: reminders written before this existed have no
    /// <c>music</c> key at all, and must load as "no music" rather than failing
    /// the whole file and losing every reminder the user configured.
    /// </summary>
    public MusicChoice Music { get; init; } = MusicChoice.None;
    /// <summary>
    /// The exercise list for an "Exercise" reminder; <c>null</c> for an
    /// ordinary reminder.
    ///
    /// Decoded leniently for the same reason as <see cref="Music"/>: files
    /// written before this existed have no <c>exercises</c> key. Never stored
    /// empty — the editor collapses an empty list to <c>null</c> through
    /// <see cref="Exercise.Normalized"/> — but an empty array read from disk
    /// is kept as-is so the file re-encodes byte-identically.
    /// </summary>
    public IReadOnlyList<Exercise>? Exercises { get; init; }
    /// <summary>When the reminder last fired. Drives interval scheduling.</summary>
    public Instant? LastFiredAt { get; init; }
    /// <summary>When the reminder was last acknowledged (completed or dismissed).</summary>
    public Instant? LastAcknowledgedAt { get; init; }
    /// <summary>When set, the reminder is snoozed and must not fire before this date.</summary>
    public Instant? SnoozedUntil { get; init; }
    public Instant CreatedAt { get; init; } = SystemClock.Instance.GetCurrentInstant();

    /// <summary>True when the reminder carries at least one exercise.</summary>
    public bool IsExercise => Exercises is { Count: > 0 };

    /// <summary>
    /// <see cref="Exercise.SummaryOf"/> for this reminder's list; <c>null</c>
    /// for an ordinary reminder.
    /// </summary>
    public string? ExerciseSummary => Exercise.SummaryOf(Exercises);

    /// <summary>
    /// The list-row subtitle: the schedule, plus the exercise summary for an
    /// exercise reminder ("Every 2 hours · 3 exercises · 9 sets"). One place
    /// composes it so every platform's rows read the same.
    /// </summary>
    public string ScheduleLine =>
        ExerciseSummary is { } exercises ? $"{Schedule.Summary} · {exercises}" : Schedule.Summary;

    // List-valued property: the synthesized record equality would compare the
    // list by reference, and AppData.Equals (hence the store round-trip tests)
    // relies on reminders comparing structurally. Same reason as WeeklyAt.
    public bool Equals(Reminder? other) =>
        other is not null
        && Id == other.Id
        && Title == other.Title
        && Message == other.Message
        && Schedule == other.Schedule
        && Priority == other.Priority
        && IsEnabled == other.IsEnabled
        && SymbolName == other.SymbolName
        && ActivityDurationSeconds == other.ActivityDurationSeconds
        && SoundName == other.SoundName
        && DisplaySeconds == other.DisplaySeconds
        && Music == other.Music
        && ExercisesEqual(other.Exercises)
        && LastFiredAt == other.LastFiredAt
        && LastAcknowledgedAt == other.LastAcknowledgedAt
        && SnoozedUntil == other.SnoozedUntil
        && CreatedAt == other.CreatedAt;

    private bool ExercisesEqual(IReadOnlyList<Exercise>? other)
    {
        if (Exercises is null || other is null) return Exercises is null && other is null;
        return Exercises.SequenceEqual(other);
    }

    public override int GetHashCode() =>
        HashCode.Combine(
            Id, Title, Schedule, Priority, CreatedAt, Music, Exercises?.Count ?? -1
        );
}

/// <summary>Records that a reminder fired and what the user did about it.</summary>
public sealed record ReminderEvent
{
    public enum Outcome
    {
        Fired,
        Completed,
        Snoozed,
        Dismissed,
        Missed,
    }

    public Guid Id { get; init; } = Guid.NewGuid();
    public required Guid ReminderId { get; init; }
    public required string ReminderTitle { get; init; }
    public Instant Date { get; init; } = SystemClock.Instance.GetCurrentInstant();
    public required Outcome EventOutcome { get; init; }
}

/// <summary>A window of the day/week during which reminders are suppressed.</summary>
public sealed record QuietHours
{
    public bool IsEnabled { get; init; } = false;
    public int StartHour { get; init; } = 22;
    public int StartMinute { get; init; } = 0;
    public int EndHour { get; init; } = 7;
    public int EndMinute { get; init; } = 0;
    /// <summary>
    /// Critical reminders can be allowed to pierce quiet hours, since for some
    /// users (like pressure-relief) they are medically necessary.
    /// </summary>
    public bool AllowsCritical { get; init; } = true;

    /// <summary>
    /// True when <paramref name="date"/> falls inside the quiet window. Handles
    /// windows that wrap past midnight (e.g. 22:00 → 07:00).
    /// </summary>
    public bool Contains(Instant date, DateTimeZone zone)
    {
        if (!IsEnabled) return false;
        var local = date.InZone(zone);
        var now = local.Hour * 60 + local.Minute;
        var start = StartHour * 60 + StartMinute;
        var end = EndHour * 60 + EndMinute;
        if (start == end) return false;
        if (start < end)
        {
            return now >= start && now < end;
        }
        // Wraps midnight.
        return now >= start || now < end;
    }

    /// <summary>
    /// The moment the quiet window containing <paramref name="date"/> ends.
    /// Only meaningful when <c>Contains(date)</c> is true; used to show when a
    /// suppressed reminder will actually surface.
    /// </summary>
    public Instant? NextEnd(Instant date, DateTimeZone zone)
    {
        if (!IsEnabled) return null;
        var day = date.InZone(zone).Date;
        var endToday = CalendarMath.SlotAt(day, EndHour, EndMinute, zone);
        if (endToday is null) return null;
        if (endToday > date) return endToday;
        // Inside a window that wraps past midnight: the end is tomorrow.
        return CalendarMath.SlotAt(day.PlusDays(1), EndHour, EndMinute, zone);
    }
}

/// <summary>Global app preferences.</summary>
public sealed record Settings
{
    public QuietHours QuietHours { get; init; } = new();
    /// <summary>Master switch. When paused, nothing fires.</summary>
    public bool IsPaused { get; init; } = false;
    /// <summary>When set, the app is paused until this date, then resumes automatically.</summary>
    public Instant? PausedUntil { get; init; }
    /// <summary>Minutes added when the user snoozes a reminder.</summary>
    public int SnoozeMinutes { get; init; } = 5;
    /// <summary>Seconds a subtle reminder stays on screen before self-dismissing.</summary>
    public int SubtleDisplaySeconds { get; init; } = 8;
    public bool LaunchAtLogin { get; init; } = false;
    /// <summary>Show a countdown to the next reminder beside the tray icon.</summary>
    public bool ShowsNextReminderInMenuBar { get; init; } = true;
    /// <summary>Play sound for important/critical tiers.</summary>
    public bool SoundEnabled { get; init; } = true;
    /// <summary>
    /// The playlist reminders set to "default" will play, as a canonical
    /// <c>spotify:playlist:ID</c> URI. <c>null</c> means none is configured yet.
    /// Spotify control itself is deferred on Windows; the field persists so the
    /// data file stays interchangeable with the Mac app.
    /// </summary>
    public string? DefaultPlaylistUri { get; init; }
    /// <summary>
    /// Master switch for music, independent of the per-reminder choice.
    ///
    /// Separate from clearing the playlist so a user can silence every reminder
    /// at once — during a meeting, say — without losing the playlist they
    /// picked and the per-reminder settings around it.
    /// </summary>
    public bool MusicEnabled { get; init; } = true;
    /// <summary>
    /// Volume to fade the player up to when a reminder starts music, 0–100.
    /// Applied as a gentle ramp so a relaxation prompt does not blast whatever
    /// volume the player was last left at.
    /// </summary>
    public int MusicVolume { get; init; } = 55;

    /// <summary>
    /// The playlist <paramref name="reminder"/> should start when it fires, or
    /// <c>null</c> for silence.
    ///
    /// One place decides this, so the master switch and the per-reminder choice
    /// cannot drift apart between the settings UI and the firing path.
    /// </summary>
    public string? PlaylistUriFor(Reminder reminder)
    {
        if (!MusicEnabled) return null;
        return reminder.Music.ResolvedUri(DefaultPlaylistUri);
    }
}
