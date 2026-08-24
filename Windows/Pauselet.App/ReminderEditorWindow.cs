using System.Windows;
using System.Windows.Controls;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// The add/edit dialog for a single reminder: schedule (repeating / daily /
/// weekly), priority tier, icon, sound, on-screen time, activity countdown —
/// with a Preview button that shows the reminder exactly as it will appear,
/// without touching its schedule or history.
/// </summary>
internal sealed class ReminderEditorWindow : Window
{
    private readonly Reminder? _existing;
    private readonly Action<Reminder> _onSave;
    private readonly Action<Reminder> _onPreview;

    private readonly TextBox _titleBox = new();
    private readonly TextBox _messageBox = new()
    {
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        Height = 56,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
    };
    private readonly ComboBox _scheduleKind = new();
    private readonly TextBox _intervalMinutes = new() { Width = 60, Text = "30" };
    private readonly TextBox _timeHour = new() { Width = 34, Text = "17" };
    private readonly TextBox _timeMinute = new() { Width = 34, Text = "00" };
    private readonly TextBox _dayInterval = new() { Width = 40, Text = "1" };
    private readonly List<CheckBox> _weekdayBoxes = [];
    private readonly List<RadioButton> _priorityButtons = [];
    private readonly ComboBox _symbolPicker = new() { Width = 200 };
    private readonly ComboBox _soundPicker = new() { Width = 160 };
    private readonly TextBox _displaySeconds = new() { Width = 60 };
    private readonly TextBox _activityMinutes = new() { Width = 60 };

    private StackPanel? _intervalPanel;
    private StackPanel? _dailyPanel;
    private StackPanel? _weeklyPanel;

    /// <summary>Weekday order shown in the picker; values are Calendar numbering.</summary>
    private static readonly (string Label, int Value)[] Weekdays =
    [
        ("Mon", 2), ("Tue", 3), ("Wed", 4), ("Thu", 5),
        ("Fri", 6), ("Sat", 7), ("Sun", 1),
    ];

    public ReminderEditorWindow(
        Reminder? existing, Action<Reminder> onSave, Action<Reminder> onPreview)
    {
        _existing = existing;
        _onSave = onSave;
        _onPreview = onPreview;

        Title = existing is null ? "Add Reminder" : "Edit Reminder";
        Width = 480;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Theme.Brush(Theme.Current.WindowBackground);

        Content = BuildForm();
        LoadFrom(existing);
    }

    private UIElement BuildForm()
    {
        var stack = new StackPanel { Margin = new Thickness(16) };

        stack.Children.Add(FieldLabel("Title"));
        stack.Children.Add(_titleBox);

        stack.Children.Add(FieldLabel("Message"));
        stack.Children.Add(_messageBox);

        stack.Children.Add(FieldLabel("Schedule"));
        _scheduleKind.Items.Add("Repeating interval");
        _scheduleKind.Items.Add("Daily at a time");
        _scheduleKind.Items.Add("Weekly on days");
        _scheduleKind.SelectedIndex = 0;
        _scheduleKind.SelectionChanged += (_, _) => UpdateSchedulePanels();
        stack.Children.Add(_scheduleKind);

        _intervalPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 6, 0, 0),
        };
        _intervalPanel.Children.Add(InlineLabel("Every"));
        _intervalPanel.Children.Add(_intervalMinutes);
        _intervalPanel.Children.Add(InlineLabel("minutes"));
        stack.Children.Add(_intervalPanel);

        _dailyPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 6, 0, 0),
        };
        _dailyPanel.Children.Add(InlineLabel("At"));
        _dailyPanel.Children.Add(_timeHour);
        _dailyPanel.Children.Add(InlineLabel(":"));
        _dailyPanel.Children.Add(_timeMinute);
        _dailyPanel.Children.Add(InlineLabel("every"));
        _dailyPanel.Children.Add(_dayInterval);
        _dailyPanel.Children.Add(InlineLabel("day(s)"));
        stack.Children.Add(_dailyPanel);

        _weeklyPanel = new StackPanel { Margin = new Thickness(0, 6, 0, 0) };
        var dayRow = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (label, value) in Weekdays)
        {
            var box = new CheckBox
            {
                Content = label,
                Tag = value,
                Margin = new Thickness(0, 0, 8, 0),
            };
            _weekdayBoxes.Add(box);
            dayRow.Children.Add(box);
        }
        _weeklyPanel.Children.Add(dayRow);
        var weeklyTime = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 6, 0, 0),
        };
        // The weekly panel shares the same hour/minute boxes as the daily one;
        // only one panel is visible at a time.
        weeklyTime.Children.Add(InlineLabel("The time above applies to the selected days."));
        _weeklyPanel.Children.Add(weeklyTime);
        stack.Children.Add(_weeklyPanel);

        stack.Children.Add(FieldLabel("How it interrupts"));
        foreach (var priority in Enum.GetValues<Priority>())
        {
            var radio = new RadioButton
            {
                GroupName = "priority",
                Tag = priority,
                Margin = new Thickness(0, 3, 0, 0),
                Content = new StackPanel
                {
                    Children =
                    {
                        new TextBlock
                        {
                            Text = priority.DisplayName(),
                            FontWeight = FontWeights.Medium,
                        },
                        new TextBlock
                        {
                            Text = priority.Explanation(),
                            FontSize = 11,
                            Foreground = Theme.Brush(Theme.Current.SecondaryForeground),
                        },
                    },
                },
            };
            _priorityButtons.Add(radio);
            stack.Children.Add(radio);
        }

        var optionsGrid = new StackPanel { Margin = new Thickness(0, 4, 0, 0) };

        optionsGrid.Children.Add(FieldLabel("Icon"));
        foreach (var symbol in SymbolMap.PickerSymbols)
        {
            _symbolPicker.Items.Add(new ComboBoxItem
            {
                Tag = symbol,
                Content = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Children =
                    {
                        new TextBlock
                        {
                            Text = SymbolMap.Glyph(symbol),
                            FontFamily = SymbolMap.IconFont,
                            Margin = new Thickness(0, 0, 8, 0),
                        },
                        new TextBlock { Text = symbol },
                    },
                },
            });
        }
        optionsGrid.Children.Add(_symbolPicker);

        optionsGrid.Children.Add(FieldLabel("Sound (Important and Critical)"));
        _soundPicker.Items.Add("Tier default");
        foreach (var sound in Sounds.Available) _soundPicker.Items.Add(sound);
        _soundPicker.SelectedIndex = 0;
        var soundRow = new StackPanel { Orientation = Orientation.Horizontal };
        soundRow.Children.Add(_soundPicker);
        var listen = new Button
        {
            Content = "Listen",
            Margin = new Thickness(8, 0, 0, 0),
            Padding = new Thickness(10, 2, 10, 2),
        };
        listen.Click += (_, _) =>
        {
            if (_soundPicker.SelectedIndex > 0)
            {
                Sounds.Play((string)_soundPicker.SelectedItem);
            }
            else
            {
                Sounds.Play("Submarine");
            }
        };
        soundRow.Children.Add(listen);
        optionsGrid.Children.Add(soundRow);

        optionsGrid.Children.Add(FieldLabel("On-screen time for a Subtle card (seconds, blank = default)"));
        optionsGrid.Children.Add(_displaySeconds);

        optionsGrid.Children.Add(FieldLabel("Activity countdown (minutes, blank = none)"));
        optionsGrid.Children.Add(_activityMinutes);

        stack.Children.Add(optionsGrid);

        var buttonRow = new Grid { Margin = new Thickness(0, 18, 0, 0) };
        buttonRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttonRow.ColumnDefinitions.Add(
            new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }
        );
        buttonRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        buttonRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var preview = new Button { Content = "Preview", Padding = new Thickness(14, 6, 14, 6) };
        preview.Click += (_, _) =>
        {
            if (BuildReminder() is { } reminder) _onPreview(reminder);
        };
        buttonRow.Children.Add(preview);

        var cancel = new Button
        {
            Content = "Cancel",
            Padding = new Thickness(14, 6, 14, 6),
            Margin = new Thickness(0, 0, 8, 0),
            IsCancel = true,
        };
        Grid.SetColumn(cancel, 2);
        buttonRow.Children.Add(cancel);

        var save = new Button
        {
            Content = "Save",
            Padding = new Thickness(14, 6, 14, 6),
            IsDefault = true,
        };
        save.Click += (_, _) =>
        {
            if (BuildReminder() is not { } reminder) return;
            _onSave(reminder);
            Close();
        };
        Grid.SetColumn(save, 3);
        buttonRow.Children.Add(save);

        stack.Children.Add(buttonRow);
        return stack;
    }

    private static TextBlock FieldLabel(string text) => new()
    {
        Text = text,
        FontSize = 12,
        FontWeight = FontWeights.SemiBold,
        Margin = new Thickness(0, 12, 0, 3),
    };

    private static TextBlock InlineLabel(string text) => new()
    {
        Text = text,
        VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(4, 0, 4, 0),
    };

    private void UpdateSchedulePanels()
    {
        if (_intervalPanel is null || _dailyPanel is null || _weeklyPanel is null) return;
        var kind = _scheduleKind.SelectedIndex;
        _intervalPanel.Visibility = kind == 0 ? Visibility.Visible : Visibility.Collapsed;
        _dailyPanel.Visibility = kind == 1 || kind == 2
            ? Visibility.Visible
            : Visibility.Collapsed;
        _weeklyPanel.Visibility = kind == 2 ? Visibility.Visible : Visibility.Collapsed;
        // "every N day(s)" only makes sense for the daily kind.
        _dayInterval.Visibility = kind == 1 ? Visibility.Visible : Visibility.Collapsed;
        if (_dailyPanel.Children.Count >= 7)
        {
            _dailyPanel.Children[4].Visibility = _dayInterval.Visibility; // "every"
            _dailyPanel.Children[6].Visibility = _dayInterval.Visibility; // "day(s)"
        }
    }

    private void LoadFrom(Reminder? existing)
    {
        if (existing is null)
        {
            _symbolPicker.SelectedIndex = 0;
            SelectPriority(Priority.Normal);
            UpdateSchedulePanels();
            return;
        }

        _titleBox.Text = existing.Title;
        _messageBox.Text = existing.Message;
        SelectPriority(existing.Priority);

        switch (existing.Schedule)
        {
            case Schedule.Interval interval:
                _scheduleKind.SelectedIndex = 0;
                _intervalMinutes.Text = interval.Minutes.ToString();
                break;
            case Schedule.DailyAt daily:
                _scheduleKind.SelectedIndex = 1;
                _timeHour.Text = daily.Hour.ToString("D2");
                _timeMinute.Text = daily.Minute.ToString("D2");
                _dayInterval.Text = daily.DayInterval.ToString();
                break;
            case Schedule.WeeklyAt weekly:
                _scheduleKind.SelectedIndex = 2;
                _timeHour.Text = weekly.Hour.ToString("D2");
                _timeMinute.Text = weekly.Minute.ToString("D2");
                foreach (var box in _weekdayBoxes)
                {
                    box.IsChecked = weekly.Weekdays.Contains((int)box.Tag);
                }
                break;
        }

        var symbolIndex = Array.IndexOf(SymbolMap.PickerSymbols, existing.SymbolName);
        _symbolPicker.SelectedIndex = symbolIndex >= 0 ? symbolIndex : 0;

        if (existing.SoundName is { } sound)
        {
            var soundIndex = Array.IndexOf(Sounds.Available, sound);
            _soundPicker.SelectedIndex = soundIndex >= 0 ? soundIndex + 1 : 0;
        }

        _displaySeconds.Text = existing.DisplaySeconds?.ToString() ?? "";
        _activityMinutes.Text = existing.ActivityDurationSeconds is { } seconds
            ? (seconds / 60).ToString()
            : "";

        UpdateSchedulePanels();
    }

    private void SelectPriority(Priority priority)
    {
        foreach (var radio in _priorityButtons)
        {
            radio.IsChecked = (Priority)radio.Tag == priority;
        }
    }

    /// <summary>
    /// The reminder as currently described by the form, or <c>null</c> (with a
    /// message) when the form does not describe a valid one.
    /// </summary>
    private Reminder? BuildReminder()
    {
        var title = _titleBox.Text.Trim();
        if (title.Length == 0)
        {
            MessageBox.Show(this, "Give the reminder a title.", "Pauselet");
            return null;
        }

        Schedule schedule;
        switch (_scheduleKind.SelectedIndex)
        {
            case 0:
            {
                if (!int.TryParse(_intervalMinutes.Text, out var minutes) || minutes < 1)
                {
                    MessageBox.Show(this, "The interval needs a number of minutes.", "Pauselet");
                    return null;
                }
                schedule = new Schedule.Interval(minutes);
                break;
            }
            case 1:
            {
                if (!TryParseTime(out var hour, out var minute)) return null;
                if (!int.TryParse(_dayInterval.Text, out var days) || days < 1)
                {
                    days = 1;
                }
                schedule = new Schedule.DailyAt(hour, minute, days);
                break;
            }
            default:
            {
                if (!TryParseTime(out var hour, out var minute)) return null;
                var weekdays = _weekdayBoxes
                    .Where(box => box.IsChecked == true)
                    .Select(box => (int)box.Tag)
                    .ToHashSet();
                if (weekdays.Count == 0)
                {
                    MessageBox.Show(this, "Pick at least one weekday.", "Pauselet");
                    return null;
                }
                schedule = new Schedule.WeeklyAt(hour, minute, weekdays);
                break;
            }
        }

        var priority = _priorityButtons
            .FirstOrDefault(radio => radio.IsChecked == true)?.Tag is Priority selected
            ? selected
            : Priority.Normal;

        var symbol = (_symbolPicker.SelectedItem as ComboBoxItem)?.Tag as string ?? "bell";
        var sound = _soundPicker.SelectedIndex > 0 ? (string)_soundPicker.SelectedItem : null;

        int? displaySeconds = int.TryParse(_displaySeconds.Text, out var display) && display > 0
            ? display
            : null;
        int? activitySeconds =
            int.TryParse(_activityMinutes.Text, out var activity) && activity > 0
                ? activity * 60
                : null;

        var baseline = _existing ?? new Reminder { Title = title, Schedule = schedule };
        return baseline with
        {
            Title = title,
            Message = _messageBox.Text.Trim(),
            Schedule = schedule,
            Priority = priority,
            SymbolName = symbol,
            SoundName = sound,
            DisplaySeconds = displaySeconds,
            ActivityDurationSeconds = activitySeconds,
        };
    }

    private bool TryParseTime(out int hour, out int minute)
    {
        hour = 0;
        minute = 0;
        if (!int.TryParse(_timeHour.Text, out hour) || hour is < 0 or > 23
            || !int.TryParse(_timeMinute.Text, out minute) || minute is < 0 or > 59)
        {
            MessageBox.Show(this, "The time needs to be HH:MM (24-hour).", "Pauselet");
            return false;
        }
        return true;
    }
}
