using System.IO;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// A minimal append-only log: <c>app.log</c> in <see cref="DataLocation.Directory"/>
/// (<c>%APPDATA%\Pauselet</c> for the zip build).
///
/// The app is a resident background process with no console: when something
/// goes wrong at 3am — or during a headless VM test — this file is the only
/// witness. Writes are best-effort and never throw.
/// </summary>
internal static class Log
{
    private static readonly object Gate = new();
    private static string? _path;

    private static string? PathOrNull()
    {
        if (_path is not null) return _path;
        try
        {
            var directory = DataLocation.Directory;
            Directory.CreateDirectory(directory);
            _path = Path.Combine(directory, "app.log");
            return _path;
        }
        catch
        {
            return null;
        }
    }

    public static void Line(string message)
    {
        if (PathOrNull() is not { } path) return;
        try
        {
            lock (Gate)
            {
                File.AppendAllText(
                    path,
                    $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {message}{Environment.NewLine}"
                );
            }
        }
        catch
        {
            // Logging must never be the thing that breaks.
        }
    }

    public static void Error(string context, Exception exception) =>
        Line($"{context}: {exception.GetType().Name}: {exception.Message}\n{exception.StackTrace}");
}
