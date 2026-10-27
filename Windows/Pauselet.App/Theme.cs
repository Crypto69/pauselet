using Microsoft.Win32;
using System.Windows.Media;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// Light/dark handling. SwiftUI's semantic colours did this for free on the
/// Mac; here the app/taskbar theme is read from the registry and every themed
/// surface re-reads <see cref="Current"/> when <see cref="Changed"/> fires.
/// The critical overlay is deliberately exempt: it is always dark by design.
/// </summary>
internal static class Theme
{
    private const string PersonalizeKey =
        @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    public sealed record Palette(
        Color WindowBackground,
        Color CardBackground,
        Color Foreground,
        Color SecondaryForeground,
        Color TertiaryForeground,
        Color Divider,
        Color HoverBackground,
        Color Accent);

    public static readonly Palette Light = new(
        WindowBackground: Color.FromRgb(0xF7, 0xF7, 0xF8),
        CardBackground: Color.FromRgb(0xFF, 0xFF, 0xFF),
        Foreground: Color.FromRgb(0x1B, 0x1F, 0x23),
        SecondaryForeground: Color.FromRgb(0x6B, 0x72, 0x78),
        TertiaryForeground: Color.FromRgb(0xA6, 0xAC, 0xB2),
        Divider: Color.FromRgb(0xE4, 0xE6, 0xE8),
        HoverBackground: Color.FromArgb(0x0A, 0x00, 0x00, 0x00),
        Accent: Color.FromRgb(0x2E, 0x8B, 0x83));

    public static readonly Palette Dark = new(
        WindowBackground: Color.FromRgb(0x20, 0x24, 0x28),
        CardBackground: Color.FromRgb(0x2A, 0x2F, 0x34),
        Foreground: Color.FromRgb(0xF0, 0xF2, 0xF4),
        SecondaryForeground: Color.FromRgb(0x9B, 0xA3, 0xAA),
        TertiaryForeground: Color.FromRgb(0x62, 0x6A, 0x71),
        Divider: Color.FromRgb(0x3A, 0x40, 0x46),
        HoverBackground: Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF),
        Accent: Color.FromRgb(0x5F, 0xC7, 0xBC));

    /// <summary>Fires after the user flips the Windows app theme.</summary>
    public static event Action? Changed;

    public static Palette Current => IsAppLight ? Light : Dark;

    /// <summary>Whether apps should use the light theme (windows, cards).</summary>
    public static bool IsAppLight => ReadPersonalize("AppsUseLightTheme", fallback: true);

    /// <summary>
    /// Whether the *taskbar* is light — a separate registry value, and the one
    /// that decides which tray glyph variant is visible against it.
    /// </summary>
    public static bool IsTaskbarLight =>
        ReadPersonalize("SystemUsesLightTheme", fallback: false);

    private static bool ReadPersonalize(string valueName, bool fallback)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
            return key?.GetValue(valueName) is int value ? value != 0 : fallback;
        }
        catch
        {
            return fallback;
        }
    }

    public static void StartWatching()
    {
        SystemEvents.UserPreferenceChanged += (_, args) =>
        {
            if (args.Category == UserPreferenceCategory.General)
            {
                Changed?.Invoke();
            }
        };
    }

    public static SolidColorBrush Brush(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    /// <summary>
    /// The tier's colour: the dot in the flyout, and the icon on the surface
    /// the reminder fires on, so a blue dot in the list means a blue icon on
    /// screen. Subtle is the teal its corner card has always used. The same
    /// in light and dark, like the Mac's system colours it stands in for.
    /// </summary>
    public static Color PriorityColor(Priority priority) =>
        priority switch
        {
            Priority.Subtle => Color.FromRgb(0x5C, 0xB8, 0xAB),
            Priority.Normal => Color.FromRgb(0x3B, 0x82, 0xF6),
            Priority.Important => Color.FromRgb(0xE8, 0x8A, 0x2E),
            Priority.Critical => Color.FromRgb(0xE0, 0x4F, 0x4F),
            _ => Colors.Gray,
        };

    public static SolidColorBrush PriorityBrush(Priority priority) =>
        Brush(PriorityColor(priority));
}
