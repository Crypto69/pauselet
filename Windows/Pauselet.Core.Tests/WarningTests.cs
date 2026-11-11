using System.Text;
using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// Advance warnings before a Critical takeover. Mirrors the Swift
/// <c>WarningTests</c>.
/// </summary>
public class WarningTests
{
    private static readonly DateTimeZone Utc = DateTimeZone.Utc;

    private static Instant Date(
        int year, int month, int day, int hour = 0, int minute = 0, int second = 0) =>
        TestDates.At(Utc, year, month, day, hour, minute, second);

    // Every 50 minutes from 05:45, Mon–Fri. 9 Mar 2026 is a Monday.
    private static readonly Schedule Breaks =
        new Schedule.TimedInterval(50, 5, 45, 13, 0, new HashSet<int> { 2, 3, 4, 5, 6 });

    private static Reminder Critical(
        Schedule schedule, Instant createdAt, int? warning = 5, Instant? lastFiredAt = null,
        Instant? snoozedUntil = null, Priority priority = Priority.Critical) =>
        new Reminder
        {
            Title = "Screen break",
            Schedule = schedule,
            Priority = priority,
            WarningMinutes = warning,
            CreatedAt = createdAt,
        } with { LastFiredAt = lastFiredAt, SnoozedUntil = snoozedUntil };

    private static IReadOnlyList<ReminderWarning> Project(
        Reminder reminder, Instant from, int limit = 3, Settings? settings = null) =>
        Warnings.Projected(reminder, from, limit, settings ?? new Settings(), Utc);

    [Fact]
    public void WarnsTheLeadAheadOfEachTakeover()
    {
        var r = Critical(Breaks, Date(2026, 3, 9, 5, 0));
        Assert.Equal(
            [
                new ReminderWarning(Date(2026, 3, 9, 5, 40), Date(2026, 3, 9, 5, 45)),
                new ReminderWarning(Date(2026, 3, 9, 6, 30), Date(2026, 3, 9, 6, 35)),
                new ReminderWarning(Date(2026, 3, 9, 7, 20), Date(2026, 3, 9, 7, 25)),
            ],
            Project(r, Date(2026, 3, 9, 5, 0))
        );
    }

    [Fact]
    public void IntervalReminderWarnsBeforeItsNextFire()
    {
        var r = Critical(new Schedule.Interval(60), Date(2026, 3, 9), 10, Date(2026, 3, 9, 9, 0));
        Assert.Equal(
            [new ReminderWarning(Date(2026, 3, 9, 9, 50), Date(2026, 3, 9, 10, 0))],
            Project(r, Date(2026, 3, 9, 9, 5), 1)
        );
    }

    [Fact]
    public void AWarningWhoseMomentPassedIsStillDueBeforeTheTakeover()
    {
        var r = Critical(Breaks, Date(2026, 3, 9, 5, 0));
        Assert.Equal(Date(2026, 3, 9, 5, 45), Project(r, Date(2026, 3, 9, 5, 43), 1)[0].TakeoverAt);
    }

    [Fact]
    public void ALeadAsLongAsTheIntervalCannotWarn()
    {
        var r = Critical(new Schedule.Interval(10), Date(2026, 3, 9), 10, Date(2026, 3, 9, 9, 0));
        Assert.Empty(Project(r, Date(2026, 3, 9, 9, 1)));
        Assert.True(Warnings.OutlastsInterval(10, r.Schedule));
        Assert.False(Warnings.OutlastsInterval(9, r.Schedule));
    }

    [Fact]
    public void ASnoozeComingBackIsNotWarnedButTheNextTakeoverIs()
    {
        var r = Critical(
            new Schedule.Interval(60), Date(2026, 3, 9),
            lastFiredAt: Date(2026, 3, 9, 9, 0), snoozedUntil: Date(2026, 3, 9, 9, 20));
        Assert.Equal(
            [new ReminderWarning(Date(2026, 3, 9, 10, 15), Date(2026, 3, 9, 10, 20))],
            Project(r, Date(2026, 3, 9, 9, 10), 1)
        );
    }

    [Fact]
    public void AWarningInsideATimedPauseIsDropped()
    {
        var settings = new Settings
        {
            PausedUntil = Date(2026, 3, 9, 9, 58),
            PausedAt = Date(2026, 3, 9, 9, 0),
        };
        var r = Critical(
            new Schedule.DailyAt(10, 0, 1), Date(2026, 3, 8), lastFiredAt: Date(2026, 3, 8, 10, 0));
        Assert.Equal(
            [new ReminderWarning(Date(2026, 3, 10, 9, 55), Date(2026, 3, 10, 10, 0))],
            Project(r, Date(2026, 3, 9, 9, 30), 1, settings)
        );
    }

    [Fact]
    public void QuietHoursTheTakeoverRespectsSilenceItsWarning()
    {
        var quiet = new QuietHours { IsEnabled = true, AllowsCritical = false }; // 22:00–07:00
        var r = Critical(new Schedule.DailyAt(7, 2, 1), Date(2026, 3, 9));
        Assert.Empty(Project(r, Date(2026, 3, 9), settings: new Settings { QuietHours = quiet }));

        var piercing = new Settings { QuietHours = quiet with { AllowsCritical = true } };
        Assert.Equal(Date(2026, 3, 9, 6, 57), Project(r, Date(2026, 3, 9), 1, piercing)[0].WarnAt);
    }

    [Fact]
    public void AnIndefinitePauseWarnsOfNothing()
    {
        var r = Critical(Breaks, Date(2026, 3, 9, 5, 0));
        Assert.Empty(Project(r, Date(2026, 3, 9, 5, 0), settings: new Settings { IsPaused = true }));
    }

    [Fact]
    public void OnlyCriticalRemindersWarn()
    {
        Assert.Empty(Project(
            Critical(Breaks, Date(2026, 3, 9, 5, 0), priority: Priority.Important),
            Date(2026, 3, 9, 5, 0)));
        Assert.Empty(Project(Critical(Breaks, Date(2026, 3, 9, 5, 0), warning: null), Date(2026, 3, 9, 5, 0)));
    }

    private static (ReminderEngine, MutableDateProvider, RecordingPresenter) MakeEngine(
        Reminder reminder, Instant now)
    {
        var store = new InMemoryDataStore(new AppData
        {
            Reminders = [reminder],
            Settings = new Settings(),
            Events = [],
        });
        var clock = new MutableDateProvider(now);
        var presenter = new RecordingPresenter();
        return (new ReminderEngine(store, clock, presenter, Utc), clock, presenter);
    }

    [Fact]
    public void TheEngineWarnsOnceThenTakesOver()
    {
        var (engine, clock, presenter) = MakeEngine(
            Critical(Breaks, Date(2026, 3, 9, 5, 0)), Date(2026, 3, 9, 5, 39, 58));
        engine.Tick();
        Assert.Empty(presenter.Warnings);

        clock.Set(Date(2026, 3, 9, 5, 40, 3));
        engine.Tick();
        Assert.Equal([Date(2026, 3, 9, 5, 45)], presenter.Warnings.Select(w => w.TakeoverAt).ToList());
        Assert.Equal("Screen break", presenter.Warnings[0].Title);

        for (var i = 0; i < 5; i++)
        {
            clock.AdvanceSeconds(5);
            engine.Tick();
        }
        Assert.Single(presenter.Warnings); // shown once, not every tick
        Assert.Empty(presenter.Presented); // the warning is not the reminder
        Assert.Empty(engine.Events); // nor is it history

        clock.Set(Date(2026, 3, 9, 5, 45, 3));
        Assert.Single(engine.Tick());
        Assert.Single(presenter.Warnings);

        clock.Set(Date(2026, 3, 9, 6, 30, 2));
        engine.Tick();
        Assert.Equal(Date(2026, 3, 9, 6, 35), presenter.Warnings[^1].TakeoverAt);
    }

    [Fact]
    public void StartingInsideTheWindowWarnsAtOnce()
    {
        var (engine, _, presenter) = MakeEngine(
            Critical(Breaks, Date(2026, 3, 9, 5, 0)), Date(2026, 3, 9, 5, 43));
        engine.Tick();
        Assert.Equal([Date(2026, 3, 9, 5, 45)], presenter.Warnings.Select(w => w.TakeoverAt).ToList());
    }

    [Fact]
    public void ATakeoverAlreadyDueIsNotWarnedAbout()
    {
        var (engine, _, presenter) = MakeEngine(
            Critical(Breaks, Date(2026, 3, 9, 5, 0)), Date(2026, 3, 9, 5, 46));
        Assert.Single(engine.Tick());
        Assert.Empty(presenter.Warnings);
    }

    [Fact]
    public void WarningText()
    {
        var r = Critical(Breaks, Date(2026, 3, 9));
        Assert.Equal("Coming up: Screen break", Warnings.Title(r));
        Assert.Equal("Takes over your screen at 05:45.", Warnings.Message(Date(2026, 3, 9, 5, 45), Utc));
    }

    [Fact]
    public void WarningMinutesPersistAndOldFilesLoadWithout()
    {
        var data = new AppData
        {
            Reminders = [Critical(Breaks, Date(2026, 3, 9), warning: 15)],
            Settings = new Settings(),
            Events = [],
        };
        var encoded = AppDataJson.Encode(data);
        Assert.Contains("\"warningMinutes\"", Encoding.UTF8.GetString(encoded));
        Assert.Equal(15, AppDataJson.Decode(encoded).Reminders[0].WarningMinutes);

        var withoutWarning = data with { Reminders = [data.Reminders[0] with { WarningMinutes = null }] };
        var old = AppDataJson.Encode(withoutWarning);
        Assert.DoesNotContain("warningMinutes", Encoding.UTF8.GetString(old));
        Assert.Null(AppDataJson.Decode(old).Reminders[0].WarningMinutes);
    }

    // Sound

    [Fact]
    public void WarningChimesByDefaultAndCanBeQuiet()
    {
        var r = Critical(Breaks, Date(2026, 3, 9));
        Assert.True(Warnings.PlaysSound(r, new Settings()));
        Assert.False(Warnings.PlaysSound(r with { WarningIsSilent = true }, new Settings()));
    }

    [Fact]
    public void SoundsOffSilencesEveryWarning()
    {
        var r = Critical(Breaks, Date(2026, 3, 9));
        Assert.False(Warnings.PlaysSound(r, new Settings { SoundEnabled = false }));
    }

    [Fact]
    public void QuietWarningLeavesTheTakeoverSound()
    {
        var r = Critical(Breaks, Date(2026, 3, 9)) with { WarningIsSilent = true };
        Assert.True(new Settings().PlaysSound(r.Priority));
    }

    [Fact]
    public void QuietWarningPersistsAndTheDefaultIsNotWritten()
    {
        var data = new AppData
        {
            Reminders = [Critical(Breaks, Date(2026, 3, 9), warning: 15)],
            Settings = new Settings(),
            Events = [],
        };
        var chiming = AppDataJson.Encode(data);
        Assert.DoesNotContain("warningIsSilent", Encoding.UTF8.GetString(chiming));
        Assert.Null(AppDataJson.Decode(chiming).Reminders[0].WarningIsSilent);

        var quiet = AppDataJson.Encode(
            data with { Reminders = [data.Reminders[0] with { WarningIsSilent = true }] }
        );
        Assert.Contains("\"warningIsSilent\" : true", Encoding.UTF8.GetString(quiet));
        Assert.True(AppDataJson.Decode(quiet).Reminders[0].WarningIsSilent);
    }

    [Fact]
    public void WarningPlaysTheChosenSoundOrTheDefault()
    {
        var r = Critical(Breaks, Date(2026, 3, 9));
        Assert.Equal("Glass", Warnings.Sound(r));
        Assert.Equal("Submarine", Warnings.Sound(r with { WarningSoundName = "Submarine" }));
    }

    [Fact]
    public void WarningSoundPersistsAndTheDefaultIsNotWritten()
    {
        var data = new AppData
        {
            Reminders = [Critical(Breaks, Date(2026, 3, 9), warning: 15)],
            Settings = new Settings(),
            Events = [],
        };
        Assert.DoesNotContain("warningSoundName", Encoding.UTF8.GetString(AppDataJson.Encode(data)));

        var chosen = AppDataJson.Encode(
            data with { Reminders = [data.Reminders[0] with { WarningSoundName = "Hero" }] }
        );
        Assert.Contains("\"warningSoundName\" : \"Hero\"", Encoding.UTF8.GetString(chosen));
        Assert.Equal("Hero", AppDataJson.Decode(chosen).Reminders[0].WarningSoundName);
    }
}
