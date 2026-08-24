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
    /// actually reach the user, honouring snooze, pause, and quiet hours
    /// exactly as the live engine does.
    ///
    /// This is the keystone of pre-scheduled delivery (iOS): there is no tick
    /// loop watching the clock, so everything the engine would have decided at
    /// fire time must be decided now. The rules are the ones <c>Tick()</c> and
    /// <c>RefreshNextUp()</c> apply:
    ///
    /// - A snooze is authoritative and fires exactly once, first.
    /// - An indefinite pause schedules nothing; a timed pause schedules
    ///   nothing before it ends, and re-anchors interval reminders to its end
    ///   just as <c>Resume()</c> does.
    /// - A wall-clock slot that lands inside quiet hours is skipped, not
    ///   delivered late; interval fires wait the window out and deliver the
    ///   moment it ends. Critical pierces when <c>AllowsCritical</c>.
    /// </summary>
    public static IReadOnlyList<ProjectedFire> ProjectedFires(
        Reminder reminder, Instant from, int limit, Settings settings, DateTimeZone zone)
    {
        if (!reminder.IsEnabled || limit <= 0) return [];
        // Paused indefinitely: nothing should be scheduled at all. Resuming
        // triggers a fresh scheduling pass, so nothing is lost.
        if (settings.PausedUntil is null && settings.IsPaused) return [];

        var sim = reminder;
        var cursor = from;
        if (settings.PausedUntil is { } until && until > from)
        {
            // Project from the pause's end. Resume() re-anchors interval
            // reminders so they do not fire the instant the pause lifts;
            // wall-clock reminders keep their anchors, so a slot that elapsed
            // during the pause surfaces as one catch-up fire at the end,
            // exactly as a post-resume tick would deliver it.
            cursor = until;
            if (sim.Schedule is Schedule.Interval)
            {
                sim = sim with { LastFiredAt = until };
            }
        }

        var fires = new List<ProjectedFire>();
        // Bounded so a schedule that can never deliver (every slot inside
        // quiet hours, say) terminates instead of spinning.
        var iterations = 0;
        var maxIterations = limit * 16 + 64;

        while (fires.Count < limit && iterations < maxIterations)
        {
            iterations += 1;
            if (Scheduler.NextFireDate(sim, cursor, zone) is not { } due)
            {
                break;
            }
            var fireAt = Instant.Max(due, cursor);
            var wasSnoozed = sim.SnoozedUntil is not null;

            // The stamp mirrors Tick(): wall-clock fires honour their slot so
            // an "every 2 days" grid stays in phase; snoozed and interval
            // fires honour the moment of delivery.
            var stamp = fireAt;
            if (!wasSnoozed && sim.Schedule.IsWallClock)
            {
                stamp = Scheduler.LatestElapsedSlot(sim, fireAt, zone) ?? fireAt;
            }

            if (Scheduler.IsSuppressedByQuietHours(sim.Priority, settings, fireAt, zone))
            {
                if (!wasSnoozed && sim.Schedule.IsWallClock)
                {
                    // The slot passes unheard inside the window — consumed,
                    // not delivered late. Same as Tick()'s skip path.
                    sim = sim with { LastFiredAt = stamp, SnoozedUntil = null };
                    cursor = fireAt;
                    continue;
                }
                // Interval (and snoozed) fires stay pending through the
                // window and deliver the moment it ends.
                if (settings.QuietHours.NextEnd(fireAt, zone) is not { } end)
                {
                    break;
                }
                sim = sim with { LastFiredAt = end, SnoozedUntil = null };
                fires.Add(new ProjectedFire(end, end));
                cursor = end;
                continue;
            }

            sim = sim with { LastFiredAt = stamp, SnoozedUntil = null };
            fires.Add(new ProjectedFire(fireAt, stamp));
            cursor = fireAt;
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
