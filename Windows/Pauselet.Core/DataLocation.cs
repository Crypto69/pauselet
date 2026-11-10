namespace Pauselet.Core;

/// <summary>
/// The one folder Pauselet keeps its files in: <c>data.json</c>,
/// <c>secrets.dat</c> and <c>app.log</c>.
///
/// The zip build uses <c>%APPDATA%\Pauselet</c>. The Microsoft Store build is
/// an MSIX package, where Windows quietly redirects new files under AppData
/// to a private per-package copy that disappears on uninstall; rather than
/// leave the data split between the real folder and that hidden copy, the
/// app points this at the package's own LocalState folder before it reads or
/// writes anything.
/// </summary>
public static class DataLocation
{
    /// <summary>The zip build's folder: <c>%APPDATA%\Pauselet</c>.</summary>
    public static string Unpackaged() => Path.Combine(
        Environment.GetFolderPath(
            Environment.SpecialFolder.ApplicationData,
            Environment.SpecialFolderOption.Create
        ),
        "Pauselet"
    );

    /// <summary>
    /// Where the files live. Set once at startup, before anything is read or
    /// written; every default path is built from it.
    /// </summary>
    public static string Directory { get; set; } = Unpackaged();
}
