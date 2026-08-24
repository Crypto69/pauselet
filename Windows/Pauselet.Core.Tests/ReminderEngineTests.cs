using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

public class ReminderEngineTests
{
    private static readonly DateTimeZone Utc = DateTimeZone.Utc;

    private static Instant Date(int year, int month, int day, int hour = 0, int minute = 0) =>
        TestDates.At(Utc, year, month, day, hour, minute);

    /// <summary>Builds an engine with a controllable clock.</summary>
    private static (ReminderEngine, MutableDateProvider, RecordingPresenter, InMemoryDataStore)
        MakeEngine(IReadOnlyList<Reminder>? reminders = null, Settings? settings = null,
                   Instant now = default)
    {
        var store = new InMemoryDataStore(new AppData
        {
            Reminders = reminders ?? [],
            Settings = settings ?? new Settings(),
            Events = [],
        });
        var clock = new MutableDateProvider(now);
        var presenter = new RecordingPresenter();
        var engine = new ReminderEngine(store, clock, presenter, Utc);
        return (engine, clock, presenter, store);
    }

    // MARK: - Firing

    [Fact]
    public void TickFiresDueReminderAndPresentsIt()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Weight Shift", Schedule = new Schedule.Interval(20),
            Priority = Priority.Subtle, CreatedAt = start,
        } with { LastFiredAt = start };
        var (engine, clock, presenter, _) = MakeEngine([reminder], now: start);

        Assert.Empty(engine.Tick()); // Nothing is due yet
        Assert.Empty(presenter.Presented);

        clock.AdvanceSeconds(20 * 60);
        var fired = engine.Tick();
        Assert.Single(fired);
        Assert.Equal(["Weight Shift"], presenter.Presented.Select(r => r.Title).ToArray());
    }

    /// <summary>
    /// The critical bug this guards: repeated ticks in the same due window must
    /// not re-fire and spam the user.
    /// </summary>
    [Fact]
    public void RepeatedTicksDoNotRefireSameWindow()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Tilt Back", Schedule = new Schedule.Interval(60), CreatedAt = start,
        } with { LastFiredAt = start };
        var (engine, clock, presenter, _) = MakeEngine([reminder], now: start);

        clock.AdvanceSeconds(60 * 60);
        Assert.Single(engine.Tick());
        // Several more ticks a few seconds apart.
        for (var i = 0; i < 5; i++)
        {
            clock.AdvanceSeconds(5);
            Assert.Empty(engine.Tick());
        }
        Assert.Single(presenter.Presented);
    }

    [Fact]
    public void HigherPriorityPresentedLastSoItSitsInFront()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var subtle = new Reminder
        {
            Title = "Shift", Schedule = new Schedule.Interval(20),
            Priority = Priority.Subtle, CreatedAt = start,
        } with { LastFiredAt = start };
        var critical = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(20),
            Priority = Priority.Critical, CreatedAt = start,
        } with { LastFiredAt = start };

        var (engine, clock, presenter, _) = MakeEngine([subtle, critical], now: start);
        clock.AdvanceSeconds(20 * 60);
        engine.Tick();

        Assert.Equal(["Shift", "Tilt"], presenter.Presented.Select(r => r.Title).ToArray());
    }

    [Fact]
    public void DisabledReminderDoesNotFire()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Off", Schedule = new Schedule.Interval(10), CreatedAt = start,
        } with { IsEnabled = false, LastFiredAt = start };
        var (engine, clock, presenter, _) = MakeEngine([reminder], now: start);

        clock.AdvanceSeconds(60 * 60);
        Assert.Empty(engine.Tick());
        Assert.Empty(presenter.Presented);
    }

    // MARK: - Pause

    [Fact]
    public void PausedEngineFiresNothing()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(20), CreatedAt = start,
        } with { LastFiredAt = start };
        var (engine, clock, presenter, _) = MakeEngine([reminder], now: start);

        engine.SetPaused(true);
        clock.AdvanceSeconds(60 * 60);
        Assert.Empty(engine.Tick());
        Assert.Empty(presenter.Presented);
        Assert.Equal(1, presenter.DismissAllCount); // Pausing clears anything on screen
    }

    [Fact]
    public void TimedPauseExpiresAndResumesFiring()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(20), CreatedAt = start,
        } with { LastFiredAt = start };
        var (engine, clock, presenter, _) = MakeEngine([reminder], now: start);

        engine.PauseFor(30);
        clock.AdvanceSeconds(20 * 60);
        Assert.Empty(engine.Tick()); // Still paused

        clock.AdvanceSeconds(15 * 60); // 35 min total, pause has expired
        Assert.Single(engine.Tick());
        Assert.False(engine.Settings.IsPaused); // Pause auto-clears on expiry
        Assert.Null(engine.Settings.PausedUntil);
        Assert.Single(presenter.Presented);
    }

    /// <summary>Coming back from a long pause should not dump a backlog on the user.</summary>
    [Fact]
    public void ResumeReanchorsIntervalRemindersSoNoBacklogFires()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Shift", Schedule = new Schedule.Interval(20), CreatedAt = start,
        } with { LastFiredAt = start };
        var (engine, clock, presenter, _) = MakeEngine([reminder], now: start);

        engine.SetPaused(true);
        clock.AdvanceSeconds(4 * 60 * 60); // paused for 4 hours
        engine.Resume();

        Assert.Empty(engine.Tick()); // Nothing should fire the instant we resume
        clock.AdvanceSeconds(20 * 60);
        Assert.Single(engine.Tick()); // Next fire is a full interval after resume
        Assert.Single(presenter.Presented);
    }

    // MARK: - Quiet hours

    [Fact]
    public void QuietHoursSuppressNonCriticalButAllowCritical()
    {
        var night = Date(2026, 3, 10, 23, 0);
        var settings = new Settings
        {
            QuietHours = new QuietHours
            {
                IsEnabled = true, StartHour = 22, StartMinute = 0,
                EndHour = 7, EndMinute = 0, AllowsCritical = true,
            },
        };
        var normal = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(20),
            Priority = Priority.Normal, CreatedAt = night,
        } with { LastFiredAt = night };
        var critical = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(20),
            Priority = Priority.Critical, CreatedAt = night,
        } with { LastFiredAt = night };

        var (engine, clock, presenter, _) = MakeEngine([normal, critical], settings, night);
        clock.AdvanceSeconds(20 * 60);
        var fired = engine.Tick();

        Assert.Equal(["Tilt"], fired.Select(r => r.Title).ToArray());
        Assert.Equal(["Tilt"], presenter.Presented.Select(r => r.Title).ToArray());
    }

    // MARK: - User responses

    [Fact]
    public void CompleteResetsTheIntervalAndRecordsHistory()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(60), CreatedAt = start,
        } with { LastFiredAt = start };
        var (engine, clock, _, _) = MakeEngine([reminder], now: start);

        clock.AdvanceSeconds(60 * 60);
        engine.Tick();
        clock.AdvanceSeconds(5 * 60);
        engine.Complete(reminder.Id);

        var stored = engine.ReminderWithId(reminder.Id);
        Assert.Equal(clock.Now, stored?.LastFiredAt);
        Assert.Equal(clock.Now, stored?.LastAcknowledgedAt);
        Assert.Equal(
            [ReminderEvent.Outcome.Fired, ReminderEvent.Outcome.Completed],
            engine.Events.Select(e => e.EventOutcome).ToArray()
        );

        // The next fire is a full hour after completion, not after the original fire.
        clock.AdvanceSeconds(58 * 60);
        Assert.Empty(engine.Tick());
        clock.AdvanceSeconds(3 * 60);
        Assert.Single(engine.Tick());
    }

    [Fact]
    public void SnoozeDelaysNextFireByConfiguredMinutes()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(60), CreatedAt = start,
        } with { LastFiredAt = start };
        var settings = new Settings { SnoozeMinutes = 10 };
        var (engine, clock, presenter, _) = MakeEngine([reminder], settings, start);

        clock.AdvanceSeconds(60 * 60);
        engine.Tick();
        engine.Snooze(reminder.Id);

        clock.AdvanceSeconds(9 * 60);
        Assert.Empty(engine.Tick()); // Still snoozed
        clock.AdvanceSeconds(2 * 60);
        Assert.Single(engine.Tick()); // Fires again after the snooze
        Assert.Equal(2, presenter.Presented.Count);
    }

    [Fact]
    public void SnoozeWithExplicitMinutesOverridesSetting()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(60), CreatedAt = start,
        } with { LastFiredAt = start };
        var (engine, clock, _, _) = MakeEngine([reminder], now: start);

        clock.AdvanceSeconds(60 * 60);
        engine.Tick();
        engine.Snooze(reminder.Id, 2);

        clock.AdvanceSeconds(60);
        Assert.Empty(engine.Tick());
        clock.AdvanceSeconds(90);
        Assert.Single(engine.Tick());
    }

    [Fact]
    public void DismissRecordsHistoryWithoutResettingSchedule()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(60), CreatedAt = start,
        } with { LastFiredAt = start };
        var (engine, clock, _, _) = MakeEngine([reminder], now: start);

        clock.AdvanceSeconds(60 * 60);
        engine.Tick();
        var firedAt = engine.ReminderWithId(reminder.Id)?.LastFiredAt;
        clock.AdvanceSeconds(60);
        engine.Dismiss(reminder.Id);

        Assert.Equal(firedAt, engine.ReminderWithId(reminder.Id)?.LastFiredAt);
        Assert.Equal(
            [ReminderEvent.Outcome.Fired, ReminderEvent.Outcome.Dismissed],
            engine.Events.Select(e => e.EventOutcome).ToArray()
        );
    }

    // MARK: - CRUD

    [Fact]
    public void AddedReminderDoesNotFireImmediately()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var (engine, clock, _, _) = MakeEngine(now: start);

        engine.Add(new Reminder
        {
            Title = "New",
            Schedule = new Schedule.Interval(15),
            CreatedAt = Date(2020, 1, 1), // deliberately stale
        });
        Assert.Empty(engine.Tick()); // Add re-anchors creation to now

        clock.AdvanceSeconds(15 * 60);
        Assert.Single(engine.Tick());
    }

    [Fact]
    public void ReenablingReminderReanchorsSoItDoesNotFireInstantly()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Shift", Schedule = new Schedule.Interval(20), CreatedAt = start,
        } with { IsEnabled = false, LastFiredAt = Date(2020, 1, 1) };
        var (engine, clock, _, _) = MakeEngine([reminder], now: start);

        engine.SetEnabled(true, reminder.Id);
        Assert.Empty(engine.Tick()); // Should not fire from a stale timestamp

        clock.AdvanceSeconds(20 * 60);
        Assert.Single(engine.Tick());
    }

    [Fact]
    public void DeleteRemovesReminder()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Gone", Schedule = new Schedule.Interval(10), CreatedAt = start,
        };
        var (engine, clock, _, _) = MakeEngine([reminder], now: start);

        engine.Delete(reminder.Id);
        Assert.Empty(engine.Reminders);
        clock.AdvanceSeconds(60 * 60);
        Assert.Empty(engine.Tick());
    }

    [Fact]
    public void UpdateChangesScheduleInPlace()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Shift", Schedule = new Schedule.Interval(60), CreatedAt = start,
        } with { LastFiredAt = start };
        var (engine, clock, _, _) = MakeEngine([reminder], now: start);

        engine.Update(reminder with { Schedule = new Schedule.Interval(10) });

        clock.AdvanceSeconds(10 * 60);
        Assert.Single(engine.Tick());
    }

    // MARK: - Persistence

    [Fact]
    public void ChangesArePersistedToStore()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var (engine, _, _, store) = MakeEngine(now: start);

        engine.Add(new Reminder { Title = "Persisted", Schedule = new Schedule.Interval(30) });

        Assert.Equal(["Persisted"], store.Data.Reminders.Select(r => r.Title).ToArray());
        Assert.True(store.SaveCount > 0);
    }

    [Fact]
    public void EngineLoadsExistingDataFromStore()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var existing = new Reminder { Title = "Loaded", Schedule = new Schedule.Interval(45) };
        var (engine, _, _, _) = MakeEngine([existing], now: start);
        Assert.Equal(["Loaded"], engine.Reminders.Select(r => r.Title).ToArray());
    }

    // MARK: - History and stats

    [Fact]
    public void HistoryIsCappedToAvoidUnboundedGrowth()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Chatty", Schedule = new Schedule.Interval(1), CreatedAt = start,
        } with { LastFiredAt = start };
        var (engine, clock, _, _) = MakeEngine([reminder], now: start);

        // Fire well past the cap.
        for (var i = 0; i < ReminderEngine.MaxStoredEvents + 50; i++)
        {
            clock.AdvanceSeconds(60);
            engine.Tick();
        }
        Assert.True(engine.Events.Count <= ReminderEngine.MaxStoredEvents);
    }

    [Fact]
    public void AdherenceReflectsCompletionRate()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(60), CreatedAt = start,
        } with { LastFiredAt = start };
        var (engine, clock, _, _) = MakeEngine([reminder], now: start);

        // Fire four times, complete two of them.
        for (var index = 0; index < 4; index++)
        {
            clock.AdvanceSeconds(60 * 60);
            engine.Tick();
            if (index % 2 == 0) engine.Complete(reminder.Id);
        }

        var adherence = engine.Adherence(reminder.Id, start);
        Assert.NotNull(adherence);
        Assert.Equal(0.5, adherence!.Value, 3);
    }

    [Fact]
    public void AdherenceIsNullWhenNothingFired()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder { Title = "Quiet", Schedule = new Schedule.Interval(60) };
        var (engine, _, _, _) = MakeEngine([reminder], now: start);
        Assert.Null(engine.Adherence(reminder.Id, start));
    }

    [Fact]
    public void ClearHistoryEmptiesEvents()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(10), CreatedAt = start,
        } with { LastFiredAt = start };
        var (engine, clock, _, _) = MakeEngine([reminder], now: start);

        clock.AdvanceSeconds(10 * 60);
        engine.Tick();
        Assert.NotEmpty(engine.Events);

        engine.ClearHistory();
        Assert.Empty(engine.Events);
    }

    // MARK: - Next up

    [Fact]
    public void NextUpTracksSoonestEnabledReminder()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var hourly = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(60), CreatedAt = start,
        } with { LastFiredAt = start };
        var frequent = new Reminder
        {
            Title = "Shift", Schedule = new Schedule.Interval(20), CreatedAt = start,
        } with { LastFiredAt = start };
        var (engine, _, _, _) = MakeEngine([hourly, frequent], now: start);

        Assert.Equal("Shift", engine.NextUp?.Reminder.Title);

        engine.SetEnabled(false, frequent.Id);
        Assert.Equal("Tilt", engine.NextUp?.Reminder.Title);
    }
}
