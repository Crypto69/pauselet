using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// The small corner card shown for Subtle reminders — and, with a sticky
/// minimum duration, the fallback surface when a toast cannot be delivered.
///
/// This is the every-20-minutes weight shift: it must register without
/// hijacking attention, so it is quiet, small, disappears on its own, and —
/// via WS_EX_NOACTIVATE — never steals keyboard focus from what the user is
/// typing into. It stays clickable: the checkmark marks the reminder done.
///
/// The same card carries a Critical reminder's advance warning: given
/// <c>warning</c> text and no display time, it shows that text in the
/// Critical colour and stays until its tick is clicked.
/// </summary>
internal sealed class SubtleCardWindow : Window
{
    private readonly Action _onComplete;
    private readonly Action _onTimedOut;
    private readonly DispatcherTimer? _dismissTimer;
    private bool _closing;

    /// <param name="displaySeconds">
    /// How long before the card dismisses itself; <c>null</c> keeps it until
    /// the tick is clicked.
    /// </param>
    /// <param name="warning">Title and message replacing the reminder's own.</param>
    public SubtleCardWindow(
        Reminder reminder, int? displaySeconds, Action onComplete, Action onTimedOut,
        (string Title, string Message)? warning = null)
    {
        _onComplete = onComplete;
        _onTimedOut = onTimedOut;

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = false;
        Focusable = false;
        Width = 330;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.Manual;

        // Top-right of the primary work area, near where the tray lives on a
        // top-docked bar — and out of the way of the bottom-docked default.
        var workArea = SystemParameters.WorkArea;
        Left = workArea.Right - Width - 16;
        Top = workArea.Top + 16;

        Content = BuildContent(reminder, warning);

        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            // Never activate, never appear in Alt-Tab.
            NativeMethods.AddExStyle(
                handle, NativeMethods.WS_EX_NOACTIVATE | NativeMethods.WS_EX_TOOLWINDOW
            );
        };

        Opacity = 0;
        Loaded += (_, _) =>
        {
            BeginAnimation(
                OpacityProperty,
                new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(250))
            );
        };

        if (displaySeconds is { } seconds)
        {
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                _onTimedOut();
            };
            timer.Start();
            _dismissTimer = timer;
        }
    }

    /// <summary>Fades out and closes; safe to call more than once.</summary>
    public void CloseCard()
    {
        if (_closing) return;
        _closing = true;
        _dismissTimer?.Stop();
        var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(200));
        fade.Completed += (_, _) => Close();
        BeginAnimation(OpacityProperty, fade);
    }

    private UIElement BuildContent(Reminder reminder, (string Title, string Message)? warning)
    {
        var palette = Theme.Current;

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(
            new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }
        );
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        // The tier's colour, matching the reminder's dot in the flyout: this
        // card also stands in for Normal and Important when a toast fails.
        // A warning takes the Critical colour: that is what is coming.
        var tier = Theme.PriorityColor(warning is null ? reminder.Priority : Priority.Critical);
        var titleText = warning?.Title ?? reminder.Title;
        var messageText = warning?.Message ?? reminder.Message;
        var icon = Ui.Glyph(reminder.SymbolName, 24, Theme.Brush(tier));
        icon.Width = 30;
        icon.Margin = new Thickness(0, 0, 14, 0);
        Grid.SetColumn(icon, 0);
        grid.Children.Add(icon);

        var textStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var title = Ui.Text(
            titleText, 14, Theme.Brush(palette.Foreground), FontWeights.SemiBold
        );
        textStack.Children.Add(title);
        if (messageText.Length > 0)
        {
            var message = Ui.Text(
                messageText, 12, Theme.Brush(palette.SecondaryForeground)
            );
            // Four lines rather than two: at two, a normal sentence was being
            // cut off mid-word, and a reminder you cannot finish reading has
            // failed at its one job.
            message.MaxHeight = 64;
            message.TextTrimming = TextTrimming.WordEllipsis;
            message.Margin = new Thickness(0, 3, 0, 0);
            textStack.Children.Add(message);
        }
        Grid.SetColumn(textStack, 1);
        grid.Children.Add(textStack);

        // Completing from the card is the fast path for "done". A warning's
        // tick is full strength: it is the only way the card goes away.
        var check = Ui.IconButton(
            Ui.Glyph("checkmark.circle.fill", 21,
                Theme.Brush(Color.FromArgb(warning is null ? (byte)160 : (byte)255, 92, 184, 171))),
            tooltip: warning is null ? "Mark as done" : "Got it"
        );
        check.VerticalAlignment = VerticalAlignment.Center;
        check.Margin = new Thickness(10, 0, 0, 0);
        check.Focusable = false;
        check.Click += (_, _) => _onComplete();
        Grid.SetColumn(check, 2);
        grid.Children.Add(check);

        var card = new Border
        {
            Background = Theme.Brush(palette.CardBackground),
            // Important's card carries an orange hairline, as on the Mac, so
            // one that will not time out is told apart from a passing nudge.
            BorderBrush = reminder.Priority == Priority.Important || warning is not null
                ? Theme.Brush(Color.FromArgb(89, tier.R, tier.G, tier.B))
                : Theme.Brush(palette.Divider),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(16, 14, 16, 14),
            Margin = new Thickness(6, 6, 6, 12),
            Child = grid,
            Effect = new DropShadowEffect
            {
                BlurRadius = 14,
                ShadowDepth = 5,
                Direction = 270,
                Opacity = 0.18,
                Color = Colors.Black,
            },
        };
        return card;
    }
}
