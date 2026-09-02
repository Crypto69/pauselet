import Foundation
import AVFoundation
import ReminderCore

/// The bundled sound set. iOS has no equivalent of the macOS system-sound
/// allowlist, so the app ships its own small set of synthesized chimes used by
/// notifications, AlarmKit alerts, and in-app playback alike (§3.4).
@MainActor
enum Sounds {

    /// Names offered in the reminder editor. Each is a `<name>.caf` in the
    /// app bundle. "Submarine" and "Glass" keep their macOS roles: the
    /// critical-fire default and the countdown-complete chime.
    nonisolated static let available = ["Chime", "Glass", "Pulse", "Submarine"]

    /// `available` as a set, for lookups from pure planning code.
    nonisolated static let availableNames = Set(available)

    /// What a critical fire plays when the reminder names no bundled sound:
    /// the same on the in-app takeover and the lock-screen alarm.
    nonisolated static let criticalDefault = "Submarine"

    /// The chime when an activity countdown finishes.
    nonisolated static let countdownComplete = "Glass"

    /// How in-app playback relates to the rest of the device's audio.
    enum Route {
        /// Mixes with whatever is playing and respects the Ring/Silent switch:
        /// a chime that may politely go unheard.
        case mixing
        /// Mixes with other audio but ignores the Ring/Silent switch. For the
        /// critical tier, whose whole promise is that it reaches the user —
        /// the lock-screen alarm it replaces would have sounded regardless.
        case piercing
    }

    private static var player: AVAudioPlayer?

    /// Plays a bundled sound in-app (critical takeover fire, countdown
    /// completion, editor preview). Unknown names are ignored.
    static func play(named name: String, route: Route = .mixing) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "caf") else {
            return
        }
        let session = AVAudioSession.sharedInstance()
        switch route {
        case .mixing:
            try? session.setCategory(.ambient, options: [.mixWithOthers])
        case .piercing:
            try? session.setCategory(.playback, options: [.mixWithOthers])
        }
        try? session.setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    /// Resolves a stored sound name to a bundled one, or `nil` when the
    /// reminder has no usable custom sound. Data files written by the macOS
    /// app may carry names from its system-sound list; the two sets share
    /// "Submarine" and "Glass", and anything unknown falls back to the tier's
    /// default: the system sound for notifications (`nil` here), and
    /// `criticalDefault` for alarms and the takeover (`criticalSound(for:)`).
    nonisolated static func bundledName(for raw: String?) -> String? {
        guard let raw else { return nil }
        return availableNames.contains(raw) ? raw : nil
    }

    /// The sound a critical fire of `reminder` plays, on every critical
    /// surface. Never `nil`: critical always makes a sound.
    nonisolated static func criticalSound(for reminder: Reminder) -> String {
        bundledName(for: reminder.soundName) ?? criticalDefault
    }
}
