using System.Windows;
using System.Windows.Controls;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// The add/edit dialog for a single reminder: type (standard / exercise),
/// schedule (repeating / daily / weekly), priority tier, icon, sound,
/// on-screen time, activity countdown — with a Preview button that shows the
/// reminder exactly as it will appear, without touching its schedule or
/// history.
///
/// An exercise reminder carries a list of exercises (name, instructions,
/// sets, reps) typed in here, and is always Critical: the list only makes
/// sense on the full-screen takeover, so the tier picker gives way to a note.
/// </summary>
internal sealed class ReminderEditorWindow : Window
{
    private readonly Reminder? _existing;
    private readonly AIImportController _ai;
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
    private readonly ComboBox _reminderType = new();
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
    private readonly List<ExerciseRow> _exerciseRows = [];

    private StackPanel? _intervalPanel;
    private StackPanel? _dailyPanel;
    private StackPanel? _weeklyPanel;
    private StackPanel? _exercisePanel;
    private StackPanel? _exerciseRowsHost;
    private StackPanel? _priorityPanel;
    private TextBlock? _criticalNote;
    private StackPanel? _displayPanel;
    /// <summary>
    /// True while LoadFrom populates the form, so a SelectionChanged raised by
    /// loading is not mistaken for the user switching type.
    /// </summary>
    private bool _isLoading;

    /// <summary>The controls for one exercise, kept together so rows can be removed.</summary>
    private sealed class ExerciseRow
    {
        public Guid Id { get; init; } = Guid.NewGuid();
        public required Border Container { get; init; }
        public required TextBlock Header { get; init; }
        public required TextBox Name { get; init; }
        public required TextBox Instructions { get; init; }
        public required TextBox Sets { get; init; }
        public required TextBox Reps { get; init; }
        /// <summary>
        /// Seconds each rep is held; 0 leaves the exercise untimed, which is
        /// why the two rest fields follow it rather than stand alone.
        /// </summary>
        public required TextBox Hold { get; init; }
        public required TextBox RestBetweenReps { get; init; }
        public required TextBox RestBetweenSets { get; init; }
        /// <summary>
        /// The caption under the timing fields, which says what the numbers
        /// mean and changes when a hold makes the exercise guided.
        /// </summary>
        public required TextBlock TimingCaption { get; init; }
    }

    public ReminderEditorWindow(
        Reminder? existing, AIImportController ai,
        Action<Reminder> onSave, Action<Reminder> onPreview)
    {
        _existing = existing;
        _ai = ai;
        _onSave = onSave;
        _onPreview = onPreview;

        Title = existing is null ? "Add Reminder" : "Edit Reminder";
        Width = 480;
        SizeToContent = SizeToContent.Height;
        // An exercise list can make the form taller than the screen: the
        // window grows with its content up to this cap, then the form scrolls
        // while the buttons stay put at the bottom.
        MaxHeight = SystemParameters.WorkArea.Height * 0.9;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Theme.Brush(Theme.Current.WindowBackground);
        // See SettingsWindow: unstyled WPF text is black regardless of the
        // Windows theme, so the dark palette needs an inherited foreground.
        Foreground = Theme.Brush(Theme.Current.Foreground);
        Ui.ApplyThemeChrome(this);
        // CenterOwner positions once; growth is downward, so nudge the window
        // back up if adding rows would push the buttons off the work area.
        SizeChanged += (_, _) =>
        {
            var workArea = SystemParameters.WorkArea;
            if (Top + ActualHeight > workArea.Bottom)
            {
                Top = Math.Max(workArea.Top, workArea.Bottom - ActualHeight);
            }
        };

        Content = BuildForm();
        LoadFrom(existing);
    }

    private UIElement BuildForm()
    {
        var stack = new StackPanel { Margin = new Thickness(16, 16, 16, 0) };

        stack.Children.Add(FieldLabel("Title"));
        stack.Children.Add(_titleBox);

        stack.Children.Add(FieldLabel("Message"));
        stack.Children.Add(_messageBox);

        stack.Children.Add(FieldLabel("Type"));
        _reminderType.Items.Add("Standard");
        _reminderType.Items.Add("Exercise");
        _reminderType.SelectedIndex = 0;
        _reminderType.SelectionChanged += (_, _) => UpdateTypePanels();
        stack.Children.Add(_reminderType);

        _exercisePanel = new StackPanel();
        _exercisePanel.Children.Add(FieldLabel("Exercises"));
        _exerciseRowsHost = new StackPanel();
        _exercisePanel.Children.Add(_exerciseRowsHost);
        var addExercise = new Button
        {
            Content = "Add exercise",
            Padding = new Thickness(10, 3, 10, 3),
        };
        addExercise.Click += (_, _) => AddExerciseRow(null).Name.Focus();

        var importExercises = new Button
        {
            Content = "Import from Text…",
            Padding = new Thickness(10, 3, 10, 3),
            Margin = new Thickness(8, 0, 0, 0),
            ToolTip = "Paste what your physiotherapist wrote and turn it into exercises",
        };
        importExercises.Click += (_, _) => ImportExercises();

        var exerciseButtons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 8, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        exerciseButtons.Children.Add(addExercise);
        exerciseButtons.Children.Add(importExercises);
        _exercisePanel.Children.Add(exerciseButtons);
        stack.Children.Add(_exercisePanel);

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

        // The shared catalog's presets, which Windows did not offer at all.
        // They fill the box rather than replace it, so a custom interval is
        // still just typed — the Mac's "presets, then Custom" in the shape a
        // WPF row has for it.
        var presets = new ComboBox { Width = 96, Margin = new Thickness(8, 0, 0, 0) };
        presets.Items.Add(new ComboBoxItem { Content = "Preset…", Tag = 0 });
        foreach (var minutes in EditorCatalog.IntervalPresets)
        {
            presets.Items.Add(new ComboBoxItem
            {
                Content = Schedule.HumanDuration(minutes),
                Tag = minutes,
            });
        }
        presets.SelectedIndex = 0;
        presets.SelectionChanged += (_, _) =>
        {
            if (presets.SelectedItem is ComboBoxItem { Tag: int minutes and > 0 })
            {
                _intervalMinutes.Text = minutes.ToString();
            }
        };
        _intervalPanel.Children.Add(presets);
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
        // Day order and numbering come from the shared catalog, so the three
        // platforms cannot drift on which day is which. Windows has room for
        // the abbreviation the Mac's one-letter button cannot show.
        foreach (var weekday in EditorCatalog.Weekdays)
        {
            var box = new CheckBox
            {
                Content = weekday.Name[..3],
                Tag = weekday.Number,
                Margin = new Thickness(0, 0, 8, 0),
                Foreground = Theme.Brush(Theme.Current.Foreground),
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

        _priorityPanel = new StackPanel();
        _priorityPanel.Children.Add(FieldLabel("How it interrupts"));
        foreach (var priority in Enum.GetValues<Priority>())
        {
            var radio = new RadioButton
            {
                GroupName = "priority",
                Tag = priority,
                Margin = new Thickness(0, 3, 0, 0),
                Foreground = Theme.Brush(Theme.Current.Foreground),
                Content = new StackPanel
                {
                    Children =
                    {
                        new TextBlock
                        {
                            Text = priority.DisplayName(),
                            FontWeight = FontWeights.Medium,
                            Foreground = Theme.Brush(Theme.Current.Foreground),
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
            _priorityPanel.Children.Add(radio);
        }
        stack.Children.Add(_priorityPanel);

        // Shown in place of the tier picker for an exercise reminder.
        _criticalNote = new TextBlock
        {
            Text = "Exercise reminders always interrupt as Critical: full screen, "
                + "so the list is in front of you, and it stays until you press Done.",
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Theme.Brush(Theme.Current.SecondaryForeground),
            Margin = new Thickness(0, 12, 0, 0),
        };
        stack.Children.Add(_criticalNote);

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

        _displayPanel = new StackPanel();
        _displayPanel.Children.Add(
            FieldLabel("On-screen time for a Subtle card (seconds, blank = default)")
        );
        _displayPanel.Children.Add(_displaySeconds);
        optionsGrid.Children.Add(_displayPanel);

        optionsGrid.Children.Add(FieldLabel("Activity countdown (minutes, blank = none)"));
        optionsGrid.Children.Add(_activityMinutes);

        stack.Children.Add(optionsGrid);

        var buttonRow = new Grid { Margin = new Thickness(16, 12, 16, 16) };
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

        // Buttons docked below a scrolling form, so a long exercise list never
        // pushes Save out of reach.
        var root = new DockPanel();
        DockPanel.SetDock(buttonRow, Dock.Bottom);
        root.Children.Add(buttonRow);
        root.Children.Add(new ScrollViewer
        {
            Content = stack,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        });
        return root;
    }

    private ExerciseRow AddExerciseRow(Exercise? existing)
    {
        var palette = Theme.Current;
        var header = new TextBlock
        {
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Foreground = Theme.Brush(palette.SecondaryForeground),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var remove = new Button
        {
            Content = "Remove",
            Padding = new Thickness(8, 1, 8, 1),
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        var headerRow = new Grid();
        headerRow.ColumnDefinitions.Add(
            new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }
        );
        headerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        headerRow.Children.Add(header);
        Grid.SetColumn(remove, 1);
        headerRow.Children.Add(remove);

        var name = new TextBox { Text = existing?.Name ?? "" };
        var instructions = new TextBox
        {
            Text = existing?.Instructions ?? "",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 48,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        var sets = new TextBox { Width = 40, Text = (existing?.Sets ?? 3).ToString() };
        var reps = new TextBox { Width = 40, Text = (existing?.Reps ?? 10).ToString() };
        var counts = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 6, 0, 0),
        };
        counts.Children.Add(InlineLabel("Sets"));
        counts.Children.Add(sets);
        counts.Children.Add(InlineLabel("Reps per set"));
        counts.Children.Add(reps);

        // Hold, then the two rests it enables — the same three fields, in the
        // same order, as the Mac's and iOS's shared ExerciseRowEditor.
        var hold = new TextBox { Width = 44, Text = (existing?.HoldSeconds ?? 0).ToString() };
        var restBetweenReps = new TextBox
        {
            Width = 44,
            Text = (existing?.RestBetweenRepsSeconds ?? 0).ToString(),
        };
        var restBetweenSets = new TextBox
        {
            Width = 44,
            Text = (existing?.RestBetweenSetsSeconds ?? 0).ToString(),
        };
        var timing = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 6, 0, 0),
        };
        timing.Children.Add(InlineLabel("Hold"));
        timing.Children.Add(hold);
        timing.Children.Add(InlineLabel("Rest"));
        timing.Children.Add(restBetweenReps);
        timing.Children.Add(InlineLabel("Set rest"));
        timing.Children.Add(restBetweenSets);

        var timingCaption = new TextBlock
        {
            FontSize = 11,
            Foreground = Theme.Brush(palette.SecondaryForeground),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 4, 0, 0),
        };

        var body = new StackPanel();
        body.Children.Add(headerRow);
        body.Children.Add(SmallLabel("Name"));
        body.Children.Add(name);
        body.Children.Add(SmallLabel("Instructions"));
        body.Children.Add(instructions);
        body.Children.Add(counts);
        body.Children.Add(timing);
        body.Children.Add(timingCaption);

        var container = new Border
        {
            Background = Theme.Brush(palette.CardBackground),
            BorderBrush = Theme.Brush(palette.Divider),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10),
            Margin = new Thickness(0, 6, 0, 0),
            Child = body,
        };

        var row = new ExerciseRow
        {
            Id = existing?.Id ?? Guid.NewGuid(),
            Container = container,
            Header = header,
            Name = name,
            Instructions = instructions,
            Sets = sets,
            Reps = reps,
            Hold = hold,
            RestBetweenReps = restBetweenReps,
            RestBetweenSets = restBetweenSets,
            TimingCaption = timingCaption,
        };
        // A rest only means something between held reps, so both rest fields
        // follow the hold, and the caption says which state the row is in.
        hold.TextChanged += (_, _) => UpdateTimingState(row);
        UpdateTimingState(row);
        remove.Click += (_, _) =>
        {
            _exerciseRows.Remove(row);
            _exerciseRowsHost?.Children.Remove(container);
            RenumberExerciseRows();
        };
        _exerciseRows.Add(row);
        _exerciseRowsHost?.Children.Add(container);
        RenumberExerciseRows();
        return row;
    }

    /// <summary>
    /// Opens the import dialog and appends what it returns.
    ///
    /// Switching the type to Exercise seeds one blank row for typing into.
    /// Importing is the alternative to typing, so that untouched placeholder is
    /// replaced rather than left above the imported rows. Anything the person
    /// actually filled in stays — the same rule as the Mac's ExerciseEditor.
    /// </summary>
    private void ImportExercises()
    {
        var window = new ExerciseImportWindow(_ai, imported =>
        {
            foreach (var row in _exerciseRows.ToList())
            {
                if (row.Name.Text.Trim().Length > 0) continue;
                _exerciseRows.Remove(row);
                _exerciseRowsHost?.Children.Remove(row.Container);
            }
            foreach (var exercise in imported) AddExerciseRow(exercise);
            RenumberExerciseRows();
        })
        {
            Owner = this,
        };
        window.ShowDialog();
    }

    /// <summary>
    /// Enables the rest fields only when the row has a hold, and captions the
    /// timing row accordingly — the same rule, and the same two sentences, as
    /// <c>ExerciseRowEditor</c> on the Mac and iOS.
    /// </summary>
    private static void UpdateTimingState(ExerciseRow row)
    {
        // Text that is not a number yet (mid-typing, or empty) reads as no
        // hold, so the fields disable rather than flicker on a stray keystroke.
        var isGuided = int.TryParse(row.Hold.Text, out var hold) && hold > 0;
        row.RestBetweenReps.IsEnabled = isGuided;
        row.RestBetweenSets.IsEnabled = isGuided;
        row.TimingCaption.Text = isGuided
            ? "Seconds per rep, between reps, and between sets."
            : "Seconds. Hold 0 leaves this exercise untimed.";
    }

    private void RenumberExerciseRows()
    {
        for (var i = 0; i < _exerciseRows.Count; i++)
        {
            _exerciseRows[i].Header.Text = $"Exercise {i + 1}";
        }
    }

    private static TextBlock FieldLabel(string text) => new()
    {
        Text = text,
        FontSize = 12,
        FontWeight = FontWeights.SemiBold,
        Foreground = Theme.Brush(Theme.Current.Foreground),
        Margin = new Thickness(0, 12, 0, 3),
    };

    private static TextBlock SmallLabel(string text) => new()
    {
        Text = text,
        FontSize = 11,
        Foreground = Theme.Brush(Theme.Current.SecondaryForeground),
        Margin = new Thickness(0, 6, 0, 2),
    };

    private static TextBlock InlineLabel(string text) => new()
    {
        Text = text,
        VerticalAlignment = VerticalAlignment.Center,
        Foreground = Theme.Brush(Theme.Current.Foreground),
        Margin = new Thickness(4, 0, 4, 0),
    };

    private bool IsExerciseType => _reminderType.SelectedIndex == 1;

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

    /// <summary>
    /// Shows the exercise list and hides the tier picker (and the Subtle-only
    /// on-screen time) for an exercise reminder. The radio buttons keep
    /// whatever the user had chosen: the Critical tier is imposed when the
    /// reminder is built, so switching back to Standard within one editing
    /// session restores their pick. (A saved exercise reminder is Critical on
    /// disk, so reopening it and switching back shows Critical selected.)
    /// </summary>
    private void UpdateTypePanels()
    {
        if (_exercisePanel is null || _priorityPanel is null
            || _criticalNote is null || _displayPanel is null)
        {
            return;
        }
        var isExercise = IsExerciseType;
        _exercisePanel.Visibility = isExercise ? Visibility.Visible : Visibility.Collapsed;
        _criticalNote.Visibility = _exercisePanel.Visibility;
        _priorityPanel.Visibility = isExercise ? Visibility.Collapsed : Visibility.Visible;
        _displayPanel.Visibility = _priorityPanel.Visibility;

        if (isExercise && _exerciseRows.Count == 0)
        {
            // Never an empty list: the shape of a row is the explanation.
            AddExerciseRow(null);
        }
        // Only when the user switches type, as the Mac and iOS editors do: a
        // saved exercise reminder that deliberately kept the bell must open
        // and save unchanged.
        if (isExercise && !_isLoading && SelectedSymbol() == "bell")
        {
            SelectSymbol("dumbbell.fill");
        }
    }

    private void LoadFrom(Reminder? existing)
    {
        _isLoading = true;
        try
        {
            Populate(existing);
        }
        finally
        {
            _isLoading = false;
        }
    }

    private void Populate(Reminder? existing)
    {
        if (existing is null)
        {
            _symbolPicker.SelectedIndex = 0;
            SelectPriority(Priority.Normal);
            UpdateSchedulePanels();
            UpdateTypePanels();
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

        SelectSymbol(existing.SymbolName);

        if (existing.SoundName is { } sound)
        {
            var soundIndex = Array.IndexOf(Sounds.Available, sound);
            _soundPicker.SelectedIndex = soundIndex >= 0 ? soundIndex + 1 : 0;
        }

        _displaySeconds.Text = existing.DisplaySeconds?.ToString() ?? "";
        _activityMinutes.Text = existing.ActivityDurationSeconds is { } seconds
            ? (seconds / 60).ToString()
            : "";

        // Rows first, then the type: selecting Exercise seeds a blank row
        // only when there are none.
        foreach (var exercise in existing.Exercises ?? []) AddExerciseRow(exercise);
        _reminderType.SelectedIndex = existing.IsExercise ? 1 : 0;

        UpdateSchedulePanels();
        UpdateTypePanels();
    }

    private void SelectPriority(Priority priority)
    {
        foreach (var radio in _priorityButtons)
        {
            radio.IsChecked = (Priority)radio.Tag == priority;
        }
    }

    private string SelectedSymbol() =>
        (_symbolPicker.SelectedItem as ComboBoxItem)?.Tag as string ?? "bell";

    private void SelectSymbol(string symbolName)
    {
        var index = Array.IndexOf(SymbolMap.PickerSymbols, symbolName);
        _symbolPicker.SelectedIndex = index >= 0 ? index : 0;
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

        IReadOnlyList<Exercise>? exercises = null;
        if (IsExerciseType)
        {
            exercises = BuildExercises();
            if (exercises is null) return null;
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

        var chosenPriority = _priorityButtons
            .FirstOrDefault(radio => radio.IsChecked == true)?.Tag is Priority selected
            ? selected
            : Priority.Normal;
        // Exercise reminders always take over the screen: the list is the
        // point, and only the Critical takeover can show it.
        var priority = IsExerciseType ? Priority.Critical : chosenPriority;

        var symbol = SelectedSymbol();
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
            Exercises = exercises,
        };
    }

    /// <summary>
    /// The exercise rows as a list, or <c>null</c> (with a message naming the
    /// offending row, which is focused) when one cannot be performed.
    /// </summary>
    private IReadOnlyList<Exercise>? BuildExercises()
    {
        if (_exerciseRows.Count == 0)
        {
            MessageBox.Show(this, "Add at least one exercise.", "Pauselet");
            return null;
        }

        var list = new List<Exercise>();
        for (var i = 0; i < _exerciseRows.Count; i++)
        {
            var row = _exerciseRows[i];
            // The counts must at least be numbers before the model can judge
            // them; the rule for what makes an exercise performable is the
            // model's own, so the dialog asks it rather than restating it.
            if (!int.TryParse(row.Sets.Text, out var sets))
            {
                MessageBox.Show(this, $"Exercise {i + 1}: sets needs to be a whole number.", "Pauselet");
                row.Sets.Focus();
                return null;
            }
            if (!int.TryParse(row.Reps.Text, out var reps))
            {
                MessageBox.Show(this, $"Exercise {i + 1}: reps needs to be a whole number.", "Pauselet");
                row.Reps.Focus();
                return null;
            }
            // The timing fields carry the numbers a Mac user set, so a blank
            // or malformed one is refused rather than silently read as 0 —
            // that would discard a hold instead of asking about it.
            if (!TryParseSeconds(row.Hold, "hold", i, Exercise.MaxHoldSeconds, out var hold)
                || !TryParseSeconds(
                    row.RestBetweenReps, "rest between reps", i, Exercise.MaxRestSeconds,
                    out var restBetweenReps)
                || !TryParseSeconds(
                    row.RestBetweenSets, "rest between sets", i, Exercise.MaxRestSeconds,
                    out var restBetweenSets))
            {
                return null;
            }
            var exercise = new Exercise
            {
                Id = row.Id,
                Name = row.Name.Text,
                Instructions = row.Instructions.Text,
                Sets = sets,
                Reps = reps,
                HoldSeconds = hold,
                RestBetweenRepsSeconds = restBetweenReps,
                RestBetweenSetsSeconds = restBetweenSets,
            };
            if (!exercise.IsValid)
            {
                MessageBox.Show(
                    this,
                    $"Exercise {i + 1} needs a name, and at least one set of at least one rep.",
                    "Pauselet"
                );
                (row.Name.Text.Trim().Length == 0 ? row.Name : sets < 1 ? row.Sets : row.Reps).Focus();
                return null;
            }
            list.Add(exercise);
        }
        // Trims and folds the TextBox's CRLF line endings to the "\n" the data
        // file uses on every platform. Nothing is dropped: every row passed
        // IsValid, the same test Normalized applies.
        return Exercise.Normalized(list);
    }

    /// <summary>
    /// One timing field as whole seconds within its editor range, or
    /// <c>false</c> with the offending field named and focused.
    /// </summary>
    private bool TryParseSeconds(
        TextBox field, string label, int rowIndex, int maximum, out int seconds)
    {
        if (!int.TryParse(field.Text, out seconds) || seconds < 0 || seconds > maximum)
        {
            MessageBox.Show(
                this,
                $"Exercise {rowIndex + 1}: {label} needs to be a whole number of seconds "
                    + $"from 0 to {maximum}.",
                "Pauselet"
            );
            field.Focus();
            seconds = 0;
            return false;
        }
        return true;
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
