using System.IO;
using System.Windows;
using System.Windows.Controls;
using H.NotifyIcon;
using NodaTime;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// Owns the tray icon, its flyout, and the settings window — the counterpart
/// of the Mac status bar controller.
///
/// Windows-specific realities, both by design:
/// - Windows 11 hides new tray icons in the overflow flyout until the user
///   pins them. The settings window carries first-run guidance for that; code
///   cannot pin itself.
/// - There is no text-beside-the-icon primitive, so the countdown that lives
///   in the Mac menu bar lives in the tooltip and at the top of the flyout
///   instead.
/// </summary>
internal sealed class TrayController : IDisposable
{
    private readonly ReminderEngine _engine;
    private readonly OverlayPresenter _overlays;
    private readonly Action _quit;
    private readonly TaskbarIcon _icon;
    private FlyoutWindow? _flyout;
    private SettingsWindow? _settingsWindow;

    public TrayController(ReminderEngine engine, OverlayPresenter overlays, Action quit)
    {
        _engine = engine;
        _overlays = overlays;
        _quit = quit;

        _icon = new TaskbarIcon
        {
            ToolTipText = "Pauselet",
            // Shown on right click (the default activation mode); left click
            // is handled below and opens the flyout.
            ContextMenu = new ContextMenu(),
        };
        UpdateIcon();
        _icon.TrayLeftMouseUp += (_, _) => ToggleFlyout();
        _icon.ContextMenu.Opened += (_, _) => RebuildMenu();
        _icon.ForceCreate();

        Theme.Changed += UpdateIcon;
        Refresh();
    }

    /// <summary>
    /// Picks the tray glyph variant that is visible against the current
    /// taskbar — Windows has no template-image auto-tinting.
    /// </summary>
    private void UpdateIcon()
    {
        var name = Theme.IsTaskbarLight ? "TrayLight.ico" : "TrayDark.ico";
        var path = Path.Combine(AppContext.BaseDirectory, "Assets", name);
        try
        {
            _icon.Icon = new System.Drawing.Icon(path);
        }
        catch
        {
            // Missing asset: the default app icon still shows something.
        }
    }

    /// <summary>
    /// Updates the countdown shown in the tooltip — the stand-in for the Mac
    /// menu bar's live countdown text. Called from the 5-second tick.
    /// </summary>
    public void Refresh()
    {
        var now = SystemClock.Instance.GetCurrentInstant();

        if (!_engine.Settings.ShowsNextReminderInMenuBar)
        {
            _icon.ToolTipText = "Pauselet";
            return;
        }
        if (Scheduler.IsPaused(_engine.Settings, now))
        {
            _icon.ToolTipText = "Pauselet — paused";
            return;
        }
        if (_engine.NextUp is { } next)
        {
            var countdown = Scheduler.CountdownText(now, next.Date);
            _icon.ToolTipText = $"Pauselet — {next.Reminder.Title} in {countdown}";
            return;
        }
        _icon.ToolTipText = "Pauselet";
    }

    // MARK: - Flyout

    private void ToggleFlyout()
    {
        if (_flyout is { IsVisible: true })
        {
            _flyout.Close();
            _flyout = null;
            return;
        }
        _flyout = new FlyoutWindow(_engine, OpenSettings, _quit);
        _flyout.Closed += (_, _) => _flyout = null;
        _flyout.Show();
        _flyout.Activate();
    }

    // MARK: - Quick menu

    /// <summary>
    /// The right-click menu holds the things people reach for most: pausing
    /// and quitting, without having to open the flyout. Rebuilt on open so the
    /// pause state is always current.
    /// </summary>
    private void RebuildMenu()
    {
        var menu = _icon.ContextMenu!;
        menu.Items.Clear();
        var paused = Scheduler.IsPaused(
            _engine.Settings, SystemClock.Instance.GetCurrentInstant()
        );

        if (paused)
        {
            var resume = new MenuItem { Header = "Resume Reminders" };
            resume.Click += (_, _) =>
            {
                _engine.Resume();
                Refresh();
            };
            menu.Items.Add(resume);
        }
        else
        {
            foreach (var minutes in new[] { 30, 60, 120 })
            {
                var label = minutes >= 60 ? $"{minutes / 60}h" : $"{minutes}m";
                var item = new MenuItem { Header = $"Pause for {label}" };
                var captured = minutes;
                item.Click += (_, _) =>
                {
                    _engine.PauseFor(captured);
                    Refresh();
                };
                menu.Items.Add(item);
            }
            var indefinite = new MenuItem { Header = "Pause Indefinitely" };
            indefinite.Click += (_, _) =>
            {
                _engine.SetPaused(true);
                Refresh();
            };
            menu.Items.Add(indefinite);
        }

        menu.Items.Add(new Separator());
        var settings = new MenuItem { Header = "Settings…" };
        settings.Click += (_, _) => OpenSettings();
        menu.Items.Add(settings);
        menu.Items.Add(new Separator());
        var quit = new MenuItem { Header = "Quit Pauselet" };
        quit.Click += (_, _) => _quit();
        menu.Items.Add(quit);
    }

    // MARK: - Settings window

    public void OpenSettings()
    {
        _flyout?.Close();

        if (_settingsWindow is { IsVisible: true })
        {
            _settingsWindow.Activate();
            return;
        }
        _settingsWindow = new SettingsWindow(_engine, _overlays);
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    public void Dispose()
    {
        Theme.Changed -= UpdateIcon;
        _icon.Dispose();
    }
}
