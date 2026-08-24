using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// Regression tests for wall-clock (daily/weekly) schedules firing through the
/// engine's tick loop.
///
/// These exist because the original due-check compared "the next *future*
/// slot" against now — a comparison that can never be true — so daily and
/// weekly reminders never fired at all, and no test noticed: every engine test
/// used intervals, and every daily/weekly test only asserted display dates.
/// </summary>
public class WallClockFiringTests
{
    private static readonly DateTimeZone Utc = DateTimeZone.Utc;

    private static Instant Date(
        int year, int month, int day, int hour = 0, int minute = 0, int second = 0) =>
        TestDates.At(Utc, year, month, day, hour, minute, second);

    private static (ReminderEngine, MutableDateProvider, RecordingPresenter) MakeEngine(
        IReadOnlyList<Reminder> reminders, Settings? settings, Instant now)
    {
        var store = new InMemoryDataStore(new AppData
        {
            Reminders = reminders,
            Settings = settings ?? new Settings(),
            Events = [],
        });
        var clock = new MutableDateProvider(now);
        var presenter = new RecordingPresenter();
        var engine = new ReminderEngine(store, clock, presenter, Utc);
        return (engine, clock, presenter);
    }

    // MARK: - The headline regression

    /// <summary>
    /// A daily reminder must actually fire when a tick lands just after its
    /// slot. This is the core promise of the schedule kind.
    /// </summary>
    [Fact]
    public void DailyReminderFiresWhenATickCrossesItsSlot()
    {
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(17, 0, 1),
            CreatedAt = Date(2026, 3, 9, 8, 0),
        } with { LastFiredAt = Date(2026, 3, 9, 17, 0) };
        var (engine, clock, presenter) = MakeEngine(
            [reminder], null, Date(2026, 3, 10, 16, 59, 55)
        );

        Assert.Empty(engine.Tick()); // Not due a few seconds early

        // The tick timer lands a few seconds past the slot, as it does live.
        clock.Set(Date(2026, 3, 10, 17, 0, 4));
        Assert.Single(engine.Tick()); // Fires at its slot
        Assert.Equal(["Physio"], presenter.Presented.Select(r => r.Title).ToArray());

        // Repeated ticks in the same window must not re-fire.
        for (var i = 0; i < 5; i++)
        {
            clock.AdvanceSeconds(5);
            Assert.Empty(engine.Tick());
        }

        // And the next day it fires again.
        clock.Set(Date(2026, 3, 11, 17, 0, 3));
        Assert.Single(engine.Tick());
        Assert.Equal(2, presenter.Presented.Count);
    }

    [Fact]
    public void WeeklyReminderFiresOnItsSelectedWeekday()
    {
        // Weekday numbering: 1 = Sunday ... 7 = Saturday. 11 Mar 2026 is a Wed.
        var reminder = new Reminder
        {
            Title = "Call Mum",
            Schedule = new Schedule.WeeklyAt(10, 30, new HashSet<int> { 4 }),
            CreatedAt = Date(2026, 3, 2, 8, 0),
        } with { LastFiredAt = Date(2026, 3, 4, 10, 30) };
        var (engine, clock, presenter) = MakeEngine(
            [reminder], null, Date(2026, 3, 11, 10, 29)
        );

        Assert.Empty(engine.Tick());

        clock.Set(Date(2026, 3, 11, 10, 30, 5));
        Assert.Single(engine.Tick());
        Assert.Equal(["Call Mum"], presenter.Presented.Select(r => r.Title).ToArray());

        // Fired, so the rest of the day stays quiet.
        clock.Set(Date(2026, 3, 11, 18, 0));
        Assert.Empty(engine.Tick());

        // Next Wednesday it comes back.
        clock.Set(Date(2026, 3, 18, 10, 30, 2));
        Assert.Single(engine.Tick());
    }

    /// <summary>A brand-new daily reminder added in the morning fires the same day.</summary>
    [Fact]
    public void NewlyAddedDailyReminderFiresAtItsFirstSlot()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var (engine, clock, presenter) = MakeEngine([], null, start);

        engine.Add(new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(17, 0, 1),
        });
        Assert.Empty(engine.Tick()); // Not due before the slot

        clock.Set(Date(2026, 3, 10, 17, 0, 4));
        Assert.Single(engine.Tick());
        Assert.Equal(["Physio"], presenter.Presented.Select(r => r.Title).ToArray());
    }

    // MARK: - Catch-up and grid phase

    /// <summary>
    /// Slots missed while the machine was off collapse to one catch-up fire,
    /// and the "every 2 days" grid stays in phase afterwards.
    /// </summary>
    [Fact]
    public void MissedSlotsFireOnceAndKeepTheCycleGrid()
    {
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(17, 0, 2),
            CreatedAt = Date(2026, 3, 1, 8, 0),
            // Grid: Mar 4, 6, 8, 10... The machine was off for a week.
        } with { LastFiredAt = Date(2026, 3, 2, 17, 0) };
        var (engine, clock, presenter) = MakeEngine([reminder], null, Date(2026, 3, 9, 12, 0));

        Assert.Single(engine.Tick()); // One catch-up fire, not three
        Assert.Single(presenter.Presented);

        clock.AdvanceSeconds(60);
        Assert.Empty(engine.Tick()); // The catch-up consumed the backlog

        // The next fire lands on the original grid: Mar 10, not Mar 11.
        clock.Set(Date(2026, 3, 10, 17, 0, 4));
        Assert.Single(engine.Tick());
    }

    // MARK: - Quiet hours

    /// <summary>
    /// A wall-clock slot that passes inside quiet hours is skipped and recorded
    /// as missed — "daily at 23:00" must not arrive at 07:00.
    /// </summary>
    [Fact]
    public void WallClockSlotInsideQuietHoursIsSkippedNotDeliveredLate()
    {
        var settings = new Settings
        {
            QuietHours = new QuietHours
            {
                IsEnabled = true, StartHour = 22, StartMinute = 0,
                EndHour = 7, EndMinute = 0, AllowsCritical = true,
            },
        };
        var reminder = new Reminder
        {
            Title = "Evening Pills",
            Schedule = new Schedule.DailyAt(23, 0, 1),
            Priority = Priority.Normal,
            CreatedAt = Date(2026, 3, 8, 8, 0),
        } with { LastFiredAt = Date(2026, 3, 9, 23, 0) };
        var (engine, clock, presenter) = MakeEngine(
            [reminder], settings, Date(2026, 3, 10, 21, 0)
        );

        // Through the night: suppressed, nothing fires.
        foreach (var hour in new[] { 23, 24, 26, 30 }) // 23:00, 00:00, 02:00, 06:00
        {
            clock.Set(
                Date(2026, 3, 10, 21, 0)
                    .Plus(Duration.FromSeconds((hour - 21) * 3600 + 5))
            );
            Assert.Empty(engine.Tick());
        }

        // Quiet hours end at 07:00: the slot is skipped, not delivered.
        clock.Set(Date(2026, 3, 11, 7, 0, 5));
        Assert.Empty(engine.Tick()); // The 23:00 slot must not fire at 07:00
        Assert.Empty(presenter.Presented);
        // The skipped slot is recorded so history shows what happened.
        Assert.Equal(
            [ReminderEvent.Outcome.Missed],
            engine.Events.Select(e => e.EventOutcome).ToArray()
        );

        // And tonight's slot is the next one up.
        var next = Scheduler.NextFireDate(engine.Reminders[0], clock.Now, Utc);
        Assert.Equal(Date(2026, 3, 11, 23, 0), next);
    }

    /// <summary>
    /// Critical reminders opt out of quiet-hours suppression, so their slots
    /// fire on time even at night.
    /// </summary>
    [Fact]
    public void CriticalWallClockSlotPiercesQuietHours()
    {
        var settings = new Settings
        {
            QuietHours = new QuietHours
            {
                IsEnabled = true, StartHour = 22, StartMinute = 0,
                EndHour = 7, EndMinute = 0, AllowsCritical = true,
            },
        };
        var reminder = new Reminder
        {
            Title = "Pressure Relief",
            Schedule = new Schedule.DailyAt(23, 0, 1),
            Priority = Priority.Critical,
            CreatedAt = Date(2026, 3, 8, 8, 0),
        } with { LastFiredAt = Date(2026, 3, 9, 23, 0) };
        var (engine, clock, presenter) = MakeEngine(
            [reminder], settings, Date(2026, 3, 10, 22, 30)
        );

        clock.Set(Date(2026, 3, 10, 23, 0, 5));
        Assert.Single(engine.Tick()); // Critical fires despite quiet hours
        Assert.Equal(
            ["Pressure Relief"], presenter.Presented.Select(r => r.Title).ToArray()
        );
    }

    // MARK: - Enable / complete interactions

    /// <summary>
    /// Toggling a daily reminder off and back on in the morning must not skip
    /// that day's slot.
    /// </summary>
    [Fact]
    public void ReenablingDailyBeforeItsSlotStillFiresThatDay()
    {
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(17, 0, 1),
            CreatedAt = Date(2026, 3, 1, 8, 0),
        } with
        {
            IsEnabled = false,
            LastFiredAt = Date(2026, 3, 5, 17, 0), // stale
        };
        var (engine, clock, presenter) = MakeEngine([reminder], null, Date(2026, 3, 10, 10, 0));

        engine.SetEnabled(true, reminder.Id);
        Assert.Empty(engine.Tick()); // Must not fire instantly from stale state

        clock.Set(Date(2026, 3, 10, 17, 0, 4));
        Assert.Single(engine.Tick()); // Today's slot still fires
        Assert.Single(presenter.Presented);
    }

    /// <summary>
    /// Completing a daily reminder ahead of its slot ("I already did it")
    /// consumes that slot rather than firing it a few hours later.
    /// </summary>
    [Fact]
    public void EarlyCompleteConsumesTheUpcomingSlot()
    {
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(17, 0, 1),
            CreatedAt = Date(2026, 3, 8, 8, 0),
        } with
        {
            LastFiredAt = Date(2026, 3, 9, 17, 0),
            LastAcknowledgedAt = Date(2026, 3, 9, 17, 2),
        };
        var (engine, clock, presenter) = MakeEngine([reminder], null, Date(2026, 3, 10, 10, 0));

        engine.Complete(reminder.Id);

        clock.Set(Date(2026, 3, 10, 17, 0, 5));
        Assert.Empty(engine.Tick()); // The completed slot must not fire
        Assert.Empty(presenter.Presented);

        // Tomorrow is unaffected.
        clock.Set(Date(2026, 3, 11, 17, 0, 5));
        Assert.Single(engine.Tick());
    }

    /// <summary>Acknowledging a fire that just happened must not eat the next slot.</summary>
    [Fact]
    public void AcknowledgingAFireDoesNotConsumeTheNextSlot()
    {
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(17, 0, 1),
            CreatedAt = Date(2026, 3, 8, 8, 0),
        } with { LastFiredAt = Date(2026, 3, 9, 17, 0) };
        var (engine, clock, _) = MakeEngine([reminder], null, Date(2026, 3, 10, 16, 59));

        clock.Set(Date(2026, 3, 10, 17, 0, 4));
        Assert.Single(engine.Tick());

        // The user clicks Done on the overlay a couple of minutes later.
        clock.AdvanceSeconds(120);
        engine.Complete(reminder.Id);

        clock.Set(Date(2026, 3, 11, 17, 0, 4));
        Assert.Single(engine.Tick()); // Tomorrow's slot still fires
    }

    /// <summary>
    /// Snoozing a fired daily reminder brings it back at the snooze time, and
    /// the schedule then resumes normally.
    /// </summary>
    [Fact]
    public void SnoozedDailyReminderComesBackAndResumesSchedule()
    {
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(17, 0, 1),
            CreatedAt = Date(2026, 3, 8, 8, 0),
        } with { LastFiredAt = Date(2026, 3, 9, 17, 0) };
        var (engine, clock, presenter) = MakeEngine([reminder], null, Date(2026, 3, 10, 16, 59));

        clock.Set(Date(2026, 3, 10, 17, 0, 4));
        Assert.Single(engine.Tick());
        engine.Snooze(reminder.Id, 10);

        clock.AdvanceSeconds(9 * 60);
        Assert.Empty(engine.Tick()); // Still snoozed

        clock.AdvanceSeconds(2 * 60);
        Assert.Single(engine.Tick()); // Comes back after the snooze
        Assert.Equal(2, presenter.Presented.Count);

        // The snooze fire does not disturb tomorrow's slot.
        clock.Set(Date(2026, 3, 11, 17, 0, 4));
        Assert.Single(engine.Tick());
    }

    // MARK: - Tray countdown around quiet hours

    /// <summary>
    /// During quiet hours the countdown shows the reminder's real next audible
    /// fire rather than hiding it or counting to a suppressed slot.
    /// </summary>
    [Fact]
    public void NextUpDuringQuietHoursShowsTheAudibleFire()
    {
        var settings = new Settings
        {
            QuietHours = new QuietHours
            {
                IsEnabled = true, StartHour = 22, StartMinute = 0,
                EndHour = 7, EndMinute = 0, AllowsCritical = true,
            },
        };
        var water = new Reminder
        {
            Title = "Water",
            Schedule = new Schedule.Interval(60),
            Priority = Priority.Normal,
            CreatedAt = Date(2026, 3, 10, 22, 30),
        } with { LastFiredAt = Date(2026, 3, 10, 22, 30) };
        var (engine, clock, _) = MakeEngine([water], settings, Date(2026, 3, 10, 22, 30));

        // 23:30: the hourly slot lands at 23:30, inside the window, so the
        // real next fire is 07:00 when the window ends.
        clock.Set(Date(2026, 3, 10, 23, 0));
        engine.Tick();
        Assert.Equal("Water", engine.NextUp?.Reminder.Title);
        Assert.Equal(Date(2026, 3, 11, 7, 0), engine.NextUp?.Date);
    }
}
