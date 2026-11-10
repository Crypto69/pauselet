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

    /// <summary>How often the watchdog checks that ticks are still arriving.</summary>
    private static readonly TimeSpan WatchdogInterval = TimeSpan.FromSeconds(10);

    /// <summary>
    /// How long without a tick before the watchdog rebuilds the timer: three
    /// missed ticks, so an ordinary busy moment on the UI thread never trips it.
    /// </summary>
    private static readonly TimeSpan TickStaleAfter = TimeSpan.FromSeconds(20);

    private static System.Threading.Timer? _watchdog;

    /// <summary>
    /// When the last tick ran, as UTC ticks. Written on the UI thread and
    /// read by the watchdog on the thread pool, hence Interlocked.
    /// </summary>
    private static long _lastTickUtcTicks = DateTime.UtcNow.Ticks;

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
        app.Startup += (_, _) =>
        {
            try
            {
                Start(args);
            }
            catch (Exception exception)
            {
                // Half-started is worse than not started: no tray icon, no
                // ticks, and the single-instance mutex held so a relaunch
                // exits at once. Log it and go.
                Log.Error("startup failed", exception);
                app.Shutdown(1);
            }
        };
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
        try
        {
            notifier.Configure();
            Log.Line("startup: toasts configured");
        }
        catch (Exception exception)
        {
            // Registering for toast activation writes COM and registry
            // entries; an account that forbids them still gets reminders —
            // the in-app card stands in — rather than no app at all.
            Log.Error("toasts unavailable", exception);
            notifier.MarkUnavailable();
        }

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
        RestartTicking("startup");
        _watchdog = new System.Threading.Timer(
            _ => CheckTickIsAlive(), null, WatchdogInterval, WatchdogInterval
        );
    }

    /// <summary>
    /// Throws the tick timer away and starts a fresh one, then ticks at once.
    ///
    /// A DispatcherTimer that was running when the PC hibernated can come
    /// back stalled: it stays silent for about as long as the machine was
    /// off, so every reminder after wake arrives that much late, until a
    /// relaunch builds a new timer. Building a new timer here does what the
    /// relaunch did. The engine works from the wall clock, so ticking late
    /// never loses a reminder; it only delays it.
    /// </summary>
    private static void RestartTicking(string reason)
    {
        _tickTimer?.Stop();
        _tickTimer = new DispatcherTimer { Interval = TickInterval };
        _tickTimer.Tick += (_, _) => RunTick();
        _tickTimer.Start();
        if (reason != "startup") Log.Line($"ticking restarted: {reason}");
        RunTick();
    }

    private static void RunTick()
    {
        Interlocked.Exchange(ref _lastTickUtcTicks, DateTime.UtcNow.Ticks);
        _engine?.Tick();
        _tray?.Refresh();
    }

    /// <summary>
    /// The backstop for the wake handler. Windows does not always say it
    /// resumed: SystemEvents reports no resume for an unattended wake, and
    /// Modern Standby machines send no suspend or resume at all. This timer
    /// runs on the thread pool, whose clock is separate from the dispatcher's,
    /// and rebuilds the tick timer whenever the wall clock shows no tick for
    /// several intervals: after any sleep, hibernate, or a stalled timer.
    /// A clock set backwards counts too, since the gap then reads as
    /// negative.
    /// </summary>
    private static void CheckTickIsAlive()
    {
        var last = new DateTime(Interlocked.Read(ref _lastTickUtcTicks), DateTimeKind.Utc);
        var gap = DateTime.UtcNow - last;
        if (gap >= TimeSpan.Zero && gap < TickStaleAfter) return;
        // Push the stamp forward so a busy dispatcher is not sent a queue of
        // restarts while the first one is still waiting to run.
        Interlocked.Exchange(ref _lastTickUtcTicks, DateTime.UtcNow.Ticks);
        RunOnDispatcher(() => RestartTicking($"no tick for {gap.TotalSeconds:F0} s"));
    }

    /// <summary>
    /// Restart ticking on wake and on unlock, so the first reminder after
    /// wake is not late and the tooltip is never stale. The timer is rebuilt,
    /// not just nudged; see <see cref="RestartTicking"/>.
    /// </summary>
    private static void ObserveSystemEvents()
    {
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.SessionSwitch += OnSessionSwitch;
    }

    private static void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend)
        {
            // A guided hold must not "complete" under a sleeping machine, so
            // the coach pauses and the user resumes when they are back in
            // position — the Mac's willSleep behaviour.
            RunOnDispatcher(() => _overlays?.SuspendCoach());
            return;
        }
        if (e.Mode != PowerModes.Resume) return;
        RunOnDispatcher(() => RestartTicking("resume"));
    }

    private static void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionLock)
        {
            // Same reasoning as sleep: nobody is doing the exercise behind a
            // lock screen.
            RunOnDispatcher(() => _overlays?.SuspendCoach());
            return;
        }
        if (e.Reason != SessionSwitchReason.SessionUnlock) return;
        RunOnDispatcher(() =>
        {
            // A toast that fired against the lock screen may have been
            // swallowed; the availability re-check keeps the fallback honest.
            _notifier?.RefreshAvailability();
            RestartTicking("unlock");
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
        _watchdog?.Dispose();
        _tickTimer?.Stop();
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        _overlays?.DismissAll();
        _tray?.Dispose();
        _engine?.Persist();
    }
}
