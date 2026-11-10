using System.Text;
using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// <see cref="Schedule.TimedInterval"/>: a repeat interval pinned to the clock
/// ("every 50 minutes from 05:40, Mon–Fri, until 13:00") rather than to the
/// last fire. Mirrors the Swift <c>TimedIntervalTests</c>.
/// </summary>
public class TimedIntervalTests
{
    private static readonly DateTimeZone Utc = DateTimeZone.Utc;

    private static Instant Date(
        int year, int month, int day, int hour = 0, int minute = 0, int second = 0) =>
        TestDates.At(Utc, year, month, day, hour, minute, second);

    // 9 Mar 2026 is a Monday.
    private static readonly HashSet<int> MonFri = [2, 3, 4, 5, 6];
    private static readonly Schedule Customer = new Schedule.TimedInterval(50, 5, 40, 13, 0, MonFri);

    private static Reminder Make(Schedule schedule, Instant createdAt, Instant? lastFiredAt = null) =>
        new Reminder { Title = "Break soon", Schedule = schedule, CreatedAt = createdAt }
            with { LastFiredAt = lastFiredAt };

    private static List<Instant> Slots(Reminder reminder, int count, DateTimeZone? zone = null)
    {
        var sim = reminder;
        var result = new List<Instant>();
        for (var i = 0; i < count; i++)
        {
            if (Scheduler.NextScheduleSlot(sim, zone ?? Utc) is not { } slot) break;
            result.Add(slot);
            sim = sim with { LastFiredAt = slot };
        }
        return result;
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
        return (new ReminderEngine(store, clock, presenter, Utc), clock, presenter);
    }

    // MARK: - The grid

    [Fact]
    public void CustomerTimetableRunsFromStartToEndThenNextDay()
    {
        var expected = new (int H, int M)[]
            { (5, 40), (6, 30), (7, 20), (8, 10), (9, 0), (9, 50), (10, 40), (11, 30), (12, 20) }
            .Select(t => Date(2026, 3, 9, t.H, t.M))
            .Append(Date(2026, 3, 10, 5, 40))
            .ToList();
        Assert.Equal(expected, Slots(Make(Customer, Date(2026, 3, 9, 5, 0)), 10));
    }

    [Fact]
    public void EndTimeIsInclusive()
    {
        var schedule = new Schedule.TimedInterval(50, 5, 40, 12, 20, MonFri);
        Assert.Equal(
            [Date(2026, 3, 9, 12, 20), Date(2026, 3, 10, 5, 40)],
            Slots(Make(schedule, Date(2026, 3, 9, 12, 0)), 2)
        );
    }

    [Fact]
    public void AfterFridaysLastSlotTheNextIsMonday()
    {
        var r = Make(Customer, Date(2026, 3, 9), Date(2026, 3, 13, 12, 20));
        Assert.Equal(Date(2026, 3, 16, 5, 40), Scheduler.NextScheduleSlot(r, Utc));
    }

    [Fact]
    public void WithoutAnEndTheGridRunsToMidnight()
    {
        var schedule = new Schedule.TimedInterval(
            50, 22, 0, null, null, new HashSet<int>(Enumerable.Range(1, 7))
        );
        Assert.Equal(
            [
                Date(2026, 3, 9, 22, 0), Date(2026, 3, 9, 22, 50), Date(2026, 3, 9, 23, 40),
                Date(2026, 3, 10, 22, 0),
            ],
            Slots(Make(schedule, Date(2026, 3, 9, 21, 0)), 4)
        );
    }

    [Fact]
    public void AReminderCreatedMidMorningJoinsTheGrid()
    {
        var r = Make(Customer, Date(2026, 3, 9, 9, 5));
        Assert.Equal(Date(2026, 3, 9, 9, 50), Scheduler.NextScheduleSlot(r, Utc));
    }

    [Fact]
    public void NoWeekdaysNeverFires()
    {
        var schedule = new Schedule.TimedInterval(30, 9, 0, null, null, new HashSet<int>());
        var r = Make(schedule, Date(2026, 3, 9));
        Assert.Null(Scheduler.NextScheduleSlot(r, Utc));
        Assert.Null(Scheduler.NextFireDate(r, Date(2026, 3, 9), Utc));
    }

    [Fact]
    public void SlotsKeepTheirClockTimesAcrossDst()
    {
        var newYork = DateTimeZoneProviders.Tzdb["America/New_York"];
        // Clocks go forward at 02:00 on Sunday 8 Mar 2026.
        var schedule = new Schedule.TimedInterval(
            120, 1, 0, 5, 0, new HashSet<int>(Enumerable.Range(1, 7))
        );
        var fired = Slots(Make(schedule, TestDates.At(newYork, 2026, 3, 7, 23, 0)), 3, newYork);
        Assert.Equal(
            [
                TestDates.At(newYork, 2026, 3, 8, 1, 0),
                TestDates.At(newYork, 2026, 3, 8, 3, 0),
                TestDates.At(newYork, 2026, 3, 8, 5, 0),
            ],
            fired
        );
        // 01:00 → 03:00 on the clock is one real hour that night.
        Assert.Equal(Duration.FromHours(1), fired[1] - fired[0]);
    }

    [Fact]
    public void LatestElapsedSlotAfterAGap()
    {
        var r = Make(Customer, Date(2026, 3, 9), Date(2026, 3, 9, 6, 30));
        Assert.Equal(Date(2026, 3, 9, 9, 0), Scheduler.LatestElapsedSlot(r, Date(2026, 3, 9, 9, 15), Utc));
        // Over a weekend the latest elapsed slot is Friday's last one.
        Assert.Equal(
            Date(2026, 3, 13, 12, 20), Scheduler.LatestElapsedSlot(r, Date(2026, 3, 15, 9, 0), Utc)
        );
        Assert.Null(Scheduler.LatestElapsedSlot(r, Date(2026, 3, 9, 7, 0), Utc));
    }

    // MARK: - Firing through the engine

    [Fact]
    public void FiresOnEachSlotAndNotBetween()
    {
        var r = Make(Customer, Date(2026, 3, 9), Date(2026, 3, 9, 6, 30));
        var (engine, clock, presenter) = MakeEngine([r], null, Date(2026, 3, 9, 7, 19, 55));
        Assert.Empty(engine.Tick());
        clock.Set(Date(2026, 3, 9, 7, 20, 4));
        Assert.Single(engine.Tick());
        Assert.Equal(Date(2026, 3, 9, 7, 20), engine.Reminders[0].LastFiredAt);
        clock.Set(Date(2026, 3, 9, 8, 9, 0));
        Assert.Empty(engine.Tick());
        clock.Set(Date(2026, 3, 9, 8, 10, 3));
        Assert.Single(engine.Tick());
        Assert.Equal(2, presenter.Presented.Count);
    }

    [Fact]
    public void ASlotMissedByLessThanHalfAnIntervalIsDeliveredLate()
    {
        var r = Make(Customer, Date(2026, 3, 9), Date(2026, 3, 9, 6, 30));
        var (engine, _, presenter) = MakeEngine([r], null, Date(2026, 3, 9, 7, 40));
        Assert.Single(engine.Tick());
        Assert.Single(presenter.Presented);
        Assert.Equal(Date(2026, 3, 9, 7, 20), engine.Reminders[0].LastFiredAt);
    }

    [Fact]
    public void ASlotMissedByMoreThanHalfAnIntervalIsSkipped()
    {
        var r = Make(Customer, Date(2026, 3, 9), Date(2026, 3, 9, 6, 30));
        var (engine, clock, presenter) = MakeEngine([r], null, Date(2026, 3, 9, 7, 50));
        Assert.Empty(engine.Tick());
        Assert.Empty(presenter.Presented);
        Assert.Equal(Date(2026, 3, 9, 7, 20), engine.Reminders[0].LastFiredAt);
        Assert.Equal(ReminderEvent.Outcome.Missed, engine.Events[^1].EventOutcome);

        clock.Set(Date(2026, 3, 9, 8, 10, 3));
        Assert.Single(engine.Tick());
        Assert.Single(presenter.Presented);
    }

    [Fact]
    public void ASlotInsideQuietHoursIsSkipped()
    {
        var settings = new Settings
        {
            QuietHours = new QuietHours
            {
                IsEnabled = true, StartHour = 12, StartMinute = 0, EndHour = 14, EndMinute = 0,
            },
        };
        var r = Make(Customer, Date(2026, 3, 9), Date(2026, 3, 9, 11, 30));
        var (engine, clock, presenter) = MakeEngine([r], settings, Date(2026, 3, 9, 12, 20, 3));
        Assert.Empty(engine.Tick());
        clock.Set(Date(2026, 3, 9, 14, 0, 3));
        Assert.Empty(engine.Tick());
        Assert.Empty(presenter.Presented);
        Assert.Equal(ReminderEvent.Outcome.Missed, engine.Events[^1].EventOutcome);
        Assert.Equal(Date(2026, 3, 10, 5, 40), Scheduler.NextScheduleSlot(engine.Reminders[0], Utc));
    }

    [Fact]
    public void CompletingAheadOfASlotConsumesIt()
    {
        var r = Make(Customer, Date(2026, 3, 9), Date(2026, 3, 9, 6, 30))
            with { LastAcknowledgedAt = Date(2026, 3, 9, 6, 31) };
        var (engine, _, _) = MakeEngine([r], null, Date(2026, 3, 9, 7, 0));
        engine.Complete(r.Id);
        Assert.Equal(Date(2026, 3, 9, 7, 20), engine.Reminders[0].LastFiredAt);
        Assert.Equal(Date(2026, 3, 9, 8, 10), Scheduler.NextScheduleSlot(engine.Reminders[0], Utc));
    }

    [Fact]
    public void SnoozeFiresOnceAndTheGridStaysPut()
    {
        var r = Make(Customer, Date(2026, 3, 9), Date(2026, 3, 9, 6, 30));
        var (engine, clock, presenter) = MakeEngine([r], null, Date(2026, 3, 9, 7, 20, 3));
        Assert.Single(engine.Tick());
        engine.Snooze(r.Id, 5);
        clock.Set(Date(2026, 3, 9, 7, 25, 3));
        Assert.Single(engine.Tick());
        Assert.Equal(2, presenter.Presented.Count);
        Assert.Equal(Date(2026, 3, 9, 7, 20), engine.Reminders[0].LastFiredAt);
        Assert.Equal(Date(2026, 3, 9, 8, 10), Scheduler.NextScheduleSlot(engine.Reminders[0], Utc));
    }

    [Fact]
    public void ProjectionFollowsTheGrid()
    {
        var r = Make(Customer, Date(2026, 3, 13, 12, 0));
        var fires = Projection.ProjectedFires(r, Date(2026, 3, 13, 12, 0), 2, new Settings(), Utc);
        Assert.Equal(
            [Date(2026, 3, 13, 12, 20), Date(2026, 3, 16, 5, 40)],
            fires.Select(f => f.FireDate).ToList()
        );
        Assert.Equal(fires.Select(f => f.FireDate), fires.Select(f => f.StampDate));
    }

    // MARK: - Editor helpers and persistence

    [Fact]
    public void SilencedSlotCountAndWarning()
    {
        var settings = new Settings { QuietHours = new QuietHours { IsEnabled = true } }; // 22:00–07:00
        var timed = (Schedule.TimedInterval)Customer;
        Assert.Equal((2, 9), Scheduler.TimedIntervalSilencedSlots(timed, Priority.Normal, settings));
        Assert.Equal(
            "2 of the 9 daily times fall inside quiet hours (22:00–07:00) and will be skipped.",
            Scheduler.TimedIntervalQuietHoursWarning(timed, Priority.Normal, settings)
        );
        Assert.Null(Scheduler.TimedIntervalQuietHoursWarning(timed, Priority.Normal, new Settings()));
    }

    [Fact]
    public void Summary()
    {
        Assert.Equal("Every 50 min, 05:40–13:00, Mon, Tue, Wed, Thu, Fri", Customer.Summary);
        var open = new Schedule.TimedInterval(90, 8, 0, null, null, new HashSet<int> { 1, 7 });
        Assert.Equal("Every 1h 30m from 08:00, Sun, Sat", open.Summary);
        Assert.True(Customer.IsWallClock);
    }

    [Fact]
    public void StructuralEqualityComparesWeekdayContents()
    {
        Assert.Equal(
            new Schedule.TimedInterval(50, 5, 40, 13, 0, new HashSet<int> { 2, 3 }),
            new Schedule.TimedInterval(50, 5, 40, 13, 0, new HashSet<int> { 3, 2 })
        );
        Assert.NotEqual(
            new Schedule.TimedInterval(50, 5, 40, 13, 0, MonFri),
            new Schedule.TimedInterval(50, 5, 40, null, null, MonFri)
        );
    }

    /// <summary>
    /// Reads the shape Swift's synthesized coding writes (see the Swift
    /// <c>testJSONShape</c>), and writes it back the same way: an absent end
    /// is a missing key.
    /// </summary>
    [Theory]
    [InlineData(
        """{"timedInterval":{"endHour":13,"endMinute":0,"minutes":50,"startHour":5,"startMinute":40,"weekdays":[2]}}""",
        true)]
    [InlineData(
        """{"timedInterval":{"minutes":30,"startHour":9,"startMinute":0,"weekdays":[2]}}""",
        false)]
    public void JsonMatchesTheSwiftShape(string scheduleJson, bool hasEnd)
    {
        var file = $$"""
            {"schemaVersion":1,"settings":{"quietHours":{"isEnabled":false,"startHour":22,"startMinute":0,"endHour":7,"endMinute":0,"allowsCritical":true},"isPaused":false,"snoozeMinutes":5,"subtleDisplaySeconds":8,"launchAtLogin":false,"showsNextReminderInMenuBar":true,"soundEnabled":true},
             "events":[],
             "reminders":[{"id":"6A3F2C1E-0000-4000-8000-000000000001","title":"Break soon","message":"","schedule":{{scheduleJson}},"priority":"normal","isEnabled":true,"symbolName":"bell","createdAt":794793600}]}
            """;
        var data = AppDataJson.Decode(Encoding.UTF8.GetBytes(file));
        var timed = Assert.IsType<Schedule.TimedInterval>(data.Reminders[0].Schedule);
        Assert.Equal(hasEnd, timed.EndHour is not null);
        Assert.Equal(hasEnd, timed.EndMinute is not null);

        var reencoded = Encoding.UTF8.GetString(AppDataJson.Encode(data));
        Assert.Contains(StripWhitespace(scheduleJson), StripWhitespace(reencoded));
        Assert.Equal(timed, AppDataJson.Decode(AppDataJson.Encode(data)).Reminders[0].Schedule);
    }

    private static string StripWhitespace(string s) =>
        new(s.Where(c => !char.IsWhiteSpace(c)).ToArray());
}
