using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// Tests for the pure scheduling logic. Every case pins "now" to a fixed date
/// so results are deterministic regardless of when the suite runs.
/// </summary>
public class SchedulerTests
{
    // A fixed calendar in UTC keeps wall-clock assertions stable on any machine.
    private static readonly DateTimeZone Utc = DateTimeZone.Utc;

    private static Instant Date(int year, int month, int day, int hour = 0, int minute = 0) =>
        TestDates.At(Utc, year, month, day, hour, minute);

    // MARK: - Interval schedules

    [Fact]
    public void IntervalFirstFireIsOneIntervalAfterCreation()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Weight Shift",
            Schedule = new Schedule.Interval(20),
            CreatedAt = created,
        };
        var next = Scheduler.NextFireDate(reminder, created, Utc);
        Assert.Equal(Date(2026, 3, 10, 9, 20), next);
    }

    [Fact]
    public void IntervalFiresFromLastFiredNotCreation()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Tilt Back",
            Schedule = new Schedule.Interval(60),
            CreatedAt = created,
        };
        reminder = reminder with { LastFiredAt = Date(2026, 3, 10, 11, 30) };
        var next = Scheduler.NextFireDate(reminder, Date(2026, 3, 10, 11, 45), Utc);
        Assert.Equal(Date(2026, 3, 10, 12, 30), next);
    }

    /// <summary>
    /// If the machine slept for hours we want a single catch-up fire, not a
    /// burst of every interval that elapsed while it was away.
    /// </summary>
    [Fact]
    public void OverdueIntervalCollapsesToNowRatherThanReplaying()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Weight Shift",
            Schedule = new Schedule.Interval(20),
            CreatedAt = created,
        };
        reminder = reminder with { LastFiredAt = Date(2026, 3, 10, 9, 0) };
        var now = Date(2026, 3, 10, 15, 0); // 6 hours later = 18 missed intervals
        var next = Scheduler.NextFireDate(reminder, now, Utc);
        Assert.Equal(now, next); // An overdue interval should fire once, immediately
    }

    [Fact]
    public void DisabledReminderNeverFires()
    {
        var reminder = new Reminder
        {
            Title = "Off",
            Schedule = new Schedule.Interval(5),
            CreatedAt = Date(2026, 3, 10, 9, 0),
        };
        reminder = reminder with { IsEnabled = false };
        Assert.Null(Scheduler.NextFireDate(reminder, Date(2026, 3, 10, 12, 0), Utc));
    }

    [Fact]
    public void ZeroOrNegativeIntervalIsClampedToOneMinute()
    {
        var created = Date(2026, 3, 10, 9, 0);
        foreach (var badInterval in new[] { 0, -5 })
        {
            var reminder = new Reminder
            {
                Title = "Bad",
                Schedule = new Schedule.Interval(badInterval),
                CreatedAt = created,
            };
            var next = Scheduler.NextFireDate(reminder, created, Utc);
            // Interval should clamp to 1 minute, not spin.
            Assert.Equal(Date(2026, 3, 10, 9, 1), next);
        }
    }

    // MARK: - Snooze

    [Fact]
    public void SnoozePushesFireDateOut()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Tilt Back",
            Schedule = new Schedule.Interval(60),
            CreatedAt = created,
        };
        reminder = reminder with
        {
            LastFiredAt = created,
            SnoozedUntil = Date(2026, 3, 10, 10, 15),
        };
        var next = Scheduler.NextFireDate(reminder, Date(2026, 3, 10, 10, 5), Utc);
        Assert.Equal(Date(2026, 3, 10, 10, 15), next);
    }

    /// <summary>
    /// A snooze whose moment passed between two ticks must still fire, late,
    /// rather than silently evaporating. The engine clears <c>SnoozedUntil</c>
    /// as soon as it honours it, so a stale snooze cannot fire twice.
    /// </summary>
    [Fact]
    public void ElapsedSnoozeStillFiresRatherThanBeingSkipped()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Tilt Back",
            Schedule = new Schedule.Interval(60),
            CreatedAt = created,
        };
        reminder = reminder with
        {
            LastFiredAt = Date(2026, 3, 10, 10, 0),
            SnoozedUntil = Date(2026, 3, 10, 10, 2),
        };
        var now = Date(2026, 3, 10, 10, 5); // tick landed 3 minutes late
        var next = Scheduler.NextFireDate(reminder, now, Utc);

        Assert.Equal(Date(2026, 3, 10, 10, 2), next);
        // An elapsed snooze should be due immediately.
        Assert.True(Scheduler.IsDue(reminder, now, new Settings(), Utc));
    }

    /// <summary>
    /// Snoozing an already-overdue reminder must actually delay it. Without
    /// this, the catch-up "fire now" path would override the snooze and the
    /// reminder would reappear on the very next tick.
    /// </summary>
    [Fact]
    public void SnoozingAnOverdueReminderHonoursTheSnooze()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Shift",
            Schedule = new Schedule.Interval(20),
            CreatedAt = created,
        };
        reminder = reminder with
        {
            LastFiredAt = Date(2026, 3, 10, 9, 0), // long overdue
            SnoozedUntil = Date(2026, 3, 10, 10, 15),
        };
        var now = Date(2026, 3, 10, 10, 5);

        Assert.Equal(Date(2026, 3, 10, 10, 15), Scheduler.NextFireDate(reminder, now, Utc));
        Assert.False(Scheduler.IsDue(reminder, now, new Settings(), Utc));
    }

    // MARK: - Daily / multi-day schedules

    [Fact]
    public void DailyFiresTodayWhenSlotStillAhead()
    {
        var created = Date(2026, 3, 10, 8, 0);
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(17, 0, 1),
            CreatedAt = created,
        };
        var next = Scheduler.NextFireDate(reminder, Date(2026, 3, 10, 9, 0), Utc);
        Assert.Equal(Date(2026, 3, 10, 17, 0), next);
    }

    [Fact]
    public void DailyRollsToTomorrowOnceTodaysSlotHasFired()
    {
        var created = Date(2026, 3, 10, 8, 0);
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(17, 0, 1),
            CreatedAt = created,
        };
        reminder = reminder with { LastFiredAt = Date(2026, 3, 10, 17, 0) };
        var next = Scheduler.NextFireDate(reminder, Date(2026, 3, 10, 18, 0), Utc);
        Assert.Equal(Date(2026, 3, 11, 17, 0), next);
    }

    /// <summary>
    /// A slot that passed without ever firing (the app was closed at 17:00) is
    /// overdue, not skipped: it must be due immediately so it fires once, late.
    /// </summary>
    [Fact]
    public void DailySlotThatPassedUnfiredIsDueImmediately()
    {
        var created = Date(2026, 3, 10, 8, 0);
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(17, 0, 1),
            CreatedAt = created,
        };
        var now = Date(2026, 3, 10, 18, 0);
        // An elapsed, unfired slot answers "now", not tomorrow.
        Assert.Equal(now, Scheduler.NextFireDate(reminder, now, Utc));
        Assert.True(Scheduler.IsDue(reminder, now, new Settings(), Utc));
    }

    /// <summary>
    /// "Every 2 days" must stay in phase with the last fire rather than
    /// drifting or collapsing to daily.
    /// </summary>
    [Fact]
    public void EveryTwoDaysStaysInPhaseWithLastFire()
    {
        var created = Date(2026, 3, 1, 8, 0);
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(17, 0, 2),
            CreatedAt = created,
        };
        reminder = reminder with { LastFiredAt = Date(2026, 3, 10, 17, 0) };
        var next = Scheduler.NextFireDate(reminder, Date(2026, 3, 10, 18, 0), Utc);
        Assert.Equal(Date(2026, 3, 12, 17, 0), next); // Should skip the 11th
    }

    /// <summary>
    /// After missing several cycles the reminder is due once, immediately, and
    /// the catch-up collapses to the *latest* missed slot so the next fire
    /// still lands on the cycle grid.
    /// </summary>
    [Fact]
    public void EveryTwoDaysAfterLongGapCatchesUpOnceAndKeepsTheGrid()
    {
        var created = Date(2026, 3, 1, 8, 0);
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(17, 0, 2),
            CreatedAt = created,
        };
        reminder = reminder with { LastFiredAt = Date(2026, 3, 2, 17, 0) };
        var now = Date(2026, 3, 9, 12, 0);

        // Grid from Mar 2: 4, 6, 8, 10. Slots on the 4th, 6th and 8th were
        // missed, so the reminder is due right now.
        Assert.Equal(now, Scheduler.NextFireDate(reminder, now, Utc));

        // The engine stamps the latest elapsed slot when it fires the catch-up…
        var elapsed = Scheduler.LatestElapsedSlot(reminder, now, Utc);
        Assert.Equal(Date(2026, 3, 8, 17, 0), elapsed);

        // …which keeps the grid in phase: the next fire is Mar 10, not Mar 11.
        reminder = reminder with { LastFiredAt = elapsed };
        Assert.Equal(Date(2026, 3, 10, 17, 0), Scheduler.NextFireDate(reminder, now, Utc));
    }

    // MARK: - Weekly schedules

    [Fact]
    public void WeeklyPicksNextSelectedWeekday()
    {
        var created = Date(2026, 3, 9, 8, 0); // Monday
        // Weekday numbering: 1 = Sunday ... 7 = Saturday. Wed = 4, Fri = 6.
        var reminder = new Reminder
        {
            Title = "Call Mum",
            Schedule = new Schedule.WeeklyAt(10, 30, new HashSet<int> { 4, 6 }),
            CreatedAt = created,
        };
        var next = Scheduler.NextFireDate(reminder, Date(2026, 3, 9, 9, 0), Utc);
        Assert.Equal(Date(2026, 3, 11, 10, 30), next); // Next Wednesday
    }

    [Fact]
    public void WeeklyWrapsToNextWeekOnceThisWeeksSlotHasFired()
    {
        var created = Date(2026, 3, 9, 8, 0);
        var reminder = new Reminder
        {
            Title = "Call Mum",
            Schedule = new Schedule.WeeklyAt(10, 30, new HashSet<int> { 2 }), // Monday only
            CreatedAt = created,
        };
        // Monday 11:00, and the 10:30 slot already fired -> next Monday.
        reminder = reminder with { LastFiredAt = Date(2026, 3, 9, 10, 30) };
        var next = Scheduler.NextFireDate(reminder, Date(2026, 3, 9, 11, 0), Utc);
        Assert.Equal(Date(2026, 3, 16, 10, 30), next);
    }

    /// <summary>A weekly slot that passed without firing is due, not deferred a week.</summary>
    [Fact]
    public void WeeklySlotThatPassedUnfiredIsDueImmediately()
    {
        var created = Date(2026, 3, 9, 8, 0);
        var reminder = new Reminder
        {
            Title = "Call Mum",
            Schedule = new Schedule.WeeklyAt(10, 30, new HashSet<int> { 2 }),
            CreatedAt = created,
        };
        var now = Date(2026, 3, 9, 11, 0);
        Assert.Equal(now, Scheduler.NextFireDate(reminder, now, Utc));
        Assert.True(Scheduler.IsDue(reminder, now, new Settings(), Utc));
    }

    [Fact]
    public void WeeklyWithNoWeekdaysNeverFires()
    {
        var reminder = new Reminder
        {
            Title = "Nothing",
            Schedule = new Schedule.WeeklyAt(10, 0, new HashSet<int>()),
            CreatedAt = Date(2026, 3, 9, 8, 0),
        };
        Assert.Null(Scheduler.NextFireDate(reminder, Date(2026, 3, 9, 9, 0), Utc));
    }

    // MARK: - Quiet hours

    [Fact]
    public void QuietHoursWrappingMidnightContainsLateNightAndEarlyMorning()
    {
        var quiet = new QuietHours
        {
            IsEnabled = true, StartHour = 22, StartMinute = 0, EndHour = 7, EndMinute = 0,
        };
        Assert.True(quiet.Contains(Date(2026, 3, 10, 23, 30), Utc));
        Assert.True(quiet.Contains(Date(2026, 3, 10, 2, 0), Utc));
        Assert.False(quiet.Contains(Date(2026, 3, 10, 12, 0), Utc));
        // End of the window is exclusive.
        Assert.False(quiet.Contains(Date(2026, 3, 10, 7, 0), Utc));
        // Start of the window is inclusive.
        Assert.True(quiet.Contains(Date(2026, 3, 10, 22, 0), Utc));
    }

    [Fact]
    public void QuietHoursSameDayWindow()
    {
        var quiet = new QuietHours
        {
            IsEnabled = true, StartHour = 13, StartMinute = 0, EndHour = 14, EndMinute = 0,
        };
        Assert.True(quiet.Contains(Date(2026, 3, 10, 13, 30), Utc));
        Assert.False(quiet.Contains(Date(2026, 3, 10, 12, 59), Utc));
        Assert.False(quiet.Contains(Date(2026, 3, 10, 23, 0), Utc));
    }

    [Fact]
    public void DisabledQuietHoursNeverContains()
    {
        var quiet = new QuietHours
        {
            IsEnabled = false, StartHour = 0, StartMinute = 0, EndHour = 23, EndMinute = 59,
        };
        Assert.False(quiet.Contains(Date(2026, 3, 10, 12, 0), Utc));
    }

    /// <summary>
    /// Pressure-relief reminders are medically necessary, so critical is
    /// allowed to pierce quiet hours when the user opts in.
    /// </summary>
    [Fact]
    public void CriticalPiercesQuietHoursWhenAllowed()
    {
        var settings = new Settings
        {
            QuietHours = new QuietHours
            {
                IsEnabled = true, StartHour = 22, StartMinute = 0,
                EndHour = 7, EndMinute = 0, AllowsCritical = true,
            },
        };
        var night = Date(2026, 3, 10, 23, 0);
        Assert.False(
            Scheduler.IsSuppressedByQuietHours(Priority.Critical, settings, night, Utc)
        );
        Assert.True(
            Scheduler.IsSuppressedByQuietHours(Priority.Important, settings, night, Utc)
        );
    }

    [Fact]
    public void CriticalSuppressedWhenNotAllowed()
    {
        var settings = new Settings
        {
            QuietHours = new QuietHours
            {
                IsEnabled = true, StartHour = 22, StartMinute = 0,
                EndHour = 7, EndMinute = 0, AllowsCritical = false,
            },
        };
        Assert.True(
            Scheduler.IsSuppressedByQuietHours(
                Priority.Critical, settings, Date(2026, 3, 10, 23, 0), Utc
            )
        );
    }

    // MARK: - Due / pause

    [Fact]
    public void IsDueRespectsPause()
    {
        var settings = new Settings { IsPaused = true };
        var reminder = new Reminder
        {
            Title = "Tilt",
            Schedule = new Schedule.Interval(60),
            CreatedAt = Date(2026, 3, 10, 9, 0),
        };
        reminder = reminder with { LastFiredAt = Date(2026, 3, 10, 9, 0) };
        Assert.False(Scheduler.IsDue(reminder, Date(2026, 3, 10, 11, 0), settings, Utc));
    }

    [Fact]
    public void TimedPauseExpires()
    {
        var settings = new Settings
        {
            IsPaused = true,
            PausedUntil = Date(2026, 3, 10, 10, 0),
        };
        Assert.True(Scheduler.IsPaused(settings, Date(2026, 3, 10, 9, 59)));
        Assert.False(Scheduler.IsPaused(settings, Date(2026, 3, 10, 10, 1)));
    }

    // MARK: - Next upcoming

    [Fact]
    public void NextUpcomingPicksSoonest()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var hourly = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(60), CreatedAt = created,
        } with { LastFiredAt = created };
        var frequent = new Reminder
        {
            Title = "Shift", Schedule = new Schedule.Interval(20), CreatedAt = created,
        } with { LastFiredAt = created };

        var result = Scheduler.NextUpcoming(
            [hourly, frequent], Date(2026, 3, 10, 9, 5), Utc
        );
        Assert.Equal("Shift", result?.Reminder.Title);
        Assert.Equal(Date(2026, 3, 10, 9, 20), result?.Date);
    }

    [Fact]
    public void NextUpcomingBreaksTiesByPriority()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var low = new Reminder
        {
            Title = "Low", Schedule = new Schedule.Interval(30),
            Priority = Priority.Subtle, CreatedAt = created,
        } with { LastFiredAt = created };
        var high = new Reminder
        {
            Title = "High", Schedule = new Schedule.Interval(30),
            Priority = Priority.Critical, CreatedAt = created,
        } with { LastFiredAt = created };

        var result = Scheduler.NextUpcoming([low, high], Date(2026, 3, 10, 9, 5), Utc);
        Assert.Equal("High", result?.Reminder.Title);
    }

    [Fact]
    public void NextUpcomingWithNoCandidatesIsNull()
    {
        Assert.Null(
            Scheduler.NextUpcoming([], SystemClock.Instance.GetCurrentInstant(), Utc)
        );
    }

    // MARK: - Countdown formatting

    [Fact]
    public void CountdownText()
    {
        var now = Date(2026, 3, 10, 9, 0);
        Assert.Equal("now", Scheduler.CountdownText(now, now));
        Assert.Equal("now", Scheduler.CountdownText(now, now.Plus(Duration.FromSeconds(-60))));
        Assert.Equal("<1 min", Scheduler.CountdownText(now, now.Plus(Duration.FromSeconds(30))));
        Assert.Equal("20 min", Scheduler.CountdownText(now, now.Plus(Duration.FromMinutes(20))));
        Assert.Equal("1h", Scheduler.CountdownText(now, now.Plus(Duration.FromMinutes(60))));
        Assert.Equal("2h 10m", Scheduler.CountdownText(now, now.Plus(Duration.FromMinutes(130))));
    }

    // MARK: - Priority ordering

    [Fact]
    public void PriorityOrdering()
    {
        Assert.True(Priority.Subtle < Priority.Normal);
        Assert.True(Priority.Normal < Priority.Important);
        Assert.True(Priority.Important < Priority.Critical);
        Assert.Equal(
            [Priority.Subtle, Priority.Normal, Priority.Important, Priority.Critical],
            Enum.GetValues<Priority>().OrderBy(p => p).ToArray()
        );
    }

    // MARK: - Schedule summaries

    [Fact]
    public void ScheduleSummaries()
    {
        Assert.Equal("Every 20 min", new Schedule.Interval(20).Summary);
        Assert.Equal("Every hour", new Schedule.Interval(60).Summary);
        Assert.Equal("Every 2 hours", new Schedule.Interval(120).Summary);
        Assert.Equal("Every 1h 30m", new Schedule.Interval(90).Summary);
        Assert.Equal("Daily at 17:00", new Schedule.DailyAt(17, 0, 1).Summary);
        Assert.Equal("Every 2 days at 09:05", new Schedule.DailyAt(9, 5, 2).Summary);
        Assert.Equal(
            "Mon, Wed at 10:30",
            new Schedule.WeeklyAt(10, 30, new HashSet<int> { 2, 4 }).Summary
        );
    }
}
