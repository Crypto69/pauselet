using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// The full-screen takeover shown for Critical reminders — one instance per
/// monitor, borderless and topmost, sized to the monitor's physical bounds so
/// it covers the taskbar too.
///
/// Design intent carried over from the Mac: this interrupts someone who is
/// concentrating, so it is calm rather than alarming — dark, soft, and
/// unhurried. For a reminder with an activity duration it runs a countdown,
/// which turns "stop working" into a concrete, finite thing to do.
///
/// Two Windows-specific defences:
/// - Topmost is re-asserted on a 2-second timer for as long as the takeover is
///   up. The initial z-order can lose races against other topmost windows
///   (the documented failure mode of shipping break apps on secondary
///   monitors), and re-asserting is cheap insurance. The same pass re-pins the
///   window to its monitor bounds, which also brings it along when the user
///   switches virtual desktops.
/// - WM_DISPLAYCHANGE triggers a re-layout, so plugging or unplugging a
///   monitor mid-takeover leaves every current display covered.
/// </summary>
internal sealed class CriticalOverlayWindow : Window
{
    private readonly Reminder _reminder;
    private readonly System.Drawing.Rectangle _bounds;
    private readonly Action _onComplete;
    private readonly Action _onSnooze;
    public bool IsPrimaryScreen { get; }

    /// <summary>Raised (from the primary window only) when the monitor set changes.</summary>
    public event Action? DisplayLayoutChanged;

    private readonly DispatcherTimer _topmostTimer;
    private DispatcherTimer? _countdownTimer;
    private IntPtr _handle;
    private bool _acknowledged;

    private int _remaining;
    private bool _hasStarted;
    private System.Windows.Shapes.Path? _ringProgress;
    private TextBlock? _ringLabel;
    private TextBlock? _ringSubLabel;
    private Button? _doneButton;

    private bool HasCountdown => (_reminder.ActivityDurationSeconds ?? 0) > 0;

    private static readonly Brush IconBrush =
        Theme.Brush(Color.FromRgb(158, 227, 217));
    private static readonly Brush RingBrush =
        Theme.Brush(Color.FromRgb(107, 217, 199));
    private static readonly Brush RingTrackBrush =
        Theme.Brush(Color.FromArgb(31, 255, 255, 255));
    private static readonly Brush PrimaryButtonBrush =
        Theme.Brush(Color.FromRgb(140, 224, 209));
    private static readonly Brush PrimaryButtonTextBrush =
        Theme.Brush(Color.FromRgb(8, 31, 33));
    private static readonly Brush SecondaryButtonBrush =
        Theme.Brush(Color.FromArgb(33, 255, 255, 255));
    private static readonly Brush SecondaryButtonBorderBrush =
        Theme.Brush(Color.FromArgb(46, 255, 255, 255));

    public CriticalOverlayWindow(
        Reminder reminder,
        System.Drawing.Rectangle physicalBounds,
        bool isPrimary,
        Action onComplete,
        Action onSnooze)
    {
        _reminder = reminder;
        _bounds = physicalBounds;
        IsPrimaryScreen = isPrimary;
        _onComplete = onComplete;
        _onSnooze = onSnooze;
        _remaining = reminder.ActivityDurationSeconds ?? 0;

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = false;
        WindowStartupLocation = WindowStartupLocation.Manual;
        // A rough landing spot near the target monitor; SourceInitialized pins
        // the exact physical bounds, and PerMonitorV2 re-lays out from there.
        Left = physicalBounds.X;
        Top = physicalBounds.Y;

        Content = BuildContent();
        KeyDown += OnKeyDown;
        SourceInitialized += OnSourceInitialized;

        _topmostTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(2),
        };
        _topmostTimer.Tick += (_, _) => PinToBounds(activate: false);

        if (HasCountdown)
        {
            _countdownTimer = new DispatcherTimer
            {
                Interval = TimeSpan.FromSeconds(1),
            };
            _countdownTimer.Tick += (_, _) => AdvanceCountdown();
        }
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        _handle = new WindowInteropHelper(this).Handle;
        HwndSource.FromHwnd(_handle)?.AddHook(WndProc);
        PinToBounds(activate: false);
        _topmostTimer.Start();
        if (HasCountdown)
        {
            _hasStarted = true;
            _countdownTimer?.Start();
        }
    }

    /// <summary>
    /// Places the window over its monitor's full physical bounds and re-stakes
    /// its topmost claim. SetWindowPos speaks physical pixels, which sidesteps
    /// WPF's DIP conversion entirely — the one reliable way to fill a monitor
    /// exactly in a mixed-DPI setup.
    /// </summary>
    private void PinToBounds(bool activate)
    {
        if (_handle == IntPtr.Zero) return;
        var flags = NativeMethods.SWP_SHOWWINDOW
            | (activate ? 0 : NativeMethods.SWP_NOACTIVATE);
        NativeMethods.SetWindowPos(
            _handle, NativeMethods.HWND_TOPMOST,
            _bounds.X, _bounds.Y, _bounds.Width, _bounds.Height, flags
        );
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == NativeMethods.WM_DISPLAYCHANGE && IsPrimaryScreen)
        {
            // Re-layout outside the message handler; the handler must not
            // destroy the window it is running in.
            Dispatcher.BeginInvoke(() => DisplayLayoutChanged?.Invoke());
        }
        return IntPtr.Zero;
    }

    /// <summary>
    /// Asks Windows for focus so Return / S work without a click. May be
    /// refused for a background process — the buttons are the primary path
    /// and the takeover does not depend on focus.
    /// </summary>
    public void TryActivate()
    {
        try
        {
            PinToBounds(activate: true);
            Activate();
            Focus();
        }
        catch
        {
            // Focus refusal flashes the taskbar icon instead; acceptable.
        }
    }

    public void CloseOverlay()
    {
        _topmostTimer.Stop();
        _countdownTimer?.Stop();
        _countdownTimer = null;
        Close();
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Enter:
                e.Handled = true;
                Acknowledge(_onComplete);
                break;
            case Key.S:
                e.Handled = true;
                Acknowledge(_onSnooze);
                break;
        }
    }

    /// <summary>
    /// Buttons exist on every monitor's copy of the overlay; the first
    /// acknowledgment wins and the rest are ignored.
    /// </summary>
    private void Acknowledge(Action action)
    {
        if (_acknowledged) return;
        _acknowledged = true;
        action();
    }

    // MARK: - Content

    private UIElement BuildContent()
    {
        // A deep, soft backdrop rather than a harsh alert colour — near-opaque
        // so it dims the desktop instead of blanking it.
        var root = new Grid
        {
            Background = new LinearGradientBrush(
                Color.FromArgb(247, 10, 23, 28),
                Color.FromArgb(250, 5, 13, 18),
                90
            ),
            Focusable = true,
        };

        var stack = new StackPanel
        {
            Orientation = Orientation.Vertical,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };

        var icon = Ui.Glyph(_reminder.SymbolName, 72, IconBrush);
        icon.Margin = new Thickness(0, 0, 0, 34);
        stack.Children.Add(icon);

        var title = Ui.Text(
            _reminder.Title, 46, Brushes.White,
            FontWeights.SemiBold, TextAlignment.Center
        );
        title.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(title);

        if (_reminder.Message.Length > 0)
        {
            var message = Ui.Text(
                _reminder.Message, 21,
                Theme.Brush(Color.FromArgb(194, 255, 255, 255)),
                alignment: TextAlignment.Center
            );
            message.MaxWidth = 620;
            message.LineHeight = 30;
            message.Margin = new Thickness(0, 14, 0, 0);
            message.HorizontalAlignment = HorizontalAlignment.Center;
            stack.Children.Add(message);
        }

        if (HasCountdown)
        {
            stack.Children.Add(BuildCountdownRing());
        }

        stack.Children.Add(BuildButtons());

        var hint = Ui.Text(
            "Press Return when you're done · S to snooze", 12,
            Theme.Brush(Color.FromArgb(97, 255, 255, 255)),
            alignment: TextAlignment.Center
        );
        hint.Margin = new Thickness(0, 20, 0, 0);
        hint.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(hint);

        root.Children.Add(stack);
        return root;
    }

    private UIElement BuildCountdownRing()
    {
        var canvas = new Grid
        {
            Width = 168,
            Height = 168,
            Margin = new Thickness(0, 34, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Center,
        };

        var track = new System.Windows.Shapes.Ellipse
        {
            Stroke = RingTrackBrush,
            StrokeThickness = 8,
        };
        canvas.Children.Add(track);

        _ringProgress = new System.Windows.Shapes.Path
        {
            Stroke = RingBrush,
            StrokeThickness = 8,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
        };
        canvas.Children.Add(_ringProgress);

        var labels = new StackPanel
        {
            Orientation = Orientation.Vertical,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _ringLabel = Ui.Text(
            TimeString(_remaining), 40, Brushes.White,
            FontWeights.Medium, TextAlignment.Center
        );
        labels.Children.Add(_ringLabel);
        _ringSubLabel = Ui.Text(
            "remaining", 12,
            Theme.Brush(Color.FromArgb(128, 255, 255, 255)),
            alignment: TextAlignment.Center
        );
        labels.Children.Add(_ringSubLabel);
        canvas.Children.Add(labels);

        UpdateRing();
        return canvas;
    }

    private UIElement BuildButtons()
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 38, 0, 0),
        };

        var snooze = Ui.RoundedButton(
            "Snooze", SecondaryButtonBrush, Brushes.White,
            SecondaryButtonBorderBrush, minWidth: 148
        );
        snooze.Margin = new Thickness(0, 0, 14, 0);
        snooze.Click += (_, _) => Acknowledge(_onSnooze);
        row.Children.Add(snooze);

        _doneButton = Ui.RoundedButton(
            DoneButtonText(), PrimaryButtonBrush, PrimaryButtonTextBrush,
            minWidth: 148
        );
        _doneButton.Click += (_, _) => Acknowledge(_onComplete);
        row.Children.Add(_doneButton);

        return row;
    }

    private string DoneButtonText() =>
        HasCountdown && _hasStarted && _remaining > 0 ? "Finish Early" : "Done";

    private void AdvanceCountdown()
    {
        if (!HasCountdown || !_hasStarted || _remaining <= 0) return;
        _remaining -= 1;
        if (_remaining == 0)
        {
            // The activity is finished; let the user see that before it closes.
            Sounds.Play("Glass");
        }
        UpdateRing();
    }

    private void UpdateRing()
    {
        if (_ringLabel is not null) _ringLabel.Text = TimeString(_remaining);
        if (_ringSubLabel is not null)
        {
            _ringSubLabel.Text = _remaining > 0 ? "remaining" : "complete";
        }
        if (_doneButton is not null) _doneButton.Content = DoneButtonText();

        if (_ringProgress is null) return;
        var total = _reminder.ActivityDurationSeconds ?? 0;
        var progress = total > 0 ? 1.0 - ((double)_remaining / total) : 0.0;
        _ringProgress.Data = RingGeometry(progress);
    }

    /// <summary>
    /// The progress arc: starts at 12 o'clock, sweeps clockwise. 168px ring,
    /// 8px stroke, drawn on the stroke's centreline.
    /// </summary>
    private static Geometry RingGeometry(double progress)
    {
        const double center = 84;
        const double radius = 80;
        if (progress <= 0)
        {
            return Geometry.Empty;
        }
        if (progress >= 0.9999)
        {
            return new EllipseGeometry(new Point(center, center), radius, radius);
        }
        var angle = progress * 2 * Math.PI;
        var start = new Point(center, center - radius);
        var end = new Point(
            center + (radius * Math.Sin(angle)),
            center - (radius * Math.Cos(angle))
        );
        var geometry = new StreamGeometry();
        using (var context = geometry.Open())
        {
            context.BeginFigure(start, isFilled: false, isClosed: false);
            context.ArcTo(
                end, new Size(radius, radius), 0,
                isLargeArc: angle > Math.PI,
                SweepDirection.Clockwise,
                isStroked: true, isSmoothJoin: false
            );
        }
        geometry.Freeze();
        return geometry;
    }

    private static string TimeString(int seconds) => $"{seconds / 60}:{seconds % 60:D2}";
}
