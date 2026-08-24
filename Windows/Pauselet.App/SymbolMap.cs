using System.Windows.Media;

namespace Pauselet.App;

/// <summary>
/// Maps the SF Symbol names persisted in reminder data onto Segoe Fluent
/// Icons glyphs (with Segoe MDL2 Assets as the Windows 10 fallback — the two
/// fonts share codepoints for everything used here).
///
/// The SF names stay in the data file untouched, so a data.json moved between
/// a Mac and a PC keeps every icon choice. Anything unmapped falls back to the
/// bell rather than rendering a missing-glyph box.
///
/// NOTE: glyph choices are best-effort until reviewed on a real Windows
/// machine — the codepoints are stable, but whether each reads as a good
/// stand-in for its SF counterpart needs eyes on actual rendering.
/// </summary>
internal static class SymbolMap
{
    public static readonly FontFamily IconFont =
        new("Segoe Fluent Icons, Segoe MDL2 Assets");

    private static readonly Dictionary<string, string> Glyphs = new()
    {
        // Tier symbols.
        ["circle.dotted"] = "",              // StatusCircleRing
        ["bell"] = "",                       // Ringer
        ["bell.badge"] = "",                 // ActionCenterNotification
        ["exclamationmark.triangle.fill"] = "", // Warning

        // Starter set + editor picker.
        ["figure.seated.side"] = "",         // Contact presence / person
        ["arrow.up.and.down.circle"] = "",   // Sort
        ["drop.fill"] = "",                  // Drop
        ["figure.flexibility"] = "",         // Running/exercise stand-in
        ["bell.slash"] = "",                 // RingerSilent
        ["figure.walk"] = "",                // Running
        ["figure.stand"] = "",               // Contact
        ["eye"] = "",                        // RedEye
        ["cup.and.saucer.fill"] = "",        // Coffee-ish
        ["fork.knife"] = "",                 // EatDrink
        ["pills.fill"] = "",                 // Pill-ish
        ["heart.fill"] = "",                 // HeartFill
        ["lungs.fill"] = "",                 // Heart (breathing stand-in)
        ["brain.head.profile"] = "",         // Diagnostic
        ["moon.fill"] = "",                  // QuietHours moon
        ["sun.max.fill"] = "",               // Brightness sun
        ["alarm"] = "",                      // Recent/clock
        ["clock"] = "",                      // Recent/clock
        ["timer"] = "",                      // Stopwatch
        ["calendar"] = "",                   // Calendar
        ["book.fill"] = "",                  // Library
        ["phone.fill"] = "",                 // Phone
        ["envelope.fill"] = "",              // Mail
        ["gamecontroller.fill"] = "",        // Game
        ["music.note"] = "",                 // MusicNote
        ["leaf.fill"] = "",                  // Leaf-ish (World)
        ["pawprint.fill"] = "",              // stand-in
        ["house.fill"] = "",                 // Home
        ["desktopcomputer"] = "",            // TVMonitor
        ["keyboard"] = "",                   // KeyboardClassic
        ["hands.sparkles.fill"] = "",        // Sparkle-ish (Lightbulb)
        ["sparkles"] = "",                   // Lightbulb stand-in
        ["checkmark.circle"] = "",           // Completed
        ["checkmark.circle.fill"] = "",      // Completed
        ["gearshape"] = "",                  // Settings
        ["pause.circle"] = "",               // Pause
        ["play.circle.fill"] = "",           // Play
    };

    public static string Glyph(string sfSymbolName) =>
        Glyphs.TryGetValue(sfSymbolName, out var glyph) ? glyph : Glyphs["bell"];

    /// <summary>The names offered in the editor's icon picker, same set as the Mac editor.</summary>
    public static readonly string[] PickerSymbols =
    [
        "bell", "figure.seated.side", "arrow.up.and.down.circle", "drop.fill",
        "figure.flexibility", "figure.walk", "figure.stand", "eye",
        "cup.and.saucer.fill", "fork.knife", "pills.fill", "heart.fill",
        "lungs.fill", "brain.head.profile", "moon.fill", "sun.max.fill",
        "alarm", "clock", "timer", "calendar", "book.fill", "phone.fill",
        "envelope.fill", "music.note", "leaf.fill", "house.fill",
        "desktopcomputer", "keyboard", "sparkles",
    ];
}
