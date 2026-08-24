using NodaTime;

namespace Pauselet.Core;

/// <summary>The on-disk shape of everything the app persists.</summary>
public sealed record AppData
{
    /// <summary>
    /// Bumped when the on-disk format changes, so migrations have something to
    /// branch on.
    /// </summary>
    public int SchemaVersion { get; init; } = CurrentSchemaVersion;
    public IReadOnlyList<Reminder> Reminders { get; init; } = [];
    public Settings Settings { get; init; } = new();
    public IReadOnlyList<ReminderEvent> Events { get; init; } = [];

    public const int CurrentSchemaVersion = 1;

    // List-valued properties need element-wise comparison; the synthesized
    // record equality would compare list references.
    public bool Equals(AppData? other) =>
        other is not null
        && SchemaVersion == other.SchemaVersion
        && Reminders.SequenceEqual(other.Reminders)
        && Settings == other.Settings
        && Events.SequenceEqual(other.Events);

    public override int GetHashCode() =>
        HashCode.Combine(SchemaVersion, Reminders.Count, Settings, Events.Count);
}

/// <summary>Abstracts the filesystem so tests can run against a temp directory.</summary>
public interface IDataStoring
{
    AppData Load();
    void Save(AppData data);
    /// <summary>
    /// Whether anything has actually been written yet. Lets the engine tell a
    /// genuine first launch from a returning one, so it can persist the starter
    /// set once rather than reseeding timing anchors on every launch.
    /// </summary>
    bool HasPersistedData { get; }
}

/// <summary>
/// Persists <c>AppData</c> as pretty-printed JSON in a single local file.
///
/// Everything stays on this machine — there is no network path out of this
/// type, by design. The file is byte-compatible with the Mac app's, so copying
/// it between machines is a supported migration path.
/// </summary>
public sealed class FileDataStore : IDataStoring
{
    public string FilePath { get; }
    private readonly object _gate = new();

    /// <summary>The folder the app stores data in, under the roaming app-data directory.</summary>
    internal const string DirectoryName = "Pauselet";

    /// <summary>
    /// The default location: <c>%APPDATA%\Pauselet\data.json</c> on Windows.
    /// (The Mac app's legacy-directory migration has no counterpart here —
    /// there has never been a Windows install under the old name.)
    /// </summary>
    public static string DefaultFilePath()
    {
        var baseDirectory = Environment.GetFolderPath(
            Environment.SpecialFolder.ApplicationData,
            Environment.SpecialFolderOption.Create
        );
        var directory = Path.Combine(baseDirectory, DirectoryName);
        Directory.CreateDirectory(directory);
        return Path.Combine(directory, "data.json");
    }

    public FileDataStore(string filePath)
    {
        FilePath = filePath;
    }

    public FileDataStore() : this(DefaultFilePath()) { }

    public bool HasPersistedData
    {
        get
        {
            try
            {
                var info = new FileInfo(FilePath);
                return info.Exists && info.Length > 0;
            }
            catch
            {
                return false;
            }
        }
    }

    /// <summary>
    /// Rounds every date in <paramref name="data"/> to whole seconds, matching
    /// what a save/load cycle produces. The engine stamps this on values it
    /// holds in memory so they stay equal to what is on disk.
    /// </summary>
    public static AppData NormalizingDates(AppData data) => data with
    {
        Reminders = data.Reminders.Select(reminder => reminder with
        {
            CreatedAt = reminder.CreatedAt.RoundedToSecond(),
            LastFiredAt = reminder.LastFiredAt?.RoundedToSecond(),
            LastAcknowledgedAt = reminder.LastAcknowledgedAt?.RoundedToSecond(),
            SnoozedUntil = reminder.SnoozedUntil?.RoundedToSecond(),
        }).ToList(),
        Events = data.Events.Select(e => e with
        {
            Date = e.Date.RoundedToSecond(),
        }).ToList(),
        Settings = data.Settings with
        {
            PausedUntil = data.Settings.PausedUntil?.RoundedToSecond(),
        },
    };

    /// <summary>
    /// Where an unreadable data file is preserved before the engine's fallback
    /// path overwrites it with defaults.
    /// </summary>
    public string CorruptBackupPath => Path.ChangeExtension(FilePath, "corrupt.json");

    public AppData Load()
    {
        lock (_gate)
        {
            if (!File.Exists(FilePath))
            {
                return new AppData { Reminders = DefaultReminders.StarterSet() };
            }
            var raw = File.ReadAllBytes(FilePath);
            if (raw.Length == 0)
            {
                return new AppData { Reminders = DefaultReminders.StarterSet() };
            }
            try
            {
                return AppDataJson.Decode(raw);
            }
            catch
            {
                // The engine reacts to an unreadable file by starting from the
                // defaults, and its next persist overwrites this file. Keep
                // the bytes around first, so a decode bug degrades into a
                // recoverable incident instead of silently destroying every
                // reminder the user configured.
                try
                {
                    File.Copy(FilePath, CorruptBackupPath, overwrite: true);
                }
                catch
                {
                    // Preserving the backup is best-effort, as on the Mac.
                }
                throw;
            }
        }
    }

    public void Save(AppData data)
    {
        lock (_gate)
        {
            var encoded = AppDataJson.Encode(NormalizingDates(data));
            var directory = Path.GetDirectoryName(FilePath);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }
            // Atomic write: a crash mid-save must not leave a truncated file
            // that loses every reminder the user configured.
            var temporary = FilePath + ".tmp";
            File.WriteAllBytes(temporary, encoded);
            File.Move(temporary, FilePath, overwrite: true);
        }
    }
}

/// <summary>An in-memory store for tests and previews.</summary>
public sealed class InMemoryDataStore : IDataStoring
{
    public AppData Data { get; private set; }
    public int SaveCount { get; private set; }

    public InMemoryDataStore(AppData? data = null)
    {
        Data = data ?? new AppData();
    }

    public bool HasPersistedData => SaveCount > 0;

    public AppData Load() => Data;

    public void Save(AppData data)
    {
        Data = data;
        SaveCount += 1;
    }
}

/// <summary>The reminders a brand-new install starts with.</summary>
public static class DefaultReminders
{
    /// <summary>
    /// Pressure relief and movement prompts, plus a couple of general examples
    /// so the concept of priority tiers is visible immediately.
    /// </summary>
    public static IReadOnlyList<Reminder> StarterSet(Instant? now = null)
    {
        var createdAt = now ?? SystemClock.Instance.GetCurrentInstant();
        return
        [
            new Reminder
            {
                Title = "Tilt Back",
                Message = "Tilt your chair back for 5 minutes. Stop working and listen to calming music.",
                Schedule = new Schedule.Interval(60),
                Priority = Priority.Critical,
                SymbolName = "figure.seated.side",
                ActivityDurationSeconds = 5 * 60,
                CreatedAt = createdAt,
            },
            new Reminder
            {
                Title = "Weight Shift",
                Message = "Activate your glutes and redistribute your weight.",
                Schedule = new Schedule.Interval(20),
                Priority = Priority.Subtle,
                SymbolName = "arrow.up.and.down.circle",
                CreatedAt = createdAt,
            },
            new Reminder
            {
                Title = "Drink Water",
                Message = "Have a drink of water.",
                Schedule = new Schedule.Interval(60),
                Priority = Priority.Normal,
                SymbolName = "drop.fill",
                CreatedAt = createdAt,
            },
            // Ships switched off so the user opts in rather than being
            // surprised by it.
            new Reminder
            {
                Title = "Stretch & Range of Motion",
                Message = "Run through your physio stretches.",
                Schedule = new Schedule.DailyAt(17, 0, 2),
                Priority = Priority.Important,
                SymbolName = "figure.flexibility",
                ActivityDurationSeconds = 10 * 60,
                IsEnabled = false,
                CreatedAt = createdAt,
            },
        ];
    }
}
