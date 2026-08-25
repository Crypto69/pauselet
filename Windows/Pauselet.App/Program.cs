using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// The resident tray process: composition root, 5-second tick loop, wake and
/// unlock handlers, and launch-time backlog absorption — the same three
/// drivers the Mac app runs, plus the Windows-only unlock trigger (a PC can
/// be awake-but-locked for hours, and the tooltip must be fresh at unlock).
/// </summary>
public static class Program
{
    /// <summary>
    /// How often the engine re-evaluates. Every 5 seconds is far more often
    /// than any schedule needs, but it keeps the tray tooltip honest and costs
    /// nothing measurable. Desktop Windows does not nap background processes,
    /// so there is no App Nap opt-out to port.
    /// </summary>
    private static readonly TimeSpan TickInterval = TimeSpan.FromSeconds(5);

    private static ReminderEngine? _engine;
    private static TrayController? _tray;
    private static OverlayPresenter? _overlays;
    private static ToastPresenter? _notifier;
    private static DispatcherTimer? _tickTimer;

    [STAThread]
    public static void Main(string[] args)
    {
        // Single instance: LaunchServices did this for free on the Mac; here a
        // named mutex does. A second copy simply exits.
        using var mutex = new Mutex(
            initiallyOwned: true, "com.pauselet.pauselet.single-instance", out var isFirst
        );
        if (!isFirst)
        {
            return;
        }

        var app = new Application
        {
            // The UI lives entirely in the tray and in windows we open;
            // closing any of them must not end the process.
            ShutdownMode = ShutdownMode.OnExplicitShutdown,
        };
        // A resident background app must not die because one window
        // misbehaved — a crashed Pauselet delivers no reminders at all, which
        // is the one failure this app cannot afford. Log the exception (there
        // is no console and nobody watching) and keep the engine running.
        app.DispatcherUnhandledException += (_, e) =>
        {
            Log.Error("DispatcherUnhandledException", e.Exception);
            e.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            if (e.ExceptionObject is Exception exception)
            {
                Log.Error("UnhandledException", exception);
            }
        };
        app.Startup += (_, _) => Start(args);
        app.Exit += (_, _) => Stop();
        app.Run();
    }

    private static void Start(string[] args)
    {
        Log.Line("startup: begin");
        Theme.StartWatching();

        var notifier = new ToastPresenter();
        var overlays = new OverlayPresenter(notifier);

        IDataStoring store;
        try
        {
            store = new FileDataStore();
        }
        catch
        {
            // Falling back to memory keeps the app usable for the session even
            // if the app-data directory is somehow unwritable.
            store = new InMemoryDataStore(
                new AppData { Reminders = DefaultReminders.StarterSet() }
            );
        }

        var engine = new ReminderEngine(store, presenter: overlays);
        Log.Line($"startup: engine loaded ({engine.Reminders.Count} reminders)");
        notifier.Engine = engine;
        overlays.Engine = engine;
        notifier.Configure();
        Log.Line("startup: toasts configured");

        _engine = engine;
        _overlays = overlays;
        _notifier = notifier;
        _tray = new TrayController(engine, overlays, Quit);
        Log.Line("startup: tray created");

        // Clear the backlog *before* the first tick. Everything overdue at
        // this point fell due while the app was closed, and replaying it on
        // launch means overlays and toasts for reminders whose moment passed
        // hours ago.
        var absorbed = engine.AbsorbBacklogFromDowntime();
        Log.Line($"startup: backlog absorbed ({absorbed.Count})");

        StartTicking();
        ObserveSystemEvents();
        Log.Line("startup: ticking");

        // `--open-settings` opens the settings window straight after launch —
        // handy for testing, since it is otherwise only reachable through the
        // tray.
        if (args.Contains("--open-settings"))
        {
            _tray.OpenSettings();
        }
    }

    private static void StartTicking()
    {
        _tickTimer = new DispatcherTimer { Interval = TickInterval };
        _tickTimer.Tick += (_, _) =>
        {
            _engine?.Tick();
            _tray?.Refresh();
        };
        _tickTimer.Start();
        _engine?.Tick();
        _tray?.Refresh();
    }

    /// <summary>
    /// Tick immediately on wake and on unlock. The timer does not fire while
    /// the machine sleeps, so without this the first post-wake reminder would
    /// be late by up to one tick and the tooltip would show a stale value.
    /// </summary>
    private static void ObserveSystemEvents()
    {
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.SessionSwitch += OnSessionSwitch;
    }

    private static void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode != PowerModes.Resume) return;
        RunOnDispatcher(() =>
        {
            _engine?.Tick();
            _tray?.Refresh();
        });
    }

    private static void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason != SessionSwitchReason.SessionUnlock) return;
        RunOnDispatcher(() =>
        {
            // A toast that fired against the lock screen may have been
            // swallowed; the availability re-check keeps the fallback honest.
            _notifier?.RefreshAvailability();
            _engine?.Tick();
            _tray?.Refresh();
        });
    }

    private static void RunOnDispatcher(Action action)
    {
        Application.Current?.Dispatcher.BeginInvoke(action);
    }

    private static void Quit()
    {
        Application.Current?.Shutdown();
    }

    private static void Stop()
    {
        _tickTimer?.Stop();
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        _overlays?.DismissAll();
        _tray?.Dispose();
        _engine?.Persist();
    }
}
