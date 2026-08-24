using System.Diagnostics;
using Microsoft.Win32;

namespace Pauselet.App;

/// <summary>
/// Launch-at-login via the per-user Run key — the unpackaged-build mechanism
/// (an MSIX StartupTask replaces this for a future Store build; both would sit
/// behind this same type).
///
/// Mirrors the Mac helper's contract: the OS state is the truth. The user can
/// disable the entry behind the app's back in Task Manager → Startup, so the
/// settings UI re-reads <see cref="IsEnabled"/> rather than trusting the
/// stored preference.
/// </summary>
internal static class LaunchAtLogin
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Pauselet";

    public static bool IsEnabled
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                return key?.GetValue(ValueName) is string;
            }
            catch
            {
                return false;
            }
        }
    }

    public static void SetEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (enabled)
            {
                var executable = Environment.ProcessPath
                    ?? Process.GetCurrentProcess().MainModule?.FileName;
                if (executable is null) return;
                key.SetValue(ValueName, $"\"{executable}\"");
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }
        }
        catch
        {
            // A locked-down registry must not crash the settings window; the
            // checkbox re-reads IsEnabled and shows the truth.
        }
    }
}
