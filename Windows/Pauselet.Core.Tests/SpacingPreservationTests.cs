using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// Pausing and resuming used to weld interval reminders together.
/// </summary>
/// <remarks>
/// The old re-anchor stamped every interval reminder with the same "now", and
/// since the next fire is <c>anchor + interval</c>, every reminder sharing an
/// interval then fired at the same second — and stayed that way forever. The
/// user-visible symptom was three "Every hour" reminders all counting down
/// "58 min", with unrelated exercises arriving at once.
/// <para>
/// These mirror the Swift SpacingPreservationTests so the two cores cannot
/// drift apart.
/// </para>
/// </remarks>
public class SpacingPreservationTests
{
    private static readonly DateTimeZone Utc = DateTimeZone.Utc;

    private static Instant Date(int year, int month, int day, int hour = 0, int minute = 0) =>
        TestDates.At(Utc, year, month, day, hour, minute);

    private static (ReminderEngine, MutableDateProvider, RecordingPresenter)
        MakeEngine(IReadOnlyList<Reminder> reminders, Settings? settings = null,
                   Instant now = default)
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
    /// Three hourly reminders, deliberately staggered 20 minutes apart, as a
    /// user would set up over a morning.
    /// </summary>
    private static List<Reminder> StaggeredHourlyTrio(Instant start)
    {
        string[] titles = ["Lean Back", "Drink Water", "Chin Tuck"];
        int[] offsets = [0, 20, 40];
        var result = new List<Reminder>();
        for (var i = 0; i < titles.Length; i++)
        {
            result.Add(new Reminder
            {
                Title = titles[i],
                Schedule = new Schedule.Interval(60),
                CreatedAt = start,
                LastFiredAt = start + Duration.FromMinutes(offsets[i]),
            });
        }
        return result;
    }

    private static List<Instant> NextFires(ReminderEngine engine, Instant now) =>
        engine.Reminders.Select(r => Scheduler.NextFireDate(r, now, Utc)!.Value).ToList();

    // MARK: - The reported bug

    /// <summary>
    /// The screenshot: three hourly reminders that were 20 minutes apart must
    /// still be 20 minutes apart after an indefinite pause is lifted.
    /// </summary>
    [Fact]
    public void ResumeKeepsHourlyRemindersSpacedApart()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var (engine, clock, _) = MakeEngine(
            StaggeredHourlyTrio(start), now: Date(2026, 3, 10, 9, 50));

        engine.SetPaused(true);
        clock.Advance(Duration.FromMinutes(30));
        engine.Resume();

        var fires = NextFires(engine, clock.Now);
        var gaps = fires.Zip(fires.Skip(1), (a, b) => (b - a).TotalMinutes).ToList();
        Assert.Equal([20d, 20d], gaps);
        Assert.Equal(3, fires.Distinct().Count());
    }

    /// <summary>The precise regression: identical fire times.</summary>
    [Fact]
    public void ResumeDoesNotCollapseRemindersOntoOneInstant()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var (engine, clock, _) = MakeEngine(
            StaggeredHourlyTrio(start), now: Date(2026, 3, 10, 9, 50));

        engine.SetPaused(true);
        clock.Advance(Duration.FromMinutes(45));
        engine.Resume();

        var countdowns = NextFires(engine, clock.Now)
            .Select(f => Scheduler.CountdownText(clock.Now, f))
            .Distinct()
            .Count();
        Assert.Equal(3, countdowns);
    }

    /// <summary>
    /// Phase is preserved exactly: a reminder with 50 minutes left comes back
    /// with 50 minutes left, not a fresh full hour.
    /// </summary>
    [Fact]
    public void ResumePreservesRemainingTimeExactly()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var water = new Reminder
        {
            Title = "Drink Water", Schedule = new Schedule.Interval(60),
            CreatedAt = start, LastFiredAt = Date(2026, 3, 10, 9, 50),
        };
        var tuck = new Reminder
        {
            Title = "Chin Tuck", Schedule = new Schedule.Interval(60),
            CreatedAt = start, LastFiredAt = Date(2026, 3, 10, 9, 12),
        };
        var (engine, clock, _) = MakeEngine([water, tuck], now: Date(2026, 3, 10, 10, 0));

        engine.SetPaused(true);
        clock.Advance(Duration.FromHours(4));
        engine.Resume();

        var fires = NextFires(engine, clock.Now);
        Assert.Equal(Date(2026, 3, 10, 14, 50), fires[0]);
        Assert.Equal(Date(2026, 3, 10, 14, 12), fires[1]);
    }

    // MARK: - Overdue reminders are staggered, not stacked

    [Fact]
    public void FullyOverdueRemindersComeBackStaggeredInOriginalOrder()
    {
        var start = Date(2026, 3, 10, 9, 0);
        string[] titles = ["First", "Second", "Third"];
        int[] offsets = [0, 5, 10];
        var reminders = new List<Reminder>();
        for (var i = 0; i < titles.Length; i++)
        {
            reminders.Add(new Reminder
            {
                Title = titles[i], Schedule = new Schedule.Interval(30),
                CreatedAt = start, LastFiredAt = start + Duration.FromMinutes(offsets[i]),
            });
        }
        var (engine, clock, _) = MakeEngine(reminders, now: Date(2026, 3, 10, 10, 30));

        engine.SetPaused(true);
        clock.Advance(Duration.FromHours(2));
        engine.Resume();

        var fires = NextFires(engine, clock.Now);
        Assert.Equal(3, fires.Distinct().Count());
        Assert.Equal(fires.OrderBy(f => f).ToList(), fires);
        Assert.True((fires.Max() - fires.Min()) <= Duration.FromMinutes(10));
    }

    /// <summary>Staggering must not reintroduce the burst the old code avoided.</summary>
    [Fact]
    public void NothingFiresImmediatelyOnResume()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var (engine, clock, presenter) = MakeEngine(
            StaggeredHourlyTrio(start), now: Date(2026, 3, 10, 9, 50));

        engine.SetPaused(true);
        clock.Advance(Duration.FromHours(6));
        engine.Resume();

        Assert.Empty(engine.Tick());
        Assert.Empty(presenter.Presented);
    }

    // MARK: - Timed pause

    [Fact]
    public void TimedPauseExpiryKeepsSpacing()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var (engine, clock, _) = MakeEngine(
            StaggeredHourlyTrio(start), now: Date(2026, 3, 10, 9, 50));

        engine.PauseFor(60);
        clock.Set(Date(2026, 3, 10, 10, 50));
        Assert.Empty(engine.Tick());

        var fires = NextFires(engine, clock.Now);
        Assert.Equal(3, fires.Distinct().Count());
        var sorted = fires.OrderBy(f => f).ToList();
        var gaps = sorted.Zip(sorted.Skip(1), (a, b) => (b - a).TotalMinutes).ToList();
        Assert.Equal([20d, 20d], gaps);
    }

    /// <summary>
    /// The projection drives pre-scheduled delivery, so it must predict the
    /// same spacing the live engine produces.
    /// </summary>
    [Fact]
    public void ProjectionAgreesWithTheEngineDuringATimedPause()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var reminders = StaggeredHourlyTrio(start);
        var now = Date(2026, 3, 10, 9, 50);
        var settings = new Settings
        {
            IsPaused = true,
            PausedAt = now,
            PausedUntil = Date(2026, 3, 10, 10, 50),
        };

        var projected = reminders
            .Select(r => Projection.ProjectedFires(r, now, 1, settings, Utc)[0].FireDate)
            .ToList();
        Assert.Equal(3, projected.Distinct().Count());

        var (engine, clock, _) = MakeEngine(reminders, settings, now);
        clock.Set(Date(2026, 3, 10, 10, 50));
        engine.Tick();
        Assert.Equal(
            projected.OrderBy(f => f).ToList(),
            NextFires(engine, clock.Now).OrderBy(f => f).ToList());
    }

    // MARK: - Machine sleep

    [Fact]
    public void WakingFromSleepKeepsRemindersApart()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var (engine, clock, _) = MakeEngine(
            StaggeredHourlyTrio(start), now: Date(2026, 3, 10, 9, 50));

        clock.Set(Date(2026, 3, 10, 17, 0));
        engine.AbsorbBacklogFromDowntime();

        var fires = NextFires(engine, clock.Now);
        Assert.Equal(3, fires.Distinct().Count());
        Assert.Equal(fires.OrderBy(f => f).ToList(), fires);
    }

    // MARK: - Wall-clock schedules are untouched

    [Fact]
    public void ResumeDoesNotMoveWallClockReminders()
    {
        var reminder = new Reminder
        {
            Title = "Wind Down",
            Schedule = new Schedule.DailyAt(20, 59, 1),
            CreatedAt = Date(2026, 3, 10, 9, 0),
        };
        var (engine, clock, _) = MakeEngine([reminder], now: Date(2026, 3, 10, 10, 0));

        engine.SetPaused(true);
        clock.Advance(Duration.FromHours(3));
        engine.Resume();

        Assert.Null(engine.Reminders[0].LastFiredAt);
        Assert.Equal(
            Date(2026, 3, 10, 20, 59),
            Scheduler.NextFireDate(engine.Reminders[0], clock.Now, Utc));
    }

    /// <summary>
    /// Repeated pausing must never drag reminders together — the property the
    /// old code violated.
    /// </summary>
    [Fact]
    public void RepeatedPausingNeverConvergesReminders()
    {
        var start = Date(2026, 3, 10, 9, 0);
        var (engine, clock, _) = MakeEngine(
            StaggeredHourlyTrio(start), now: Date(2026, 3, 10, 9, 45));

        for (var i = 0; i < 12; i++)
        {
            engine.SetPaused(true);
            clock.Advance(Duration.FromMinutes(7));
            engine.Resume();
            clock.Advance(Duration.FromMinutes(3));
            engine.Tick();
        }

        var fires = NextFires(engine, clock.Now);
        Assert.Equal(3, fires.Distinct().Count());
        Assert.True((fires.Max() - fires.Min()) > Duration.FromMinutes(20));
    }
}
