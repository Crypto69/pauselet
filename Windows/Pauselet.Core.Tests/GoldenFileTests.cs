using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// The cross-platform persistence contract: the fixtures were written by the
/// real Mac app's Swift encoder (<c>FileDataStore.save</c> on macOS), and this
/// suite proves the C# store reads them and writes them back byte-for-byte.
/// That single guarantee is what makes "copy your data.json between a Mac and
/// a PC" a supported behaviour rather than an accident.
///
/// If one of these tests fails after a change, the change broke file
/// interchange with the Mac app — fix the code, not the fixture. Regenerate
/// fixtures only when the Mac encoder itself changes, and then on a Mac.
///
/// (One known asymmetry, invisible here because the fixtures use single-day
/// weekday sets: Swift encodes weekly weekday *sets* in per-process hash
/// order, while this encoder always writes them sorted ascending. Both sides
/// decode either order.)
/// </summary>
public class GoldenFileTests
{
    private static byte[] Fixture(string name) =>
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", name));

    private static Instant Epoch(long seconds) => Instant.FromUnixTimeSeconds(seconds);

    // MARK: - Reading what the Mac wrote

    [Fact]
    public void FullFixtureDecodesToTheExpectedValues()
    {
        var data = AppDataJson.Decode(Fixture("golden-full.json"));

        Assert.Equal(1, data.SchemaVersion);
        Assert.Equal(3, data.Reminders.Count);
        Assert.Equal(3, data.Events.Count);

        var tilt = data.Reminders[0];
        Assert.Equal(Guid.Parse("AAAAAAAA-1111-2222-3333-444444444444"), tilt.Id);
        Assert.Equal("Tilt Back", tilt.Title);
        Assert.Equal(new Schedule.Interval(60), tilt.Schedule);
        Assert.Equal(Priority.Critical, tilt.Priority);
        Assert.True(tilt.IsEnabled);
        Assert.Equal("figure.seated.side", tilt.SymbolName);
        Assert.Equal(300, tilt.ActivityDurationSeconds);
        Assert.Equal("Submarine", tilt.SoundName);
        Assert.Null(tilt.DisplaySeconds);
        Assert.Equal(MusicChoice.DefaultPlaylist, tilt.Music);
        Assert.Equal(Epoch(1_770_000_000), tilt.LastFiredAt);
        Assert.Equal(Epoch(1_770_000_100), tilt.LastAcknowledgedAt);
        Assert.Null(tilt.SnoozedUntil);
        Assert.Equal(Epoch(1_760_000_000), tilt.CreatedAt);

        var stretch = data.Reminders[1];
        // The escaped "\/" and the non-ASCII characters must both survive.
        Assert.Equal("Stretch & Range / Motion", stretch.Title);
        Assert.Equal("Run through your physio stretches — café con calma.", stretch.Message);
        Assert.Equal(new Schedule.DailyAt(17, 0, 2), stretch.Schedule);
        Assert.False(stretch.IsEnabled);
        Assert.Equal(25, stretch.DisplaySeconds);
        Assert.Equal(
            MusicChoice.Playlist("spotify:playlist:37i9dQZF1DX4sWSpwq3LiO"), stretch.Music
        );
        Assert.Equal(Epoch(1_770_000_500), stretch.SnoozedUntil);

        var call = data.Reminders[2];
        Assert.Equal(new Schedule.WeeklyAt(10, 30, new HashSet<int> { 4 }), call.Schedule);
        Assert.Equal(Priority.Subtle, call.Priority);
        Assert.Equal(MusicChoice.None, call.Music);
        Assert.Equal("", call.Message);

        Assert.True(data.Settings.QuietHours.IsEnabled);
        Assert.Equal(21, data.Settings.QuietHours.StartHour);
        Assert.Equal(30, data.Settings.QuietHours.StartMinute);
        Assert.Equal(6, data.Settings.QuietHours.EndHour);
        Assert.Equal(45, data.Settings.QuietHours.EndMinute);
        Assert.True(data.Settings.IsPaused);
        Assert.Equal(Epoch(1_770_001_000), data.Settings.PausedUntil);
        Assert.Equal(12, data.Settings.SnoozeMinutes);
        Assert.True(data.Settings.LaunchAtLogin);
        Assert.False(data.Settings.ShowsNextReminderInMenuBar);
        Assert.Equal("spotify:playlist:37i9dQZF1DX4sWSpwq3LiO", data.Settings.DefaultPlaylistUri);
        Assert.False(data.Settings.MusicEnabled);
        Assert.Equal(42, data.Settings.MusicVolume);

        Assert.Equal(ReminderEvent.Outcome.Fired, data.Events[0].EventOutcome);
        Assert.Equal(ReminderEvent.Outcome.Completed, data.Events[1].EventOutcome);
        Assert.Equal(ReminderEvent.Outcome.Missed, data.Events[2].EventOutcome);
        Assert.Equal(tilt.Id, data.Events[0].ReminderId);
        Assert.Equal("Stretch & Range / Motion", data.Events[2].ReminderTitle);
    }

    // MARK: - Writing exactly what the Mac writes

    [Fact]
    public void FullFixtureReencodesByteIdentically()
    {
        var original = Fixture("golden-full.json");
        var reencoded = AppDataJson.Encode(AppDataJson.Decode(original));
        Assert.Equal(original, reencoded);
    }

    /// <summary>
    /// A data file resaved by a BOM-writing Windows editor must still load —
    /// the engine answers a decode failure by replacing the user's reminders
    /// with the starter set, far too high a price for three invisible bytes.
    /// (Found the hard way: Windows PowerShell's UTF8 encoding writes a BOM.)
    /// </summary>
    [Fact]
    public void BomPrefixedFileStillDecodes()
    {
        var withBom = new byte[] { 0xEF, 0xBB, 0xBF }
            .Concat(Fixture("golden-minimal.json"))
            .ToArray();
        var data = AppDataJson.Decode(withBom);
        Assert.Equal("Drink Water", data.Reminders[0].Title);
    }

    [Fact]
    public void MinimalFixtureReencodesByteIdentically()
    {
        // The minimal fixture pins the awkward formatting corners: an empty
        // events array, the empty payload object of `music: none`, and every
        // optional field absent.
        var original = Fixture("golden-minimal.json");
        var reencoded = AppDataJson.Encode(AppDataJson.Decode(original));
        Assert.Equal(original, reencoded);
    }

    /// <summary>
    /// The full path a real migration takes: the Mac file is dropped where the
    /// store expects it, loaded, and saved again — and the file on disk is
    /// still exactly what the Mac wrote.
    /// </summary>
    [Fact]
    public void MacFileSurvivesALoadSaveCycleThroughTheStore()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"PauseletGolden-{Guid.NewGuid()}");
        Directory.CreateDirectory(directory);
        try
        {
            var path = Path.Combine(directory, "data.json");
            File.WriteAllBytes(path, Fixture("golden-full.json"));

            var store = new FileDataStore(path);
            store.Save(store.Load());

            Assert.Equal(Fixture("golden-full.json"), File.ReadAllBytes(path));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
