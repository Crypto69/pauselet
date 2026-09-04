using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
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
    /// <summary>
    /// Owns the API key and any request in flight. Shared with the import
    /// dialog the editor opens, so both agree on whether AI import is
    /// available without each reading the secret store.
    /// </summary>
    private readonly AIImportController _ai;
    private readonly DateTimeZone _zone = DateTimeZoneProviders.Tzdb.GetSystemDefault();

    private ListView? _reminderList;
    private ListView? _historyList;
    private StackPanel? _adherenceHost;
    private TextBlock? _historyEmptyState;
    /// <summary>
    /// The synthesizer behind the Voice Coach Test button, kept so a second
    /// press interrupts the first rather than talking over it. Created on
    /// first use, so opening Settings on a machine with no speech stack costs
    /// nothing.
    /// </summary>
    private SpeechCoach? _testSpeech;
    private bool _loadingPreferences;

    public SettingsWindow(
        ReminderEngine engine, OverlayPresenter overlays, AIImportController ai)
    {
        _engine = engine;
        _overlays = overlays;
        _ai = ai;
        _ai.Model = Core.AIImportModel.Resolve(engine.Settings.AiImportModel);

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
        Closed += (_, _) =>
        {
            _engine.PropertyChanged -= OnEngineChanged;
            _testSpeech?.Dispose();
            _testSpeech = null;
        };
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
                reminder.ScheduleLine,
                reminder.Priority.DisplayName(),
                reminder.IsEnabled))
            .ToList();
    }

    private void OpenEditor(Reminder? existing)
    {
        var editor = new ReminderEditorWindow(
            existing,
            _ai,
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

        stack.Children.Add(SectionHeader("Exercise Import"));
        stack.Children.Add(BuildAIImportSection(settings));

        stack.Children.Add(SectionHeader("Voice Coach"));
        stack.Children.Add(BuildVoiceCoachSection(settings));

        stack.Children.Add(SectionHeader("Notifications"));
        stack.Children.Add(new TextBlock
        {
            Text = "Normal and Important reminders arrive as Windows notifications. " +
                   "How long a banner stays on screen before moving to the " +
                   "notification centre is a Windows setting — from 5 seconds up " +
                   "to 5 minutes, and it applies to every app.",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            MaxWidth = 520,
            HorizontalAlignment = HorizontalAlignment.Left,
            Foreground = Theme.Brush(Theme.Current.SecondaryForeground),
            Margin = new Thickness(0, 4, 0, 0),
        });
        var timingLink = new Button
        {
            Content = "Change how long notifications stay on screen…",
            Padding = new Thickness(10, 4, 10, 4),
            Margin = new Thickness(0, 8, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        timingLink.Click += (_, _) =>
            OpenUri("ms-settings:easeofaccess-visualeffects");
        stack.Children.Add(timingLink);

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

    /// <summary>
    /// Opens a URI with the shell — ms-settings: pages, web links. The
    /// Windows counterpart of the Mac app's x-apple.systempreferences links.
    /// </summary>
    private static void OpenUri(string uri)
    {
        try
        {
            Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
        }
        catch
        {
            // A missing handler association is not ours to fix.
        }
    }

    /// <summary>
    /// Interpreting pasted exercise text with AI. (Mirrors AIImportSettings.swift.)
    ///
    /// Entirely optional: with no key stored, the importer still works using
    /// the built-in parser and the app makes no network requests at all. That
    /// is why the copy here is explicit about what gets sent where — it is the
    /// only part of the app that leaves the machine.
    /// </summary>
    private UIElement BuildAIImportSection(Core.Settings settings)
    {
        var stack = new StackPanel();

        stack.Children.Add(new TextBlock
        {
            Text = "Optional. Pasted exercise text is read on this PC; adding a key lets "
                + "you send it to OpenAI instead, which handles unusual wording better. "
                + "Only text you explicitly choose to interpret is ever sent, and your "
                + "key is encrypted for your Windows account — never written to data.json.",
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 520,
            HorizontalAlignment = HorizontalAlignment.Left,
            Foreground = Theme.Brush(Theme.Current.SecondaryForeground),
        });

        // Everything below the key field only makes sense once one is stored.
        var configured = new StackPanel();
        var status = new TextBlock
        {
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 520,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 6, 0, 0),
        };

        var keyRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 8, 0, 0),
        };
        keyRow.Children.Add(new TextBlock
        {
            Text = "OpenAI API key",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
            Foreground = Theme.Brush(Theme.Current.Foreground),
        });
        // A PasswordBox, not a TextBox: the key must not be shoulder-readable,
        // and it is held here only until Save hands it to the secret store.
        var keyField = new PasswordBox { Width = 260 };
        keyRow.Children.Add(keyField);

        var save = new Button
        {
            Content = "Save",
            Padding = new Thickness(12, 4, 12, 4),
            Margin = new Thickness(8, 0, 0, 0),
        };
        var remove = new Button
        {
            Content = "Remove",
            Padding = new Thickness(12, 4, 12, 4),
            Margin = new Thickness(8, 0, 0, 0),
        };
        keyRow.Children.Add(save);
        keyRow.Children.Add(remove);
        stack.Children.Add(keyRow);
        stack.Children.Add(status);

        void RefreshConfiguredState()
        {
            configured.Visibility = _ai.IsConfigured ? Visibility.Visible : Visibility.Collapsed;
            remove.Visibility = _ai.IsConfigured ? Visibility.Visible : Visibility.Collapsed;
        }

        save.Click += (_, _) =>
        {
            var error = _ai.Store(keyField.Password);
            // Never leave the secret sitting in a control once it is stored.
            keyField.Clear();
            status.Text = error ?? (_ai.IsConfigured
                ? "A key is stored, encrypted for your Windows account."
                : "");
            status.Foreground = Theme.Brush(
                error is null ? Theme.Current.SecondaryForeground : Theme.Current.Foreground);
            RefreshConfiguredState();
        };
        remove.Click += (_, _) =>
        {
            var error = _ai.Store(null);
            keyField.Clear();
            status.Text = error ?? "";
            RefreshConfiguredState();
        };

        var modelRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 8, 0, 0),
        };
        modelRow.Children.Add(new TextBlock
        {
            Text = "Model",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
            Foreground = Theme.Brush(Theme.Current.Foreground),
        });
        var modelPicker = new ComboBox { Width = 260 };
        foreach (var model in Core.AIImportModel.All)
        {
            modelPicker.Items.Add(new ComboBoxItem { Content = model.Title, Tag = model.Id });
        }
        var currentModel = Core.AIImportModel.Resolve(settings.AiImportModel);
        modelPicker.SelectedIndex = Core.AIImportModel.All
            .ToList()
            .FindIndex(model => model.Id == currentModel.Id);

        var modelDetail = new TextBlock
        {
            Text = currentModel.Detail,
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 520,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 4, 0, 0),
            Foreground = Theme.Brush(Theme.Current.SecondaryForeground),
        };
        modelPicker.SelectionChanged += (_, _) =>
        {
            if (_loadingPreferences) return;
            var id = (modelPicker.SelectedItem as ComboBoxItem)?.Tag as string;
            var chosen = Core.AIImportModel.Resolve(id);
            modelDetail.Text = chosen.Detail;
            _ai.Model = chosen;
            // null in settings means "the default", so the stored file does not
            // pin a model the user never chose.
            UpdateSettings(s => s with
            {
                AiImportModel = chosen.Id == Core.AIImportModel.Default.Id ? null : chosen.Id,
            });
        };
        modelRow.Children.Add(modelPicker);

        var test = new Button
        {
            Content = "Test",
            Padding = new Thickness(12, 4, 12, 4),
            Margin = new Thickness(8, 0, 0, 0),
            ToolTip = "Check the key and model by interpreting one short phrase",
        };
        var testStatus = new TextBlock
        {
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 520,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 4, 0, 0),
            Foreground = Theme.Brush(Theme.Current.SecondaryForeground),
        };
        test.Click += async (_, _) =>
        {
            if (_ai.IsTesting) return;
            test.IsEnabled = false;
            testStatus.Text = "Testing…";
            _ai.Model = Core.AIImportModel.Resolve(_engine.Settings.AiImportModel);
            await _ai.TestKeyAsync();
            testStatus.Text = _ai.LastTestResult switch
            {
                { Succeeded: true } => "The key works.",
                { Message: { } message } => message,
                _ => "",
            };
            test.IsEnabled = true;
        };
        modelRow.Children.Add(test);

        configured.Children.Add(modelRow);
        configured.Children.Add(modelDetail);
        configured.Children.Add(testStatus);
        stack.Children.Add(configured);

        RefreshConfiguredState();
        if (_ai.IsConfigured)
        {
            status.Text = "A key is stored, encrypted for your Windows account.";
        }
        return stack;
    }

    /// <summary>
    /// Whether the exercise coach talks, which system voice it uses, and a way
    /// to hear it before an exercise does. (Mirrors VoiceCoachSettings.swift.)
    ///
    /// Voices are read once when the tab is built: enumerating them is not
    /// free, and the list only changes when the user installs one in Windows'
    /// speech settings.
    /// </summary>
    private UIElement BuildVoiceCoachSection(Core.Settings settings)
    {
        // What the Test button says — the coach's first real cue.
        const string sampleCue = "Set 1, rep 1. Hold for 5 seconds.";

        var stack = new StackPanel();
        var details = new StackPanel
        {
            Margin = new Thickness(22, 0, 0, 0),
            Visibility = settings.VoiceCoachEnabled ? Visibility.Visible : Visibility.Collapsed,
        };

        stack.Children.Add(CheckRow(
            "Speak exercise cues", settings.VoiceCoachEnabled,
            value =>
            {
                UpdateSettings(s => s with { VoiceCoachEnabled = value });
                details.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
            },
            help: "Reads out each set, rep, hold and rest while the exercise "
                + "takeover coaches you through an exercise. Only exercises with "
                + "a hold time are coached; the others keep their tick box."
        ));

        var voices = VoiceCatalog.InstalledVoices();

        var voiceRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 6, 0, 0),
        };
        voiceRow.Children.Add(new TextBlock
        {
            Text = "Voice",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
            Foreground = Theme.Brush(Theme.Current.Foreground),
        });

        var voicePicker = new ComboBox { Width = 260 };
        // The empty tag stands for "no preference": the best installed voice,
        // re-resolved on every utterance so uninstalling one degrades rather
        // than silences.
        voicePicker.Items.Add(new ComboBoxItem { Content = "Best available", Tag = "" });
        foreach (var voice in voices)
        {
            voicePicker.Items.Add(new ComboBoxItem { Content = voice.Label, Tag = voice.Id });
        }
        voicePicker.SelectedIndex = Math.Max(0, voices
            .ToList()
            .FindIndex(voice => voice.Id == settings.VoiceCoachVoiceIdentifier) + 1);
        voicePicker.SelectionChanged += (_, _) =>
        {
            if (_loadingPreferences) return;
            var id = (voicePicker.SelectedItem as ComboBoxItem)?.Tag as string;
            UpdateSettings(s => s with
            {
                VoiceCoachVoiceIdentifier = string.IsNullOrEmpty(id) ? null : id,
            });
        };
        voiceRow.Children.Add(voicePicker);

        var test = new Button
        {
            Content = "Test",
            Padding = new Thickness(12, 4, 12, 4),
            Margin = new Thickness(8, 0, 0, 0),
            ToolTip = "Say a sample cue with the chosen voice",
        };
        test.Click += (_, _) =>
        {
            var current = _engine.Settings;
            _testSpeech ??= new SpeechCoach();
            _testSpeech.Speak(
                sampleCue, current.VoiceCoachVoiceIdentifier, current.VoiceCoachRate);
        };
        voiceRow.Children.Add(test);
        details.Children.Add(voiceRow);

        details.Children.Add(NumberRow(
            "Speaking pace (percent of normal)", settings.VoiceCoachRate, 30, 70,
            value => UpdateSettings(s => s with { VoiceCoachRate = value })
        ));
        details.Children.Add(new TextBlock
        {
            Text = voices.Count == 0
                ? "No English speech voices are installed. Add one in Windows "
                    + "Settings › Time & language › Speech."
                : "English voices only. Add or remove voices in Windows Settings › "
                    + "Time & language › Speech.",
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 520,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 6, 0, 0),
            Foreground = Theme.Brush(Theme.Current.SecondaryForeground),
        });

        stack.Children.Add(details);
        return stack;
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

    /// <summary>The window the history tab reports over; 7 days as on the Mac.</summary>
    private static readonly (string Label, int Days)[] HistoryWindows =
        [("24 hours", 1), ("7 days", 7), ("30 days", 30)];

    private int _historyWindowDays = 7;

    private UIElement BuildHistoryTab()
    {
        var layout = new DockPanel { Margin = new Thickness(12) };

        // The window picker and Clear share the top row, as on the Mac. WPF
        // has no segmented control, so the three windows are radio buttons
        // styled as toggles — one choice, visibly exclusive.
        var toolbar = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
        var windowPicker = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (label, days) in HistoryWindows)
        {
            var option = new RadioButton
            {
                Content = label,
                GroupName = "HistoryWindow",
                IsChecked = days == _historyWindowDays,
                Margin = new Thickness(0, 0, 14, 0),
                VerticalAlignment = VerticalAlignment.Center,
            };
            option.Checked += (_, _) =>
            {
                _historyWindowDays = days;
                ReloadHistory();
            };
            windowPicker.Children.Add(option);
        }
        toolbar.Children.Add(windowPicker);

        var clear = new Button
        {
            Content = "Clear History",
            Padding = new Thickness(12, 5, 12, 5),
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        clear.Click += (_, _) =>
        {
            var answer = MessageBox.Show(
                this, "Clear all reminder history?", "Clear History",
                MessageBoxButton.YesNo, MessageBoxImage.Question
            );
            if (answer == MessageBoxResult.Yes) _engine.ClearHistory();
        };
        DockPanel.SetDock(clear, Dock.Right);
        toolbar.Children.Add(clear);
        DockPanel.SetDock(toolbar, Dock.Top);
        layout.Children.Add(toolbar);

        // Adherence above the log: the question the app exists to answer —
        // are you actually doing them? — before the event by event detail.
        _adherenceHost = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
        DockPanel.SetDock(_adherenceHost, Dock.Top);
        layout.Children.Add(_adherenceHost);

        // Shown instead of the log when nothing fired in the window, so an
        // empty table never reads as a broken one.
        _historyEmptyState = new TextBlock
        {
            Text = "No activity in this period",
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = Theme.Brush(Theme.Current.SecondaryForeground),
            Visibility = Visibility.Collapsed,
        };

        _historyList = new ListView();
        var view = new GridView();
        view.Columns.Add(Column("When", nameof(HistoryRowModel.When), 170));
        view.Columns.Add(Column("Reminder", nameof(HistoryRowModel.Title), 260));
        view.Columns.Add(Column("Outcome", nameof(HistoryRowModel.Outcome), 110));
        _historyList.View = view;

        var body = new Grid();
        body.Children.Add(_historyList);
        body.Children.Add(_historyEmptyState);
        layout.Children.Add(body);

        ReloadHistory();
        return layout;
    }

    private void ReloadHistory()
    {
        if (_historyList is null) return;

        var since = SystemClock.Instance.GetCurrentInstant()
            - NodaTime.Duration.FromDays(_historyWindowDays);
        var recent = _engine.Events
            .Where(e => e.Date >= since)
            .Reverse()
            // The Mac caps the log at 200 rows; a longer one is scrolling, not
            // reading, and the adherence figures above already summarize it.
            .Take(200)
            .Select(e => new HistoryRowModel(
                e.Date.InZone(_zone).ToDateTimeUnspecified().ToString("g"),
                e.ReminderTitle,
                e.EventOutcome.ToString().ToLowerInvariant()))
            .ToList();

        _historyList.ItemsSource = recent;
        var isEmpty = recent.Count == 0;
        _historyList.Visibility = isEmpty ? Visibility.Collapsed : Visibility.Visible;
        if (_historyEmptyState is not null)
        {
            _historyEmptyState.Visibility = isEmpty ? Visibility.Visible : Visibility.Collapsed;
        }

        ReloadAdherence(since, isEmpty);
    }

    /// <summary>
    /// One bar per reminder that fired in the window, showing completed ÷
    /// fired. Reminders with nothing in the window are left out rather than
    /// shown at 0%, which would read as a failure instead of a silence.
    /// </summary>
    private void ReloadAdherence(Instant since, bool isEmpty)
    {
        if (_adherenceHost is null) return;
        _adherenceHost.Children.Clear();
        if (isEmpty) return;

        var rows = _engine.Reminders
            .Select(reminder => (reminder, adherence: _engine.Adherence(reminder.Id, since)))
            .Where(row => row.adherence is not null)
            .ToList();
        if (rows.Count == 0) return;

        _adherenceHost.Children.Add(new TextBlock
        {
            Text = "Adherence",
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = Theme.Brush(Theme.Current.Foreground),
            Margin = new Thickness(0, 0, 0, 4),
        });

        foreach (var (reminder, adherence) in rows)
        {
            _adherenceHost.Children.Add(AdherenceRow(reminder, adherence!.Value));
        }
    }

    /// <summary>Icon, title, a progress bar and the percentage — the Mac's AdherenceRow.</summary>
    private static UIElement AdherenceRow(Reminder reminder, double adherence)
    {
        var palette = Theme.Current;
        var row = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };

        var icon = Ui.Glyph(reminder.SymbolName, 13, Theme.Brush(palette.Accent));
        icon.Width = 20;
        icon.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);

        var percent = new TextBlock
        {
            Text = $"{(int)(adherence * 100)}%",
            FontSize = 11,
            FontWeight = FontWeights.Medium,
            Width = 40,
            TextAlignment = TextAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = Theme.Brush(palette.Foreground),
        };
        DockPanel.SetDock(percent, Dock.Right);
        row.Children.Add(percent);

        var bar = new ProgressBar
        {
            Minimum = 0,
            Maximum = 1,
            Value = adherence,
            Width = 120,
            Height = 6,
            Margin = new Thickness(8, 0, 8, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = Theme.Brush(palette.Accent),
        };
        DockPanel.SetDock(bar, Dock.Right);
        row.Children.Add(bar);

        // Last, so it takes the space the icon, bar and percentage leave.
        row.Children.Add(new TextBlock
        {
            Text = reminder.Title,
            FontSize = 12,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = Theme.Brush(palette.Foreground),
        });
        return row;
    }

    // MARK: - About tab

    /// <summary>
    /// What the app is, who made it, and where to find more — mirroring the
    /// Mac AboutTab section for section, so someone who finds the app through
    /// the repository and someone who opens Settings are told the same thing.
    /// The one wording change: the Mac's sentence about Spotify/AppleScript
    /// has no Windows counterpart (music is deferred here), so the local-only
    /// paragraph ends earlier.
    /// </summary>
    private UIElement BuildAboutTab()
    {
        var palette = Theme.Current;
        var stack = new StackPanel { Margin = new Thickness(24) };

        // Header: the real app icon beside the name, so this looks like the
        // app rather than a generic panel.
        var header = new StackPanel { Orientation = Orientation.Horizontal };
        if (LoadAppIcon() is { } icon)
        {
            header.Children.Add(new Image
            {
                Source = icon,
                Width = 72,
                Height = 72,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 16, 0),
            });
        }
        else
        {
            var fallback = Ui.Glyph("bell", 56, Theme.Brush(palette.Accent));
            fallback.Width = 72;
            fallback.Margin = new Thickness(0, 0, 16, 0);
            header.Children.Add(fallback);
        }

        var titleStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titleStack.Children.Add(new TextBlock
        {
            Text = "Pauselet",
            FontSize = 24,
            FontWeight = FontWeights.SemiBold,
            Foreground = Theme.Brush(palette.Foreground),
        });
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "—";
        titleStack.Children.Add(SecondaryText($"Version {version}"));
        var tagline = SecondaryText(
            "Recurring reminders for Windows, where you choose how loudly " +
            "each one interrupts you."
        );
        tagline.Margin = new Thickness(0, 2, 0, 0);
        tagline.MaxWidth = 440;
        titleStack.Children.Add(tagline);
        header.Children.Add(titleStack);
        stack.Children.Add(header);

        stack.Children.Add(AboutDivider(palette));

        // Description — mirrors the README's opening, deliberately.
        var whoFor = SecondaryText(
            "It was built for a wheelchair user who needs regular pressure " +
            "relief, so the central idea is that a medically important prompt " +
            "and a nice-to-have nudge should not feel the same. It works just " +
            "as well for anyone who wants to drink water, stretch, take " +
            "medication, or call their mum every Sunday."
        );
        stack.Children.Add(whoFor);
        var localOnly = SecondaryText(
            "Everything is stored locally. There is no account, no sync, and " +
            "no network code in the app at all."
        );
        localOnly.Margin = new Thickness(0, 10, 0, 0);
        stack.Children.Add(localOnly);

        stack.Children.Add(AboutDivider(palette));

        stack.Children.Add(new TextBlock
        {
            Text = "More from MyAccessibility.ai",
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = Theme.Brush(palette.Foreground),
            Margin = new Thickness(0, 0, 0, 8),
        });
        stack.Children.Add(SecondaryText(
            "A nonprofit making free accessibility software, 3D print files " +
            "and resources for people with spinal cord injuries and disabilities."
        ));

        // Wraps, so a narrow window does not clip the last link.
        var links = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
        links.Children.Add(LinkButton("globe", "myaccessibility.ai", "https://myaccessibility.ai"));
        links.Children.Add(LinkButton("play.rectangle", "YouTube", "https://www.youtube.com/@myaccessibility"));
        links.Children.Add(LinkButton("camera", "Instagram", "https://www.instagram.com/myaccessibility"));
        links.Children.Add(LinkButton("person.crop.square", "LinkedIn", "https://www.linkedin.com/in/chris-venter/"));
        stack.Children.Add(links);

        stack.Children.Add(AboutDivider(palette));

        const string email = "support@myaccessibility.ai";
        var feedback = new StackPanel { Orientation = Orientation.Horizontal };
        var prompt = SecondaryText("Questions or feedback:");
        prompt.VerticalAlignment = VerticalAlignment.Center;
        prompt.Margin = new Thickness(0, 0, 4, 0);
        feedback.Children.Add(prompt);
        var emailLink = Ui.RoundedButton(
            email, Brushes.Transparent, Theme.Brush(palette.Accent),
            cornerRadius: 4, padding: new Thickness(2, 0, 2, 0)
        );
        emailLink.FontSize = 12;
        emailLink.Click += (_, _) => OpenUri($"mailto:{email}");
        feedback.Children.Add(emailLink);
        stack.Children.Add(feedback);

        var licence = new TextBlock
        {
            Text = "Free and open source, under the MIT licence.",
            FontSize = 11,
            Foreground = Theme.Brush(palette.TertiaryForeground),
            Margin = new Thickness(0, 8, 0, 0),
        };
        stack.Children.Add(licence);

        return new ScrollViewer
        {
            Content = stack,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
    }

    private static TextBlock SecondaryText(string text) => new()
    {
        Text = text,
        FontSize = 12,
        TextWrapping = TextWrapping.Wrap,
        MaxWidth = 560,
        HorizontalAlignment = HorizontalAlignment.Left,
        Foreground = Theme.Brush(Theme.Current.SecondaryForeground),
    };

    private static Border AboutDivider(Theme.Palette palette) => new()
    {
        Height = 1,
        Background = Theme.Brush(palette.Divider),
        Margin = new Thickness(0, 18, 0, 18),
    };

    private Button LinkButton(string sfSymbol, string label, string url)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        var glyph = Ui.Glyph(sfSymbol, 14, Theme.Brush(Theme.Current.Foreground));
        glyph.Margin = new Thickness(0, 0, 5, 0);
        content.Children.Add(glyph);
        content.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 12,
            Foreground = Theme.Brush(Theme.Current.Foreground),
            VerticalAlignment = VerticalAlignment.Center,
        });

        var button = Ui.RoundedButton(
            content, Theme.Brush(Theme.Current.HoverBackground),
            Theme.Brush(Theme.Current.Foreground),
            Theme.Brush(Theme.Current.Divider),
            cornerRadius: 6, padding: new Thickness(10, 5, 10, 5)
        );
        button.FontSize = 12;
        button.Margin = new Thickness(0, 0, 8, 8);
        button.ToolTip = url;
        button.Click += (_, _) => OpenUri(url);
        return button;
    }

    /// <summary>
    /// The app icon's largest frame from the bundled .ico, or <c>null</c> if
    /// the asset is missing — the caller falls back to a glyph, as the Mac
    /// About tab does.
    /// </summary>
    private static ImageSource? LoadAppIcon()
    {
        try
        {
            var path = System.IO.Path.Combine(
                AppContext.BaseDirectory, "Assets", "Pauselet.ico"
            );
            var decoder = BitmapDecoder.Create(
                new Uri(path), BitmapCreateOptions.None, BitmapCacheOption.OnLoad
            );
            return decoder.Frames.OrderByDescending(frame => frame.PixelWidth).First();
        }
        catch
        {
            return null;
        }
    }
}
