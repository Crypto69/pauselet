using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// Tests for the fire-date projection that pre-scheduled delivery (iOS) is
/// built on. The projection must agree with what the live engine would have
/// done tick by tick — snooze first, quiet hours resolved at fire time, pause
/// re-anchoring — because on iOS there is no tick to correct it later.
/// </summary>
public class ProjectionTests
{
    private static readonly DateTimeZone Utc = DateTimeZone.Utc;

    private static Instant Date(int year, int month, int day, int hour = 0, int minute = 0) =>
        TestDates.At(Utc, year, month, day, hour, minute);

    // MARK: - Interval schedules

    [Fact]
    public void IntervalProjectsSuccessiveFires()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(60), CreatedAt = created,
        };
        var fires = Projection.ProjectedFires(reminder, created, 3, new Settings(), Utc);
        Assert.Equal(
            [Date(2026, 3, 10, 10, 0), Date(2026, 3, 10, 11, 0), Date(2026, 3, 10, 12, 0)],
            fires.Select(f => f.FireDate).ToArray()
        );
        // Interval fires stamp their delivery time.
        Assert.Equal(
            fires.Select(f => f.FireDate).ToArray(),
            fires.Select(f => f.StampDate).ToArray()
        );
    }

    [Fact]
    public void OverdueIntervalProjectsNowFirstThenReanchors()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(20), CreatedAt = created,
        } with { LastFiredAt = Date(2026, 3, 10, 9, 0) };
        var now = Date(2026, 3, 10, 15, 0);
        var fires = Projection.ProjectedFires(reminder, now, 2, new Settings(), Utc);
        Assert.Equal(
            [now, Date(2026, 3, 10, 15, 20)],
            fires.Select(f => f.FireDate).ToArray()
        );
    }

    [Fact]
    public void SnoozeWinsFirstThenScheduleResumes()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(60), CreatedAt = created,
        } with
        {
            LastFiredAt = Date(2026, 3, 10, 9, 30),
            SnoozedUntil = Date(2026, 3, 10, 9, 40),
        };
        var fires = Projection.ProjectedFires(
            reminder, Date(2026, 3, 10, 9, 35), 2, new Settings(), Utc
        );
        // The snooze fires once, and the interval restarts from its delivery.
        Assert.Equal(
            [Date(2026, 3, 10, 9, 40), Date(2026, 3, 10, 10, 40)],
            fires.Select(f => f.FireDate).ToArray()
        );
    }

    [Fact]
    public void DisabledReminderProjectsNothing()
    {
        var reminder = new Reminder
        {
            Title = "Off", Schedule = new Schedule.Interval(5),
            CreatedAt = Date(2026, 3, 10, 9, 0),
        } with { IsEnabled = false };
        Assert.Empty(
            Projection.ProjectedFires(
                reminder, Date(2026, 3, 10, 12, 0), 5, new Settings(), Utc
            )
        );
    }

    // MARK: - Wall-clock schedules

    [Fact]
    public void DailyProjectsSuccessiveSlotsWithSlotStamps()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Stretch",
            Schedule = new Schedule.DailyAt(17, 0, 1),
            CreatedAt = created,
        };
        var fires = Projection.ProjectedFires(reminder, created, 3, new Settings(), Utc);
        Assert.Equal(
            [Date(2026, 3, 10, 17, 0), Date(2026, 3, 11, 17, 0), Date(2026, 3, 12, 17, 0)],
            fires.Select(f => f.FireDate).ToArray()
        );
        Assert.Equal(
            fires.Select(f => f.FireDate).ToArray(),
            fires.Select(f => f.StampDate).ToArray()
        );
    }

    [Fact]
    public void EveryTwoDaysStaysOnItsGrid()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Stretch",
            Schedule = new Schedule.DailyAt(17, 0, 2),
            CreatedAt = created,
        };
        var fires = Projection.ProjectedFires(reminder, created, 3, new Settings(), Utc);
        Assert.Equal(
            [Date(2026, 3, 10, 17, 0), Date(2026, 3, 12, 17, 0), Date(2026, 3, 14, 17, 0)],
            fires.Select(f => f.FireDate).ToArray()
        );
    }

    [Fact]
    public void WeeklyProjectsSelectedWeekdaysOnly()
    {
        // 2026-03-10 is a Tuesday.
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Call",
            Schedule = new Schedule.WeeklyAt(18, 30, new HashSet<int> { 2, 6 }), // Mon, Fri
            CreatedAt = created,
        };
        var fires = Projection.ProjectedFires(reminder, created, 3, new Settings(), Utc);
        Assert.Equal(
            [
                Date(2026, 3, 13, 18, 30), // Friday
                Date(2026, 3, 16, 18, 30), // Monday
                Date(2026, 3, 20, 18, 30), // Friday
            ],
            fires.Select(f => f.FireDate).ToArray()
        );
    }

    [Fact]
    public void WeeklyWithNoWeekdaysProjectsNothing()
    {
        var reminder = new Reminder
        {
            Title = "Never",
            Schedule = new Schedule.WeeklyAt(9, 0, new HashSet<int>()),
            CreatedAt = Date(2026, 3, 10, 9, 0),
        };
        Assert.Empty(
            Projection.ProjectedFires(
                reminder, Date(2026, 3, 10, 10, 0), 5, new Settings(), Utc
            )
        );
    }

    [Fact]
    public void OverdueDailySlotStampsTheSlotNotDeliveryTime()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Stretch",
            Schedule = new Schedule.DailyAt(17, 0, 1),
            CreatedAt = created,
        };
        // The 17:00 slot elapsed unheard; projection from 18:00 delivers a
        // catch-up now, stamped with the slot it honours.
        var now = Date(2026, 3, 10, 18, 0);
        var fires = Projection.ProjectedFires(reminder, now, 2, new Settings(), Utc);
        Assert.Equal(now, fires[0].FireDate);
        Assert.Equal(Date(2026, 3, 10, 17, 0), fires[0].StampDate);
        Assert.Equal(Date(2026, 3, 11, 17, 0), fires[1].FireDate);
    }

    // MARK: - Quiet hours

    private static Settings QuietSettings(
        (int Hour, int Minute) start, (int Hour, int Minute) end, bool allowsCritical = true) =>
        new()
        {
            QuietHours = new QuietHours
            {
                IsEnabled = true,
                StartHour = start.Hour, StartMinute = start.Minute,
                EndHour = end.Hour, EndMinute = end.Minute,
                AllowsCritical = allowsCritical,
            },
        };

    [Fact]
    public void IntervalFireInsideQuietHoursWaitsForWindowEnd()
    {
        var created = Date(2026, 3, 10, 21, 30);
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(60), CreatedAt = created,
        };
        var settings = QuietSettings((22, 0), (7, 0));
        var fires = Projection.ProjectedFires(reminder, created, 2, settings, Utc);
        // 22:30 falls inside the window; it delivers at 07:00, and the next
        // interval runs from that delivery.
        Assert.Equal(
            [Date(2026, 3, 11, 7, 0), Date(2026, 3, 11, 8, 0)],
            fires.Select(f => f.FireDate).ToArray()
        );
    }

    [Fact]
    public void WallClockSlotInsideQuietHoursIsSkippedNotDelayed()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Late stretch",
            Schedule = new Schedule.DailyAt(23, 0, 1),
            CreatedAt = created,
        };
        var settings = QuietSettings((22, 0), (7, 0));
        var fires = Projection.ProjectedFires(reminder, created, 3, settings, Utc);
        // Every 23:00 slot lives inside the window, so nothing is ever
        // delivered — and the projection terminates rather than spinning.
        Assert.Empty(fires);
    }

    [Fact]
    public void CriticalPiercesQuietHoursWhenAllowed()
    {
        var created = Date(2026, 3, 10, 21, 30);
        var reminder = new Reminder
        {
            Title = "Pressure relief",
            Schedule = new Schedule.Interval(60),
            Priority = Priority.Critical,
            CreatedAt = created,
        };
        var settings = QuietSettings((22, 0), (7, 0), allowsCritical: true);
        var fires = Projection.ProjectedFires(reminder, created, 1, settings, Utc);
        Assert.Equal([Date(2026, 3, 10, 22, 30)], fires.Select(f => f.FireDate).ToArray());
    }

    [Fact]
    public void CriticalRespectsQuietHoursWhenNotAllowed()
    {
        var created = Date(2026, 3, 10, 21, 30);
        var reminder = new Reminder
        {
            Title = "Pressure relief",
            Schedule = new Schedule.Interval(60),
            Priority = Priority.Critical,
            CreatedAt = created,
        };
        var settings = QuietSettings((22, 0), (7, 0), allowsCritical: false);
        var fires = Projection.ProjectedFires(reminder, created, 1, settings, Utc);
        Assert.Equal([Date(2026, 3, 11, 7, 0)], fires.Select(f => f.FireDate).ToArray());
    }

    // MARK: - Pause

    [Fact]
    public void IndefinitePauseProjectsNothing()
    {
        var settings = new Settings { IsPaused = true };
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(30),
            CreatedAt = Date(2026, 3, 10, 9, 0),
        };
        Assert.Empty(
            Projection.ProjectedFires(reminder, Date(2026, 3, 10, 10, 0), 5, settings, Utc)
        );
    }

    [Fact]
    public void TimedPauseReanchorsIntervalsToItsEnd()
    {
        var settings = new Settings
        {
            IsPaused = true,
            PausedUntil = Date(2026, 3, 10, 12, 0),
        };
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(30),
            CreatedAt = Date(2026, 3, 10, 9, 0),
        } with { LastFiredAt = Date(2026, 3, 10, 9, 30) };
        var fires = Projection.ProjectedFires(
            reminder, Date(2026, 3, 10, 10, 0), 2, settings, Utc
        );
        // Not 10:00 (the natural overdue fire): the pause absorbs it and the
        // interval restarts from the pause's end, exactly as Resume() does.
        Assert.Equal(
            [Date(2026, 3, 10, 12, 30), Date(2026, 3, 10, 13, 0)],
            fires.Select(f => f.FireDate).ToArray()
        );
    }

    [Fact]
    public void TimedPauseDeliversElapsedWallClockSlotAtItsEnd()
    {
        var settings = new Settings
        {
            IsPaused = true,
            PausedUntil = Date(2026, 3, 10, 18, 0),
        };
        var reminder = new Reminder
        {
            Title = "Stretch",
            Schedule = new Schedule.DailyAt(17, 0, 1),
            CreatedAt = Date(2026, 3, 10, 9, 0),
        };
        var fires = Projection.ProjectedFires(
            reminder, Date(2026, 3, 10, 16, 0), 2, settings, Utc
        );
        // The 17:00 slot elapses during the pause and surfaces once at 18:00,
        // stamped with the slot it honours.
        Assert.Equal(Date(2026, 3, 10, 18, 0), fires[0].FireDate);
        Assert.Equal(Date(2026, 3, 10, 17, 0), fires[0].StampDate);
        Assert.Equal(Date(2026, 3, 11, 17, 0), fires[1].FireDate);
    }

    // MARK: - DST

    [Fact]
    public void DailySlotStaysOnLocalTimeAcrossSpringForward()
    {
        var newYork = TestDates.Zone("America/New_York");
        var created = TestDates.At(newYork, 2026, 3, 7, 9, 0);
        var reminder = new Reminder
        {
            Title = "Meds",
            Schedule = new Schedule.DailyAt(12, 0, 1),
            CreatedAt = created,
        };
        // Spring forward is 2026-03-08 in New York.
        var fires = Projection.ProjectedFires(reminder, created, 3, new Settings(), newYork);
        for (var offset = 0; offset < fires.Count; offset++)
        {
            var local = fires[offset].FireDate.InZone(newYork);
            Assert.Equal(12, local.Hour); // Slot must stay 12:00 local across DST
            Assert.Equal(7 + offset, local.Day);
        }
    }
}

/// <summary>Tests for the 64-request budget allocator.</summary>
public class NotificationBudgetTests
{
    private static ProjectedFire Fire(int minutesFromNow)
    {
        // Mirrors the Swift tests' use of the 2001 reference epoch.
        var date = Instant.FromUnixTimeSeconds(978_307_200)
            .Plus(Duration.FromMinutes(minutesFromNow));
        return new ProjectedFire(date, date);
    }

    [Fact]
    public void EveryReminderGetsItsFirstFireBeforeAnySecond()
    {
        var frequent = Guid.NewGuid();
        var daily = Guid.NewGuid();
        (Guid, IReadOnlyList<ProjectedFire>)[] projections =
        [
            (frequent, [Fire(5), Fire(10), Fire(15), Fire(20)]),
            (daily, [Fire(600)]),
        ];
        var entries = NotificationBudget.Allocate(projections, 2);
        Assert.Equal(2, entries.Count);
        // The daily reminder must not be starved by the frequent one.
        Assert.Equal(
            new HashSet<Guid> { frequent, daily },
            entries.Select(e => e.ReminderId).ToHashSet()
        );
    }

    [Fact]
    public void WithinALayerSoonerFiresWin()
    {
        var a = Guid.NewGuid();
        var b = Guid.NewGuid();
        var c = Guid.NewGuid();
        (Guid, IReadOnlyList<ProjectedFire>)[] projections =
        [
            (a, [Fire(30)]), (b, [Fire(10)]), (c, [Fire(20)]),
        ];
        var entries = NotificationBudget.Allocate(projections, 2);
        Assert.Equal(
            [Fire(10).FireDate, Fire(20).FireDate],
            entries.Select(e => e.Fire.FireDate).ToArray()
        );
    }

    [Fact]
    public void BudgetLargerThanSupplyReturnsEverything()
    {
        var a = Guid.NewGuid();
        var b = Guid.NewGuid();
        (Guid, IReadOnlyList<ProjectedFire>)[] projections =
        [
            (a, [Fire(5), Fire(10)]), (b, [Fire(7)]),
        ];
        var entries = NotificationBudget.Allocate(projections, 64);
        Assert.Equal(3, entries.Count);
    }

    [Fact]
    public void ZeroBudgetReturnsNothing()
    {
        (Guid, IReadOnlyList<ProjectedFire>)[] projections = [(Guid.NewGuid(), [Fire(5)])];
        Assert.Empty(NotificationBudget.Allocate(projections, 0));
    }

    [Fact]
    public void AllocationIsDeterministic()
    {
        var a = Guid.NewGuid();
        var b = Guid.NewGuid();
        (Guid, IReadOnlyList<ProjectedFire>)[] projections =
        [
            (a, [Fire(5)]), (b, [Fire(5)]),
        ];
        var first = NotificationBudget.Allocate(projections, 1);
        var second = NotificationBudget.Allocate(projections, 1);
        Assert.Equal(first, second);
    }
}
