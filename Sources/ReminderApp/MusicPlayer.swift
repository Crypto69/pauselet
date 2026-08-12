import Foundation
import SwiftUI
import ReminderCore

/// Starts and stops reminder music, keeping the blocking AppleScript work off
/// the main thread.
///
/// `SpotifyController` blocks for as long as Spotify takes to launch — up to
/// about ten seconds. Calling it directly from the fire path would freeze the
/// reminder overlay as it appears, which is exactly when the UI must be
/// responsive. Everything here hops to a background queue and comes back to the
/// main actor only to publish state.
@MainActor
final class MusicPlayer: ObservableObject {

    /// Where reminder-started playback currently stands. Drives the decision
    /// to pause on acknowledgement: only music a reminder actually started (or
    /// is still starting) may be paused, never the user's own listening.
    enum ReminderMusicState {
        case idle
        case starting
        case playing
    }

    /// The most recent failure, for the settings UI to explain. Cleared on the
    /// next success so a fixed permission stops nagging.
    @Published private(set) var lastError: SpotifyError?

    /// True while a play request is in flight, so the UI can show progress
    /// during the launch wait rather than looking like nothing happened.
    @Published private(set) var isStarting = false

    @Published private(set) var reminderMusicState: ReminderMusicState = .idle

    var isSpotifyInstalled: Bool { SpotifyController.isInstalled }

    /// Serialised so two reminders firing in the same tick cannot race two
    /// Spotify launches against each other.
    private let queue = DispatchQueue(label: "com.reminder.music", qos: .userInitiated)

    /// Starts the music `reminder` asks for, if any.
    ///
    /// Silently does nothing when the reminder has no music configured — that
    /// is the overwhelmingly common case and must cost nothing.
    func play(for reminder: Reminder, settings: ReminderCore.Settings) {
        guard let uri = settings.playlistURI(for: reminder) else { return }
        start(uri: uri, volume: settings.musicVolume, forReminder: true)
    }

    /// Starts `uri` directly. Used by the settings "Test" buttons; playback
    /// started this way is the user's own and is never auto-paused.
    func play(uri: String, volume: Int?) {
        start(uri: uri, volume: volume, forReminder: false)
    }

    private func start(uri: String, volume: Int?, forReminder: Bool) {
        isStarting = true
        if forReminder { reminderMusicState = .starting }
        queue.async { [weak self] in
            var failure: SpotifyError?
            do {
                try SpotifyController.play(playlistURI: uri, volume: volume)
            } catch let error as SpotifyError {
                failure = error
            } catch {
                failure = .scriptError("\(error)")
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isStarting = false
                self.lastError = failure
                if forReminder, self.reminderMusicState == .starting {
                    // A play that failed must leave the pause-on-acknowledge
                    // path unarmed, or acknowledging the reminder would pause
                    // whatever the user was already listening to. If an
                    // acknowledgement already asked to stop (state cleared
                    // while we were launching), stay idle.
                    self.reminderMusicState = failure == nil ? .playing : .idle
                }
            }
        }
    }

    /// Stops playback. Failures are ignored: a pause that does not land is not
    /// worth interrupting the user over, and the common cause is simply that
    /// Spotify is no longer running.
    func pause() {
        reminderMusicState = .idle
        queue.async {
            try? SpotifyController.pause()
        }
    }

    /// Stops reminder-started music, if there is any — including a launch that
    /// is still in flight, which the serial queue guarantees the pause lands
    /// after. Music the user started themselves is left alone.
    func stopReminderMusic() {
        guard reminderMusicState != .idle else { return }
        pause()
    }

    /// Triggers the macOS Automation consent prompt at a controlled moment, and
    /// records the outcome so the settings UI can react.
    func requestAutomationPermission() {
        queue.async { [weak self] in
            let result = SpotifyController.requestAutomationPermission()
            Task { @MainActor [weak self] in
                switch result {
                case .success:
                    self?.lastError = nil
                case .failure(let error):
                    self?.lastError = error
                }
            }
        }
    }

    func clearError() {
        lastError = nil
    }
}
