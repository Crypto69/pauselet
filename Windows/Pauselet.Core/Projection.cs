using NodaTime;

namespace Pauselet.Core;

/// <summary>
/// One projected future delivery of a reminder.
///
/// <c>FireDate</c> is when the reminder reaches the user. <c>StampDate</c> is
/// what <c>LastFiredAt</c> must be stamped with when that fire is honoured —
/// the wall-clock slot for daily/weekly schedules, the delivery time otherwise
/// — mirroring what <c>ReminderEngine.Tick()</c> stamps, so a fire delivered by
/// the system while the app was not running can be reconciled into exactly the
/// state a live tick would have produced.
///
/// The Windows shell is a resident tick loop and does not pre-schedule, so it
/// has no call site for this today; it is ported because it is core logic with
/// its own test coverage, and it becomes relevant the moment a "works while not
/// running" mode (scheduled toasts) is ever wanted.
/// </summary>
public sealed record ProjectedFire(Instant FireDate, Instant StampDate);

public static class Projection
{
    /// <summary>
    /// The next <paramref name="limit"/> times <paramref name="reminder"/> will
    /// actually reach the user.
    ///
    /// This is the keystone of pre-scheduled delivery (iOS): there is no tick
    /// loop watching the clock, so everything the engine would have decided at
    /// fire time must be decided now. It is nothing more than
    /// <see cref="Scheduler.NextStep"/> applied repeatedly — the same step
    /// <c>Tick()</c> applies once — so the projection cannot hold an opinion
    /// the live engine does not share. Skipped slots (wall-clock slots inside
    /// quiet hours) are consumed but not returned; they are not deliveries.
    /// </summary>
    public static IReadOnlyList<ProjectedFire> ProjectedFires(
        Reminder reminder, Instant from, int limit, Settings settings, DateTimeZone zone)
    {
        if (!reminder.IsEnabled || limit <= 0) return [];

        var sim = reminder;
        var cursor = from;
        var fires = new List<ProjectedFire>();
        // Bounded so a schedule that can never deliver (every slot inside
        // quiet hours, say) terminates instead of spinning.
        var iterations = 0;
        var maxIterations = limit * 16 + 64;

        while (fires.Count < limit && iterations < maxIterations)
        {
            iterations += 1;
            if (Scheduler.NextStep(sim, cursor, settings, zone) is not { } step) break;
            sim = step.Apply(sim);
            cursor = step.FireDate;
            if (step.StepOutcome == Scheduler.FireStep.Outcome.Deliver)
            {
                fires.Add(new ProjectedFire(step.FireDate, step.StampDate));
            }
        }
        return fires;
    }
}

/// <summary>
/// An advance warning of a Critical takeover: shown at <c>WarnAt</c>, saying
/// the screen will be taken over at <c>TakeoverAt</c>.
/// </summary>
public sealed record ReminderWarning(Instant WarnAt, Instant TakeoverAt);

/// <summary>Advance warnings before a Critical takeover. Mirrors the Swift core.</summary>
public static class Warnings
{
    /// <summary>
    /// The lead an editor accepts: one minute up to a day — long enough for
    /// any heads-up, short enough that a typo cannot set one weeks ahead.
    /// </summary>
    public const int MinMinutes = 1;
    public const int MaxMinutes = 1440;

    /// <summary>
    /// The next <paramref name="limit"/> advance warnings of the reminder's
    /// takeovers, judged from <paramref name="from"/>. Built on the same
    /// <see cref="Scheduler.NextStep"/> walk as
    /// <see cref="Projection.ProjectedFires"/>, so a warning only ever
    /// announces a takeover the engine will deliver. No warning for a snooze
    /// coming back, for a moment inside a pause or inside quiet hours the
    /// takeover respects, or when the moment is not after the previous fire
    /// (a lead as long as the interval). A warning whose moment has passed is
    /// still returned while its takeover is ahead.
    /// </summary>
    public static IReadOnlyList<ReminderWarning> Projected(
        Reminder reminder, Instant from, int limit, Settings settings, DateTimeZone zone)
    {
        if (!reminder.IsEnabled || reminder.Priority != Priority.Critical
            || reminder.WarningMinutes is not { } minutes || minutes <= 0 || limit <= 0)
            return [];
        var lead = Duration.FromMinutes(minutes);

        var sim = reminder;
        var cursor = from;
        var warnings = new List<ReminderWarning>();
        var iterations = 0;
        var maxIterations = limit * 16 + 64;

        while (warnings.Count < limit && iterations < maxIterations)
        {
            iterations += 1;
            var wasSnoozed = sim.SnoozedUntil is not null;
            var previous = sim.LastFiredAt ?? sim.CreatedAt;
            if (Scheduler.NextStep(sim, cursor, settings, zone) is not { } step) break;
            sim = step.Apply(sim);
            cursor = step.FireDate;
            if (step.StepOutcome != Scheduler.FireStep.Outcome.Deliver || wasSnoozed
                || step.FireDate <= from) continue;
            var warnAt = step.FireDate - lead;
            if (warnAt <= previous
                || Scheduler.IsPaused(settings, warnAt)
                || Scheduler.IsSuppressedByQuietHours(Priority.Critical, settings, warnAt, zone))
                continue;
            warnings.Add(new ReminderWarning(warnAt, step.FireDate));
        }
        return warnings;
    }

    /// <summary>
    /// Whether a warning of <paramref name="minutes"/> would have to come
    /// before the previous takeover of a repeating schedule, so none would be
    /// shown. The editors say so.
    /// </summary>
    public static bool OutlastsInterval(int minutes, Schedule schedule) => schedule switch
    {
        Schedule.Interval interval => minutes >= interval.Minutes,
        Schedule.TimedInterval timed => minutes >= timed.Minutes,
        _ => false,
    };

    /// <summary>
    /// Whether a reminder's advance warning chimes: sounds are on (the
    /// warning follows the Important tier's rule, as its card does) and the
    /// reminder has not asked for a quiet one. The takeover's own sound is
    /// separate and unaffected.
    /// </summary>
    public static bool PlaysSound(Reminder reminder, Settings settings) =>
        settings.PlaysSound(Priority.Important) && reminder.WarningIsSilent != true;

    /// <summary>
    /// The chime a warning plays when it plays one. A warning has its own
    /// sound rather than the reminder's: that belongs to the takeover.
    /// </summary>
    public const string DefaultSound = "Glass";

    /// <summary>
    /// The sound <paramref name="reminder"/>'s warning plays, by name: the one
    /// chosen in the editor, or the default chime.
    /// </summary>
    public static string Sound(Reminder reminder) => reminder.WarningSoundName ?? DefaultSound;

    /// <summary>The warning card's title, the same on every platform.</summary>
    public static string Title(Reminder reminder) => $"Coming up: {reminder.Title}";

    /// <summary>
    /// The warning card's text, naming the takeover's time rather than a
    /// countdown so it stays true however long it sits on screen.
    /// </summary>
    public static string Message(Instant takeoverAt, DateTimeZone zone)
    {
        var time = takeoverAt.InZone(zone).TimeOfDay;
        return $"Takes over your screen at {time.Hour:D2}:{time.Minute:D2}.";
    }
}

/// <summary>
/// Divides a pending-notification budget across reminders.
///
/// iOS caps an app at 64 pending notification requests. Breadth-first
/// allocation guarantees the promise that matters: every reminder always has
/// at least its *next* fire scheduled before any reminder gets its second,
/// its second before any third, and so on — a 5-minute interval reminder can
/// never starve a daily one out of the budget.
/// </summary>
public static class NotificationBudget
{
    public sealed record Entry(Guid ReminderId, ProjectedFire Fire);

    /// <summary>
    /// Allocates up to <paramref name="budget"/> slots across
    /// <paramref name="projections"/>, layer by layer. Within a layer, sooner
    /// fires win; ties break on the reminder ID so the result is deterministic.
    /// </summary>
    public static IReadOnlyList<Entry> Allocate(
        IReadOnlyList<(Guid ReminderId, IReadOnlyList<ProjectedFire> Fires)> projections,
        int budget)
    {
        if (budget <= 0) return [];
        var result = new List<Entry>();
        var depth = 0;
        while (result.Count < budget)
        {
            var layer = projections
                .Where(projection => depth < projection.Fires.Count)
                .Select(projection => new Entry(projection.ReminderId, projection.Fires[depth]))
                .OrderBy(entry => entry.Fire.FireDate)
                .ThenBy(
                    entry => entry.ReminderId.ToString("D").ToUpperInvariant(),
                    StringComparer.Ordinal
                )
                .ToList();
            if (layer.Count == 0) break;
            foreach (var entry in layer)
            {
                if (result.Count >= budget) break;
                result.Add(entry);
            }
            depth += 1;
        }
        return result;
    }
}
