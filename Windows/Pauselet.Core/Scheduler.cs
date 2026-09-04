using NodaTime;

namespace Pauselet.Core;

/// <summary>
/// Calendar plumbing shared by the scheduler and quiet hours: turning an
/// instant into a local day and materialising "this day at HH:MM" as an
/// instant, DST included. The lenient resolver mirrors Apple Calendar's
/// behaviour at DST edges: a time inside a spring-forward gap lands just after
/// the gap instead of failing.
/// </summary>
internal static class CalendarMath
{
    internal static LocalDate DayOf(Instant instant, DateTimeZone zone) =>
        instant.InZone(zone).Date;

    internal static Instant StartOfDay(Instant instant, DateTimeZone zone) =>
        zone.AtStartOfDay(DayOf(instant, zone)).ToInstant();

    /// <summary>
    /// The instant at <paramref name="hour"/>:<paramref name="minute"/> on
    /// <paramref name="day"/>, or <c>null</c> for values no day can contain.
    /// </summary>
    internal static Instant? SlotAt(LocalDate day, int hour, int minute, DateTimeZone zone)
    {
        if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
        var local = day.At(new LocalTime(hour, minute));
        return zone.AtLeniently(local).ToInstant();
    }

    /// <summary>
    /// Apple <c>Calendar</c> weekday numbering (1 = Sunday ... 7 = Saturday)
    /// for a local day — the numbering the persisted data uses.
    /// </summary>
    internal static int CalendarWeekday(LocalDate day) => ((int)day.DayOfWeek % 7) + 1;

    /// <summary>Whole calendar days from <paramref name="from"/> to <paramref name="to"/>.</summary>
    internal static int DaysBetween(LocalDate from, LocalDate to) =>
        Period.Between(from, to, PeriodUnits.Days).Days;
}

/// <summary>
/// Pure scheduling logic: given a reminder and "now", when should it next fire?
///
/// Everything here is a static function over explicit inputs so the behaviour
/// can be tested exhaustively without waiting on wall-clock time. The live app
/// layers a timer on top of this; the timer only ever asks these questions.
///
/// The central concept is the *pending* fire: the moment the reminder is next
/// obliged to fire, computed purely from its own anchors (<c>LastFiredAt</c>,
/// <c>CreatedAt</c>) and never from "now". A pending date in the past means the
/// reminder is overdue and fires at the next tick. Computing due-ness this way
/// is what lets a daily 17:00 reminder actually fire when a tick lands at
/// 17:00:04 — a "next future slot" formulation can only ever see tomorrow.
/// </summary>
public static class Scheduler
{
    /// <summary>
    /// The next date at which <paramref name="reminder"/> should fire, or
    /// <c>null</c> if it never will (disabled, or a weekly schedule with no
    /// weekdays selected).
    ///
    /// An overdue reminder answers <paramref name="now"/>: it fires at the next
    /// tick, and the tray should say "due", not count down to a slot that
    /// already passed.
    /// </summary>
    public static Instant? NextFireDate(Reminder reminder, Instant now, DateTimeZone zone)
    {
        if (!reminder.IsEnabled) return null;

        // A snooze is authoritative: it is the user saying "not before this
        // time", and it is also a promise that the reminder *will* come back.
        //
        // It therefore wins over the natural slot in both directions — it can
        // pull a fire in (snooze 2 min on an hourly reminder) and push one out
        // (snooze an already-overdue reminder). It also stays the answer once
        // elapsed, so a snooze whose moment passed between two ticks fires late
        // rather than silently evaporating. The engine clears
        // <c>SnoozedUntil</c> the moment it honours it, so this can never fire
        // twice.
        if (reminder.SnoozedUntil is { } snoozedUntil)
        {
            return snoozedUntil;
        }
        if (PendingFireDate(reminder, zone) is not { } pending)
        {
            return null;
        }
        return pending > now ? pending : now;
    }

    /// <summary>
    /// The moment <paramref name="reminder"/> is next obliged to fire,
    /// independent of "now".
    ///
    /// A date in the past means the reminder is overdue: it should fire at the
    /// next opportunity. Firing stamps <c>LastFiredAt</c>, which moves the
    /// pending date forward — that stamp is the only thing that consumes a
    /// slot, so a slot that passes while the app is asleep is delivered late
    /// rather than silently skipped.
    /// </summary>
    public static Instant? PendingFireDate(Reminder reminder, DateTimeZone zone)
    {
        if (!reminder.IsEnabled) return null;
        if (reminder.SnoozedUntil is { } snoozedUntil)
        {
            return snoozedUntil;
        }
        return NextScheduleSlot(reminder, zone);
    }

    /// <summary>
    /// The first slot of the reminder's schedule strictly after its anchor
    /// (<c>LastFiredAt</c>, or <c>CreatedAt</c> if it has never fired),
    /// ignoring any snooze. This is the schedule's own opinion of when it fires
    /// next.
    /// </summary>
    public static Instant? NextScheduleSlot(Reminder reminder, DateTimeZone zone)
    {
        var anchor = reminder.LastFiredAt ?? reminder.CreatedAt;
        switch (reminder.Schedule)
        {
            case Schedule.Interval interval:
                var clamped = Math.Max(1, interval.Minutes);
                // Intervals run from the last fire; a brand new reminder starts
                // its first interval from when it was created, so a 20-minute
                // reminder added now fires in 20 minutes rather than
                // immediately.
                return anchor.Plus(Duration.FromMinutes(clamped));

            case Schedule.DailyAt daily:
                return FirstDailySlot(
                    anchor, daily.Hour, daily.Minute,
                    Math.Max(1, daily.DayInterval), zone
                );

            case Schedule.WeeklyAt weekly:
                return FirstWeeklySlot(
                    anchor, weekly.Hour, weekly.Minute, weekly.Weekdays, zone
                );

            default:
                throw new InvalidOperationException();
        }
    }

    /// <summary>
    /// The first daily-grid slot strictly after <paramref name="anchor"/>. The
    /// grid is anchored on the anchor's day, so "every 2 days" stays in phase
    /// rather than drifting.
    /// </summary>
    internal static Instant? FirstDailySlot(
        Instant anchor, int hour, int minute, int dayInterval, DateTimeZone zone)
    {
        var anchorDay = CalendarMath.DayOf(anchor, zone);
        // Starting at step 0 catches an anchor-day slot that is still ahead of
        // the anchor itself (a reminder created in the morning for 17:00).
        var step = 0;
        // Bound the search so a pathological input cannot spin forever.
        var maxSteps = dayInterval * 400 + 400;
        while (step <= maxSteps)
        {
            // A day whose slot cannot be materialised is skipped rather than
            // aborting the whole search.
            var slot = CalendarMath.SlotAt(anchorDay.PlusDays(step), hour, minute, zone);
            if (slot is { } found && found > anchor)
            {
                return found;
            }
            step += dayInterval;
        }
        return null;
    }

    /// <summary>The first selected-weekday slot strictly after <paramref name="anchor"/>.</summary>
    internal static Instant? FirstWeeklySlot(
        Instant anchor, int hour, int minute, IReadOnlySet<int> weekdays, DateTimeZone zone)
    {
        if (weekdays.Count == 0) return null;
        var anchorDay = CalendarMath.DayOf(anchor, zone);
        // Check the anchor day plus the next 7 so every weekday is covered even
        // if the anchor day's own slot has already passed.
        for (var offset = 0; offset <= 7; offset++)
        {
            var day = anchorDay.PlusDays(offset);
            if (!weekdays.Contains(CalendarMath.CalendarWeekday(day))) continue;
            if (CalendarMath.SlotAt(day, hour, minute, zone) is not { } slot) continue;
            if (slot > anchor) return slot;
        }
        return null;
    }

    /// <summary>
    /// For a wall-clock schedule, the most recent slot that has already passed:
    /// after the anchor, at or before <paramref name="now"/>. <c>null</c> for
    /// interval schedules and when no slot has elapsed.
    ///
    /// This is what the engine stamps into <c>LastFiredAt</c> when a wall-clock
    /// reminder fires. Stamping the slot rather than the tick time keeps an
    /// "every 2 days" grid in phase, and collapsing to the *latest* elapsed
    /// slot is what turns a week of missed slots into a single catch-up fire
    /// instead of a cascade.
    /// </summary>
    public static Instant? LatestElapsedSlot(Reminder reminder, Instant now, DateTimeZone zone)
    {
        var anchor = reminder.LastFiredAt ?? reminder.CreatedAt;
        switch (reminder.Schedule)
        {
            case Schedule.Interval:
                return null;

            case Schedule.DailyAt daily:
            {
                var interval = Math.Max(1, daily.DayInterval);
                var anchorDay = CalendarMath.DayOf(anchor, zone);
                var nowDay = CalendarMath.DayOf(now, zone);
                var days = CalendarMath.DaysBetween(anchorDay, nowDay);
                if (days < 0) return null;
                // Jump straight to the last grid day at or before today, then
                // walk back a step at a time; the answer is at most a couple of
                // iterations away regardless of how long the gap was.
                var step = (days / interval) * interval;
                while (step >= 0)
                {
                    var slot = CalendarMath.SlotAt(
                        anchorDay.PlusDays(step), daily.Hour, daily.Minute, zone
                    );
                    if (slot is { } found && found <= now)
                    {
                        return found > anchor ? found : null;
                    }
                    step -= interval;
                }
                return null;
            }

            case Schedule.WeeklyAt weekly:
            {
                if (weekly.Weekdays.Count == 0) return null;
                var today = CalendarMath.DayOf(now, zone);
                // Walk backwards from today; the most recent selected slot is
                // within the last 7 days if one exists at all.
                for (var offset = 0; offset <= 7; offset++)
                {
                    var day = today.PlusDays(-offset);
                    if (!weekly.Weekdays.Contains(CalendarMath.CalendarWeekday(day))) continue;
                    if (CalendarMath.SlotAt(day, weekly.Hour, weekly.Minute, zone)
                        is not { } slot) continue;
                    if (slot <= now && slot > anchor) return slot;
                    if (slot <= now) return null;
                }
                return null;
            }

            default:
                throw new InvalidOperationException();
        }
    }

    /// <summary>
    /// How long apart staggered catch-up fires are placed when several
    /// interval reminders all came due during downtime.
    /// </summary>
    public static readonly Duration StaggerStep = Duration.FromSeconds(90);

    /// <summary>
    /// The anchor an interval reminder should carry after a stretch of
    /// downtime ending at <paramref name="resumeDate"/> — a pause being
    /// lifted, a timed pause expiring, or the machine waking up.
    /// </summary>
    /// <remarks>
    /// This is the fix for reminders collapsing onto a single instant. The
    /// naive re-anchor (<c>LastFiredAt = resumeDate</c> for everything) is
    /// what welds them together: the next fire is <c>anchor + interval</c>, so
    /// an identical anchor makes every reminder sharing an interval fire at
    /// the same second, and they never come apart again.
    /// <para>
    /// Instead each reminder keeps its <em>phase</em> — how far through its
    /// interval it had got when the downtime began — so the original spacing
    /// is preserved without storing anything new. A reminder whose interval
    /// fully elapsed has no phase left, so the caller stakes out a distinct
    /// slot for each of those via <paramref name="staggerOffset"/>.
    /// </para>
    /// <para>
    /// Non-interval schedules return <c>null</c>: a wall-clock grid is
    /// anchored to the clock, not to the downtime.
    /// </para>
    /// </remarks>
    public static Instant? ReanchorForDowntime(
        Reminder reminder,
        Instant downtimeStart,
        Instant resumeDate,
        Duration staggerOffset = default)
    {
        if (reminder.Schedule is not Schedule.Interval interval) return null;
        var anchor = reminder.LastFiredAt ?? reminder.CreatedAt;
        // An anchor already past the resume point belongs to a fire that
        // happened after the downtime; it is current, so leave it alone.
        if (anchor >= resumeDate) return null;

        var length = Duration.FromMinutes(Math.Max(1, interval.Minutes));
        var due = anchor + length;

        if (due > downtimeStart)
        {
            // Still mid-interval when the downtime began. Preserve exactly the
            // remaining time by shifting the anchor forward by the length of
            // the downtime, so two reminders that were 38 minutes apart still
            // are.
            var elapsedDowntime = resumeDate - downtimeStart;
            if (elapsedDowntime <= Duration.Zero) return null;
            return anchor + elapsedDowntime;
        }

        // Fully overdue: no phase survives. Restart the interval from the
        // resume, offset so this reminder gets a slot of its own.
        return resumeDate + staggerOffset;
    }

    /// <summary>
    /// Applies <see cref="ReanchorForDowntime"/> across a whole set of
    /// reminders, allocating a distinct stagger slot to each one that went
    /// fully overdue, ordered by when it was originally due so the reminder
    /// that waited longest comes back first.
    /// </summary>
    /// <returns>The new anchor for each reminder that needs one, keyed by ID.</returns>
    public static Dictionary<Guid, Instant> ReanchorAllForDowntime(
        IReadOnlyList<Reminder> reminders,
        Instant downtimeStart,
        Instant resumeDate,
        Func<Reminder, bool>? includeReminder = null)
    {
        var include = includeReminder ?? (_ => true);

        var overdue = new List<(Guid Id, Instant Due)>();
        foreach (var reminder in reminders)
        {
            if (!include(reminder)) continue;
            if (reminder.Schedule is not Schedule.Interval interval) continue;
            var anchor = reminder.LastFiredAt ?? reminder.CreatedAt;
            if (anchor >= resumeDate) continue;
            var due = anchor + Duration.FromMinutes(Math.Max(1, interval.Minutes));
            if (due <= downtimeStart) overdue.Add((reminder.Id, due));
        }
        overdue.Sort((a, b) =>
            a.Due == b.Due
                ? string.CompareOrdinal(a.Id.ToString(), b.Id.ToString())
                : a.Due.CompareTo(b.Due));

        var slot = new Dictionary<Guid, int>();
        for (var i = 0; i < overdue.Count; i++) slot[overdue[i].Id] = i;

        var result = new Dictionary<Guid, Instant>();
        foreach (var reminder in reminders)
        {
            if (!include(reminder)) continue;
            var offset = slot.TryGetValue(reminder.Id, out var rank)
                ? StaggerStep * rank
                : Duration.Zero;
            if (ReanchorForDowntime(reminder, downtimeStart, resumeDate, offset)
                is { } anchor)
            {
                result[reminder.Id] = anchor;
            }
        }
        return result;
    }

    /// <summary>
    /// One decision of the firing policy: when the engine next acts on a
    /// reminder, what it stamps, and whether the user hears it. Produced by
    /// <see cref="NextStep"/>, applied once by <c>Tick()</c> and repeatedly by
    /// the projection, so the two cannot hold different opinions.
    /// </summary>
    public sealed record FireStep(Instant FireDate, Instant StampDate, FireStep.Outcome StepOutcome)
    {
        public enum Outcome
        {
            /// <summary>The reminder reaches the user at <c>FireDate</c>.</summary>
            Deliver,
            /// <summary>
            /// A wall-clock slot that passed inside quiet hours is consumed
            /// unheard at <c>FireDate</c> and recorded as missed — "daily at
            /// 23:00" must not arrive at 07:00.
            /// </summary>
            Skip,
        }

        /// <summary>
        /// The reminder as the engine leaves it the moment it acts on this
        /// step: anchored at the stamp, any snooze consumed.
        /// </summary>
        public Reminder Apply(Reminder reminder) =>
            reminder with { LastFiredAt = StampDate, SnoozedUntil = null };
    }

    /// <summary>
    /// The next thing the engine will do with <paramref name="reminder"/> at
    /// or after <paramref name="now"/>, or <c>null</c> if nothing will ever
    /// happen (disabled, paused indefinitely, a weekly schedule with no days).
    ///
    /// The rules, in order (mirrors <c>Scheduler.nextStep</c> in Swift):
    /// - An indefinite pause schedules nothing. A timed pause schedules
    ///   nothing before it ends, and re-anchors interval reminders to its end
    ///   — the same thing the engine does when the pause expires — so a long
    ///   pause never dumps an overdue fire the instant it lifts.
    /// - A snooze is authoritative and fires exactly once, at its moment.
    /// - A fire that falls due inside quiet hours waits for the window to
    ///   end. Interval and snoozed fires are then delivered ("it has been an
    ///   hour since water" is still true at 07:00); a wall-clock slot is
    ///   judged *at the slot*: one that passed inside the window is skipped,
    ///   one that passed outside it (the app was asleep from 17:00 until the
    ///   window began) is delivered late, stamped with the slot.
    /// - Overdue wall-clock slots collapse to the latest elapsed one, so a
    ///   week away becomes a single catch-up rather than a cascade.
    /// </summary>
    public static FireStep? NextStep(
        Reminder reminder, Instant now, Settings settings, DateTimeZone zone)
    {
        if (!reminder.IsEnabled) return null;
        if (settings.PausedUntil is null && settings.IsPaused) return null;

        var sim = reminder;
        var cursor = now;
        if (settings.PausedUntil is { } until && until > now)
        {
            cursor = until;
            // Re-anchor exactly as the engine will when the pause expires,
            // preserving the reminder's phase, so the projection and the live
            // engine cannot disagree about when this lands.
            if (ReanchorForDowntime(sim, now, until) is { } anchor)
            {
                sim = sim with { LastFiredAt = anchor };
            }
        }

        if (PendingFireDate(sim, zone) is not { } pending) return null;
        var due = Instant.Max(pending, cursor);
        if (DeliveryMoment(due, sim.Priority, settings, zone) is not { } fireAt) return null;

        if (sim.SnoozedUntil is not null || !sim.Schedule.IsWallClock)
        {
            return new FireStep(fireAt, fireAt, FireStep.Outcome.Deliver);
        }

        var slot = LatestElapsedSlot(sim, fireAt, zone) ?? fireAt;
        var skipped = IsSuppressedByQuietHours(sim.Priority, settings, slot, zone);
        return new FireStep(
            fireAt, slot, skipped ? FireStep.Outcome.Skip : FireStep.Outcome.Deliver
        );
    }

    /// <summary>
    /// When a fire that falls due at <paramref name="due"/> is actually acted
    /// on: <paramref name="due"/> itself, or — if quiet hours cover it — the
    /// moment the window ends. <c>null</c> only when the window's end cannot
    /// be computed.
    /// </summary>
    public static Instant? DeliveryMoment(
        Instant due, Priority priority, Settings settings, DateTimeZone zone)
    {
        if (!IsSuppressedByQuietHours(priority, settings, due, zone)) return due;
        return settings.QuietHours.NextEnd(due, zone);
    }

    /// <summary>
    /// Whether <paramref name="reminder"/> is due to fire at
    /// <paramref name="now"/>, accounting for global settings such as pause and
    /// quiet hours. Defined through <see cref="NextStep"/> so it cannot
    /// disagree with what the engine would actually do.
    /// </summary>
    public static bool IsDue(
        Reminder reminder, Instant now, Settings settings, DateTimeZone zone) =>
        NextStep(reminder, now, settings, zone) is { } step && step.FireDate <= now;

    /// <summary>True when the master pause is active. A timed pause expires on its own.</summary>
    public static bool IsPaused(Settings settings, Instant now)
    {
        if (settings.PausedUntil is { } until)
        {
            return now < until;
        }
        return settings.IsPaused;
    }

    /// <summary>True when quiet hours should suppress a reminder of this priority.</summary>
    public static bool IsSuppressedByQuietHours(
        Priority priority, Settings settings, Instant now, DateTimeZone zone)
    {
        var quiet = settings.QuietHours;
        if (!quiet.Contains(now, zone)) return false;
        if (quiet.AllowsCritical && priority == Priority.Critical) return false;
        return true;
    }

    /// <summary>
    /// The soonest upcoming reminder across <paramref name="reminders"/>, used
    /// for the tray countdown. Ties break toward the higher priority.
    /// </summary>
    public static (Reminder Reminder, Instant Date)? NextUpcoming(
        IEnumerable<Reminder> reminders, Instant now, DateTimeZone zone)
    {
        (Reminder Reminder, Instant Date)? best = null;
        foreach (var reminder in reminders)
        {
            if (NextFireDate(reminder, now, zone) is not { } date)
            {
                continue;
            }
            if (best is not { } current)
            {
                best = (reminder, date);
                continue;
            }
            if (date < current.Date
                || (date == current.Date && reminder.Priority > current.Reminder.Priority))
            {
                best = (reminder, date);
            }
        }
        return best;
    }

    /// <summary>Human-readable countdown such as "in 4 min" or "in 2h 10m".</summary>
    public static string CountdownText(Instant now, Instant date)
    {
        var remaining = (date - now).TotalSeconds;
        if (remaining <= 0) return "now";
        var totalMinutes = (int)Math.Ceiling(remaining) / 60;
        if (totalMinutes < 1) return "<1 min";
        if (totalMinutes < 60) return $"{totalMinutes} min";
        var hours = totalMinutes / 60;
        var minutes = totalMinutes % 60;
        if (minutes == 0) return $"{hours}h";
        return $"{hours}h {minutes}m";
    }
}
