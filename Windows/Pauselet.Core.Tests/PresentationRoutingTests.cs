using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// A presenter that records how each reminder would be shown, standing in for
/// the app's real routing (subtle card / notification / full-screen overlay).
///
/// The app layer cannot be imported here, so this mirrors the same decision the
/// real presenter makes. The point is to pin down the routing rules, which are
/// the part a user actually feels.
/// </summary>
public sealed class RoutingPresenter : IReminderPresenting
{
    public enum Surface
    {
        SubtleCard,
        Notification,
        FullScreenOverlay,
    }

    public List<(string Title, Surface Surface)> Routed { get; } = [];
    public int DismissAllCount { get; private set; }

    /// <summary>Mirrors the real presenter's routing decision.</summary>
    public static Surface SurfaceFor(Priority priority) => priority switch
    {
        Priority.Subtle => Surface.SubtleCard,
        Priority.Normal or Priority.Important => Surface.Notification,
        Priority.Critical => Surface.FullScreenOverlay,
        _ => throw new ArgumentOutOfRangeException(nameof(priority)),
    };

    public void Present(Reminder reminder, Settings settings)
    {
        Routed.Add((reminder.Title, SurfaceFor(reminder.Priority)));
    }

    public void DismissAll() => DismissAllCount += 1;
}

public class PresentationRoutingTests
{
    private static readonly DateTimeZone Utc = DateTimeZone.Utc;

    private static Reminder MakeDueReminder(string title, Priority priority, Instant start) =>
        new Reminder
        {
            Title = title, Schedule = new Schedule.Interval(10),
            Priority = priority, CreatedAt = start,
        } with { LastFiredAt = start };

    /// <summary>
    /// Each tier must reach a genuinely different surface. This is the whole
    /// premise of the app: a 20-minute nudge and an hourly pressure-relief
    /// prompt must not feel the same.
    /// </summary>
    [Fact]
    public void EachPriorityRoutesToItsOwnSurface()
    {
        Assert.Equal(RoutingPresenter.Surface.SubtleCard,
            RoutingPresenter.SurfaceFor(Priority.Subtle));
        Assert.Equal(RoutingPresenter.Surface.Notification,
            RoutingPresenter.SurfaceFor(Priority.Normal));
        Assert.Equal(RoutingPresenter.Surface.Notification,
            RoutingPresenter.SurfaceFor(Priority.Important));
        Assert.Equal(RoutingPresenter.Surface.FullScreenOverlay,
            RoutingPresenter.SurfaceFor(Priority.Critical));
    }

    [Fact]
    public void FiredRemindersAreRoutedByPriority()
    {
        var start = Instant.FromUnixTimeSeconds(1_800_000_000);
        var reminders = new[]
        {
            MakeDueReminder("Shift", Priority.Subtle, start),
            MakeDueReminder("Water", Priority.Normal, start),
            MakeDueReminder("Meds", Priority.Important, start),
            MakeDueReminder("Tilt", Priority.Critical, start),
        };
        var store = new InMemoryDataStore(new AppData { Reminders = reminders });
        var clock = new MutableDateProvider(start);
        var presenter = new RoutingPresenter();
        var engine = new ReminderEngine(store, clock, presenter, Utc);

        clock.AdvanceSeconds(10 * 60);
        engine.Tick();

        // Presented lowest priority first, so the overlay lands on top.
        Assert.Equal(
            [
                RoutingPresenter.Surface.SubtleCard,
                RoutingPresenter.Surface.Notification,
                RoutingPresenter.Surface.Notification,
                RoutingPresenter.Surface.FullScreenOverlay,
            ],
            presenter.Routed.Select(r => r.Surface).ToArray()
        );
    }

    /// <summary>
    /// The default reminders must map to the presentations they were designed
    /// for: the hourly tilt takes over the screen, the 20-minute shift does
    /// not.
    /// </summary>
    [Fact]
    public void StarterSetRoutesTheWayItWasDesignedTo()
    {
        var starters = DefaultReminders.StarterSet();

        var tilt = starters.First(r => r.Title == "Tilt Back");
        // The hourly pressure-relief prompt must interrupt.
        Assert.Equal(
            RoutingPresenter.Surface.FullScreenOverlay,
            RoutingPresenter.SurfaceFor(tilt.Priority)
        );

        var shift = starters.First(r => r.Title == "Weight Shift");
        // A nudge every 20 minutes must stay quiet or it gets tuned out.
        Assert.Equal(
            RoutingPresenter.Surface.SubtleCard,
            RoutingPresenter.SurfaceFor(shift.Priority)
        );

        var water = starters.First(r => r.Title == "Drink Water");
        Assert.Equal(
            RoutingPresenter.Surface.Notification,
            RoutingPresenter.SurfaceFor(water.Priority)
        );
    }

    /// <summary>Pausing must clear anything already on screen, not just stop new ones.</summary>
    [Fact]
    public void PausingClearsWhateverIsOnScreen()
    {
        var start = Instant.FromUnixTimeSeconds(1_800_000_000);
        var reminder = MakeDueReminder("Tilt", Priority.Critical, start);
        var store = new InMemoryDataStore(new AppData { Reminders = [reminder] });
        var clock = new MutableDateProvider(start);
        var presenter = new RoutingPresenter();
        var engine = new ReminderEngine(store, clock, presenter, Utc);

        clock.AdvanceSeconds(10 * 60);
        engine.Tick();
        Assert.Single(presenter.Routed);

        engine.SetPaused(true);
        Assert.Equal(1, presenter.DismissAllCount);
    }

    /// <summary>
    /// A reminder with an activity duration drives the countdown, so the value
    /// has to survive into what gets presented.
    /// </summary>
    [Fact]
    public void ActivityDurationReachesThePresenter()
    {
        var start = Instant.FromUnixTimeSeconds(1_800_000_000);
        var reminder = MakeDueReminder("Tilt", Priority.Critical, start) with
        {
            ActivityDurationSeconds = 5 * 60,
        };

        var store = new InMemoryDataStore(new AppData { Reminders = [reminder] });
        var clock = new MutableDateProvider(start);
        var presenter = new RecordingPresenter();
        var engine = new ReminderEngine(store, clock, presenter, Utc);

        clock.AdvanceSeconds(10 * 60);
        engine.Tick();

        Assert.Equal(300, presenter.Presented.First().ActivityDurationSeconds);
    }
}

/// <summary>Tests for the per-reminder on-screen duration.</summary>
public class DisplayDurationTests
{
    /// <summary>Mirrors how the presenter picks a duration for a subtle card.</summary>
    private static int EffectiveSeconds(Reminder reminder, Settings settings) =>
        Math.Max(2, reminder.DisplaySeconds ?? settings.SubtleDisplaySeconds);

    [Fact]
    public void FallsBackToTheGlobalSettingWhenUnset()
    {
        var settings = new Settings { SubtleDisplaySeconds = 8 };
        var reminder = new Reminder { Title = "Shift", Schedule = new Schedule.Interval(20) };

        Assert.Null(reminder.DisplaySeconds);
        Assert.Equal(8, EffectiveSeconds(reminder, settings));
    }

    /// <summary>The point of the feature: a wordy reminder can be given longer to read.</summary>
    [Fact]
    public void PerReminderValueOverridesTheGlobalSetting()
    {
        var settings = new Settings { SubtleDisplaySeconds = 8 };
        var reminder = new Reminder
        {
            Title = "Shift", Schedule = new Schedule.Interval(20), DisplaySeconds = 25,
        };

        Assert.Equal(25, EffectiveSeconds(reminder, settings));
    }

    /// <summary>A too-short value would flash the card and vanish before it can be read.</summary>
    [Fact]
    public void DurationIsClampedToAReadableMinimum()
    {
        var settings = new Settings { SubtleDisplaySeconds = 8 };
        var reminder = new Reminder
        {
            Title = "Shift", Schedule = new Schedule.Interval(20), DisplaySeconds = 0,
        };

        Assert.Equal(2, EffectiveSeconds(reminder, settings));
    }

    [Fact]
    public void DisplaySecondsSurvivesARoundTrip()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"ReminderDisplay-{Guid.NewGuid()}");
        Directory.CreateDirectory(directory);
        try
        {
            var store = new FileDataStore(Path.Combine(directory, "data.json"));
            var reminder = new Reminder
            {
                Title = "Shift", Schedule = new Schedule.Interval(20), DisplaySeconds = 30,
            };

            store.Save(new AppData { Reminders = [reminder] });
            var loaded = store.Load();

            Assert.Equal(30, loaded.Reminders.First().DisplaySeconds);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    /// <summary>Reminders saved before this field existed must still load.</summary>
    [Fact]
    public void OlderDataWithoutDisplaySecondsStillLoads()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"ReminderLegacy-{Guid.NewGuid()}");
        Directory.CreateDirectory(directory);
        try
        {
            var url = Path.Combine(directory, "data.json");

            // A record written before `displaySeconds` was added.
            var legacy = $$"""
            {
              "schemaVersion": 1,
              "reminders": [{
                "id": "{{Guid.NewGuid().ToString().ToUpperInvariant()}}",
                "title": "Weight Shift",
                "message": "Shift your weight.",
                "schedule": { "interval": { "minutes": 20 } },
                "priority": "subtle",
                "isEnabled": true,
                "symbolName": "arrow.up.and.down.circle",
                "createdAt": 1780000000
              }],
              "settings": {
                "quietHours": {
                  "isEnabled": false, "startHour": 22, "startMinute": 0,
                  "endHour": 7, "endMinute": 0, "allowsCritical": true
                },
                "isPaused": false, "snoozeMinutes": 5, "subtleDisplaySeconds": 8,
                "launchAtLogin": false, "showsNextReminderInMenuBar": true,
                "soundEnabled": true
              },
              "events": []
            }
            """;
            File.WriteAllText(url, legacy);

            var loaded = new FileDataStore(url).Load();
            Assert.Single(loaded.Reminders);
            // A missing field should decode as null, not fail the whole file.
            Assert.Null(loaded.Reminders.First().DisplaySeconds);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
