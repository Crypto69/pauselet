using System.Windows.Media;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// Maps the SF Symbol names persisted in reminder data onto glyphs from a
/// bundled subset of Google's Material Symbols (Apache 2.0 — see
/// Assets/Fonts/LICENSE-MaterialSymbols.txt, built by scripts/build_assets.py).
///
/// Why a bundled font: SF Symbols are licensed for Apple platforms only, and
/// Windows' built-in Segoe icon fonts are UI-chrome sets with no human-figure
/// glyphs at all — there is no "person reclining" in them, and this app's
/// starter reminders are body positions. Material Symbols has the poses.
///
/// The SF names stay in the data file untouched, so a data.json moved between
/// a Mac and a PC keeps every icon choice; only the rendering differs per
/// platform. Anything unmapped falls back to the bell rather than a
/// missing-glyph box. The codepoint table below must stay in step with
/// SUBSET_GLYPHS in scripts/build_assets.py — escapes rather than literal
/// characters, because private-use-area glyphs are invisible in a diff and an
/// invisibly wrong icon is exactly the bug this table exists to prevent.
/// </summary>
internal static class SymbolMap
{
    /// <summary>
    /// The bundled subset font. WPF resolves loose font files via a base URI
    /// plus "./relative/#Family Name".
    /// </summary>
    public static readonly FontFamily IconFont = new(
        new Uri(AppContext.BaseDirectory),
        "./Assets/Fonts/#Material Symbols Outlined"
    );

    private static readonly Dictionary<string, string> Glyphs = new()
    {
        // Tier symbols.
        ["circle.dotted"] = "\uE9C1",                  // motion_photos_on
        ["bell"] = "\uE7F5",                           // notifications
        ["bell.badge"] = "\uF4FE",                     // notifications_unread
        ["exclamationmark.triangle.fill"] = "\uF083",  // warning

        // Starter set + editor picker.
        ["figure.seated.side"] = "\uE636",             // airline_seat_recline_extra
        ["arrow.up.and.down.circle"] = "\uE8D6",       // swap_vertical_circle
        ["drop.fill"] = "\uE798",                      // water_drop
        ["figure.flexibility"] = "\uEBC4",             // sports_gymnastics
        ["figure.mind.and.body"] = "\uEA78",           // self_improvement
        ["bell.slash"] = "\uE7F6",                     // notifications_off
        ["figure.walk"] = "\uE536",                    // directions_walk
        ["figure.stand"] = "\uE92C",                   // accessibility_new
        ["dumbbell.fill"] = "\uEB43",                  // fitness_center
        ["eye"] = "\uE8F4",                            // visibility
        // The catalog offers the filled variant; Material Symbols' outlined
        // subset has one eye, so both SF names land on it rather than one of
        // them falling back to a bell.
        ["eye.fill"] = "\uE8F4",                       // visibility
        ["hand.raised.fill"] = "\uE769",               // front_hand
        ["cross.case.fill"] = "\uF109",                // medical_services
        ["wind"] = "\uEFD8",                           // air
        ["cup.and.saucer.fill"] = "\uEB44",            // local_cafe
        ["fork.knife"] = "\uE56C",                     // restaurant
        ["pills.fill"] = "\uF033",                     // medication
        ["heart.fill"] = "\uE87E",                     // favorite
        ["lungs.fill"] = "\uE124",                     // pulmonology
        ["brain.head.profile"] = "\uEA4A",             // psychology
        ["moon.fill"] = "\uF159",                      // bedtime
        ["sun.max.fill"] = "\uE518",                   // light_mode
        ["alarm"] = "\uE855",                          // alarm
        ["clock"] = "\uEFD6",                          // schedule
        ["timer"] = "\uE425",                          // timer
        ["calendar"] = "\uEBCC",                       // calendar_month
        ["book.fill"] = "\uEA19",                      // menu_book
        ["phone.fill"] = "\uF0D4",                     // call
        ["envelope.fill"] = "\uE159",                  // mail
        ["gamecontroller.fill"] = "\uEA28",            // sports_esports
        ["music.note"] = "\uE405",                     // music_note
        ["leaf.fill"] = "\uEA35",                      // eco
        ["pawprint.fill"] = "\uE91D",                  // pets
        ["house.fill"] = "\uE9B2",                     // home
        ["desktopcomputer"] = "\uE30C",                // desktop_windows
        ["keyboard"] = "\uE312",                       // keyboard
        ["hands.sparkles.fill"] = "\uF21F",            // clean_hands
        ["sparkles"] = "\uE65F",                       // auto_awesome

        // UI glyphs used by the app's own surfaces.
        ["checkmark.circle"] = "\uF0BE",               // check_circle
        ["checkmark.circle.fill"] = "\uF0BE",          // check_circle
        ["circle"] = "\uE836",                         // radio_button_unchecked
        ["gearshape"] = "\uE8B8",                      // settings
        ["pause.circle"] = "\uE1A2",                   // pause_circle
        ["play.circle.fill"] = "\uE1C4",               // play_circle

        // About-tab links (same SF names the Mac AboutTab uses).
        ["globe"] = "\uE80B",                          // public
        ["play.rectangle"] = "\uF06A",                 // smart_display
        ["camera"] = "\uE412",                         // photo_camera
        ["person.crop.square"] = "\uE851",             // account_box
    };

    public static string Glyph(string sfSymbolName) =>
        Glyphs.TryGetValue(sfSymbolName, out var glyph) ? glyph : Glyphs["bell"];

    /// <summary>
    /// The names offered in the editor's icon picker. SF names, so every
    /// choice stays valid when the data file moves to the Mac.
    ///
    /// EditorCatalog.Symbols first and in its order, so the three platforms
    /// lead with the same icons; the rest are ones Windows has glyphs for and
    /// the Mac picker does not list. Every name here must have an entry in
    /// <see cref="Glyphs"/> — one that does not falls back to a bell, which
    /// looks like a bug rather than a choice.
    /// </summary>
    public static readonly string[] PickerSymbols =
    [
        .. EditorCatalog.Symbols,
        "figure.mind.and.body", "figure.stand", "eye", "cup.and.saucer.fill",
        "brain.head.profile", "alarm", "clock", "calendar",
        "envelope.fill", "gamecontroller.fill", "music.note", "leaf.fill",
        "pawprint.fill", "house.fill", "desktopcomputer", "keyboard",
        "hands.sparkles.fill", "sparkles",
    ];
}
