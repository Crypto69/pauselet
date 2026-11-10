using System.Diagnostics;
using Microsoft.Win32;
using Windows.ApplicationModel;

namespace Pauselet.App;

/// <summary>
/// Launch at login, by whichever mechanism this build can use:
///
/// - The zip build writes the per-user Run key.
/// - The Store (MSIX) build uses the package's StartupTask, declared in
///   <c>Windows/Packaging/AppxManifest.xml</c>. A Run key written from inside
///   a package lands in the package's private copy of the registry, which
///   Windows never reads at login, so it would silently do nothing.
///
/// Mirrors the Mac helper's contract: the OS state is the truth. The user can
/// disable the entry behind the app's back (Task Manager → Startup, or
/// Settings → Apps → Startup), so the settings UI re-reads
/// <see cref="IsEnabled"/> rather than trusting the stored preference.
/// </summary>
internal static class LaunchAtLogin
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "Pauselet";

    /// <summary>Must match the manifest's <c>uap5:StartupTask TaskId</c>.</summary>
    private const string StartupTaskId = "PauseletStartup";

    public static bool IsEnabled
    {
        get
        {
            if (PackageInfo.IsPackaged)
            {
                return StartupTaskState() is Windows.ApplicationModel.StartupTaskState.Enabled
                    or Windows.ApplicationModel.StartupTaskState.EnabledByPolicy;
            }
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

    /// <summary>
    /// True when Windows will not let the app turn launch at login on, because
    /// the user (or policy) switched it off in Windows' own settings. Only
    /// they can turn it back on there, so the settings window says where.
    /// </summary>
    public static bool IsBlockedBySystem =>
        PackageInfo.IsPackaged
        && StartupTaskState() is Windows.ApplicationModel.StartupTaskState.DisabledByUser
            or Windows.ApplicationModel.StartupTaskState.DisabledByPolicy;

    public static void SetEnabled(bool enabled)
    {
        if (PackageInfo.IsPackaged)
        {
            SetStartupTask(enabled);
            return;
        }
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

    /// <summary>
    /// Removes the zip build's Run entry. Used when the zip copy hands over to
    /// the Store copy, so the zip copy stops starting at login.
    /// </summary>
    public static void RemoveRunKey()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            key?.DeleteValue(ValueName, throwOnMissingValue: false);
        }
        catch
        {
            // Nothing more to do; at worst the zip copy starts and hands over again.
        }
    }

    private static Windows.ApplicationModel.StartupTaskState? StartupTaskState()
    {
        try
        {
            return GetTask()?.State;
        }
        catch
        {
            return null;
        }
    }

    private static void SetStartupTask(bool enabled)
    {
        try
        {
            if (GetTask() is not { } task)
            {
                Log.Line("launch at login: no startup task in the manifest");
                return;
            }
            if (enabled)
            {
                // A packaged desktop app gets no consent dialog here; if the
                // user disabled the task in Windows' settings this leaves it
                // disabled, and IsBlockedBySystem reports why.
                var state = task.RequestEnableAsync().AsTask().GetAwaiter().GetResult();
                Log.Line($"launch at login: startup task {state}");
            }
            else
            {
                task.Disable();
                Log.Line($"launch at login: startup task {task.State}");
            }
        }
        catch (Exception exception)
        {
            // As with the registry: the checkbox re-reads the truth.
            Log.Error("launch at login: startup task failed", exception);
        }
    }

    /// <summary>
    /// The WinRT calls complete on the thread pool, so blocking the UI thread
    /// on them briefly cannot deadlock.
    /// </summary>
    private static StartupTask? GetTask() =>
        StartupTask.GetAsync(StartupTaskId).AsTask().GetAwaiter().GetResult();
}
