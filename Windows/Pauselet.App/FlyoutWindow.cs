using NodaTime;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// The tray flyout — the Windows counterpart of the Mac menu bar popover.
///
/// This is the everyday surface: see what is coming, mark something done,
/// pause for a while. Editing lives in the settings window rather than here.
/// Transient like the popover: it closes the moment it loses focus.
/// </summary>
internal sealed class FlyoutWindow : Window
{
    private readonly ReminderEngine _engine;
    private readonly Action _openSettings;
    private readonly Action _quit;
    private readonly DispatcherTimer _ticker;
    private readonly DateTimeZone _zone = DateTimeZoneProviders.Tzdb.GetSystemDefault();

    private readonly StackPanel _root;

    public FlyoutWindow(ReminderEngine engine, Action openSettings, Action quit)
    {
        _engine = engine;
        _openSettings = openSettings;
        _quit = quit;

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        Width = 380;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.Manual;

        _root = new StackPanel { Orientation = Orientation.Vertical };
        Content = BuildChrome(_root);
        Rebuild();

        // Bottom-right of the work area, next to the (default bottom-docked)
        // taskbar's tray corner.
        Loaded += (_, _) => PositionNearTray();

        // Transient, like the Mac popover — but deactivation also fires while
        // the window is already closing (closing is what deactivates it), and
        // WPF throws on Close-during-Close. Every close goes through the
        // guarded path.
        Deactivated += (_, _) => CloseSafely();
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) CloseSafely();
        };

        // Drives the countdown text without the engine having to publish per
        // second.
        _ticker = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _ticker.Tick += (_, _) => Rebuild();
        _ticker.Start();
        Closed += (_, _) => _ticker.Stop();
    }

    private bool _isClosing;

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        _isClosing = true;
        base.OnClosing(e);
    }

    /// <summary>Closes unless a close is already underway; safe to call repeatedly.</summary>
    public void CloseSafely()
    {
        if (_isClosing) return;
        _isClosing = true;
        Close();
    }

    private void PositionNearTray()
    {
        var workArea = SystemParameters.WorkArea;
        Left = workArea.Right - Width - 12;
        Top = workArea.Bottom - ActualHeight - 12;
    }

    private UIElement BuildChrome(UIElement content)
    {
        var palette = Theme.Current;
        return new Border
        {
            Background = Theme.Brush(palette.CardBackground),
            BorderBrush = Theme.Brush(palette.Divider),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Margin = new Thickness(8, 8, 8, 8),
            Child = content,
            Effect = new DropShadowEffect
            {
                BlurRadius = 18,
                ShadowDepth = 4,
                Direction = 270,
                Opacity = 0.25,
                Color = Colors.Black,
            },
        };
    }

    private void Rebuild()
    {
        var palette = Theme.Current;
        var now = SystemClock.Instance.GetCurrentInstant();
        var isPaused = Scheduler.IsPaused(_engine.Settings, now);

        _root.Children.Clear();
        _root.Children.Add(BuildHeader(palette, now, isPaused));
        _root.Children.Add(Divider(palette));
        _root.Children.Add(BuildList(palette, now, isPaused));
        _root.Children.Add(Divider(palette));
        _root.Children.Add(BuildFooter(palette));
        // A row count change (toggle, delete elsewhere) changes our height.
        if (IsLoaded) PositionNearTray();
    }

    private static Border Divider(Theme.Palette palette) => new()
    {
        Height = 1,
        Background = Theme.Brush(palette.Divider),
    };

    private UIElement BuildHeader(Theme.Palette palette, Instant now, bool isPaused)
    {
        var grid = new Grid { Margin = new Thickness(16, 13, 16, 13) };
        grid.ColumnDefinitions.Add(
            new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }
        );
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var stack = new StackPanel();
        stack.Children.Add(Ui.Text(
            isPaused ? "Paused" : "Next up", 11,
            Theme.Brush(palette.SecondaryForeground)
        ));

        if (isPaused)
        {
            var until = _engine.Settings.PausedUntil;
            var text = until is { } resume
                ? $"Resumes in {Scheduler.CountdownText(now, resume)}"
                : "All reminders";
            stack.Children.Add(Ui.Text(
                text, 15, Theme.Brush(palette.Foreground), FontWeights.Medium
            ));
        }
        else if (_engine.NextUp is { } next)
        {
            var line = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Margin = new Thickness(0, 2, 0, 0),
            };
            var glyph = Ui.Glyph(next.Reminder.SymbolName, 14, Theme.Brush(palette.Accent));
            glyph.Margin = new Thickness(0, 0, 6, 0);
            line.Children.Add(glyph);
            line.Children.Add(Ui.Text(
                next.Reminder.Title, 15, Theme.Brush(palette.Foreground), FontWeights.Medium
            ));
            line.Children.Add(Ui.Text(
                $" · {Scheduler.CountdownText(now, next.Date)}", 13,
                Theme.Brush(palette.SecondaryForeground)
            ));
            stack.Children.Add(line);
        }
        else
        {
            stack.Children.Add(Ui.Text(
                "Nothing scheduled", 15,
                Theme.Brush(palette.SecondaryForeground), FontWeights.Medium
            ));
        }
        grid.Children.Add(stack);

        var pauseButton = Ui.IconButton(
            Ui.Glyph(isPaused ? "play.circle.fill" : "pause.circle", 21,
                Theme.Brush(isPaused ? palette.Accent : palette.SecondaryForeground)),
            tooltip: isPaused ? "Resume reminders" : "Pause reminders"
        );
        pauseButton.Click += (_, _) =>
        {
            if (Scheduler.IsPaused(_engine.Settings, SystemClock.Instance.GetCurrentInstant()))
            {
                _engine.Resume();
            }
            else
            {
                _engine.SetPaused(true);
            }
            Rebuild();
        };
        Grid.SetColumn(pauseButton, 1);
        grid.Children.Add(pauseButton);

        return grid;
    }

    private UIElement BuildList(Theme.Palette palette, Instant now, bool isPaused)
    {
        var list = new StackPanel();

        if (_engine.Reminders.Count == 0)
        {
            var empty = new StackPanel
            {
                Margin = new Thickness(0, 44, 0, 44),
                HorizontalAlignment = HorizontalAlignment.Center,
            };
            var bell = Ui.Glyph("bell.slash", 30, Theme.Brush(palette.TertiaryForeground));
            bell.Margin = new Thickness(0, 0, 0, 10);
            empty.Children.Add(bell);
            var line1 = Ui.Text(
                "No reminders yet", 14, Theme.Brush(palette.Foreground), FontWeights.Medium
            );
            line1.HorizontalAlignment = HorizontalAlignment.Center;
            empty.Children.Add(line1);
            var line2 = Ui.Text(
                "Add one in Settings to get started.", 11,
                Theme.Brush(palette.SecondaryForeground)
            );
            line2.HorizontalAlignment = HorizontalAlignment.Center;
            empty.Children.Add(line2);
            list.Children.Add(empty);
        }
        else
        {
            var sorted = _engine.Reminders
                .Select(reminder =>
                    (Reminder: reminder, Next: Scheduler.NextFireDate(reminder, now, _zone)))
                .OrderBy(entry => entry.Next is null)
                .ThenBy(entry => entry.Next ?? Instant.MaxValue)
                .ThenBy(entry => entry.Reminder.Title, StringComparer.Ordinal)
                .ToList();

            foreach (var entry in sorted)
            {
                list.Children.Add(BuildRow(palette, entry.Reminder, entry.Next, now, isPaused));
                var divider = Divider(palette);
                divider.Margin = new Thickness(46, 0, 0, 0);
                list.Children.Add(divider);
            }
        }

        return new ScrollViewer
        {
            Content = list,
            MaxHeight = 340,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
    }

    private UIElement BuildRow(
        Theme.Palette palette, Reminder reminder, Instant? next, Instant now, bool isPaused)
    {
        var grid = new Grid { Margin = new Thickness(16, 9, 16, 9) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(
            new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }
        );
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var glyph = Ui.Glyph(
            reminder.SymbolName, 15,
            Theme.Brush(reminder.IsEnabled ? palette.Accent : palette.TertiaryForeground)
        );
        glyph.Width = 22;
        glyph.Margin = new Thickness(0, 0, 12, 0);
        grid.Children.Add(glyph);

        var textStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        textStack.Children.Add(Ui.Text(
            reminder.Title, 13,
            Theme.Brush(reminder.IsEnabled ? palette.Foreground : palette.SecondaryForeground),
            FontWeights.Medium
        ));
        var detail = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 2, 0, 0),
        };
        detail.Children.Add(new System.Windows.Shapes.Ellipse
        {
            Width = 6,
            Height = 6,
            Fill = PriorityBrush(reminder.Priority, palette),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 5, 0),
            ToolTip = reminder.Priority.DisplayName(),
        });
        var detailText = Ui.Text(
            reminder.ScheduleLine, 11, Theme.Brush(palette.SecondaryForeground)
        );
        detailText.TextTrimming = TextTrimming.CharacterEllipsis;
        detailText.TextWrapping = TextWrapping.NoWrap;
        detail.Children.Add(detailText);
        textStack.Children.Add(detail);
        Grid.SetColumn(textStack, 1);
        grid.Children.Add(textStack);

        if (reminder.IsEnabled && next is { } nextDate)
        {
            var isOverdue = !isPaused && nextDate <= now;
            var countdown = Ui.Text(
                isOverdue ? "due" : Scheduler.CountdownText(now, nextDate), 11,
                isOverdue
                    ? Theme.Brush(Color.FromRgb(0xE8, 0x8A, 0x2E))
                    : Theme.Brush(palette.SecondaryForeground),
                FontWeights.Medium, TextAlignment.Right
            );
            countdown.MinWidth = 44;
            countdown.VerticalAlignment = VerticalAlignment.Center;
            countdown.Margin = new Thickness(4, 0, 8, 0);
            Grid.SetColumn(countdown, 2);
            grid.Children.Add(countdown);
        }

        if (reminder.IsEnabled)
        {
            // Completing from here is the fast path for "I already did that".
            var complete = Ui.IconButton(
                Ui.Glyph("checkmark.circle", 15, Theme.Brush(palette.SecondaryForeground)),
                tooltip: "Mark as done now"
            );
            complete.Click += (_, _) =>
            {
                _engine.Complete(reminder.Id);
                Rebuild();
            };
            complete.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(complete, 3);
            grid.Children.Add(complete);
        }

        var toggle = new CheckBox
        {
            IsChecked = reminder.IsEnabled,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0, 0, 0),
            ToolTip = reminder.IsEnabled ? "Turn off" : "Turn on",
        };
        toggle.Click += (_, _) =>
        {
            _engine.SetEnabled(toggle.IsChecked == true, reminder.Id);
            Rebuild();
        };
        Grid.SetColumn(toggle, 4);
        grid.Children.Add(toggle);

        return grid;
    }

    private static Brush PriorityBrush(Priority priority, Theme.Palette palette) =>
        priority switch
        {
            Priority.Subtle => Theme.Brush(palette.SecondaryForeground),
            Priority.Normal => Theme.Brush(Color.FromRgb(0x3B, 0x82, 0xF6)),
            Priority.Important => Theme.Brush(Color.FromRgb(0xE8, 0x8A, 0x2E)),
            Priority.Critical => Theme.Brush(Color.FromRgb(0xE0, 0x4F, 0x4F)),
            _ => Brushes.Gray,
        };

    private UIElement BuildFooter(Theme.Palette palette)
    {
        var grid = new Grid { Margin = new Thickness(16, 10, 16, 10) };
        grid.ColumnDefinitions.Add(
            new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }
        );
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var settings = Ui.RoundedButton(
            "Settings", Brushes.Transparent, Theme.Brush(palette.SecondaryForeground),
            cornerRadius: 6, padding: new Thickness(6, 3, 6, 3)
        );
        settings.FontSize = 12;
        settings.HorizontalAlignment = HorizontalAlignment.Left;
        settings.Click += (_, _) =>
        {
            CloseSafely();
            _openSettings();
        };
        grid.Children.Add(settings);

        var quit = Ui.RoundedButton(
            "Quit", Brushes.Transparent, Theme.Brush(palette.SecondaryForeground),
            cornerRadius: 6, padding: new Thickness(6, 3, 6, 3)
        );
        quit.FontSize = 12;
        quit.Click += (_, _) => _quit();
        Grid.SetColumn(quit, 1);
        grid.Children.Add(quit);

        return grid;
    }
}
