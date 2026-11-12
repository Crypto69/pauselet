import XCTest
@testable import ReminderCore

/// The "None" row of the sound picker: a reminder that makes no sound at
/// all when it fires, whatever the tier and the master switch say.
final class SoundTests: XCTestCase {
    private func critical(isSilent: Bool? = nil, soundName: String? = nil) -> Reminder {
        Reminder(
            title: "Tilt back",
            schedule: .interval(minutes: 60),
            priority: .critical,
            activityDurationSeconds: 300,
            soundName: soundName,
            isSilent: isSilent,
            warningMinutes: 5,
            createdAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
    }

    func testAReminderSoundsByDefault() {
        XCTAssertTrue(Settings().playsSound(for: critical()))
    }

    func testSilentReminderPlaysNothingEvenWithSoundsOn() {
        XCTAssertFalse(Settings(soundEnabled: true).playsSound(for: critical(isSilent: true)))
    }

    func testSoundsOffIsStillOff() {
        XCTAssertFalse(Settings(soundEnabled: false).playsSound(for: critical()))
        XCTAssertFalse(Settings(soundEnabled: false).playsSound(for: critical(isSilent: true)))
    }

    /// The tier rule is unchanged: Subtle and Normal never sound, and a
    /// silent reminder of a sounding tier is the only new way to be quiet.
    func testTierRuleIsUntouched() {
        var r = critical()
        r.priority = .normal
        XCTAssertFalse(Settings().playsSound(for: r))
        r.priority = .important
        XCTAssertTrue(Settings().playsSound(for: r))
        r.isSilent = true
        XCTAssertFalse(Settings().playsSound(for: r))
    }

    /// The warning has its own rule and its own quiet switch; silencing the
    /// takeover must not silence the heads-up before it, nor the reverse.
    func testSilentDoesNotSilenceTheWarning() {
        let r = critical(isSilent: true)
        XCTAssertTrue(Scheduler.warningPlaysSound(for: r, settings: Settings()))
        var quietWarning = critical()
        quietWarning.warningIsSilent = true
        XCTAssertTrue(Settings().playsSound(for: quietWarning))
    }

    func testSilentPersistsAndTheDefaultIsNotWritten() throws {
        let sounding = try JSONEncoder().encode(critical())
        XCTAssertFalse(String(decoding: sounding, as: UTF8.self).contains("isSilent"),
                       "the default encodes exactly as before the option existed")
        XCTAssertNil(try JSONDecoder().decode(Reminder.self, from: sounding).isSilent)

        let silent = try JSONEncoder().encode(critical(isSilent: true))
        XCTAssertEqual(try JSONDecoder().decode(Reminder.self, from: silent).isSilent, true)
    }

    /// A silent reminder keeps no sound name: the picker's None row replaces
    /// the chosen sound rather than sitting beside it.
    func testSilentReminderCarriesNoSoundName() throws {
        let r = critical(isSilent: true)
        XCTAssertNil(r.soundName)
        let data = try JSONEncoder().encode(r)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("soundName"))
    }
}
