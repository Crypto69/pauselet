import Foundation

/// What music, if any, a reminder starts when it fires.
///
/// Three states rather than a plain on/off switch: most reminders that want
/// music want *the* playlist the user configured once in Preferences, but a
/// reminder is free to bring its own. Modelling "use the default" explicitly
/// means changing the default in Preferences updates every reminder that opted
/// in, instead of leaving stale copies of a URI scattered across reminders.
public enum MusicChoice: Codable, Equatable, Sendable {
    /// Fire silently. The default for every reminder.
    case none
    /// Play whatever playlist is set in Preferences.
    case defaultPlaylist
    /// Play this specific playlist, ignoring the Preferences default.
    case playlist(uri: String)

    /// The playlist to actually play, resolved against the global settings.
    /// `nil` means "play nothing" — either the reminder opted out, or it asked
    /// for the default and no default is configured.
    public func resolvedURI(defaultPlaylistURI: String?) -> String? {
        switch self {
        case .none:
            return nil
        case .defaultPlaylist:
            guard let uri = defaultPlaylistURI, !uri.isEmpty else { return nil }
            return uri
        case .playlist(let uri):
            return uri.isEmpty ? nil : uri
        }
    }

    /// Whether music is switched on at all, for driving a toggle in the UI.
    public var isEnabled: Bool {
        if case .none = self { return false }
        return true
    }
}

/// Parsing and validation for Spotify playlist references.
///
/// Kept in the core rather than beside the AppleScript so it can be tested
/// without AppKit, and so exactly one definition of "a URI we will run"
/// exists — the validator here is what makes interpolating a user-supplied
/// string into a script source safe.
public enum SpotifyURI {

    /// Spotify IDs are base-62 with `-` and `_` also appearing in share links.
    /// Anything outside this set is rejected, which is what keeps a quote or a
    /// script fragment from ever reaching the AppleScript source.
    private static let idPattern = "[A-Za-z0-9_-]+"

    /// The kinds of thing we are willing to play. Artists are deliberately
    /// absent: an artist URI is neither a playable track nor a valid playback
    /// context in Spotify's AppleScript dictionary, so accepting one would
    /// store a value that can only fail an hour later mid-reminder.
    private static let kinds = ["playlist", "album", "track"]

    /// Accepts a `spotify:playlist:ID` URI or an
    /// `https://open.spotify.com/playlist/ID?si=...` share link (including the
    /// localized `/intl-de/playlist/ID` form) and returns the canonical URI.
    ///
    /// Returns `nil` for anything it does not recognise, so the settings UI can
    /// reject bad input inline rather than failing an hour later mid-reminder.
    public static func normalize(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for kind in kinds {
            // Two accepted shapes, matched separately rather than with one
            // loose pattern:
            //
            //   spotify:playlist:ID              — the URI form
            //   open.spotify.com/playlist/ID     — the share link, which may
            //                                      carry a locale segment
            //                                      (/intl-de/playlist/ID) and
            //                                      a ?si=... query
            //
            // A single `spotify[:/]kind` pattern does not cover the link: there
            // the host is `spotify.com`, so `spotify` is followed by `.com/`
            // rather than a separator.
            let patterns = [
                "spotify:\(kind):(\(idPattern))",
                "spotify\\.com/(?:[A-Za-z0-9-]+/)?\(kind)/(\(idPattern))",
            ]

            for pattern in patterns {
                guard let range = trimmed.range(
                    of: pattern, options: [.regularExpression, .caseInsensitive]
                ) else { continue }

                // The ID is everything after the final separator of the match.
                let matched = String(trimmed[range])
                guard let id = matched
                    .components(separatedBy: CharacterSet(charactersIn: ":/"))
                    .last, !id.isEmpty else { continue }

                return "spotify:\(kind):\(id)"
            }
        }
        return nil
    }

    /// Whether `uri` is exactly a canonical URI we will execute.
    ///
    /// `play` validates with this immediately before building the script, so a
    /// value that reached storage by some other route (a hand-edited data file)
    /// still cannot inject AppleScript.
    public static func isValid(_ uri: String) -> Bool {
        let pattern = "^spotify:(\(kinds.joined(separator: "|"))):\(idPattern)$"
        return uri.range(of: pattern, options: .regularExpression) != nil
    }

    /// A short human label for a URI, for showing in the UI.
    public static func describe(_ uri: String) -> String {
        let parts = uri.components(separatedBy: ":")
        guard parts.count == 3 else { return uri }
        return "\(parts[1].capitalized) · \(parts[2])"
    }
}
