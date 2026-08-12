import XCTest
@testable import ReminderCore

/// Covers the two things that decide whether music works: turning whatever the
/// user pasted into a URI, and deciding which playlist a reminder plays.
final class MusicTests: XCTestCase {

    // MARK: - Link normalization

    /// Every form a user can plausibly paste must land on the same URI. The
    /// share link is what the Spotify UI actually puts on the clipboard, so it
    /// is the important one.
    func testEveryPlaylistInputFormNormalizesToTheSameURI() {
        let expected = "spotify:playlist:37i9dQZF1DX4sWSpwq3LiO"
        let inputs = [
            "spotify:playlist:37i9dQZF1DX4sWSpwq3LiO",
            "https://open.spotify.com/playlist/37i9dQZF1DX4sWSpwq3LiO",
            "https://open.spotify.com/playlist/37i9dQZF1DX4sWSpwq3LiO?si=abc123",
            "  https://open.spotify.com/playlist/37i9dQZF1DX4sWSpwq3LiO?si=x&pt=y  ",
        ]
        for input in inputs {
            XCTAssertEqual(
                SpotifyURI.normalize(input), expected,
                "failed to normalize: \(input)"
            )
        }
    }

    /// Spotify's localized share links carry a path segment before the kind.
    func testLocalizedShareLinkNormalizes() {
        XCTAssertEqual(
            SpotifyURI.normalize("https://open.spotify.com/intl-de/playlist/37i9dQZF1DX4sWSpwq3LiO"),
            "spotify:playlist:37i9dQZF1DX4sWSpwq3LiO"
        )
    }

    /// Albums and tracks are worth accepting: "play this one calming album" is
    /// a reasonable thing to want from a relaxation reminder.
    func testAlbumsAndTracksAreAccepted() {
        XCTAssertEqual(
            SpotifyURI.normalize("https://open.spotify.com/album/1DFixLWuPkv3KT3TnV35m3"),
            "spotify:album:1DFixLWuPkv3KT3TnV35m3"
        )
        XCTAssertEqual(
            SpotifyURI.normalize("spotify:track:4cOdK2wGLETKBW3PvgPWqT"),
            "spotify:track:4cOdK2wGLETKBW3PvgPWqT"
        )
    }

    func testGarbageInputIsRejected() {
        for input in ["", "   ", "hello", "https://example.com/playlist/abc", "spotify:"] {
            XCTAssertNil(SpotifyURI.normalize(input), "should reject: \(input)")
        }
    }

    /// The validator is the last line of defence before a string is interpolated
    /// into AppleScript source, so anything carrying script syntax must fail it
    /// even if it also contains something URI-shaped.
    func testValidationRejectsAnythingCarryingScriptSyntax() {
        let hostile = [
            #"spotify:playlist:abc" & (do shell script "echo pwned") & ""#,
            "spotify:playlist:abc\"\nend tell\ntell application \"Finder\"",
            "spotify:playlist:abc def",
            "spotify:playlist:",
            "not a uri",
        ]
        for input in hostile {
            XCTAssertFalse(SpotifyURI.isValid(input), "should be invalid: \(input)")
        }
    }

    /// A quoted payload must not survive normalization either — the ID charset
    /// stops at the quote, so what comes back is a clean URI.
    func testNormalizationStripsTrailingScriptPayload() {
        let normalized = SpotifyURI.normalize(
            #"spotify:playlist:abc123" & (do shell script "echo pwned")"#
        )
        XCTAssertEqual(normalized, "spotify:playlist:abc123")
        XCTAssertTrue(SpotifyURI.isValid(normalized ?? ""))
    }

    func testValidURIsPassValidation() {
        XCTAssertTrue(SpotifyURI.isValid("spotify:playlist:37i9dQZF1DX4sWSpwq3LiO"))
        XCTAssertTrue(SpotifyURI.isValid("spotify:album:1DFixLWuPkv3KT3TnV35m3"))
        // Share-link IDs can carry - and _.
        XCTAssertTrue(SpotifyURI.isValid("spotify:playlist:ab-cd_ef"))
    }

    // MARK: - Choosing what plays

    func testReminderWithNoMusicPlaysNothing() {
        let settings = Settings(defaultPlaylistURI: "spotify:playlist:abc")
        let reminder = Reminder(title: "Water", schedule: .interval(minutes: 60))
        XCTAssertNil(settings.playlistURI(for: reminder))
    }

    func testDefaultChoiceFollowsTheSettingsPlaylist() {
        let settings = Settings(defaultPlaylistURI: "spotify:playlist:abc")
        let reminder = Reminder(
            title: "Tilt", schedule: .interval(minutes: 60), music: .defaultPlaylist
        )
        XCTAssertEqual(settings.playlistURI(for: reminder), "spotify:playlist:abc")
    }

    /// Opting into the default before setting one must be silent rather than an
    /// error — the user simply has not finished setting up yet.
    func testDefaultChoiceWithNoDefaultConfiguredPlaysNothing() {
        let settings = Settings(defaultPlaylistURI: nil)
        let reminder = Reminder(
            title: "Tilt", schedule: .interval(minutes: 60), music: .defaultPlaylist
        )
        XCTAssertNil(settings.playlistURI(for: reminder))
    }

    /// The per-reminder playlist is the point of the feature: different music
    /// for different reminders.
    func testPerReminderPlaylistOverridesTheDefault() {
        let settings = Settings(defaultPlaylistURI: "spotify:playlist:global")
        let reminder = Reminder(
            title: "Tilt",
            schedule: .interval(minutes: 60),
            music: .playlist(uri: "spotify:playlist:calm")
        )
        XCTAssertEqual(settings.playlistURI(for: reminder), "spotify:playlist:calm")
    }

    /// The master switch has to beat every per-reminder choice, or "silence
    /// everything for this meeting" would not work.
    func testMasterSwitchSilencesEveryReminder() {
        let settings = Settings(
            defaultPlaylistURI: "spotify:playlist:global", musicEnabled: false
        )
        let usesDefault = Reminder(
            title: "A", schedule: .interval(minutes: 60), music: .defaultPlaylist
        )
        let usesOwn = Reminder(
            title: "B",
            schedule: .interval(minutes: 60),
            music: .playlist(uri: "spotify:playlist:calm")
        )
        XCTAssertNil(settings.playlistURI(for: usesDefault))
        XCTAssertNil(settings.playlistURI(for: usesOwn))
    }

    // MARK: - Backwards compatibility

    /// Adding these fields must not make an existing install fail to decode.
    /// `ReminderEngine` reacts to a decode failure by falling back to the
    /// starter set, which would silently wipe every reminder the user has.
    func testDataWrittenBeforeMusicExistedStillDecodes() throws {
        let legacy = """
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
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Date(timeIntervalSince1970: try container.decode(Double.self))
        }

        let data = try decoder.decode(AppData.self, from: Data(legacy.utf8))

        XCTAssertEqual(data.reminders.count, 1)
        XCTAssertEqual(data.reminders[0].title, "Tilt Back")
        // Absent music must read as "no music", not as a decode failure.
        XCTAssertEqual(data.reminders[0].music, .none)
        XCTAssertNil(data.settings.defaultPlaylistURI)
        // The master switch defaults on, so adding a playlist later is enough
        // to make music work without hunting for a second toggle.
        XCTAssertTrue(data.settings.musicEnabled)
    }

    /// A reminder carrying music must survive a full save/load cycle.
    func testMusicChoiceRoundTripsThroughTheStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileDataStore(fileURL: directory.appendingPathComponent("data.json"))
        let original = AppData(
            reminders: [
                Reminder(
                    title: "Tilt",
                    schedule: .interval(minutes: 60),
                    music: .playlist(uri: "spotify:playlist:calm")
                ),
                Reminder(
                    title: "Water",
                    schedule: .interval(minutes: 60),
                    music: .defaultPlaylist
                ),
            ],
            settings: Settings(
                defaultPlaylistURI: "spotify:playlist:global",
                musicEnabled: true,
                musicVolume: 42
            )
        )

        try store.save(original)
        let loaded = try store.load()

        XCTAssertEqual(loaded.reminders[0].music, .playlist(uri: "spotify:playlist:calm"))
        XCTAssertEqual(loaded.reminders[1].music, .defaultPlaylist)
        XCTAssertEqual(loaded.settings.defaultPlaylistURI, "spotify:playlist:global")
        XCTAssertEqual(loaded.settings.musicVolume, 42)
    }
}
