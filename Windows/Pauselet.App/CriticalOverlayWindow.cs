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
/// which turns "stop working" into a concrete, finite thing to do. An
/// exercise reminder lists its exercises with a tick box each — working
/// memory for the session, never persisted — above the same buttons.
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
    private readonly List<System.Windows.Controls.Primitives.ToggleButton> _exerciseToggles = [];
    private TextBlock? _exerciseProgress;

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
    private static readonly Brush RowBrush =
        Theme.Brush(Color.FromArgb(20, 255, 255, 255));
    private static readonly Brush RowDoneBrush =
        Theme.Brush(Color.FromArgb(10, 255, 255, 255));
    private static readonly Brush UntickedBrush =
        Theme.Brush(Color.FromArgb(102, 255, 255, 255));
    private static readonly Brush InstructionsBrush =
        Theme.Brush(Color.FromArgb(160, 255, 255, 255));
    private static readonly Brush BadgeBrush =
        Theme.Brush(Color.FromArgb(90, 255, 255, 255));

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
            case >= Key.D1 and <= Key.D9:
                e.Handled = ToggleExercise(e.Key - Key.D1);
                break;
            case >= Key.NumPad1 and <= Key.NumPad9:
                e.Handled = ToggleExercise(e.Key - Key.NumPad1);
                break;
        }
    }

    private bool ToggleExercise(int index)
    {
        if (index < 0 || index >= _exerciseToggles.Count) return false;
        var toggle = _exerciseToggles[index];
        toggle.IsChecked = toggle.IsChecked != true;
        return true;
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
        var root = BuildBackdrop();
        root.Children.Add(_reminder.IsExercise ? BuildExerciseLayout() : BuildPlainLayout());
        return root;
    }

    /// <summary>
    /// A deep, soft backdrop rather than a harsh alert colour — near-opaque
    /// so it dims the desktop instead of blanking it.
    /// </summary>
    private static Grid BuildBackdrop() => new()
    {
        Background = new LinearGradientBrush(
            Color.FromArgb(247, 10, 23, 28),
            Color.FromArgb(250, 5, 13, 18),
            90
        ),
        Focusable = true,
    };

    /// <summary>The ordinary reminder: one centred stack, header over footer.</summary>
    private UIElement BuildPlainLayout()
    {
        var stack = new StackPanel
        {
            Orientation = Orientation.Vertical,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        stack.Children.Add(BuildHeader(
            iconSize: 72, iconGap: 34, titleSize: 46,
            messageSize: 21, messageLineHeight: 30, messageGap: 14
        ));
        stack.Children.Add(BuildFooter(
            ringGap: 34, buttonsGap: 38,
            hint: "Press Return when you're done · S to snooze"
        ));
        return stack;
    }

    /// <summary>
    /// The exercise reminder: a tighter header, the list in the middle taking
    /// whatever height is left (scrolling when it runs out), and the footer
    /// pinned beneath.
    /// </summary>
    private UIElement BuildExerciseLayout()
    {
        var layout = new Grid
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            MaxWidth = 760,
            Margin = new Thickness(0, 48, 0, 40),
        };
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(
            new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }
        );
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var header = BuildHeader(
            iconSize: 56, iconGap: 20, titleSize: 38,
            messageSize: 18, messageLineHeight: 26, messageGap: 10
        );
        Grid.SetRow(header, 0);
        layout.Children.Add(header);

        var scroller = BuildExerciseList(_reminder.Exercises ?? []);
        Grid.SetRow(scroller, 1);
        layout.Children.Add(scroller);

        var footer = BuildFooter(
            ringGap: 20, buttonsGap: HasCountdown ? 28 : 8,
            hint: "Press Return when you're done · S to snooze · 1–9 to tick an exercise"
        );
        Grid.SetRow(footer, 2);
        layout.Children.Add(footer);

        return layout;
    }

    /// <summary>Icon, title and (if any) message, sized for the layout.</summary>
    private StackPanel BuildHeader(
        double iconSize, double iconGap, double titleSize,
        double messageSize, double messageLineHeight, double messageGap)
    {
        var header = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };

        var icon = Ui.Glyph(_reminder.SymbolName, iconSize, IconBrush);
        icon.Margin = new Thickness(0, 0, 0, iconGap);
        header.Children.Add(icon);

        var title = Ui.Text(
            _reminder.Title, titleSize, Brushes.White,
            FontWeights.SemiBold, TextAlignment.Center
        );
        title.HorizontalAlignment = HorizontalAlignment.Center;
        header.Children.Add(title);

        if (_reminder.Message.Length > 0)
        {
            var message = Ui.Text(
                _reminder.Message, messageSize,
                Theme.Brush(Color.FromArgb(194, 255, 255, 255)),
                alignment: TextAlignment.Center
            );
            message.MaxWidth = 620;
            message.LineHeight = messageLineHeight;
            message.Margin = new Thickness(0, messageGap, 0, 0);
            message.HorizontalAlignment = HorizontalAlignment.Center;
            header.Children.Add(message);
        }
        return header;
    }

    /// <summary>The countdown ring (if any), the buttons, and the key hint.</summary>
    private StackPanel BuildFooter(double ringGap, double buttonsGap, string hint)
    {
        var footer = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        if (HasCountdown)
        {
            var ring = (FrameworkElement)BuildCountdownRing();
            ring.Margin = new Thickness(0, ringGap, 0, 0);
            footer.Children.Add(ring);
        }
        var buttons = (FrameworkElement)BuildButtons();
        buttons.Margin = new Thickness(0, buttonsGap, 0, 0);
        footer.Children.Add(buttons);

        var hintText = Ui.Text(
            hint, 12,
            Theme.Brush(Color.FromArgb(97, 255, 255, 255)),
            alignment: TextAlignment.Center
        );
        hintText.Margin = new Thickness(0, 20, 0, 0);
        hintText.HorizontalAlignment = HorizontalAlignment.Center;
        footer.Children.Add(hintText);
        return footer;
    }

    /// <summary>
    /// The exercise rows with a progress caption, in a scroller that takes
    /// whatever height its grid row has.
    /// </summary>
    private ScrollViewer BuildExerciseList(IReadOnlyList<Exercise> exercises)
    {
        var list = new StackPanel { Width = 700 };
        _exerciseProgress = Ui.Text(
            "", 13, Theme.Brush(Color.FromArgb(128, 255, 255, 255)),
            alignment: TextAlignment.Center
        );
        _exerciseProgress.Margin = new Thickness(0, 0, 0, 14);
        list.Children.Add(_exerciseProgress);
        for (var i = 0; i < exercises.Count; i++)
        {
            list.Children.Add(BuildExerciseRow(exercises[i], i));
        }
        UpdateExerciseProgress();

        // Wide enough for a scrollbar on either side of the rows. When the
        // bar appears it takes its width from the right of the viewport,
        // which would leave the rows off-centre from the title above; a
        // matching left margin on the list cancels that, and comes off again
        // when the list fits.
        var scrollBarWidth = SystemParameters.VerticalScrollBarWidth;
        var scroller = new ScrollViewer
        {
            Content = list,
            Width = 700 + (2 * scrollBarWidth),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 28, 0, 0),
            Focusable = false,
        };
        scroller.ScrollChanged += (_, _) =>
        {
            var barShown = scroller.ComputedVerticalScrollBarVisibility == Visibility.Visible;
            list.Margin = new Thickness(barShown ? scrollBarWidth : 0, 0, 0, 0);
        };
        return scroller;
    }

    private UIElement BuildExerciseRow(Exercise exercise, int index)
    {
        var glyph = Ui.Glyph("circle", 26, UntickedBrush);
        glyph.VerticalAlignment = VerticalAlignment.Top;
        glyph.Margin = new Thickness(0, 1, 16, 0);

        var text = new StackPanel();
        var line = new StackPanel { Orientation = Orientation.Horizontal };
        line.Children.Add(Ui.Text(exercise.Name, 21, Brushes.White, FontWeights.Medium));
        var summary = Ui.Text(exercise.Summary, 16, IconBrush);
        summary.Margin = new Thickness(12, 4, 0, 0);
        line.Children.Add(summary);
        text.Children.Add(line);
        if (exercise.Instructions.Length > 0)
        {
            var instructions = Ui.Text(exercise.Instructions, 15, InstructionsBrush);
            instructions.LineHeight = 22;
            instructions.Margin = new Thickness(0, 4, 0, 0);
            text.Children.Add(instructions);
        }

        var badge = Ui.Text((index + 1).ToString(), 12, BadgeBrush);
        badge.VerticalAlignment = VerticalAlignment.Top;
        badge.Margin = new Thickness(16, 4, 0, 0);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(
            new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }
        );
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(glyph);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        Grid.SetColumn(badge, 2);
        grid.Children.Add(badge);

        var toggle = Ui.RoundedToggle(grid, RowBrush, 14, new Thickness(18, 12, 18, 12));
        toggle.Margin = new Thickness(0, 0, 0, 10);
        toggle.Checked += (_, _) =>
        {
            glyph.Text = SymbolMap.Glyph("checkmark.circle.fill");
            glyph.Foreground = RingBrush;
            text.Opacity = 0.5;
            toggle.Background = RowDoneBrush;
            UpdateExerciseProgress();
        };
        toggle.Unchecked += (_, _) =>
        {
            glyph.Text = SymbolMap.Glyph("circle");
            glyph.Foreground = UntickedBrush;
            text.Opacity = 1;
            toggle.Background = RowBrush;
            UpdateExerciseProgress();
        };
        System.Windows.Automation.AutomationProperties.SetName(
            toggle, $"{exercise.Name}, {exercise.Sets} sets of {exercise.Reps}"
        );
        _exerciseToggles.Add(toggle);
        return toggle;
    }

    private void UpdateExerciseProgress()
    {
        if (_exerciseProgress is null) return;
        var done = _exerciseToggles.Count(toggle => toggle.IsChecked == true);
        _exerciseProgress.Text = $"{done} of {_exerciseToggles.Count} done";
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
