using System.IO;
using System.Media;

namespace Pauselet.App;

/// <summary>
/// Plays reminder sounds. The persisted <c>SoundName</c> values are macOS
/// system-sound names ("Submarine", "Glass", …) so a data file moved from a
/// Mac keeps its choices; each name maps onto one of the bundled chimes.
///
/// The bundled .wav files are synthesized placeholders (see
/// scripts/build_assets.py) — functionally correct, sonically provisional.
/// </summary>
internal static class Sounds
{
    /// <summary>
    /// The names offered in the reminder editor — kept identical to the Mac
    /// app's list so the stored values stay portable in both directions.
    /// </summary>
    public static readonly string[] Available =
    [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ];

    private static readonly Dictionary<string, string> Mapping = new(
        StringComparer.OrdinalIgnoreCase)
    {
        ["Basso"] = "chime-low",
        ["Blow"] = "chime-low",
        ["Bottle"] = "chime-pluck",
        ["Frog"] = "chime-pluck",
        ["Funk"] = "chime-low",
        ["Glass"] = "chime-glass",
        ["Hero"] = "chime-triad",
        ["Morse"] = "chime-double",
        ["Ping"] = "chime-soft",
        ["Pop"] = "chime-pluck",
        ["Purr"] = "chime-soft",
        ["Sosumi"] = "chime-double",
        ["Submarine"] = "chime-triad",
        ["Tink"] = "chime-glass",
    };

    /// <summary>
    /// Plays a named sound, ignoring names it does not know — same contract as
    /// the Mac helper, so a hand-edited data file cannot crash a fire.
    /// </summary>
    public static void Play(string name)
    {
        if (!Mapping.TryGetValue(name, out var file))
        {
            file = "chime-soft";
        }
        var path = Path.Combine(AppContext.BaseDirectory, "Assets", "Sounds", $"{file}.wav");
        if (!File.Exists(path)) return;
        try
        {
            // SoundPlayer plays asynchronously and is plenty for short chimes.
            new SoundPlayer(path).Play();
        }
        catch
        {
            // A missing audio device must never take down a reminder.
        }
    }
}
