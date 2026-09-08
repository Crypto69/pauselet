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
/// exercise reminder lists its exercises with Start and Skip on each — what
/// is done is working memory for the session, never persisted — above the
/// same buttons, and Start all runs the whole list in sequence.
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
    /// <summary>Set by <see cref="CloseOverlay"/>: the presenter is taking the window down.</summary>
    private bool _closeRequested;

    private int _remaining;
    private bool _hasStarted;
    private System.Windows.Shapes.Path? _ringProgress;
    private TextBlock? _ringLabel;
    private TextBlock? _ringSubLabel;
    private Button? _doneButton;
    private Button? _startAllButton;
    private TextBlock? _exerciseProgress;

    /// <summary>
    /// Shared with every other monitor's copy of this takeover; <c>null</c>
    /// for an ordinary reminder.
    /// </summary>
    private readonly ExerciseCoach? _coach;
    /// <summary>Per-exercise controls, so a change refreshes the right row.</summary>
    private readonly List<CoachRow> _coachRows = [];
    private Border? _coachPanel;
    private TextBlock? _coachHeadline;
    private TextBlock? _coachCaption;
    private TextBlock? _coachCountdown;
    private System.Windows.Shapes.Path? _coachRingProgress;
    private Button? _coachPauseButton;
    private Button? _coachSkipButton;
    private Button? _coachStopButton;
    private Button? _coachStartNextButton;
    private Button? _coachStartAllButton;

    /// <summary>The coach-driven controls belonging to one exercise row.</summary>
    private sealed record CoachRow(
        Guid Id, Border Row, TextBlock Glyph, Button Start, Button Cancel,
        TextBlock Caption, StackPanel Text);

    private bool HasCoach => _coach is not null;

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
    /// <summary>The row being coached: the Mac's teal wash at 14% over the row.</summary>
    private static readonly Brush RowActiveBrush =
        Theme.Brush(Color.FromArgb(36, 107, 217, 199));
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
        ExerciseCoach? coach,
        Action onComplete,
        Action onSnooze)
    {
        _reminder = reminder;
        _coach = coach;
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
        // PreviewKeyDown, not KeyDown: WPF's ButtonBase handles Space itself,
        // so once the Start pill has been clicked the coach's Space shortcut
        // would re-invoke that button instead — restarting the exercise the
        // user meant to pause. Tunnelling reaches the window first. (The Mac's
        // .keyboardShortcut(.space) is focus-independent for the same reason.)
        PreviewKeyDown += OnKeyDown;
        SourceInitialized += OnSourceInitialized;

        if (_coach is not null)
        {
            // Every monitor's window redraws from the one shared coach, so a
            // cue spoken once is reflected on all of them. A window built
            // around a coach mid-session (a monitor relayout) draws its
            // current state now rather than at the next tick — which, once a
            // run has completed, never comes.
            _coach.Changed += OnCoachChanged;
            OnCoachChanged();
        }

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
        _closeRequested = true;
        Close();
    }

    /// <summary>
    /// A close the presenter did not ask for — Alt+F4, a taskbar close — must
    /// not simply vanish: the presenter would still believe the takeover is
    /// up and queue every later critical reminder behind it for good. It is
    /// answered as a snooze, the acknowledgement that changes nothing, which
    /// takes every monitor's copy down through the normal path.
    /// </summary>
    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        if (!_closeRequested && !_acknowledged)
        {
            e.Cancel = true;
            Dispatcher.BeginInvoke(() => Acknowledge(_onSnooze));
            return;
        }
        base.OnClosing(e);
    }

    /// <summary>
    /// Timers and subscriptions end with the window however it went — a
    /// topmost timer re-pinning a dead HWND is otherwise the first symptom.
    /// </summary>
    protected override void OnClosed(EventArgs e)
    {
        _topmostTimer.Stop();
        _countdownTimer?.Stop();
        _countdownTimer = null;
        if (_coach is not null) _coach.Changed -= OnCoachChanged;
        base.OnClosed(e);
    }

    /// <summary>
    /// Moving the window onto a monitor with a different DPI makes WPF apply
    /// the system-suggested rect, undoing the physical bounds just set; pin
    /// them again at once rather than waiting for the 2 s timer.
    /// </summary>
    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        Dispatcher.BeginInvoke(() => PinToBounds(activate: false));
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
            case Key.Space when HasCoach:
                e.Handled = true;
                _coach?.PauseResumeOrStart();
                break;
            case Key.N when HasCoach:
                e.Handled = true;
                _coach?.Skip();
                break;
            case Key.X when HasCoach:
                e.Handled = true;
                _coach?.Stop();
                break;
            // Only while the Start all button is on offer — nothing running,
            // or the last run complete — as on the Mac; mid-run it would
            // silently throw the session away.
            case Key.A when _coach is { CanStartAll: true } coach
                && coach.Session is null or { State: ExerciseSession.SessionState.Completed }:
                e.Handled = true;
                coach.StartAll();
                break;
            case >= Key.D1 and <= Key.D9:
                e.Handled = StartExerciseRow(e.Key - Key.D1);
                break;
            case >= Key.NumPad1 and <= Key.NumPad9:
                e.Handled = StartExerciseRow(e.Key - Key.NumPad1);
                break;
        }
    }

    /// <summary>
    /// 1–9: the row's Start (or Again) pill — whatever the pill offers, the
    /// key does too. Only a row being coached is left alone.
    /// </summary>
    private bool StartExerciseRow(int index)
    {
        var exercises = _reminder.Exercises ?? [];
        if (_coach is null || index < 0 || index >= exercises.Count) return false;
        var id = exercises[index].Id;
        if (_coach.RowState(id) is ExerciseRowCoachState.Idle
            or ExerciseRowCoachState.Suggested
            or ExerciseRowCoachState.Cancelled
            or ExerciseRowCoachState.Completed)
        {
            _coach.Start(id);
        }
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
        // Done and Snooze both end the takeover: silence the coach before the
        // windows come down, so a cue cannot outlive the overlay that
        // prompted it.
        _coach?.ShutDown();
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

        var middle = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        if (HasCoach) middle.Children.Add(BuildCoachPanel());
        middle.Children.Add(BuildExerciseList(_reminder.Exercises ?? []));
        Grid.SetRow(middle, 1);
        layout.Children.Add(middle);

        var footer = BuildFooter(
            ringGap: 20, buttonsGap: HasCountdown ? 28 : 8,
            hint: "Return when you're done · S to snooze · A to start all · 1–9 to start a row · "
                + "Space to start or pause the coach · N next · X stop"
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
        var glyph = Ui.Glyph("play.circle.fill", 26, UntickedBrush);
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

        // A caption naming the phase while the row is being coached, so the
        // row itself says what is happening even when the panel above is off
        // the top of a scrolled list.
        var coachCaption = Ui.Text("", 14, IconBrush);
        coachCaption.Margin = new Thickness(0, 4, 0, 0);
        coachCaption.Visibility = Visibility.Collapsed;
        text.Children.Add(coachCaption);

        var badge = Ui.Text((index + 1).ToString(), 12, BadgeBrush);
        badge.VerticalAlignment = VerticalAlignment.Top;
        badge.Margin = new Thickness(16, 4, 0, 0);

        // Start and Skip in the row's trailing edge. Their widths are fixed so
        // the rows' names all wrap at the same place — the narrow-row problem
        // iOS hit, solved here by a 700pt row having the space to spare.
        var id = exercise.Id;
        var startPill = Ui.RoundedButton(
            "Start", SecondaryButtonBrush, Brushes.White, SecondaryButtonBorderBrush,
            cornerRadius: 9, padding: new Thickness(12, 5, 12, 5), minWidth: 74);
        startPill.Click += (_, _) => _coach?.Start(id);
        System.Windows.Automation.AutomationProperties.SetName(startPill, $"Start {exercise.Name}");
        var cancelPill = Ui.RoundedButton(
            "Skip", SecondaryButtonBrush, Brushes.White, SecondaryButtonBorderBrush,
            cornerRadius: 9, padding: new Thickness(12, 5, 12, 5), minWidth: 74);
        cancelPill.Click += (_, _) => _coach?.Cancel(id);
        cancelPill.Margin = new Thickness(8, 0, 0, 0);
        System.Windows.Automation.AutomationProperties.SetName(cancelPill, $"Skip {exercise.Name}");
        var pills = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(16, 0, 0, 0),
        };
        pills.Children.Add(startPill);
        pills.Children.Add(cancelPill);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(
            new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }
        );
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(glyph);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        Grid.SetColumn(pills, 2);
        grid.Children.Add(pills);
        Grid.SetColumn(badge, 3);
        grid.Children.Add(badge);

        var row = new Border
        {
            Background = RowBrush,
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(18, 12, 18, 12),
            Margin = new Thickness(0, 0, 0, 10),
            Child = grid,
        };
        System.Windows.Automation.AutomationProperties.SetName(
            row, $"{exercise.Name}, {exercise.Sets} sets of {exercise.Reps}"
        );

        var coachRow = new CoachRow(id, row, glyph, startPill, cancelPill, coachCaption, text);
        _coachRows.Add(coachRow);
        UpdateCoachRow(coachRow);
        return row;
    }

    /// <summary>"2 of 5 done", plus the cancelled tally once there is one.</summary>
    private void UpdateExerciseProgress()
    {
        if (_exerciseProgress is null || _coach is null) return;
        var total = (_reminder.Exercises ?? []).Count;
        var cancelled = _coach.CancelledExerciseIds.Count;
        _exerciseProgress.Text = $"{_coach.CompletedExerciseIds.Count} of {total} done"
            + (cancelled > 0 ? $" · {cancelled} cancelled" : "");
    }

    // MARK: - Coach

    /// <summary>
    /// The countdown panel above the list: what phase is running, how long is
    /// left of it, and the three controls. Hidden until an exercise is
    /// started, since there is nothing to count before then.
    /// </summary>
    private UIElement BuildCoachPanel()
    {
        var body = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };

        // The ring, with the seconds inside it — the same shape as the
        // activity countdown, at the size a phase needs.
        var ring = new Grid { Width = 118, Height = 118 };
        ring.Children.Add(new System.Windows.Shapes.Ellipse
        {
            Stroke = RingTrackBrush,
            StrokeThickness = 7,
            Margin = new Thickness(3),
        });
        _coachRingProgress = new System.Windows.Shapes.Path
        {
            Stroke = RingBrush,
            StrokeThickness = 7,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
        };
        ring.Children.Add(_coachRingProgress);
        _coachCountdown = Ui.Text("", 34, Brushes.White, FontWeights.SemiBold, TextAlignment.Center);
        _coachCountdown.HorizontalAlignment = HorizontalAlignment.Center;
        _coachCountdown.VerticalAlignment = VerticalAlignment.Center;
        ring.Children.Add(_coachCountdown);
        body.Children.Add(ring);

        _coachHeadline = Ui.Text(
            "", 22, Brushes.White, FontWeights.Medium, TextAlignment.Center);
        _coachHeadline.HorizontalAlignment = HorizontalAlignment.Center;
        _coachHeadline.Margin = new Thickness(0, 12, 0, 0);
        body.Children.Add(_coachHeadline);

        _coachCaption = Ui.Text("", 15, IconBrush, alignment: TextAlignment.Center);
        _coachCaption.HorizontalAlignment = HorizontalAlignment.Center;
        _coachCaption.Margin = new Thickness(0, 4, 0, 0);
        body.Children.Add(_coachCaption);

        var controls = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 14, 0, 0),
        };
        _coachPauseButton = CoachButton("Pause", () => _coach?.TogglePause());
        controls.Children.Add(_coachPauseButton);
        _coachSkipButton = CoachButton("Skip", () => _coach?.Skip());
        controls.Children.Add(_coachSkipButton);
        _coachStopButton = CoachButton("Stop", () => _coach?.Stop());
        controls.Children.Add(_coachStopButton);
        // Once the session has run its course: what to do next, if anything.
        _coachStartNextButton = CoachButton("Start next", () => _coach?.StartSuggested());
        _coachStartNextButton.Visibility = Visibility.Collapsed;
        controls.Children.Add(_coachStartNextButton);
        _coachStartAllButton = CoachButton("Start all", () => _coach?.StartAll());
        _coachStartAllButton.Visibility = Visibility.Collapsed;
        controls.Children.Add(_coachStartAllButton);
        body.Children.Add(controls);

        _coachPanel = new Border
        {
            Background = RowBrush,
            CornerRadius = new CornerRadius(18),
            Padding = new Thickness(28, 20, 28, 20),
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 0, 0, 18),
            Visibility = Visibility.Collapsed,
            Child = body,
        };
        return _coachPanel;
    }

    private Button CoachButton(string label, Action onClick)
    {
        var button = Ui.RoundedButton(
            label, SecondaryButtonBrush, Brushes.White, SecondaryButtonBorderBrush,
            padding: new Thickness(16, 7, 16, 7), minWidth: 92);
        button.Margin = new Thickness(6, 0, 6, 0);
        button.Click += (_, _) => onClick();
        return button;
    }

    /// <summary>
    /// Redraws everything the coach owns: the panel, the ring, the Start all
    /// button and each row's pills and caption. Called on every tick of the
    /// shared coach.
    /// </summary>
    private void OnCoachChanged()
    {
        if (_coach is null) return;
        var session = _coach.Session;

        if (_coachPanel is not null)
        {
            _coachPanel.Visibility = session is not null ? Visibility.Visible : Visibility.Collapsed;
        }
        if (_startAllButton is not null)
        {
            _startAllButton.Visibility = session is null && _coach.CanStartAll
                ? Visibility.Visible
                : Visibility.Collapsed;
        }
        var isComplete = session is { State: ExerciseSession.SessionState.Completed };
        SetVisible(_coachPauseButton, !isComplete);
        SetVisible(_coachSkipButton, !isComplete);
        SetVisible(_coachStopButton, !isComplete);
        SetVisible(_coachStartNextButton, isComplete && _coach.SuggestedExerciseId is not null);
        SetVisible(_coachStartAllButton, isComplete && _coach.CanStartAll);

        if (isComplete && session is not null)
        {
            if (_coachHeadline is not null) _coachHeadline.Text = session.Timeline.CompletionTitle;
            if (_coachCaption is not null) _coachCaption.Text = "done";
            if (_coachCountdown is not null) _coachCountdown.Text = SymbolMap.Glyph("checkmark.circle.fill");
            if (_coachRingProgress is not null) _coachRingProgress.Data = RingGeometry(1, 118, 7);
        }
        else if (session is not null && session.PhaseAt(_coach.Now) is { } phase)
        {
            var position = session.PositionAt(_coach.Now);
            if (_coachHeadline is not null) _coachHeadline.Text = phase.Title;
            if (_coachCaption is not null)
            {
                var caption = $"{phase.ExerciseName} · {phase.Label}";
                _coachCaption.Text =
                    session.State == ExerciseSession.SessionState.Paused
                        ? $"Paused · {caption}"
                        : caption;
            }
            if (_coachCountdown is not null)
            {
                // Ceiling, so the last whole second reads "1" rather than "0"
                // while it is still being held.
                _coachCountdown.Text = Math.Max(0, (int)Math.Ceiling(position.Remaining))
                    .ToString();
            }
            if (_coachRingProgress is not null)
            {
                // Draining, like the activity ring: full at the phase start.
                _coachRingProgress.Data = RingGeometry(
                    Math.Clamp(1 - position.Progress, 0, 1), 118, 7);
            }
            if (_coachPauseButton is not null)
            {
                _coachPauseButton.Content =
                    session.State == ExerciseSession.SessionState.Paused ? "Resume" : "Pause";
            }
        }

        foreach (var row in _coachRows) UpdateCoachRow(row);
        UpdateExerciseProgress();
    }

    private static void SetVisible(UIElement? element, bool visible)
    {
        if (element is not null)
        {
            element.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    /// <summary>
    /// One row's presentation: its glyph and wash, which pills it shows,
    /// whether its text is dimmed, and the caption naming the phase while it
    /// is being coached.
    /// </summary>
    private void UpdateCoachRow(CoachRow row)
    {
        if (_coach is null) return;
        var state = _coach.RowState(row.Id);
        var caption = _coach.RowCaption(row.Id);

        row.Caption.Text = caption ?? "";
        row.Caption.Visibility = caption is null ? Visibility.Collapsed : Visibility.Visible;

        row.Glyph.Text = SymbolMap.Glyph(state switch
        {
            ExerciseRowCoachState.Completed => "checkmark.circle.fill",
            ExerciseRowCoachState.Cancelled => "circle",
            ExerciseRowCoachState.Active => "timer",
            _ => "play.circle.fill",
        });
        row.Glyph.Foreground = state is ExerciseRowCoachState.Completed or ExerciseRowCoachState.Active
            ? RingBrush
            : UntickedBrush;
        row.Row.Background = state switch
        {
            ExerciseRowCoachState.Active => RowActiveBrush,
            ExerciseRowCoachState.Completed or ExerciseRowCoachState.Cancelled => RowDoneBrush,
            _ => RowBrush,
        };

        row.Start.Visibility =
            state == ExerciseRowCoachState.Active ? Visibility.Collapsed : Visibility.Visible;
        row.Start.Content = state == ExerciseRowCoachState.Completed ? "Again" : "Start";
        // The suggested row is the one Space starts, so it is the one that
        // looks pressable.
        row.Start.Background = state == ExerciseRowCoachState.Suggested
            ? PrimaryButtonBrush
            : SecondaryButtonBrush;
        row.Start.Foreground = state == ExerciseRowCoachState.Suggested
            ? PrimaryButtonTextBrush
            : Brushes.White;

        // Cancel is for a row that is waiting or being coached ("not this
        // one" hands the run over to the next); a done or cancelled row has
        // nothing to cancel.
        row.Cancel.Visibility = state is ExerciseRowCoachState.Idle
            or ExerciseRowCoachState.Suggested
            or ExerciseRowCoachState.Active
            ? Visibility.Visible
            : Visibility.Collapsed;

        row.Text.Opacity = state switch
        {
            ExerciseRowCoachState.Completed or ExerciseRowCoachState.Cancelled => 0.5,
            _ => 1,
        };
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

        // Runs every exercise still to do, in order, with the reminder's rest
        // between them. Only offered while nothing is running and there are
        // two or more left; OnCoachChanged keeps that current.
        _startAllButton = Ui.RoundedButton(
            "Start all", SecondaryButtonBrush, Brushes.White,
            SecondaryButtonBorderBrush, minWidth: 148
        );
        _startAllButton.Margin = new Thickness(0, 0, 14, 0);
        _startAllButton.Click += (_, _) => _coach?.StartAll();
        _startAllButton.Visibility = _coach is { Session: null, CanStartAll: true }
            ? Visibility.Visible
            : Visibility.Collapsed;
        row.Children.Add(_startAllButton);

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
        if (_remaining == 0 && IsPrimaryScreen)
        {
            // The activity is finished; let the user see that before it
            // closes. Every monitor's window counts, one of them chimes.
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
        _ringProgress.Data = RingGeometry(progress, 168, 8);
    }

    /// <summary>
    /// The progress arc: starts at 12 o'clock, sweeps clockwise, drawn on the
    /// stroke's centreline. Sized per ring — the activity countdown is 168px
    /// with an 8px stroke, the coach's phase ring smaller.
    /// </summary>
    private static Geometry RingGeometry(double progress, double size, double stroke)
    {
        var center = size / 2;
        var radius = center - (stroke / 2);
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
