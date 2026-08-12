import SwiftUI
import AppKit
import ReminderCore

/// The Preferences section for Spotify playback: the default playlist, the
/// volume reminders fade up to, and the Automation permission.
///
/// The permission is dealt with here deliberately. macOS asks for it the first
/// time the app sends Spotify an Apple event, and if that first time is a
/// reminder firing, the user gets a consent dialog instead of their music. Doing
/// it while they are setting the playlist up puts the prompt somewhere it makes
/// sense.
struct MusicSettingsSection: View {
    @EnvironmentObject private var engine: ReminderEngine
    @EnvironmentObject private var music: MusicPlayer

    /// The text field is local until it validates, so a half-typed link does
    /// not repeatedly overwrite the stored playlist as it is being pasted.
    @State private var linkText: String = ""
    @State private var showsInvalidLink = false

    var body: some View {
        Section("Music") {
            if !music.isSpotifyInstalled {
                notInstalledNotice
            } else {
                HelpRow(
                    title: "Play music with reminders",
                    help: "Lets reminders start a Spotify playlist when they "
                        + "fire. Each reminder chooses whether to use this, in "
                        + "its own settings. Turning this off silences music "
                        + "everywhere without losing your playlist."
                ) {
                    Toggle("", isOn: binding(\.musicEnabled)).labelsHidden()
                }

                if engine.settings.musicEnabled {
                    playlistField
                    volumeRow
                    statusRow
                }
            }
        }
    }

    // MARK: - Rows

    private var notInstalledNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Spotify is not installed")
                .font(.system(size: 12, weight: .medium))
            Text(
                "Install Spotify to have reminders start a playlist. "
                + "Everything else works without it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var playlistField: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Label and field on one line: on its own row the label reads as a
            // heading detached from the control it belongs to.
            HStack(spacing: 4) {
                Text("Default playlist")
                HelpBadge(
                    text: "Paste a playlist link from Spotify — right-click a "
                        + "playlist, then Share › Copy link to playlist. "
                        + "Reminders set to \"Default playlist\" all play this "
                        + "one, so changing it here changes them all."
                )

                Spacer(minLength: 10)

                // The row's own label is enough; a Form otherwise floats the
                // field's title above it as a second, redundant label.
                TextField("Paste a Spotify link", text: $linkText)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .onSubmit(commitLink)
                    .accessibilityLabel("Default playlist link")

                Button("Save", action: commitLink)
                    .disabled(linkText.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    // Play the saved playlist so the user can confirm the whole
                    // path works — link, permission and all — before trusting
                    // it to fire an hour from now.
                    if let uri = engine.settings.defaultPlaylistURI {
                        music.play(uri: uri, volume: engine.settings.musicVolume)
                    }
                } label: {
                    if music.isStarting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test")
                    }
                }
                // Test plays the *saved* playlist, so it stays disabled while
                // the field holds something else — otherwise a freshly pasted
                // link would appear to pass a test it never took.
                .disabled(!fieldMatchesSavedPlaylist || music.isStarting)
                .help("Play the saved playlist now")
            }

            if showsInvalidLink {
                Label(
                    "That does not look like a Spotify playlist link.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if let uri = engine.settings.defaultPlaylistURI {
                HStack(spacing: 6) {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(SpotifyURI.describe(uri))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Remove") {
                        setDefaultPlaylist(nil)
                        linkText = ""
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .onAppear {
            // Show what is stored, so returning to Preferences does not look
            // like the playlist was lost — and drop any stale warning, or the
            // valid stored link would render with an invalid-link error under
            // it (and without its Saved row) after a tab switch.
            linkText = engine.settings.defaultPlaylistURI ?? ""
            showsInvalidLink = false
        }
        .onChange(of: linkText) { _ in
            // Editing the field withdraws the warning; it returns on Save if
            // the new text is still not a valid link.
            showsInvalidLink = false
        }
    }

    /// Whether the field currently shows exactly the stored playlist.
    private var fieldMatchesSavedPlaylist: Bool {
        guard let saved = engine.settings.defaultPlaylistURI else { return false }
        return linkText.trimmingCharacters(in: .whitespacesAndNewlines) == saved
    }

    private var volumeRow: some View {
        HStack(spacing: 4) {
            Text("Fade up to \(engine.settings.musicVolume)%")
            HelpBadge(
                text: "Reminder starts the music silent and fades it up to this "
                    + "level over a couple of seconds, so a relaxation prompt "
                    + "does not arrive at whatever volume Spotify was last left "
                    + "at. This changes Spotify's own volume."
            )
            Spacer(minLength: 8)
            Slider(
                value: Binding(
                    get: { Double(engine.settings.musicVolume) },
                    set: { newValue in
                        var settings = engine.settings
                        settings.musicVolume = Int(newValue.rounded())
                        engine.updateSettings(settings)
                    }
                ),
                in: 0...100
            )
            .frame(width: 180)
            .accessibilityLabel("Music volume")
        }
    }

    /// Reports the last Spotify failure, with the one action that fixes it.
    ///
    /// The permission case gets a button straight to the right System Settings
    /// pane — "grant it in Privacy & Security › Automation" is a lot of clicks
    /// to follow from memory.
    @ViewBuilder
    private var statusRow: some View {
        if let error = music.lastError {
            VStack(alignment: .leading, spacing: 6) {
                Label(error.userMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                if error == .automationDenied {
                    HStack(spacing: 8) {
                        Button("Open Automation Settings") {
                            openAutomationSettings()
                        }
                        .font(.caption)
                        Button("Try Again") {
                            music.clearError()
                            music.requestAutomationPermission()
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func commitLink() {
        let input = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            setDefaultPlaylist(nil)
            showsInvalidLink = false
            return
        }
        guard let uri = SpotifyURI.normalize(input) else {
            showsInvalidLink = true
            return
        }
        showsInvalidLink = false
        setDefaultPlaylist(uri)
        linkText = uri

        // Now that there is a playlist worth playing, get the consent prompt
        // out of the way while the user is here to answer it.
        music.requestAutomationPermission()
    }

    private func setDefaultPlaylist(_ uri: String?) {
        var settings = engine.settings
        settings.defaultPlaylistURI = uri
        engine.updateSettings(settings)
    }

    private func openAutomationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<ReminderCore.Settings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { engine.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = engine.settings
                settings[keyPath: keyPath] = newValue
                engine.updateSettings(settings)
            }
        )
    }
}

/// The per-reminder music controls, shown in the reminder editor.
///
/// Three states rather than a switch, because the useful default is "the
/// playlist I already configured" while some reminders genuinely want their
/// own — calm piano for pressure relief, something with a pulse for a movement
/// prompt.
struct ReminderMusicSection: View {
    @Binding var music: MusicChoice
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var engine: ReminderEngine

    /// Local text for the custom-playlist field, committed on submit or blur.
    @State private var linkText: String = ""
    @State private var showsInvalidLink = false
    /// The custom URI most recently seen, so clicking through the other radio
    /// options to read them does not destroy a playlist the user never meant
    /// to touch — switching back to "Its own playlist" restores it.
    @State private var lastCustomURI: String = ""

    private enum Mode: String, CaseIterable, Identifiable {
        case off, useDefault, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "No music"
            case .useDefault: return "Default playlist"
            case .custom: return "Its own playlist"
            }
        }
    }

    private var mode: Mode {
        switch music {
        case .none: return .off
        case .defaultPlaylist: return .useDefault
        case .playlist: return .custom
        }
    }

    var body: some View {
        Section("Music") {
            if !player.isSpotifyInstalled {
                Text("Install Spotify to play music with this reminder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("When this fires", selection: Binding(
                    get: { mode },
                    set: { apply($0) }
                )) {
                    ForEach(Mode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)

                switch mode {
                case .off:
                    EmptyView()
                case .useDefault:
                    defaultPlaylistNote
                case .custom:
                    customPlaylistField
                }

                if !engine.settings.musicEnabled, mode != .off {
                    Label(
                        "Music is switched off for every reminder in "
                            + "Preferences › Music.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            if case .playlist(let uri) = music, !uri.isEmpty {
                lastCustomURI = uri
            }
        }
    }

    @ViewBuilder
    private var defaultPlaylistNote: some View {
        if let uri = engine.settings.defaultPlaylistURI {
            Text("Plays \(SpotifyURI.describe(uri)).")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label(
                "No default playlist is set yet. Add one in Preferences › Music.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var customPlaylistField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Paste a Spotify playlist link", text: $linkText)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(commitLink)
                    .accessibilityLabel("Playlist link for this reminder")

                Button("Save", action: commitLink)
                    .disabled(linkText.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    if case .playlist(let uri) = music {
                        player.play(uri: uri, volume: engine.settings.musicVolume)
                    }
                } label: {
                    if player.isStarting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test")
                    }
                }
                // Test plays the committed link, so it stays disabled while
                // the field holds different, uncommitted text.
                .disabled(
                    !isCustomSaved || player.isStarting || !fieldMatchesCommittedURI
                )
                .help("Play this playlist now")
            }

            if showsInvalidLink {
                Label(
                    "That does not look like a Spotify playlist link.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if case .playlist(let uri) = music, !uri.isEmpty {
                // "Playlist set" rather than "Saved": the value lives in the
                // editor's draft and is only persisted when the reminder
                // itself is saved — the Preferences row's "Saved" genuinely
                // means stored, and this must not borrow that promise.
                HStack(spacing: 6) {
                    Label("Playlist set", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(SpotifyURI.describe(uri))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help("Stored when you save this reminder")
            }
        }
        .onAppear {
            if case .playlist(let uri) = music { linkText = uri }
            showsInvalidLink = false
        }
        .onChange(of: linkText) { _ in
            showsInvalidLink = false
        }
    }

    /// Whether the field currently shows exactly the committed custom URI.
    private var fieldMatchesCommittedURI: Bool {
        guard case .playlist(let uri) = music, !uri.isEmpty else { return false }
        return linkText.trimmingCharacters(in: .whitespacesAndNewlines) == uri
    }

    private var isCustomSaved: Bool {
        if case .playlist(let uri) = music { return !uri.isEmpty }
        return false
    }

    private func apply(_ mode: Mode) {
        // Leaving the custom mode keeps the URI in reserve, so a round trip
        // through the other options cannot silently delete it.
        if case .playlist(let uri) = music, !uri.isEmpty {
            lastCustomURI = uri
        }
        switch mode {
        case .off:
            music = .none
        case .useDefault:
            music = .defaultPlaylist
        case .custom:
            // Keep any URI already chosen; restore the remembered one when
            // returning; otherwise start empty and let the field collect one.
            if case .playlist = music { return }
            music = .playlist(uri: lastCustomURI)
            linkText = lastCustomURI
        }
        showsInvalidLink = false
    }

    private func commitLink() {
        let input = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            // Explicitly cleared: forget the remembered URI too, or it would
            // resurrect on the next mode round trip.
            music = .playlist(uri: "")
            lastCustomURI = ""
            showsInvalidLink = false
            return
        }
        guard let uri = SpotifyURI.normalize(input) else {
            showsInvalidLink = true
            return
        }
        showsInvalidLink = false
        music = .playlist(uri: uri)
        lastCustomURI = uri
        linkText = uri
        player.requestAutomationPermission()
    }
}
