using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using NodaTime;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// The settings window: Reminders / Preferences / History / About, mirroring
/// the Mac app's tabs. Preference edits apply immediately (no OK/Apply),
/// exactly as the Mac settings do.
/// </summary>
internal sealed class SettingsWindow : Window
{
    private readonly ReminderEngine _engine;
    private readonly OverlayPresenter _overlays;
    private readonly DateTimeZone _zone = DateTimeZoneProviders.Tzdb.GetSystemDefault();

    private ListView? _reminderList;
    private ListView? _historyList;
    private bool _loadingPreferences;

    public SettingsWindow(ReminderEngine engine, OverlayPresenter overlays)
    {
        _engine = engine;
        _overlays = overlays;

        Title = "Pauselet";
        Width = 760;
        Height = 560;
        MinWidth = 640;
        MinHeight = 460;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Theme.Brush(Theme.Current.WindowBackground);
        // Default WPF text is black whatever Windows' theme is; on the dark
        // palette every unstyled label must inherit a readable foreground.
        Foreground = Theme.Brush(Theme.Current.Foreground);
        Ui.ApplyThemeChrome(this);

        var tabs = new TabControl
        {
            Margin = new Thickness(8),
            Background = Theme.Brush(Theme.Current.WindowBackground),
            BorderBrush = Theme.Brush(Theme.Current.Divider),
        };
        tabs.Items.Add(new TabItem { Header = "Reminders", Content = BuildRemindersTab() });
        tabs.Items.Add(new TabItem { Header = "Preferences", Content = BuildPreferencesTab() });
        tabs.Items.Add(new TabItem { Header = "History", Content = BuildHistoryTab() });
        tabs.Items.Add(new TabItem { Header = "About", Content = BuildAboutTab() });
        Content = tabs;

        _engine.PropertyChanged += OnEngineChanged;
        Closed += (_, _) => _engine.PropertyChanged -= OnEngineChanged;
    }

    private void OnEngineChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(ReminderEngine.Reminders) or null)
        {
            ReloadReminders();
        }
        if (e.PropertyName is nameof(ReminderEngine.Events) or null)
        {
            ReloadHistory();
        }
    }

    // MARK: - Reminders tab

    private sealed record ReminderRowModel(
        Reminder Reminder, string Glyph, string Title, string Schedule,
        string Priority, bool Enabled)
    {
        public string EnabledText => Enabled ? "On" : "Off";
    }

    private UIElement BuildRemindersTab()
    {
        var layout = new DockPanel { Margin = new Thickness(12) };

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 10, 0, 0),
        };
        DockPanel.SetDock(buttons, Dock.Bottom);

        var add = new Button { Content = "Add Reminder", Padding = new Thickness(12, 5, 12, 5) };
        add.Click += (_, _) => OpenEditor(null);
        buttons.Children.Add(add);

        var edit = new Button
        {
            Content = "Edit",
            Padding = new Thickness(12, 5, 12, 5),
            Margin = new Thickness(8, 0, 0, 0),
        };
        edit.Click += (_, _) =>
        {
            if (SelectedReminder() is { } reminder) OpenEditor(reminder);
        };
        buttons.Children.Add(edit);

        var delete = new Button
        {
            Content = "Delete",
            Padding = new Thickness(12, 5, 12, 5),
            Margin = new Thickness(8, 0, 0, 0),
        };
        delete.Click += (_, _) =>
        {
            if (SelectedReminder() is not { } reminder) return;
            var answer = MessageBox.Show(
                this,
                $"Delete “{reminder.Title}”? Its history stays in the History tab.",
                "Delete Reminder",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question
            );
            if (answer == MessageBoxResult.Yes) _engine.Delete(reminder.Id);
        };
        buttons.Children.Add(delete);

        layout.Children.Add(buttons);

        _reminderList = new ListView();
        var view = new GridView();
        view.Columns.Add(Column("", nameof(ReminderRowModel.Glyph), 36, iconFont: true));
        view.Columns.Add(Column("Title", nameof(ReminderRowModel.Title), 220));
        view.Columns.Add(Column("Schedule", nameof(ReminderRowModel.Schedule), 190));
        view.Columns.Add(Column("Priority", nameof(ReminderRowModel.Priority), 90));
        view.Columns.Add(Column("Enabled", nameof(ReminderRowModel.EnabledText), 70));
        _reminderList.View = view;
        _reminderList.MouseDoubleClick += (_, _) =>
        {
            if (SelectedReminder() is { } reminder) OpenEditor(reminder);
        };
        layout.Children.Add(_reminderList);

        ReloadReminders();
        return layout;
    }

    private static GridViewColumn Column(
        string header, string property, double width, bool iconFont = false)
    {
        var column = new GridViewColumn { Header = header, Width = width };
        var factory = new FrameworkElementFactory(typeof(TextBlock));
        factory.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding(property));
        if (iconFont)
        {
            factory.SetValue(TextBlock.FontFamilyProperty, SymbolMap.IconFont);
        }
        column.CellTemplate = new DataTemplate { VisualTree = factory };
        return column;
    }

    private Reminder? SelectedReminder() =>
        (_reminderList?.SelectedItem as ReminderRowModel)?.Reminder;

    private void ReloadReminders()
    {
        if (_reminderList is null) return;
        _reminderList.ItemsSource = _engine.Reminders
            .Select(reminder => new ReminderRowModel(
                reminder,
                SymbolMap.Glyph(reminder.SymbolName),
                reminder.Title,
                reminder.Schedule.Summary,
                reminder.Priority.DisplayName(),
                reminder.IsEnabled))
            .ToList();
    }

    private void OpenEditor(Reminder? existing)
    {
        var editor = new ReminderEditorWindow(
            existing,
            onSave: reminder =>
            {
                if (existing is null)
                {
                    _engine.Add(reminder);
                }
                else
                {
                    _engine.Update(reminder);
                }
            },
            onPreview: reminder => _overlays.Preview(reminder, _engine.Settings)
        )
        {
            Owner = this,
        };
        editor.ShowDialog();
    }

    // MARK: - Preferences tab

    private UIElement BuildPreferencesTab()
    {
        _loadingPreferences = true;
        var settings = _engine.Settings;
        var stack = new StackPanel { Margin = new Thickness(16) };

        // First-run tray guidance — the Windows-specific note every tray
        // utility needs, because new icons start hidden in the overflow.
        stack.Children.Add(InfoCard(
            "Tip: pin Pauselet to the taskbar corner (Settings → Personalization → " +
            "Taskbar → Other system tray icons) so the countdown tooltip and flyout " +
            "are always one click away."
        ));

        stack.Children.Add(SectionHeader("Quiet hours"));
        var quietEnabled = CheckRow(
            "Enable quiet hours", settings.QuietHours.IsEnabled,
            value => UpdateSettings(s => s with
            {
                QuietHours = s.QuietHours with { IsEnabled = value },
            })
        );
        stack.Children.Add(quietEnabled);

        var quietTimes = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(24, 4, 0, 0),
        };
        quietTimes.Children.Add(new TextBlock
        {
            Text = "From",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 6, 0),
            Foreground = Theme.Brush(Theme.Current.Foreground),
        });
        quietTimes.Children.Add(TimeBox(
            settings.QuietHours.StartHour, settings.QuietHours.StartMinute,
            (hour, minute) => UpdateSettings(s => s with
            {
                QuietHours = s.QuietHours with { StartHour = hour, StartMinute = minute },
            })
        ));
        quietTimes.Children.Add(new TextBlock
        {
            Text = "to",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(10, 0, 6, 0),
            Foreground = Theme.Brush(Theme.Current.Foreground),
        });
        quietTimes.Children.Add(TimeBox(
            settings.QuietHours.EndHour, settings.QuietHours.EndMinute,
            (hour, minute) => UpdateSettings(s => s with
            {
                QuietHours = s.QuietHours with { EndHour = hour, EndMinute = minute },
            })
        ));
        stack.Children.Add(quietTimes);

        stack.Children.Add(CheckRow(
            "Allow critical reminders during quiet hours",
            settings.QuietHours.AllowsCritical,
            value => UpdateSettings(s => s with
            {
                QuietHours = s.QuietHours with { AllowsCritical = value },
            }),
            indent: 24,
            help: "Critical reminders can be medically necessary — pressure relief " +
                  "does not stop at night."
        ));

        stack.Children.Add(SectionHeader("Timing"));
        stack.Children.Add(NumberRow(
            "Snooze length (minutes)", settings.SnoozeMinutes, 1, 240,
            value => UpdateSettings(s => s with { SnoozeMinutes = value })
        ));
        stack.Children.Add(NumberRow(
            "Subtle reminder on-screen time (seconds)", settings.SubtleDisplaySeconds, 2, 120,
            value => UpdateSettings(s => s with { SubtleDisplaySeconds = value })
        ));

        stack.Children.Add(SectionHeader("System"));
        stack.Children.Add(CheckRow(
            "Launch at login", LaunchAtLogin.IsEnabled,
            value =>
            {
                // The registry entry is the OS truth; the stored setting keeps
                // the data file in sync with it.
                LaunchAtLogin.SetEnabled(value);
                UpdateSettings(s => s with { LaunchAtLogin = LaunchAtLogin.IsEnabled });
            }
        ));
        stack.Children.Add(CheckRow(
            "Show next-reminder countdown on the tray icon's tooltip",
            settings.ShowsNextReminderInMenuBar,
            value => UpdateSettings(s => s with { ShowsNextReminderInMenuBar = value })
        ));
        stack.Children.Add(CheckRow(
            "Play sounds for Important and Critical reminders", settings.SoundEnabled,
            value => UpdateSettings(s => s with { SoundEnabled = value })
        ));

        // Spotify control is deferred on Windows (v2): the music sections of
        // the Mac settings are intentionally absent, while every music field
        // in the data file persists untouched.

        _loadingPreferences = false;
        return new ScrollViewer
        {
            Content = stack,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
    }

    private void UpdateSettings(Func<Core.Settings, Core.Settings> transform)
    {
        if (_loadingPreferences) return;
        _engine.UpdateSettings(transform(_engine.Settings));
    }

    private static TextBlock SectionHeader(string text) => new()
    {
        Text = text,
        FontSize = 13,
        FontWeight = FontWeights.SemiBold,
        Foreground = Theme.Brush(Theme.Current.Foreground),
        Margin = new Thickness(0, 18, 0, 6),
    };

    private static Border InfoCard(string text) => new()
    {
        Background = Theme.Brush(Color.FromArgb(26, 46, 139, 131)),
        CornerRadius = new CornerRadius(8),
        Padding = new Thickness(12, 10, 12, 10),
        Child = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Foreground = Theme.Brush(Theme.Current.Foreground),
        },
    };

    private UIElement CheckRow(
        string label, bool initial, Action<bool> onChange,
        double indent = 0, string? help = null)
    {
        var stack = new StackPanel { Margin = new Thickness(indent, 6, 0, 0) };
        var box = new CheckBox
        {
            Content = label,
            IsChecked = initial,
            Foreground = Theme.Brush(Theme.Current.Foreground),
        };
        box.Click += (_, _) => onChange(box.IsChecked == true);
        stack.Children.Add(box);
        if (help is not null)
        {
            stack.Children.Add(new TextBlock
            {
                Text = help,
                FontSize = 11,
                Foreground = Theme.Brush(Theme.Current.SecondaryForeground),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(22, 2, 0, 0),
                MaxWidth = 520,
                HorizontalAlignment = HorizontalAlignment.Left,
            });
        }
        return stack;
    }

    private UIElement NumberRow(
        string label, int initial, int minimum, int maximum, Action<int> onChange)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 6, 0, 0),
        };
        row.Children.Add(new TextBlock
        {
            Text = label,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
            Foreground = Theme.Brush(Theme.Current.Foreground),
        });
        var current = initial;
        var box = new TextBox
        {
            Text = initial.ToString(),
            Width = 60,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        box.LostFocus += (_, _) =>
        {
            if (int.TryParse(box.Text, out var value))
            {
                current = Math.Clamp(value, minimum, maximum);
                onChange(current);
            }
            box.Text = current.ToString();
        };
        row.Children.Add(box);
        return row;
    }

    /// <summary>An "HH : MM" pair of numeric fields.</summary>
    private UIElement TimeBox(int hour, int minute, Action<int, int> onChange)
    {
        var currentHour = hour;
        var currentMinute = minute;
        var row = new StackPanel { Orientation = Orientation.Horizontal };

        var hourBox = new TextBox
        {
            Text = hour.ToString("D2"),
            Width = 34,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        var minuteBox = new TextBox
        {
            Text = minute.ToString("D2"),
            Width = 34,
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        hourBox.LostFocus += (_, _) =>
        {
            if (int.TryParse(hourBox.Text, out var value) && value is >= 0 and <= 23)
            {
                currentHour = value;
                onChange(currentHour, currentMinute);
            }
            hourBox.Text = currentHour.ToString("D2");
        };
        minuteBox.LostFocus += (_, _) =>
        {
            if (int.TryParse(minuteBox.Text, out var value) && value is >= 0 and <= 59)
            {
                currentMinute = value;
                onChange(currentHour, currentMinute);
            }
            minuteBox.Text = currentMinute.ToString("D2");
        };
        row.Children.Add(hourBox);
        row.Children.Add(new TextBlock
        {
            Text = ":",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(3, 0, 3, 0),
            Foreground = Theme.Brush(Theme.Current.Foreground),
        });
        row.Children.Add(minuteBox);
        return row;
    }

    // MARK: - History tab

    private sealed record HistoryRowModel(string When, string Title, string Outcome);

    private UIElement BuildHistoryTab()
    {
        var layout = new DockPanel { Margin = new Thickness(12) };

        var clear = new Button
        {
            Content = "Clear History",
            Padding = new Thickness(12, 5, 12, 5),
            Margin = new Thickness(0, 10, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        clear.Click += (_, _) =>
        {
            var answer = MessageBox.Show(
                this, "Clear all reminder history?", "Clear History",
                MessageBoxButton.YesNo, MessageBoxImage.Question
            );
            if (answer == MessageBoxResult.Yes) _engine.ClearHistory();
        };
        DockPanel.SetDock(clear, Dock.Bottom);
        layout.Children.Add(clear);

        _historyList = new ListView();
        var view = new GridView();
        view.Columns.Add(Column("When", nameof(HistoryRowModel.When), 170));
        view.Columns.Add(Column("Reminder", nameof(HistoryRowModel.Title), 260));
        view.Columns.Add(Column("Outcome", nameof(HistoryRowModel.Outcome), 110));
        _historyList.View = view;
        layout.Children.Add(_historyList);

        ReloadHistory();
        return layout;
    }

    private void ReloadHistory()
    {
        if (_historyList is null) return;
        _historyList.ItemsSource = _engine.Events
            .Reverse()
            .Select(e => new HistoryRowModel(
                e.Date.InZone(_zone).ToDateTimeUnspecified().ToString("g"),
                e.ReminderTitle,
                e.EventOutcome.ToString().ToLowerInvariant()))
            .ToList();
    }

    // MARK: - About tab

    private UIElement BuildAboutTab()
    {
        var stack = new StackPanel
        {
            Margin = new Thickness(16),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };

        var name = new TextBlock
        {
            Text = "Pauselet",
            FontSize = 28,
            FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            Foreground = Theme.Brush(Theme.Current.Foreground),
        };
        stack.Children.Add(name);

        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "dev";
        stack.Children.Add(new TextBlock
        {
            Text = $"Version {version} for Windows",
            FontSize = 12,
            Foreground = Theme.Brush(Theme.Current.SecondaryForeground),
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 4, 0, 16),
        });

        stack.Children.Add(new TextBlock
        {
            Text = "Gentle, insistent activity reminders.\n" +
                   "Everything stays on this PC — no account, no cloud, no tracking.",
            FontSize = 13,
            TextAlignment = TextAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
            HorizontalAlignment = HorizontalAlignment.Center,
            Foreground = Theme.Brush(Theme.Current.Foreground),
        });

        var link = new Button
        {
            Content = "github.com/Crypto69/pauselet",
            Margin = new Thickness(0, 16, 0, 0),
            Padding = new Thickness(10, 4, 10, 4),
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        link.Click += (_, _) =>
        {
            try
            {
                Process.Start(new ProcessStartInfo("https://github.com/Crypto69/pauselet")
                {
                    UseShellExecute = true,
                });
            }
            catch
            {
                // A missing browser association is not our problem to solve.
            }
        };
        stack.Children.Add(link);

        return stack;
    }
}
