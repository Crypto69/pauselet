using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// Whether this copy runs from the Microsoft Store's MSIX package or from the
/// zip, and the few things that differ between the two.
///
/// The zip build must behave exactly as it always has, so everything
/// package-specific branches on <see cref="IsPackaged"/>.
/// </summary>
internal static class PackageInfo
{
    /// <summary>
    /// The Store package's family name, from Partner Center → Product
    /// identity. Must match <c>Windows/Packaging/AppxManifest.xml</c>.
    /// </summary>
    public const string StoreFamilyName = "ChristianVenter.Pauselet_gwv76hmfms3y2";

    /// <summary>The manifest's <c>Application Id</c>.</summary>
    private const string StoreApplicationId = "Pauselet";

    private const int AppModelErrorNoPackage = 15700;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetCurrentPackageFullName(ref int length, char[]? name);

    /// <summary>True when running from an installed MSIX (Store or sideloaded).</summary>
    public static bool IsPackaged { get; } = Detect();

    private static bool Detect()
    {
        try
        {
            var length = 0;
            // Packaged: ERROR_INSUFFICIENT_BUFFER. Unpackaged: APPMODEL_ERROR_NO_PACKAGE.
            return GetCurrentPackageFullName(ref length, null) != AppModelErrorNoPackage;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Points <see cref="DataLocation.Directory"/> at the package's LocalState
    /// folder when packaged. Must run before anything logs, loads or saves.
    /// </summary>
    public static void ConfigureDataLocation()
    {
        if (!IsPackaged) return;
        try
        {
            DataLocation.Directory = Windows.Storage.ApplicationData.Current.LocalFolder.Path;
        }
        catch
        {
            // Without the package folder the virtualised %APPDATA% path still
            // works for this session; it is just not where we want it.
        }
    }

    /// <summary>
    /// First launch of the Store build on a PC that ran the zip: copy the
    /// zip's reminders, history and AI key across, once. Copy, not move, so
    /// the zip build still works if the user goes back to it. The AI key
    /// decrypts unchanged: DPAPI is tied to the Windows user, not the folder.
    /// </summary>
    public static void ImportZipDataIfNeeded()
    {
        if (!IsPackaged) return;
        try
        {
            var target = DataLocation.Directory;
            if (File.Exists(Path.Combine(target, "data.json"))) return;
            var source = DataLocation.Unpackaged();
            var sourceData = Path.Combine(source, "data.json");
            if (!File.Exists(sourceData)) return;
            Directory.CreateDirectory(target);
            File.Copy(sourceData, Path.Combine(target, "data.json"));
            var secrets = Path.Combine(source, "secrets.dat");
            if (File.Exists(secrets))
            {
                File.Copy(secrets, Path.Combine(target, "secrets.dat"), overwrite: true);
            }
            Log.Line($"imported data from the zip install at {source}");
        }
        catch (Exception exception)
        {
            Log.Error("importing the zip install's data failed", exception);
        }
    }

    /// <summary>
    /// How this process was started, for deciding whether to show a window.
    /// Read once, early: the packaged activation arguments can only be
    /// fetched the first time.
    /// </summary>
    public static LaunchKind ReadLaunchKind(string[] args)
    {
        if (args.Any(a => a.Equals("-ToastActivated", StringComparison.OrdinalIgnoreCase)))
        {
            return LaunchKind.Background;
        }
        if (!IsPackaged)
        {
            // The zip build has always started silently; keep it that way.
            return LaunchKind.Background;
        }
        try
        {
            var activation = Windows.ApplicationModel.AppInstance.GetActivatedEventArgs();
            if (activation?.Kind == Windows.ApplicationModel.Activation.ActivationKind.StartupTask)
            {
                return LaunchKind.Background;
            }
        }
        catch
        {
            // Unknown: treat it as the user opening the app.
        }
        return LaunchKind.Interactive;
    }

    /// <summary>
    /// The zip build's half of the move to the Store. If the Store package is
    /// installed for this user, the zip copy removes its own launch-at-login
    /// entry (the Store copy cannot: its registry writes are private to its
    /// package), starts the Store copy, and returns true so the caller exits.
    /// Otherwise the zip copy would start at every login, hold the
    /// single-instance lock, and the Store copy would never run.
    /// </summary>
    public static bool HandOverToStoreBuildIfInstalled()
    {
        if (IsPackaged) return false;
        try
        {
            var packages = new Windows.Management.Deployment.PackageManager()
                .FindPackagesForUser(string.Empty, StoreFamilyName);
            if (!packages.Any()) return false;
        }
        catch
        {
            return false;
        }

        Log.Line("startup: the Store build is installed; handing over to it");
        LaunchAtLogin.RemoveRunKey();
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = $@"shell:AppsFolder\{StoreFamilyName}!{StoreApplicationId}",
                UseShellExecute = true,
            });
        }
        catch (Exception exception)
        {
            Log.Error("could not start the Store build", exception);
        }
        return true;
    }
}

internal enum LaunchKind
{
    /// <summary>Login, a notification button, or the zip build: stay in the tray.</summary>
    Background,

    /// <summary>The user opened the Store build from Start or the Store: show a window.</summary>
    Interactive,
}
