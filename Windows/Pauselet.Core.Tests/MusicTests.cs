using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// Covers the two things that decide whether music works: turning whatever the
/// user pasted into a URI, and deciding which playlist a reminder plays.
/// (Playback itself is deferred on Windows; the model and validation port so
/// data files stay interchangeable with the Mac app.)
/// </summary>
public class MusicTests
{
    // MARK: - Link normalization

    /// <summary>
    /// Every form a user can plausibly paste must land on the same URI. The
    /// share link is what the Spotify UI actually puts on the clipboard, so it
    /// is the important one.
    /// </summary>
    [Fact]
    public void EveryPlaylistInputFormNormalizesToTheSameUri()
    {
        const string expected = "spotify:playlist:37i9dQZF1DX4sWSpwq3LiO";
        string[] inputs =
        [
            "spotify:playlist:37i9dQZF1DX4sWSpwq3LiO",
            "https://open.spotify.com/playlist/37i9dQZF1DX4sWSpwq3LiO",
            "https://open.spotify.com/playlist/37i9dQZF1DX4sWSpwq3LiO?si=abc123",
            "  https://open.spotify.com/playlist/37i9dQZF1DX4sWSpwq3LiO?si=x&pt=y  ",
        ];
        foreach (var input in inputs)
        {
            Assert.Equal(expected, SpotifyUri.Normalize(input));
        }
    }

    /// <summary>Spotify's localized share links carry a path segment before the kind.</summary>
    [Fact]
    public void LocalizedShareLinkNormalizes()
    {
        Assert.Equal(
            "spotify:playlist:37i9dQZF1DX4sWSpwq3LiO",
            SpotifyUri.Normalize(
                "https://open.spotify.com/intl-de/playlist/37i9dQZF1DX4sWSpwq3LiO"
            )
        );
    }

    /// <summary>
    /// Albums and tracks are worth accepting: "play this one calming album" is
    /// a reasonable thing to want from a relaxation reminder.
    /// </summary>
    [Fact]
    public void AlbumsAndTracksAreAccepted()
    {
        Assert.Equal(
            "spotify:album:1DFixLWuPkv3KT3TnV35m3",
            SpotifyUri.Normalize("https://open.spotify.com/album/1DFixLWuPkv3KT3TnV35m3")
        );
        Assert.Equal(
            "spotify:track:4cOdK2wGLETKBW3PvgPWqT",
            SpotifyUri.Normalize("spotify:track:4cOdK2wGLETKBW3PvgPWqT")
        );
    }

    [Fact]
    public void GarbageInputIsRejected()
    {
        string[] inputs = ["", "   ", "hello", "https://example.com/playlist/abc", "spotify:"];
        foreach (var input in inputs)
        {
            Assert.Null(SpotifyUri.Normalize(input));
        }
    }

    /// <summary>
    /// The validator is the last line of defence before a string reaches an
    /// interpreter, so anything carrying script syntax must fail it even if it
    /// also contains something URI-shaped.
    /// </summary>
    [Fact]
    public void ValidationRejectsAnythingCarryingScriptSyntax()
    {
        string[] hostile =
        [
            "spotify:playlist:abc\" & (do shell script \"echo pwned\") & \"",
            "spotify:playlist:abc\"\nend tell\ntell application \"Finder\"",
            "spotify:playlist:abc def",
            "spotify:playlist:",
            "not a uri",
        ];
        foreach (var input in hostile)
        {
            Assert.False(SpotifyUri.IsValid(input));
        }
    }

    /// <summary>
    /// A quoted payload must not survive normalization either — the ID charset
    /// stops at the quote, so what comes back is a clean URI.
    /// </summary>
    [Fact]
    public void NormalizationStripsTrailingScriptPayload()
    {
        var normalized = SpotifyUri.Normalize(
            """spotify:playlist:abc123" & (do shell script "echo pwned")"""
        );
        Assert.Equal("spotify:playlist:abc123", normalized);
        Assert.True(SpotifyUri.IsValid(normalized ?? ""));
    }

    [Fact]
    public void ValidUrisPassValidation()
    {
        Assert.True(SpotifyUri.IsValid("spotify:playlist:37i9dQZF1DX4sWSpwq3LiO"));
        Assert.True(SpotifyUri.IsValid("spotify:album:1DFixLWuPkv3KT3TnV35m3"));
        // Share-link IDs can carry - and _.
        Assert.True(SpotifyUri.IsValid("spotify:playlist:ab-cd_ef"));
    }

    // MARK: - Choosing what plays

    [Fact]
    public void ReminderWithNoMusicPlaysNothing()
    {
        var settings = new Settings { DefaultPlaylistUri = "spotify:playlist:abc" };
        var reminder = new Reminder { Title = "Water", Schedule = new Schedule.Interval(60) };
        Assert.Null(settings.PlaylistUriFor(reminder));
    }

    [Fact]
    public void DefaultChoiceFollowsTheSettingsPlaylist()
    {
        var settings = new Settings { DefaultPlaylistUri = "spotify:playlist:abc" };
        var reminder = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(60),
            Music = MusicChoice.DefaultPlaylist,
        };
        Assert.Equal("spotify:playlist:abc", settings.PlaylistUriFor(reminder));
    }

    /// <summary>
    /// Opting into the default before setting one must be silent rather than an
    /// error — the user simply has not finished setting up yet.
    /// </summary>
    [Fact]
    public void DefaultChoiceWithNoDefaultConfiguredPlaysNothing()
    {
        var settings = new Settings { DefaultPlaylistUri = null };
        var reminder = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(60),
            Music = MusicChoice.DefaultPlaylist,
        };
        Assert.Null(settings.PlaylistUriFor(reminder));
    }

    /// <summary>
    /// The per-reminder playlist is the point of the feature: different music
    /// for different reminders.
    /// </summary>
    [Fact]
    public void PerReminderPlaylistOverridesTheDefault()
    {
        var settings = new Settings { DefaultPlaylistUri = "spotify:playlist:global" };
        var reminder = new Reminder
        {
            Title = "Tilt",
            Schedule = new Schedule.Interval(60),
            Music = MusicChoice.Playlist("spotify:playlist:calm"),
        };
        Assert.Equal("spotify:playlist:calm", settings.PlaylistUriFor(reminder));
    }

    /// <summary>
    /// The master switch has to beat every per-reminder choice, or "silence
    /// everything for this meeting" would not work.
    /// </summary>
    [Fact]
    public void MasterSwitchSilencesEveryReminder()
    {
        var settings = new Settings
        {
            DefaultPlaylistUri = "spotify:playlist:global", MusicEnabled = false,
        };
        var usesDefault = new Reminder
        {
            Title = "A", Schedule = new Schedule.Interval(60),
            Music = MusicChoice.DefaultPlaylist,
        };
        var usesOwn = new Reminder
        {
            Title = "B",
            Schedule = new Schedule.Interval(60),
            Music = MusicChoice.Playlist("spotify:playlist:calm"),
        };
        Assert.Null(settings.PlaylistUriFor(usesDefault));
        Assert.Null(settings.PlaylistUriFor(usesOwn));
    }

    // MARK: - Backwards compatibility

    /// <summary>
    /// A data file written before the music feature existed must not fail to
    /// decode. The engine reacts to a decode failure by falling back to the
    /// starter set, which would silently wipe every reminder the user has.
    /// </summary>
    [Fact]
    public void DataWrittenBeforeMusicExistedStillDecodes()
    {
        const string legacy = """
        {
          "schemaVersion": 1,
          "reminders": [{
            "id": "9E1B4A2C-1F3D-4B5E-8A7C-0D2E3F4A5B6C",
            "title": "Tilt Back",
            "message": "Tilt your chair back.",
            "schedule": { "interval": { "minutes": 60 } },
            "priority": "critical",
            "isEnabled": true,
            "symbolName": "figure.seated.side",
            "createdAt": 1700000000
          }],
          "settings": {
            "quietHours": {
              "isEnabled": false, "startHour": 22, "startMinute": 0,
              "endHour": 7, "endMinute": 0, "allowsCritical": true
            },
            "isPaused": false,
            "snoozeMinutes": 5,
            "subtleDisplaySeconds": 8,
            "launchAtLogin": false,
            "showsNextReminderInMenuBar": true,
            "soundEnabled": true
          },
          "events": []
        }
        """;

        var data = AppDataJson.Decode(System.Text.Encoding.UTF8.GetBytes(legacy));

        Assert.Single(data.Reminders);
        Assert.Equal("Tilt Back", data.Reminders[0].Title);
        // Absent music must read as "no music", not as a decode failure.
        Assert.Equal(MusicChoice.None, data.Reminders[0].Music);
        Assert.Null(data.Settings.DefaultPlaylistUri);
        // The master switch defaults on, so adding a playlist later is enough
        // to make music work without hunting for a second toggle.
        Assert.True(data.Settings.MusicEnabled);
    }

    /// <summary>A reminder carrying music must survive a full save/load cycle.</summary>
    [Fact]
    public void MusicChoiceRoundTripsThroughTheStore()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        Directory.CreateDirectory(directory);
        try
        {
            var store = new FileDataStore(Path.Combine(directory, "data.json"));
            var original = new AppData
            {
                Reminders =
                [
                    new Reminder
                    {
                        Title = "Tilt",
                        Schedule = new Schedule.Interval(60),
                        Music = MusicChoice.Playlist("spotify:playlist:calm"),
                    },
                    new Reminder
                    {
                        Title = "Water",
                        Schedule = new Schedule.Interval(60),
                        Music = MusicChoice.DefaultPlaylist,
                    },
                ],
                Settings = new Settings
                {
                    DefaultPlaylistUri = "spotify:playlist:global",
                    MusicEnabled = true,
                    MusicVolume = 42,
                },
            };

            store.Save(original);
            var loaded = store.Load();

            Assert.Equal(MusicChoice.Playlist("spotify:playlist:calm"), loaded.Reminders[0].Music);
            Assert.Equal(MusicChoice.DefaultPlaylist, loaded.Reminders[1].Music);
            Assert.Equal("spotify:playlist:global", loaded.Settings.DefaultPlaylistUri);
            Assert.Equal(42, loaded.Settings.MusicVolume);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
