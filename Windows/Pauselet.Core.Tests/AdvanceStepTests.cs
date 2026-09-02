using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// Tests for <c>Scheduler.NextStep</c> — the one firing decision that
/// <c>Tick()</c> applies once and the projection loops — and for the places
/// that must agree with it: the live engine, launch absorption, and the
/// next-up countdown. Translated 1:1 from the Swift <c>AdvanceStepTests</c>.
///
/// The projection used to be a second hand-maintained copy of Tick()'s
/// policy, and it drifted twice (quiet hours judged at delivery instead of at
/// the slot; a timed pause re-anchoring intervals on one path but not the
/// other). These tests pin the cases that drifted and, more importantly, run
/// the two side by side over days of simulated time.
/// </summary>
public class AdvanceStepTests
{
    private static readonly DateTimeZone Utc = DateTimeZone.Utc;

    private static Instant Date(
        int year, int month, int day, int hour = 0, int minute = 0, int second = 0) =>
        TestDates.At(Utc, year, month, day, hour, minute, second);

    private static Settings QuietSettings(
        (int Hour, int Minute)? start = null, (int Hour, int Minute)? end = null,
        bool allowsCritical = true)
    {
        var s = start ?? (22, 0);
        var e = end ?? (7, 0);
        return new Settings
        {
            QuietHours = new QuietHours
            {
                IsEnabled = true,
                StartHour = s.Hour, StartMinute = s.Minute,
                EndHour = e.Hour, EndMinute = e.Minute,
                AllowsCritical = allowsCritical,
            },
        };
    }

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

    // MARK: - Quiet hours are judged at the slot, on both sides

    /// <summary>
    /// A 17:00 slot that elapsed *outside* quiet hours while the app was
    /// paused into the window is delivered when the window ends — the
    /// projection used to consume it as a skip, so an iOS user never got it.
    /// </summary>
    [Fact]
    public void SlotThatPassedOutsideQuietHoursIsDeliveredAfterTheWindow()
    {
        var settings = QuietSettings() with
        {
            IsPaused = true,
            PausedUntil = Date(2026, 3, 10, 23, 0),
        };
        var reminder = new Reminder
        {
            Title = "Stretch",
            Schedule = new Schedule.DailyAt(17, 0, 1),
            CreatedAt = Date(2026, 3, 9, 9, 0),
        } with { LastFiredAt = Date(2026, 3, 9, 17, 0) };

        var fires = Projection.ProjectedFires(
            reminder, Date(2026, 3, 10, 16, 0), 2, settings, Utc
        );
        Assert.Equal(Date(2026, 3, 11, 7, 0), fires[0].FireDate);
        Assert.Equal(Date(2026, 3, 10, 17, 0), fires[0].StampDate);
        Assert.Equal(Date(2026, 3, 11, 17, 0), fires[1].FireDate);

        // And the live engine does the same.
        var (engine, clock, presenter) = MakeEngine([reminder], settings, Date(2026, 3, 10, 16, 0));
        clock.Set(Date(2026, 3, 10, 23, 0, 5));
        Assert.Empty(engine.Tick()); // Inside quiet hours
        clock.Set(Date(2026, 3, 11, 7, 0, 5));
        Assert.Single(engine.Tick());
        Assert.Equal(["Stretch"], presenter.Presented.Select(r => r.Title).ToArray());
        Assert.Equal(Date(2026, 3, 10, 17, 0), engine.Reminders[0].LastFiredAt);
    }

    /// <summary>
    /// A 23:00 slot that passed *inside* quiet hours is skipped even when the
    /// first chance to deliver it (a pause ending at 07:30) is outside the
    /// window — the projection used to deliver it at 07:30.
    /// </summary>
    [Fact]
    public void SlotThatPassedInsideQuietHoursIsSkippedEvenWhenDeliveryWouldBeOutside()
    {
        var settings = QuietSettings() with
        {
            IsPaused = true,
            PausedUntil = Date(2026, 3, 11, 7, 30),
        };
        var reminder = new Reminder
        {
            Title = "Late pills",
            Schedule = new Schedule.DailyAt(23, 0, 1),
            CreatedAt = Date(2026, 3, 9, 9, 0),
        } with { LastFiredAt = Date(2026, 3, 9, 23, 0) };

        var fires = Projection.ProjectedFires(
            reminder, Date(2026, 3, 10, 21, 0), 1, settings, Utc
        );
        Assert.Empty(fires); // Every 23:00 slot is inside the window

        var step = Scheduler.NextStep(reminder, Date(2026, 3, 10, 21, 0), settings, Utc);
        Assert.NotNull(step);
        Assert.Equal(Scheduler.FireStep.Outcome.Skip, step.StepOutcome);
        Assert.Equal(Date(2026, 3, 10, 23, 0), step.StampDate);
        Assert.Equal(Date(2026, 3, 11, 7, 30), step.FireDate); // Noticed when the pause lifts

        var (engine, clock, presenter) = MakeEngine([reminder], settings, Date(2026, 3, 10, 21, 0));
        clock.Set(Date(2026, 3, 11, 7, 30, 5));
        Assert.Empty(engine.Tick());
        Assert.Empty(presenter.Presented);
        Assert.Equal(
            [ReminderEvent.Outcome.Missed],
            engine.Events.Select(e => e.EventOutcome).ToArray()
        );
        Assert.Equal(Date(2026, 3, 10, 23, 0), engine.Reminders[0].LastFiredAt);
    }

    // MARK: - Timed pause: one behaviour

    /// <summary>
    /// The projection made while a timed pause runs must describe exactly
    /// what the engine does once the pause expires on its own.
    /// </summary>
    [Fact]
    public void ProjectionDuringTimedPauseMatchesEngineAfterExpiry()
    {
        var settings = new Settings { IsPaused = true, PausedUntil = Date(2026, 3, 10, 12, 0) };
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(30),
            CreatedAt = Date(2026, 3, 10, 9, 0),
        } with { LastFiredAt = Date(2026, 3, 10, 9, 30) };

        var projected = Projection.ProjectedFires(
            reminder, Date(2026, 3, 10, 10, 0), 2, settings, Utc
        );
        Assert.Equal(
            [Date(2026, 3, 10, 12, 30), Date(2026, 3, 10, 13, 0)],
            projected.Select(f => f.FireDate).ToArray()
        );

        var (engine, clock, _) = MakeEngine([reminder], settings, Date(2026, 3, 10, 10, 0));
        var fired = new List<Instant>();
        var cursor = Date(2026, 3, 10, 10, 0);
        while (cursor <= Date(2026, 3, 10, 13, 0))
        {
            clock.Set(cursor);
            if (engine.Tick().Count > 0) fired.Add(cursor);
            cursor = cursor.Plus(Duration.FromMinutes(1));
        }
        Assert.Equal(projected.Select(f => f.FireDate).ToArray(), fired.ToArray());
    }

    [Fact]
    public void NextUpDuringTimedPauseLooksPastThePause()
    {
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(30),
            CreatedAt = Date(2026, 3, 10, 9, 0),
        } with { LastFiredAt = Date(2026, 3, 10, 9, 30) };
        var (engine, _, _) = MakeEngine([reminder], null, Date(2026, 3, 10, 10, 0));

        engine.PauseFor(120);
        Assert.Equal(Date(2026, 3, 10, 12, 30), engine.NextUp?.Date);

        engine.SetPaused(true);
        Assert.Null(engine.NextUp); // An indefinite pause schedules nothing
    }

    // MARK: - Absorption respects quiet hours

    /// <summary>
    /// An interval fire that fell due inside quiet hours is not a missed
    /// reminder: the live engine holds it until the window ends. Opening the
    /// app at 06:00 must leave it to fire at 07:00.
    /// </summary>
    [Fact]
    public void AbsorbLeavesAFireHeldByQuietHours()
    {
        var settings = QuietSettings();
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(60),
            CreatedAt = Date(2026, 3, 10, 20, 0),
        } with { LastFiredAt = Date(2026, 3, 10, 22, 30) };
        var (engine, clock, presenter) = MakeEngine([reminder], settings, Date(2026, 3, 11, 6, 0));

        Assert.Empty(engine.AbsorbBacklogFromDowntime());
        Assert.Empty(engine.Events); // No false "missed" entry
        Assert.Equal(Date(2026, 3, 10, 22, 30), engine.Reminders[0].LastFiredAt);

        clock.Set(Date(2026, 3, 11, 7, 0, 5));
        Assert.Single(engine.Tick());
        Assert.Equal(["Water"], presenter.Presented.Select(r => r.Title).ToArray());
    }

    [Fact]
    public void AbsorbLeavesASnoozeHeldByQuietHours()
    {
        var settings = QuietSettings();
        var reminder = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(60),
            CreatedAt = Date(2026, 3, 10, 20, 0),
        } with
        {
            LastFiredAt = Date(2026, 3, 10, 21, 0),
            SnoozedUntil = Date(2026, 3, 10, 23, 30),
        };
        var (engine, _, _) = MakeEngine([reminder], settings, Date(2026, 3, 11, 6, 0));

        Assert.Empty(engine.AbsorbBacklogFromDowntime());
        Assert.Equal(Date(2026, 3, 10, 23, 30), engine.Reminders[0].SnoozedUntil);
    }

    /// <summary>
    /// Once the window that held a fire has ended and the grace has passed,
    /// it really was missed.
    /// </summary>
    [Fact]
    public void AbsorbConsumesAFireWhoseQuietWindowEndedLongAgo()
    {
        var settings = QuietSettings();
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(60),
            CreatedAt = Date(2026, 3, 10, 20, 0),
        } with { LastFiredAt = Date(2026, 3, 10, 22, 30) };
        var (engine, _, _) = MakeEngine([reminder], settings, Date(2026, 3, 11, 9, 0));

        Assert.Single(engine.AbsorbBacklogFromDowntime());
        Assert.Equal(
            [ReminderEvent.Outcome.Missed],
            engine.Events.Select(e => e.EventOutcome).ToArray()
        );
        Assert.Equal(Date(2026, 3, 11, 9, 0), engine.Reminders[0].LastFiredAt);
    }

    // MARK: - External fires

    /// <summary>
    /// History dates a fire at the moment it reached the user, whichever path
    /// noticed it: an external wall-clock catch-up delivered at 07:00 for the
    /// 17:00 slot is a 07:00 event, exactly as Tick() would have recorded it.
    /// </summary>
    [Fact]
    public void ExternalFireIsRecordedAtDeliveryTimeAndAnchoredAtTheStamp()
    {
        var reminder = new Reminder
        {
            Title = "Stretch",
            Schedule = new Schedule.DailyAt(17, 0, 1),
            CreatedAt = Date(2026, 3, 10, 9, 0),
        };
        var (engine, _, _) = MakeEngine([reminder], null, Date(2026, 3, 11, 8, 0));

        engine.RecordExternalFire(
            reminder.Id, Date(2026, 3, 10, 17, 0), deliveredAt: Date(2026, 3, 11, 7, 0)
        );

        Assert.Equal(Date(2026, 3, 10, 17, 0), engine.Reminders[0].LastFiredAt);
        Assert.Equal([Date(2026, 3, 11, 7, 0)], engine.Events.Select(e => e.Date).ToArray());
        Assert.Equal(
            [ReminderEvent.Outcome.Fired],
            engine.Events.Select(e => e.EventOutcome).ToArray()
        );
    }

    /// <summary>
    /// A relative alarm rule has occurrences from before the reminder
    /// existed; recording one of those would invent a fire.
    /// </summary>
    [Fact]
    public void ExternalFireBeforeTheReminderExistedIsIgnored()
    {
        var reminder = new Reminder
        {
            Title = "Meds",
            Schedule = new Schedule.DailyAt(9, 0, 1),
            CreatedAt = Date(2026, 3, 10, 10, 0),
        };
        var (engine, _, _) = MakeEngine([reminder], null, Date(2026, 3, 10, 10, 5));

        engine.RecordExternalFire(reminder.Id, Date(2026, 3, 10, 9, 0));

        Assert.Null(engine.Reminders[0].LastFiredAt);
        Assert.Empty(engine.Events);
    }

    [Fact]
    public void BatchOfExternalFiresPersistsOnce()
    {
        var a = new Reminder
        {
            Title = "A", Schedule = new Schedule.Interval(60), CreatedAt = Date(2026, 3, 10, 9, 0),
        };
        var b = new Reminder
        {
            Title = "B", Schedule = new Schedule.Interval(60), CreatedAt = Date(2026, 3, 10, 9, 0),
        };
        var store = new CountingStore(new AppData { Reminders = [a, b] });
        var engine = new ReminderEngine(
            store, new MutableDateProvider(Date(2026, 3, 10, 12, 0)), null, Utc
        );
        var before = store.SaveCount;

        engine.RecordExternalFires(
        [
            new ReminderEngine.ExternalFire { ReminderId = a.Id, StampDate = Date(2026, 3, 10, 10, 0) },
            new ReminderEngine.ExternalFire { ReminderId = b.Id, StampDate = Date(2026, 3, 10, 10, 0) },
            new ReminderEngine.ExternalFire { ReminderId = a.Id, StampDate = Date(2026, 3, 10, 11, 0) },
        ]);

        Assert.Equal(1, store.SaveCount - before);
        Assert.Equal(3, engine.Events.Count(e => e.EventOutcome == ReminderEvent.Outcome.Fired));
        Assert.Equal(
            Date(2026, 3, 10, 11, 0),
            engine.Reminders.First(r => r.Id == a.Id).LastFiredAt
        );
    }

    // MARK: - The engine and the projection never disagree

    /// <summary>
    /// Runs the live engine minute by minute for three days over a mixed set
    /// of reminders with quiet hours, and checks that every fire it produces
    /// is exactly the next one the projection predicted from the start —
    /// same reminder, same moment, same stamp.
    /// </summary>
    [Fact]
    public void EngineTicksReproduceTheProjectionOverThreeDays()
    {
        var start = Date(2026, 3, 10, 8, 0);
        var settings = QuietSettings((22, 0), (7, 0), allowsCritical: false);

        var water = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(95),
            Priority = Priority.Normal, CreatedAt = start,
        } with { LastFiredAt = start };
        var stretch = new Reminder
        {
            Title = "Stretch", Schedule = new Schedule.DailyAt(21, 30, 1),
            Priority = Priority.Important, CreatedAt = start,
        };
        var night = new Reminder
        {
            Title = "Night check", Schedule = new Schedule.DailyAt(23, 15, 2),
            Priority = Priority.Critical, CreatedAt = start,
        };
        var call = new Reminder
        {
            Title = "Call",
            Schedule = new Schedule.WeeklyAt(6, 45, new HashSet<int> { 3, 4, 5 }), // Tue–Thu
            Priority = Priority.Normal, CreatedAt = start,
        };
        var snoozed = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(240),
            Priority = Priority.Critical, CreatedAt = start,
        } with { SnoozedUntil = start.Plus(Duration.FromMinutes(20)) };

        Reminder[] reminders = [water, stretch, night, call, snoozed];
        var expected = reminders.ToDictionary(
            r => r.Id,
            r => Projection.ProjectedFires(r, start, 64, settings, Utc)
        );

        // Ticks land every five minutes, so a fire is delivered by the first
        // tick at or after its projected moment.
        var tickInterval = Duration.FromMinutes(5);
        Instant TickAtOrAfter(Instant date)
        {
            var elapsed = (date - start).TotalSeconds;
            var ticks = Math.Ceiling(elapsed / tickInterval.TotalSeconds);
            return start.Plus(Duration.FromSeconds(ticks * tickInterval.TotalSeconds));
        }

        var (engine, clock, _) = MakeEngine(reminders, settings, start);
        var seen = new Dictionary<Guid, List<(Instant FireDate, Instant StampDate)>>();
        var cursor = start;
        var end = start.Plus(Duration.FromDays(3));
        while (cursor <= end)
        {
            clock.Set(cursor);
            foreach (var fired in engine.Tick())
            {
                if (!seen.TryGetValue(fired.Id, out var list))
                {
                    list = [];
                    seen[fired.Id] = list;
                }
                list.Add((cursor, fired.LastFiredAt!.Value));
            }
            cursor = cursor.Plus(tickInterval);
        }

        foreach (var reminder in reminders)
        {
            var predicted = expected[reminder.Id].Where(f => f.FireDate <= end).ToList();
            var actual = seen.TryGetValue(reminder.Id, out var list) ? list : [];
            Assert.Equal(
                predicted.Select(f => TickAtOrAfter(f.FireDate)).ToArray(),
                actual.Select(a => a.FireDate).ToArray()
            );
            Assert.Equal(
                predicted.Select(f => f.StampDate).ToArray(),
                actual.Select(a => a.StampDate).ToArray()
            );
        }
        Assert.NotEmpty(seen);
    }

    /// <summary>A store that counts writes, for asserting batch persistence.</summary>
    private sealed class CountingStore(AppData data) : IDataStoring
    {
        private AppData _data = data;
        public int SaveCount { get; private set; }
        public bool HasPersistedData => true;

        public AppData Load() => _data;

        public void Save(AppData data)
        {
            _data = data;
            SaveCount += 1;
        }
    }
}
