import Foundation
import AppKit
import ReminderCore

enum SpotifyError: Error, Equatable {
    case notInstalled
    /// The user denied the Automation permission (AppleEvent error -1743), or
    /// has not been asked yet and declined the prompt.
    case automationDenied
    /// The URI did not pass validation, so it was never executed.
    case invalidURI
    case scriptError(String)

    var userMessage: String {
        switch self {
        case .notInstalled:
            return "Spotify is not installed."
        case .automationDenied:
            return "Reminder needs permission to control Spotify. Grant it in "
                + "System Settings › Privacy & Security › Automation."
        case .invalidURI:
            return "That is not a Spotify playlist link."
        case .scriptError(let message):
            return "Spotify could not start playback: \(message)"
        }
    }
}

/// Drives Spotify over its AppleScript dictionary.
///
/// The scripts run through `osascript` in a subprocess rather than
/// `NSAppleScript` in-process: NSAppleScript (and the OSA machinery under it)
/// is documented as main-thread-only, and these calls must run on a background
/// queue because the launch wait can block for ten seconds — exactly when a
/// reminder overlay is appearing and the main thread must stay responsive. A
/// subprocess gives that thread isolation for the cost of one process launch,
/// and the macOS Automation prompt still attributes to this app, since TCC
/// resolves the responsible process.
///
/// Every entry point blocks — launching Spotify and waiting for it to become
/// ready can take several seconds — so callers must be on a background queue.
/// `MusicPlayer` is the thing that guarantees that; prefer it over calling here.
enum SpotifyController {

    static let bundleID = "com.spotify.client"

    /// AppleEvent error for "the user has not authorized this app to send
    /// events to that application".
    private static let errAEEventNotPermitted = -1743

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Starts `playlistURI`, launching Spotify first if it is not running.
    ///
    /// - Parameter volume: when set, playback starts silent and ramps up to
    ///   this level (0–100) so the music fades in rather than arriving at
    ///   whatever volume Spotify was last left at.
    static func play(playlistURI: String, volume: Int?) throws {
        guard isInstalled else { throw SpotifyError.notInstalled }
        // Validated immediately before use, which is what makes interpolating
        // it into the script source safe. Anything that is not exactly a
        // canonical URI never reaches AppleScript.
        guard SpotifyURI.isValid(playlistURI) else { throw SpotifyError.invalidURI }

        try run(source: playbackScript(uri: playlistURI, volume: volume))
    }

    /// Pauses playback, ignoring the case where Spotify is not running — there
    /// is nothing to pause then, and launching it just to pause would be absurd.
    static func pause() throws {
        guard isInstalled else { throw SpotifyError.notInstalled }
        try run(source: """
        tell application "Spotify"
            if it is running then pause
        end tell
        """)
    }

    /// Sends a real query to Spotify so the macOS Automation consent prompt
    /// appears at a moment the user chose — while configuring the playlist —
    /// rather than an hour later in the middle of a reminder.
    ///
    /// Spotify is launched first if needed: the prompt only appears when an
    /// Apple event actually reaches Spotify, and a query guarded behind
    /// `if it is running` sends nothing when it is closed — which reported
    /// success without ever asking, deferring the consent dialog to the first
    /// fired reminder, the exact outcome this function exists to prevent.
    ///
    /// Returns the outcome so the settings UI can confirm it worked or explain
    /// what to do if the user declined.
    static func requestAutomationPermission() -> Result<Void, SpotifyError> {
        guard isInstalled else { return .failure(.notInstalled) }
        do {
            try run(source: """
            tell application "Spotify"
            \(launchAndWait)
                set _ to player state
            end tell
            """)
            return .success(())
        } catch let error as SpotifyError {
            return .failure(error)
        } catch {
            return .failure(.scriptError("\(error)"))
        }
    }

    // MARK: - Script construction

    /// If Spotify is not running, `play` immediately after `launch` silently
    /// does nothing — the player is not initialized yet. Polling `player
    /// state` inside a `try` is the reliable readiness check; the state
    /// access throws until the player is up.
    private static let launchAndWait = """
        if it is not running then
            launch
            repeat 20 times
                delay 0.5
                try
                    set _ to player state
                    exit repeat
                end try
            end repeat
        end if
    """

    /// The playback script.
    ///
    /// `play track X in context Y` is what actually plays a *playlist*: bare
    /// `play track "spotify:playlist:..."` is for a single track and does not
    /// reliably start a playlist. Passing the playlist as both the track and
    /// the context makes Spotify start the playlist from its beginning and keep
    /// playing through it. A track URI is the opposite case: it is not a valid
    /// playback context, so it plays bare.
    private static func playbackScript(uri: String, volume: Int?) -> String {
        // Clamped so a bad stored value cannot produce an out-of-range volume,
        // and interpolated as an Int so it carries no script syntax.
        let target = volume.map { min(100, max(0, $0)) }

        let playLine = uri.hasPrefix("spotify:track:")
            ? "play track \"\(uri)\""
            : "play track \"\(uri)\" in context \"\(uri)\""

        guard let target else {
            return """
            tell application "Spotify"
            \(launchAndWait)
                \(playLine)
            end tell
            """
        }

        // Silence first, then start, then ramp. The ramp runs inside the one
        // script so it is a single osascript invocation rather than a dozen,
        // and the step count is fixed so the fade always takes about the same
        // time regardless of the target volume. If the play line fails (a
        // deleted or region-blocked playlist), the volume is restored before
        // rethrowing so Spotify is not left muted for the user's own listening.
        return """
        tell application "Spotify"
        \(launchAndWait)
            set sound volume to 0
            try
                \(playLine)
            on error errorMessage number errorNumber
                set sound volume to \(target)
                error errorMessage number errorNumber
            end try
            repeat with i from 1 to 10
                set sound volume to (i * \(target)) / 10
                delay 0.25
            end repeat
        end tell
        """
    }

    /// Runs `source` through `osascript`, translating failures into
    /// `SpotifyError`. Blocks until the script finishes.
    private static func run(source: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw SpotifyError.scriptError(
                "Could not run osascript: \(error.localizedDescription)"
            )
        }
        // The scripts emit at most one line of error text, far below the pipe
        // buffer, so reading after exit cannot deadlock.
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }

        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if message.contains("(\(errAEEventNotPermitted))") {
            throw SpotifyError.automationDenied
        }
        throw SpotifyError.scriptError(
            message.isEmpty
                ? "osascript exited with status \(process.terminationStatus)"
                : message
        )
    }
}
