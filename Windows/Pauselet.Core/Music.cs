using System.Text.RegularExpressions;

namespace Pauselet.Core;

/// <summary>
/// What music, if any, a reminder starts when it fires.
///
/// Three states rather than a plain on/off switch: most reminders that want
/// music want *the* playlist the user configured once in Preferences, but a
/// reminder is free to bring its own. Modelling "use the default" explicitly
/// means changing the default in Preferences updates every reminder that opted
/// in, instead of leaving stale copies of a URI scattered across reminders.
/// </summary>
public abstract record MusicChoice
{
    private MusicChoice() { }

    /// <summary>Fire silently. The default for every reminder.</summary>
    public static readonly MusicChoice None = new NoneChoice();
    /// <summary>Play whatever playlist is set in Preferences.</summary>
    public static readonly MusicChoice DefaultPlaylist = new DefaultPlaylistChoice();
    /// <summary>Play this specific playlist, ignoring the Preferences default.</summary>
    public static MusicChoice Playlist(string uri) => new PlaylistChoice(uri);

    public sealed record NoneChoice : MusicChoice;
    public sealed record DefaultPlaylistChoice : MusicChoice;
    public sealed record PlaylistChoice(string Uri) : MusicChoice;

    /// <summary>
    /// The playlist to actually play, resolved against the global settings.
    /// <c>null</c> means "play nothing" — either the reminder opted out, or it
    /// asked for the default and no default is configured.
    /// </summary>
    public string? ResolvedUri(string? defaultPlaylistUri) => this switch
    {
        NoneChoice => null,
        DefaultPlaylistChoice =>
            string.IsNullOrEmpty(defaultPlaylistUri) ? null : defaultPlaylistUri,
        PlaylistChoice playlist => playlist.Uri.Length == 0 ? null : playlist.Uri,
        _ => null,
    };

    /// <summary>Whether music is switched on at all, for driving a toggle in the UI.</summary>
    public bool IsEnabled => this is not NoneChoice;
}

/// <summary>
/// Parsing and validation for Spotify playlist references.
///
/// Kept in the core so exactly one definition of "a URI we will run" exists.
/// On macOS the validator is what makes interpolating a user-supplied string
/// into AppleScript source safe; the same discipline is kept here so the data
/// files stay interchangeable and a future Windows integration inherits it.
/// </summary>
public static class SpotifyUri
{
    /// <summary>
    /// Spotify IDs are base-62 with <c>-</c> and <c>_</c> also appearing in
    /// share links. Anything outside this set is rejected, which is what keeps
    /// a quote or a script fragment from ever reaching an interpreter.
    /// </summary>
    private const string IdPattern = "[A-Za-z0-9_-]+";

    /// <summary>
    /// The kinds of thing we are willing to play. Artists are deliberately
    /// absent: an artist URI is neither a playable track nor a valid playback
    /// context, so accepting one would store a value that can only fail an hour
    /// later mid-reminder.
    /// </summary>
    private static readonly string[] Kinds = ["playlist", "album", "track"];

    /// <summary>
    /// Accepts a <c>spotify:playlist:ID</c> URI or an
    /// <c>https://open.spotify.com/playlist/ID?si=...</c> share link (including
    /// the localized <c>/intl-de/playlist/ID</c> form) and returns the
    /// canonical URI.
    ///
    /// Returns <c>null</c> for anything it does not recognise, so the settings
    /// UI can reject bad input inline rather than failing an hour later
    /// mid-reminder.
    /// </summary>
    public static string? Normalize(string input)
    {
        var trimmed = input.Trim();
        if (trimmed.Length == 0) return null;

        foreach (var kind in Kinds)
        {
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
            string[] patterns =
            [
                $"spotify:{kind}:({IdPattern})",
                $@"spotify\.com/(?:[A-Za-z0-9-]+/)?{kind}/({IdPattern})",
            ];

            foreach (var pattern in patterns)
            {
                var match = Regex.Match(trimmed, pattern, RegexOptions.IgnoreCase);
                if (!match.Success) continue;

                // The ID is everything after the final separator of the match.
                var id = match.Value.Split(':', '/').Last();
                if (id.Length == 0) continue;

                return $"spotify:{kind}:{id}";
            }
        }
        return null;
    }

    /// <summary>
    /// Whether <paramref name="uri"/> is exactly a canonical URI we will
    /// execute. Playback validates with this immediately before acting, so a
    /// value that reached storage by some other route (a hand-edited data file)
    /// still cannot inject anything.
    /// </summary>
    public static bool IsValid(string uri)
    {
        var pattern = $"^spotify:({string.Join("|", Kinds)}):{IdPattern}$";
        return Regex.IsMatch(uri, pattern);
    }

    /// <summary>A short human label for a URI, for showing in the UI.</summary>
    public static string Describe(string uri)
    {
        var parts = uri.Split(':');
        if (parts.Length != 3) return uri;
        var kind = char.ToUpperInvariant(parts[1][0]) + parts[1][1..];
        return $"{kind} · {parts[2]}";
    }
}
