using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// Tests for the awkward real-world situations a long-running background app
/// actually meets: the machine sleeping, clocks going forward, months ending,
/// and reminders being edited while they are due.
/// </summary>
public class EdgeCaseTests
{
    private static readonly DateTimeZone Utc = DateTimeZone.Utc;

    /// <summary>A zone that observes daylight saving, for the DST cases.</summary>
    private static readonly DateTimeZone Sydney = TestDates.Zone("Australia/Sydney");

    private static Instant Date(
        DateTimeZone zone, int year, int month, int day, int hour = 0, int minute = 0) =>
        TestDates.At(zone, year, month, day, hour, minute);

    // MARK: - Sleep and wake

    /// <summary>
    /// The timer does not fire while the machine is asleep. On wake, a reminder
    /// that came due during the nap must fire once — not once per missed
    /// interval, and not never.
    /// </summary>
    [Fact]
    public void ReminderDueDuringSleepFiresExactlyOnceOnWake()
    {
        var start = Date(Utc, 2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Weight Shift", Schedule = new Schedule.Interval(20), CreatedAt = start,
        } with { LastFiredAt = start };

        var store = new InMemoryDataStore(new AppData { Reminders = [reminder] });
        var clock = new MutableDateProvider(start);
        var presenter = new RecordingPresenter();
        var engine = new ReminderEngine(store, clock, presenter, Utc);

        // Asleep for three hours — nine intervals missed.
        clock.AdvanceSeconds(3 * 60 * 60);
        Assert.Single(engine.Tick()); // One catch-up fire, not nine

        // The next one is a full interval after the catch-up.
        clock.AdvanceSeconds(19 * 60);
        Assert.Empty(engine.Tick());
        clock.AdvanceSeconds(2 * 60);
        Assert.Single(engine.Tick());
        Assert.Equal(2, presenter.Presented.Count);
    }

    /// <summary>
    /// Several reminders all overdue after a long sleep should each fire once,
    /// with the critical one presented last so it ends up in front.
    /// </summary>
    [Fact]
    public void MultipleOverdueRemindersEachFireOnceOrderedByPriority()
    {
        var start = Date(Utc, 2026, 3, 10, 9, 0);
        Reminder MakeReminder(string title, Priority priority) => new Reminder
        {
            Title = title, Schedule = new Schedule.Interval(30),
            Priority = priority, CreatedAt = start,
        } with { LastFiredAt = start };
        var reminders = new[]
        {
            MakeReminder("Water", Priority.Normal),
            MakeReminder("Tilt", Priority.Critical),
            MakeReminder("Shift", Priority.Subtle),
        };

        var store = new InMemoryDataStore(new AppData { Reminders = reminders });
        var clock = new MutableDateProvider(start);
        var presenter = new RecordingPresenter();
        var engine = new ReminderEngine(store, clock, presenter, Utc);

        clock.AdvanceSeconds(5 * 60 * 60);
        Assert.Equal(3, engine.Tick().Count);
        // Presented lowest priority first, so critical ends up on top.
        Assert.Equal(
            ["Shift", "Water", "Tilt"],
            presenter.Presented.Select(r => r.Title).ToArray()
        );
    }

    // MARK: - Daylight saving

    /// <summary>
    /// When the clocks go forward, a daily reminder should still fire at its
    /// wall-clock time rather than sliding by an hour.
    /// </summary>
    [Fact]
    public void DailyReminderKeepsWallClockTimeAcrossDstStart()
    {
        // Sydney moves to daylight time on 4 October 2026: 02:00 -> 03:00.
        var beforeChange = Date(Sydney, 2026, 10, 3, 12, 0);
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(9, 0, 1),
            CreatedAt = beforeChange,
        } with { LastFiredAt = Date(Sydney, 2026, 10, 3, 9, 0) };

        var next = Scheduler.NextFireDate(reminder, beforeChange, Sydney);

        // Still 09:00 local on the following day, despite the day being 23h long.
        Assert.NotNull(next);
        var components = next!.Value.InZone(Sydney);
        Assert.Equal(2026, components.Year);
        Assert.Equal(10, components.Month);
        Assert.Equal(4, components.Day);
        Assert.Equal(9, components.Hour);
        Assert.Equal(0, components.Minute);
    }

    /// <summary>The same when the clocks go back and the day is 25 hours long.</summary>
    [Fact]
    public void DailyReminderKeepsWallClockTimeAcrossDstEnd()
    {
        // Sydney returns to standard time on 5 April 2026: 03:00 -> 02:00.
        var beforeChange = Date(Sydney, 2026, 4, 4, 12, 0);
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(9, 0, 1),
            CreatedAt = beforeChange,
        } with { LastFiredAt = Date(Sydney, 2026, 4, 4, 9, 0) };

        var next = Scheduler.NextFireDate(reminder, beforeChange, Sydney);
        Assert.NotNull(next);
        var components = next!.Value.InZone(Sydney);
        Assert.Equal(5, components.Day);
        Assert.Equal(9, components.Hour);
        Assert.Equal(0, components.Minute);
    }

    /// <summary>
    /// An interval reminder is a pure duration, so an hour lost to DST simply
    /// means the wall-clock time it lands on shifts. It must not skip or
    /// double.
    /// </summary>
    [Fact]
    public void IntervalReminderIsUnaffectedByDstBoundary()
    {
        // 01:30 Sydney, half an hour before the clocks jump to 03:00.
        var start = Date(Sydney, 2026, 10, 4, 1, 30);
        var reminder = new Reminder
        {
            Title = "Shift", Schedule = new Schedule.Interval(60), CreatedAt = start,
        } with { LastFiredAt = start };

        var next = Scheduler.NextFireDate(reminder, start, Sydney);
        // An interval is a duration; it stays exactly one hour.
        Assert.Equal(start.Plus(Duration.FromSeconds(3600)), next);
    }

    // MARK: - Month and year boundaries

    [Fact]
    public void EveryTwoDaysCrossesMonthEndCorrectly()
    {
        var created = Date(Utc, 2026, 1, 1, 8, 0);
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(10, 0, 2),
            CreatedAt = created,
        } with { LastFiredAt = Date(Utc, 2026, 1, 31, 10, 0) };

        var next = Scheduler.NextFireDate(reminder, Date(Utc, 2026, 1, 31, 11, 0), Utc);
        Assert.Equal(Date(Utc, 2026, 2, 2, 10, 0), next);
    }

    [Fact]
    public void DailyReminderCrossesYearEnd()
    {
        var created = Date(Utc, 2026, 12, 30, 8, 0);
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(9, 0, 1),
            CreatedAt = created,
        } with { LastFiredAt = Date(Utc, 2026, 12, 31, 9, 0) };

        var next = Scheduler.NextFireDate(reminder, Date(Utc, 2026, 12, 31, 10, 0), Utc);
        Assert.Equal(Date(Utc, 2027, 1, 1, 9, 0), next);
    }

    [Fact]
    public void EveryTwoDaysHandlesLeapDay()
    {
        var created = Date(Utc, 2028, 2, 1, 8, 0);
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(10, 0, 2),
            CreatedAt = created,
            // 2028 is a leap year, so the 29th exists.
        } with { LastFiredAt = Date(Utc, 2028, 2, 27, 10, 0) };

        var next = Scheduler.NextFireDate(reminder, Date(Utc, 2028, 2, 27, 11, 0), Utc);
        Assert.Equal(Date(Utc, 2028, 2, 29, 10, 0), next);
    }

    [Fact]
    public void WeeklyReminderWrapsAcrossYearEnd()
    {
        // 31 December 2026 is a Thursday; the next Monday is 4 January 2027.
        var created = Date(Utc, 2026, 12, 28, 8, 0);
        var reminder = new Reminder
        {
            Title = "Call Mum",
            Schedule = new Schedule.WeeklyAt(18, 0, new HashSet<int> { 2 }),
            CreatedAt = created,
            // Monday the 28th's slot already fired, so the next is across the year.
        } with { LastFiredAt = Date(Utc, 2026, 12, 28, 18, 0) };

        var next = Scheduler.NextFireDate(reminder, Date(Utc, 2026, 12, 31, 12, 0), Utc);
        Assert.Equal(Date(Utc, 2027, 1, 4, 18, 0), next);
    }

    // MARK: - Editing a live reminder

    /// <summary>
    /// Changing the schedule of a reminder that is currently overdue should
    /// take effect immediately rather than firing on the old schedule once
    /// more.
    /// </summary>
    [Fact]
    public void EditingScheduleWhileOverdueAppliesImmediately()
    {
        var start = Date(Utc, 2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Shift", Schedule = new Schedule.Interval(20), CreatedAt = start,
        } with { LastFiredAt = start };

        var store = new InMemoryDataStore(new AppData { Reminders = [reminder] });
        var clock = new MutableDateProvider(start);
        var presenter = new RecordingPresenter();
        var engine = new ReminderEngine(store, clock, presenter, Utc);

        // Overdue by 40 minutes, then the user stretches the interval to 2 hours.
        clock.AdvanceSeconds(60 * 60);
        var edited = engine.Reminders[0] with
        {
            Schedule = new Schedule.Interval(120),
            LastFiredAt = clock.Now,
        };
        engine.Update(edited);

        Assert.Empty(engine.Tick()); // The new interval applies at once
        clock.AdvanceSeconds(2 * 60 * 60);
        Assert.Single(engine.Tick());
    }

    /// <summary>
    /// Deleting a reminder while it is on screen must not leave the engine
    /// trying to act on it.
    /// </summary>
    [Fact]
    public void CompletingADeletedReminderIsHarmless()
    {
        var start = Date(Utc, 2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Gone", Schedule = new Schedule.Interval(10), CreatedAt = start,
        } with { LastFiredAt = start };

        var store = new InMemoryDataStore(new AppData { Reminders = [reminder] });
        var clock = new MutableDateProvider(start);
        var engine = new ReminderEngine(store, clock, null, Utc);

        clock.AdvanceSeconds(10 * 60);
        engine.Tick();
        var id = reminder.Id;
        engine.Delete(id);

        // The overlay is still up and the user clicks Done.
        engine.Complete(id);
        engine.Snooze(id);
        engine.Dismiss(id);

        Assert.Empty(engine.Reminders);
    }

    // MARK: - Quiet hours boundaries

    /// <summary>
    /// A reminder suppressed by quiet hours should fire once they end, rather
    /// than being lost or firing repeatedly through the night.
    /// </summary>
    [Fact]
    public void SuppressedReminderFiresAfterQuietHoursEnd()
    {
        var night = Date(Utc, 2026, 3, 10, 23, 0);
        var settings = new Settings
        {
            QuietHours = new QuietHours
            {
                IsEnabled = true, StartHour = 22, StartMinute = 0,
                EndHour = 7, EndMinute = 0, AllowsCritical = false,
            },
        };
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(60),
            Priority = Priority.Normal, CreatedAt = night,
        } with { LastFiredAt = night };

        var store = new InMemoryDataStore(
            new AppData { Reminders = [reminder], Settings = settings }
        );
        var clock = new MutableDateProvider(night);
        var presenter = new RecordingPresenter();
        var engine = new ReminderEngine(store, clock, presenter, Utc);

        // Tick hourly from 23:00 through to 06:00. Every one of those is inside
        // the 22:00–07:00 window, so nothing may fire.
        for (var hour = 1; hour <= 7; hour++)
        {
            clock.AdvanceSeconds(60 * 60);
            Assert.Empty(engine.Tick());
        }

        // The next tick lands at 07:00, when the window has closed.
        clock.AdvanceSeconds(60 * 60);
        Assert.Single(engine.Tick()); // Fires once quiet hours end
        Assert.Single(presenter.Presented);
    }

    /// <summary>
    /// Quiet hours that start and end at the same time are a no-op rather than
    /// silencing the app for 24 hours a day.
    /// </summary>
    [Fact]
    public void QuietHoursWithIdenticalStartAndEndSuppressNothing()
    {
        var quiet = new QuietHours
        {
            IsEnabled = true, StartHour = 9, StartMinute = 0, EndHour = 9, EndMinute = 0,
        };
        Assert.False(quiet.Contains(Date(Utc, 2026, 3, 10, 9, 0), Utc));
        Assert.False(quiet.Contains(Date(Utc, 2026, 3, 10, 15, 0), Utc));
    }

    // MARK: - Persistence round trip through the engine

    /// <summary>
    /// The whole point of storing anything: what the user set up must come back
    /// after a restart.
    /// </summary>
    [Fact]
    public void EngineStateSurvivesARestart()
    {
        var directory = Path.Combine(
            Path.GetTempPath(), $"ReminderRestart-{Guid.NewGuid()}"
        );
        Directory.CreateDirectory(directory);
        try
        {
            var url = Path.Combine(directory, "data.json");

            var custom = new Reminder
            {
                Title = "Physiotherapy",
                Message = "Full routine.",
                Schedule = new Schedule.WeeklyAt(16, 30, new HashSet<int> { 3, 5 }),
                Priority = Priority.Important,
                SymbolName = "figure.flexibility",
                ActivityDurationSeconds = 20 * 60,
            };

            // First run: add a reminder and change a setting.
            {
                var engine = new ReminderEngine(new FileDataStore(url), zone: Utc);
                engine.Add(custom);
                var settings = engine.Settings with
                {
                    SnoozeMinutes = 17,
                    QuietHours = engine.Settings.QuietHours with { IsEnabled = true },
                };
                engine.UpdateSettings(settings);
            }

            // Second run: everything should be exactly as it was left.
            var reloaded = new ReminderEngine(new FileDataStore(url), zone: Utc);
            var restored = reloaded.Reminders.FirstOrDefault(r => r.Id == custom.Id);

            Assert.NotNull(restored);
            Assert.Equal("Physiotherapy", restored!.Title);
            Assert.Equal(
                new Schedule.WeeklyAt(16, 30, new HashSet<int> { 3, 5 }), restored.Schedule
            );
            Assert.Equal(Priority.Important, restored.Priority);
            Assert.Equal(20 * 60, restored.ActivityDurationSeconds);
            Assert.Equal(17, reloaded.Settings.SnoozeMinutes);
            Assert.True(reloaded.Settings.QuietHours.IsEnabled);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
