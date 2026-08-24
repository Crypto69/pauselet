using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// Tests for what happens when the app is opened after a spell of not running.
///
/// These exist because of a real incident: the app was left closed for a day
/// and a half, and the moment it opened it delivered the whole backlog at once
/// — last night's wall-clock reminder, plus every interval reminder, one of
/// them a critical full-screen overlay that started playing music. Nothing here
/// was due; it was all owed to sessions that had already ended.
/// </summary>
public class LaunchBacklogTests
{
    private static readonly DateTimeZone Utc = DateTimeZone.Utc;

    private static Instant Date(
        int year, int month, int day, int hour = 0, int minute = 0, int second = 0) =>
        TestDates.At(Utc, year, month, day, hour, minute, second);

    private static (ReminderEngine, MutableDateProvider, RecordingPresenter) MakeEngine(
        IReadOnlyList<Reminder> reminders, Instant now, Settings? settings = null)
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

    /// <summary>
    /// Launching after the app was closed for a day and a half — the reported
    /// bug, with the reminders and times taken from the data file that produced
    /// it. Nothing may reach the screen.
    /// </summary>
    [Fact]
    public void OpeningAfterADayAwayPresentsNothing()
    {
        var leanBack = new Reminder
        {
            Title = "Lean Back", Schedule = new Schedule.Interval(60),
            Priority = Priority.Critical, Music = MusicChoice.DefaultPlaylist,
            CreatedAt = Date(2026, 8, 11, 21, 47),
        } with { LastFiredAt = Date(2026, 8, 12, 20, 57) };

        var weightShift = new Reminder
        {
            Title = "Weight Shift", Schedule = new Schedule.Interval(20),
            Priority = Priority.Subtle, CreatedAt = Date(2026, 8, 11, 21, 47),
        } with { LastFiredAt = Date(2026, 8, 12, 20, 41) };

        var windDown = new Reminder
        {
            Title = "Wind Down",
            Schedule = new Schedule.DailyAt(20, 59, 1),
            Priority = Priority.Critical, CreatedAt = Date(2026, 8, 11, 22, 8),
        } with { LastFiredAt = Date(2026, 8, 12, 20, 59) };

        var launch = Date(2026, 8, 14, 12, 37);
        var (engine, clock, presenter) = MakeEngine(
            [leanBack, weightShift, windDown], launch
        );

        var absorbed = engine.AbsorbBacklogFromDowntime();
        Assert.Equal(3, absorbed.Count);
        Assert.Empty(engine.Tick()); // Launching must not replay the backlog
        Assert.Empty(presenter.Presented); // No overlay, no notification, no music

        // Each schedule picks up from the launch rather than from its arrears.
        clock.AdvanceSeconds(19 * 60);
        Assert.Empty(engine.Tick());
        clock.AdvanceSeconds(2 * 60);
        // 20 min after launch.
        Assert.Equal(["Weight Shift"], engine.Tick().Select(r => r.Title).ToArray());
    }

    /// <summary>
    /// Absorbing is not the same as firing: the reminders are consumed, not
    /// delivered, and the history says so.
    /// </summary>
    [Fact]
    public void AbsorbedBacklogIsRecordedAsMissedNotFired()
    {
        var reminder = new Reminder
        {
            Title = "Drink Water", Schedule = new Schedule.Interval(60),
            CreatedAt = Date(2026, 8, 11, 9, 0),
        } with { LastFiredAt = Date(2026, 8, 12, 20, 1) };
        var (engine, _, _) = MakeEngine([reminder], Date(2026, 8, 14, 12, 37));

        engine.AbsorbBacklogFromDowntime();

        Assert.Equal(
            [ReminderEvent.Outcome.Missed],
            engine.Events.Select(e => e.EventOutcome).ToArray()
        );
    }

    /// <summary>
    /// Yesterday's daily slot is consumed rather than delivered, and the next
    /// one lands at its usual time today.
    /// </summary>
    [Fact]
    public void YesterdaysDailySlotIsConsumedAndTodaysStillFires()
    {
        var reminder = new Reminder
        {
            Title = "Wind Down",
            Schedule = new Schedule.DailyAt(20, 59, 1),
            Priority = Priority.Critical, CreatedAt = Date(2026, 8, 11, 22, 8),
        } with { LastFiredAt = Date(2026, 8, 12, 20, 59) };
        var (engine, clock, presenter) = MakeEngine([reminder], Date(2026, 8, 14, 12, 37));

        engine.AbsorbBacklogFromDowntime();
        // The last elapsed slot is stamped, so the daily grid stays in phase.
        Assert.Equal(Date(2026, 8, 13, 20, 59), engine.Reminders[0].LastFiredAt);

        clock.Set(Date(2026, 8, 14, 20, 59, 4));
        Assert.Single(engine.Tick()); // Tonight's slot is unaffected
        Assert.Single(presenter.Presented);
    }

    /// <summary>
    /// An "every 2 days" grid keeps its phase across the absorbed gap rather
    /// than re-basing itself on the launch.
    /// </summary>
    [Fact]
    public void AbsorbingKeepsAnEveryTwoDaysGridInPhase()
    {
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(17, 0, 2),
            CreatedAt = Date(2026, 3, 1, 8, 0),
            // Grid: Mar 4, 6, 8, 10 — the app was closed for a week.
        } with { LastFiredAt = Date(2026, 3, 2, 17, 0) };
        var (engine, clock, presenter) = MakeEngine([reminder], Date(2026, 3, 9, 12, 0));

        engine.AbsorbBacklogFromDowntime();
        Assert.Empty(engine.Tick());

        clock.Set(Date(2026, 3, 10, 17, 0, 4));
        Assert.Single(engine.Tick()); // Next fire is Mar 10, not Mar 11
        Assert.Single(presenter.Presented);
    }

    /// <summary>
    /// Quitting and relaunching — to install an update — must not swallow a
    /// reminder that came due seconds ago.
    /// </summary>
    [Fact]
    public void AReminderDueWithinTheGraceWindowStillFires()
    {
        var launch = Date(2026, 8, 14, 12, 37);
        var reminder = new Reminder
        {
            Title = "Weight Shift", Schedule = new Schedule.Interval(20),
            CreatedAt = Date(2026, 8, 14, 9, 0),
            // Came due 30 seconds before the app was reopened.
        } with { LastFiredAt = launch.Plus(Duration.FromSeconds(-20 * 60 - 30)) };
        var (engine, _, presenter) = MakeEngine([reminder], launch);

        Assert.Empty(engine.AbsorbBacklogFromDowntime());
        Assert.Single(engine.Tick());
        Assert.Equal(["Weight Shift"], presenter.Presented.Select(r => r.Title).ToArray());
    }

    /// <summary>
    /// A daily slot that passed moments before launch is delivered even when
    /// older slots from the downtime are being absorbed alongside it.
    /// </summary>
    [Fact]
    public void DailySlotThatJustPassedIsStillDeliveredAfterALongGap()
    {
        var launch = Date(2026, 8, 14, 12, 37, 30);
        var reminder = new Reminder
        {
            Title = "Midday Check",
            Schedule = new Schedule.DailyAt(12, 37, 1),
            CreatedAt = Date(2026, 8, 10, 8, 0),
        } with { LastFiredAt = Date(2026, 8, 11, 12, 37) };
        var (engine, _, presenter) = MakeEngine([reminder], launch);

        Assert.Empty(engine.AbsorbBacklogFromDowntime());
        Assert.Single(engine.Tick());
        Assert.Single(presenter.Presented);
    }

    /// <summary>
    /// A snooze is a promise made by a session that has since ended. Reopening
    /// the app a day later must not honour it.
    /// </summary>
    [Fact]
    public void StaleSnoozeIsDroppedRatherThanFiredOnLaunch()
    {
        var reminder = new Reminder
        {
            Title = "Lean Back", Schedule = new Schedule.Interval(60),
            Priority = Priority.Critical, CreatedAt = Date(2026, 8, 12, 9, 0),
        } with
        {
            LastFiredAt = Date(2026, 8, 12, 20, 57),
            SnoozedUntil = Date(2026, 8, 12, 21, 2),
        };
        var launch = Date(2026, 8, 14, 12, 37);
        var (engine, clock, presenter) = MakeEngine([reminder], launch);

        engine.AbsorbBacklogFromDowntime();
        Assert.Null(engine.Reminders[0].SnoozedUntil);
        Assert.Empty(engine.Tick());
        Assert.Empty(presenter.Presented);

        // And the interval restarts from the launch.
        clock.AdvanceSeconds(60 * 60 + 5);
        Assert.Single(engine.Tick());
    }

    /// <summary>A snooze set a moment before the app was restarted is still owed.</summary>
    [Fact]
    public void FreshSnoozeSurvivesARestart()
    {
        var launch = Date(2026, 8, 14, 12, 37);
        var reminder = new Reminder
        {
            Title = "Lean Back", Schedule = new Schedule.Interval(60),
            CreatedAt = Date(2026, 8, 14, 9, 0),
        } with
        {
            LastFiredAt = Date(2026, 8, 14, 12, 30),
            SnoozedUntil = launch.Plus(Duration.FromSeconds(60)),
        };
        var (engine, clock, presenter) = MakeEngine([reminder], launch);

        Assert.Empty(engine.AbsorbBacklogFromDowntime());
        Assert.Equal(
            launch.Plus(Duration.FromSeconds(60)), engine.Reminders[0].SnoozedUntil
        );

        clock.AdvanceSeconds(65);
        Assert.Single(engine.Tick());
        Assert.Equal(["Lean Back"], presenter.Presented.Select(r => r.Title).ToArray());
    }

    /// <summary>
    /// A disabled reminder has nothing to absorb, and absorbing must not
    /// quietly re-anchor it — enabling it later still starts a fresh interval.
    /// </summary>
    [Fact]
    public void DisabledReminderIsUntouched()
    {
        var reminder = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.DailyAt(17, 0, 2),
            IsEnabled = false, CreatedAt = Date(2026, 3, 1, 8, 0),
        } with { LastFiredAt = Date(2026, 3, 2, 17, 0) };
        var (engine, _, _) = MakeEngine([reminder], Date(2026, 3, 9, 12, 0));

        Assert.Empty(engine.AbsorbBacklogFromDowntime());
        Assert.Equal(Date(2026, 3, 2, 17, 0), engine.Reminders[0].LastFiredAt);
        Assert.Empty(engine.Events);
    }

    /// <summary>
    /// A brand new install has no backlog to absorb, so its starter reminders
    /// keep their anchors and simply run from the first launch.
    /// </summary>
    [Fact]
    public void FirstLaunchOfAFreshInstallAbsorbsNothing()
    {
        var start = Date(2026, 8, 14, 9, 0);
        var (engine, _, presenter) = MakeEngine(DefaultReminders.StarterSet(start), start);

        Assert.Empty(engine.AbsorbBacklogFromDowntime());
        Assert.Empty(engine.Tick());
        Assert.Empty(presenter.Presented);
    }

    /// <summary>
    /// The absorbed state is written out, so a crash straight after launch
    /// cannot resurrect the backlog on the next open.
    /// </summary>
    [Fact]
    public void AbsorbedStateIsPersisted()
    {
        var reminder = new Reminder
        {
            Title = "Drink Water", Schedule = new Schedule.Interval(60),
            CreatedAt = Date(2026, 8, 11, 9, 0),
        } with { LastFiredAt = Date(2026, 8, 12, 20, 1) };
        var store = new InMemoryDataStore(new AppData { Reminders = [reminder] });
        var clock = new MutableDateProvider(Date(2026, 8, 14, 12, 37));
        var engine = new ReminderEngine(store, clock, new RecordingPresenter(), Utc);

        engine.AbsorbBacklogFromDowntime();

        Assert.Equal(Date(2026, 8, 14, 12, 37), store.Data.Reminders[0].LastFiredAt);
    }

    /// <summary>
    /// Sleep is a separate case: the app is running and the user may be sitting
    /// right there, so a nap keeps its single catch-up fire.
    /// </summary>
    [Fact]
    public void SleepCatchUpIsUnaffected()
    {
        var start = Date(2026, 8, 14, 9, 0);
        var reminder = new Reminder
        {
            Title = "Weight Shift", Schedule = new Schedule.Interval(20), CreatedAt = start,
        } with { LastFiredAt = start };
        var (engine, clock, _) = MakeEngine([reminder], start);

        Assert.Empty(engine.AbsorbBacklogFromDowntime());
        clock.AdvanceSeconds(3 * 60 * 60);
        Assert.Single(engine.Tick()); // One catch-up fire on wake
    }
}
