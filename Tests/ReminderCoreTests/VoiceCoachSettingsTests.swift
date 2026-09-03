import XCTest
@testable import ReminderCore

/// The voice coach preferences: absent from older files, and the voice
/// identifier only on disk when one was chosen.
final class VoiceCoachSettingsTests: XCTestCase {

    func testSettingsWithoutVoiceCoachKeysDecodeToDefaults() throws {
        let legacy = """
        {
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
        }
        """

        let settings = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))

        XCTAssertFalse(settings.voiceCoachEnabled)
        XCTAssertNil(settings.voiceCoachVoiceIdentifier)
        XCTAssertEqual(settings.voiceCoachRate, 45)
    }

    func testVoiceIdentifierRoundTripsAndIsOmittedWhenNil() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let silent = try String(decoding: encoder.encode(Settings()), as: UTF8.self)
        XCTAssertTrue(silent.contains("\"voiceCoachEnabled\":false"))
        XCTAssertTrue(silent.contains("\"voiceCoachRate\":45"))
        XCTAssertFalse(silent.contains("voiceCoachVoiceIdentifier"))

        var chosen = Settings()
        chosen.voiceCoachEnabled = true
        chosen.voiceCoachVoiceIdentifier = "com.apple.voice.premium.en-AU.Zoe"
        let data = try encoder.encode(chosen)
        XCTAssertTrue(String(decoding: data, as: UTF8.self)
            .contains("\"voiceCoachVoiceIdentifier\":\"com.apple.voice.premium.en-AU.Zoe\""))
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), chosen)
    }
}
