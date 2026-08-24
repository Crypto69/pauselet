using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// Tests that data survives a round trip to disk and that a damaged file cannot
/// take the app down on launch.
/// </summary>
public class StoreTests : IDisposable
{
    private readonly string _tempDirectory;

    public StoreTests()
    {
        _tempDirectory = Path.Combine(Path.GetTempPath(), $"ReminderTests-{Guid.NewGuid()}");
        Directory.CreateDirectory(_tempDirectory);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDirectory))
        {
            Directory.Delete(_tempDirectory, recursive: true);
        }
    }

    private FileDataStore MakeStore() =>
        new(Path.Combine(_tempDirectory, "data.json"));

    // MARK: - Round trip

    [Fact]
    public void SaveThenLoadPreservesEverything()
    {
        var store = MakeStore();
        var reminder = new Reminder
        {
            Title = "Tilt Back",
            Message = "Tilt for 5 minutes.",
            Schedule = new Schedule.Interval(60),
            Priority = Priority.Critical,
            SymbolName = "figure.seated.side",
            ActivityDurationSeconds = 300,
            LastFiredAt = Instant.FromUnixTimeSeconds(1_700_000_000),
        };
        var settings = new Settings
        {
            SnoozeMinutes = 12,
            QuietHours = new QuietHours
            {
                IsEnabled = true, StartHour = 21, StartMinute = 30,
                EndHour = 6, EndMinute = 45, AllowsCritical = true,
            },
        };
        var reminderEvent = new ReminderEvent
        {
            ReminderId = reminder.Id,
            ReminderTitle = reminder.Title,
            Date = Instant.FromUnixTimeSeconds(1_700_000_100),
            EventOutcome = ReminderEvent.Outcome.Completed,
        };
        var data = new AppData
        {
            Reminders = [reminder], Settings = settings, Events = [reminderEvent],
        };

        store.Save(data);
        var loaded = store.Load();

        // Exact equality: dates are stored at whole-second precision precisely
        // so a reloaded value compares equal to the one written.
        Assert.Equal(FileDataStore.NormalizingDates(data), loaded);
    }

    [Fact]
    public void EachScheduleKindSurvivesRoundTrip()
    {
        var store = MakeStore();
        Schedule[] schedules =
        [
            new Schedule.Interval(20),
            new Schedule.DailyAt(17, 30, 2),
            new Schedule.WeeklyAt(8, 0, new HashSet<int> { 2, 4, 6 }),
        ];
        var reminders = schedules
            .Select((schedule, index) => new Reminder
            {
                Title = $"R{index}", Schedule = schedule,
            })
            .ToList();

        store.Save(new AppData { Reminders = reminders });
        var loaded = store.Load();

        Assert.Equal(schedules, loaded.Reminders.Select(r => r.Schedule).ToArray());
    }

    // MARK: - First launch

    [Fact]
    public void MissingFileYieldsStarterSet()
    {
        var store = MakeStore();
        var loaded = store.Load();

        Assert.NotEmpty(loaded.Reminders);
        // The hourly pressure-relief reminder should ship by default.
        Assert.Contains(loaded.Reminders, r => r.Title == "Tilt Back");
        Assert.Contains(loaded.Reminders, r => r.Title == "Weight Shift");
    }

    [Fact]
    public void StarterSetUsesTheRequestedSchedulesAndPriorities()
    {
        var reminders = DefaultReminders.StarterSet();

        var tilt = reminders.FirstOrDefault(r => r.Title == "Tilt Back");
        Assert.Equal(new Schedule.Interval(60), tilt?.Schedule);
        Assert.Equal(Priority.Critical, tilt?.Priority); // Hourly tilt must be intrusive
        Assert.Equal(300, tilt?.ActivityDurationSeconds); // Five-minute tilt countdown
        Assert.True(tilt?.IsEnabled ?? false);

        var shift = reminders.FirstOrDefault(r => r.Title == "Weight Shift");
        Assert.Equal(new Schedule.Interval(20), shift?.Schedule);
        Assert.Equal(Priority.Subtle, shift?.Priority); // Twenty-minute nudge must be subtle
        Assert.True(shift?.IsEnabled ?? false);

        // Optional examples ship switched off so nothing surprises a new user.
        var physio = reminders.FirstOrDefault(r => r.Title == "Stretch & Range of Motion");
        Assert.Equal(new Schedule.DailyAt(17, 0, 2), physio?.Schedule);
        Assert.False(physio?.IsEnabled ?? true);
    }

    [Fact]
    public void EmptyFileYieldsStarterSetRatherThanThrowing()
    {
        var url = Path.Combine(_tempDirectory, "data.json");
        File.WriteAllBytes(url, []);
        var store = new FileDataStore(url);

        var loaded = store.Load();
        Assert.NotEmpty(loaded.Reminders);
    }

    /// <summary>
    /// A first launch must write the starter set to disk immediately. Without
    /// this the file stays absent until the user changes something, so every
    /// relaunch reseeds <c>CreatedAt</c> and the interval anchors slide
    /// forward.
    /// </summary>
    [Fact]
    public void FirstLaunchPersistsStarterSetSoAnchorsSurviveRelaunch()
    {
        var store = MakeStore();
        Assert.False(store.HasPersistedData);

        var first = new ReminderEngine(store);
        // Starting with no data file should write one.
        Assert.True(store.HasPersistedData);
        var originalAnchors = first.Reminders
            .Select(r => r.CreatedAt.ToUnixTimeSeconds())
            .OrderBy(s => s)
            .ToArray();

        // A second launch against the same file must reuse the stored anchors.
        var second = new ReminderEngine(new FileDataStore(store.FilePath));
        var reloadedAnchors = second.Reminders
            .Select(r => r.CreatedAt.ToUnixTimeSeconds())
            .OrderBy(s => s)
            .ToArray();

        Assert.Equal(originalAnchors, reloadedAnchors);
    }

    // MARK: - Corruption

    [Fact]
    public void CorruptFileThrowsSoTheEngineCanFallBack()
    {
        var url = Path.Combine(_tempDirectory, "data.json");
        File.WriteAllText(url, "{ this is not json");
        var store = new FileDataStore(url);

        Assert.ThrowsAny<Exception>(() => store.Load());
    }

    /// <summary>
    /// An unreadable file must be preserved before the fallback path can
    /// overwrite it, so the user's data survives a decode bug.
    /// </summary>
    [Fact]
    public void CorruptFileIsBackedUpBeforeFallback()
    {
        var url = Path.Combine(_tempDirectory, "data.json");
        var corruptBytes = "{ this is not json"u8.ToArray();
        File.WriteAllBytes(url, corruptBytes);
        var store = new FileDataStore(url);

        Assert.ThrowsAny<Exception>(() => store.Load());

        var backup = File.ReadAllBytes(store.CorruptBackupPath);
        Assert.Equal(corruptBytes, backup); // The original bytes are kept intact

        // The fallback overwrite must not touch the backup.
        store.Save(new AppData { Reminders = DefaultReminders.StarterSet() });
        Assert.Equal(corruptBytes, File.ReadAllBytes(store.CorruptBackupPath));
    }

    /// <summary>
    /// The engine must start with defaults rather than crashing when the file
    /// on disk is unreadable.
    /// </summary>
    [Fact]
    public void EngineRecoversFromCorruptFile()
    {
        var url = Path.Combine(_tempDirectory, "data.json");
        File.WriteAllText(url, "not json at all");
        var store = new FileDataStore(url);

        var engine = new ReminderEngine(store);
        Assert.NotEmpty(engine.Reminders); // Falls back to the starter set
    }

    // MARK: - Writes

    [Fact]
    public void SaveOverwritesPreviousContents()
    {
        var store = MakeStore();
        store.Save(new AppData
        {
            Reminders = [new Reminder { Title = "First", Schedule = new Schedule.Interval(10) }],
        });
        store.Save(new AppData
        {
            Reminders = [new Reminder { Title = "Second", Schedule = new Schedule.Interval(10) }],
        });

        var loaded = store.Load();
        Assert.Equal(["Second"], loaded.Reminders.Select(r => r.Title).ToArray());
    }

    [Fact]
    public void SaveCreatesMissingDirectory()
    {
        var nested = Path.Combine(_tempDirectory, "a", "b", "c", "data.json");
        var store = new FileDataStore(nested);

        store.Save(new AppData
        {
            Reminders = [new Reminder { Title = "Deep", Schedule = new Schedule.Interval(5) }],
        });
        Assert.True(File.Exists(nested));
    }

    [Fact]
    public void SchemaVersionIsRecorded()
    {
        var store = MakeStore();
        store.Save(new AppData());
        var loaded = store.Load();
        Assert.Equal(AppData.CurrentSchemaVersion, loaded.SchemaVersion);
    }

    /// <summary>Data is written as plain local JSON — no network, no cloud.</summary>
    [Fact]
    public void DataIsStoredAsReadableLocalJson()
    {
        var store = MakeStore();
        store.Save(new AppData
        {
            Reminders =
            [
                new Reminder { Title = "Local Only", Schedule = new Schedule.Interval(30) },
            ],
        });

        var raw = File.ReadAllText(store.FilePath);
        Assert.Contains("Local Only", raw);
        Assert.Contains("schemaVersion", raw);
    }

    [Fact]
    public void DefaultFilePathIsInsideThePauseletDirectory()
    {
        var path = FileDataStore.DefaultFilePath();
        Assert.Equal("data.json", Path.GetFileName(path));
        Assert.Contains(
            Path.Combine("Pauselet", "data.json"), path
        );
    }

    // The Mac store also migrates data written under the app's pre-rename
    // directory ("Reminder" → "Pauselet"). That path is deliberately not
    // ported: no Windows install ever existed under the old name, so there is
    // nothing to migrate from.
}
