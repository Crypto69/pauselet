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
    /// Whether <paramref name="reminder"/> is due to fire at
    /// <paramref name="now"/>, accounting for global settings such as pause and
    /// quiet hours.
    /// </summary>
    public static bool IsDue(
        Reminder reminder, Instant now, Settings settings, DateTimeZone zone)
    {
        if (!reminder.IsEnabled) return false;
        if (IsPaused(settings, now)) return false;
        if (IsSuppressedByQuietHours(reminder.Priority, settings, now, zone)) return false;
        if (PendingFireDate(reminder, zone) is not { } pending) return false;
        return pending <= now;
    }

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
    /// When <paramref name="reminder"/> will actually reach the user, given
    /// that <paramref name="date"/> — its natural next fire — falls inside
    /// quiet hours.
    ///
    /// Interval (and snoozed) reminders stay pending through the window and
    /// fire the moment it ends; wall-clock slots inside the window are skipped,
    /// so the answer is the first subsequent slot that is not suppressed.
    /// <c>null</c> when no audible fire could be found within a sensible
    /// horizon.
    /// </summary>
    internal static Instant? NextAudibleFireDate(
        Reminder reminder, Instant date, Settings settings, DateTimeZone zone)
    {
        if (reminder.SnoozedUntil is not null)
        {
            return settings.QuietHours.NextEnd(date, zone);
        }
        switch (reminder.Schedule)
        {
            case Schedule.Interval:
                return settings.QuietHours.NextEnd(date, zone);

            case Schedule.DailyAt daily:
            {
                var slot = date;
                for (var i = 0; i < 32; i++)
                {
                    if (FirstDailySlot(
                            slot, daily.Hour, daily.Minute,
                            Math.Max(1, daily.DayInterval), zone
                        ) is not { } next) return null;
                    if (!IsSuppressedByQuietHours(reminder.Priority, settings, next, zone))
                    {
                        return next;
                    }
                    slot = next;
                }
                return null;
            }

            case Schedule.WeeklyAt weekly:
            {
                var slot = date;
                for (var i = 0; i < 32; i++)
                {
                    if (FirstWeeklySlot(
                            slot, weekly.Hour, weekly.Minute, weekly.Weekdays, zone
                        ) is not { } next) return null;
                    if (!IsSuppressedByQuietHours(reminder.Priority, settings, next, zone))
                    {
                        return next;
                    }
                    slot = next;
                }
                return null;
            }

            default:
                throw new InvalidOperationException();
        }
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
