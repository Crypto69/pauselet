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
