using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// Paste a physiotherapist's instructions, see what was understood, fix
/// anything wrong, and add the lot — instead of typing six fields per
/// exercise. (Mirrors ExerciseImportSheet.swift.)
///
/// The preview rows are real editable fields, not a read-only summary, so
/// correcting a mis-parse happens here rather than after the exercises have
/// been committed. Nothing is added until the person presses Add, which is
/// what makes an imperfect parse safe.
/// </summary>
internal sealed class ExerciseImportWindow : Window
{
    private const string Placeholder =
        "3 sets of 10 chin tucks, hold 5 seconds, rest 30 seconds between sets\n"
        + "Wall slides 3 x 15";

    /// <summary>The controls for one previewed exercise, in order.</summary>
    private sealed record DraftRow(
        Guid Id,
        Border Container,
        TextBox Name,
        TextBox Instructions,
        TextBox Sets,
        TextBox Reps,
        TextBox Hold,
        TextBox RestBetweenReps,
        TextBox RestBetweenSets);

    private readonly AIImportController _ai;
    private readonly Action<IReadOnlyList<Exercise>> _onAdd;
    /// <summary>
    /// Shown when a request fails. The local parse stays on screen and this
    /// says what happened, rather than silently substituting a worse result
    /// for the one the person asked for.
    /// </summary>
    private readonly TextBlock _errorMessage;
    private readonly List<DraftRow> _drafts = [];
    private readonly TextBox _text;
    private readonly StackPanel _draftsHost = new();
    private readonly TextBlock _foundHeading;
    private readonly TextBlock _emptyState;
    private readonly Button _add;
    private readonly Button _clear;
    /// <summary>
    /// Set once the person has asked for a parse, so the empty state does not
    /// read as a failure before they have typed anything.
    /// </summary>
    private bool _hasParsed;

    public ExerciseImportWindow(
        AIImportController ai, Action<IReadOnlyList<Exercise>> onAdd)
    {
        _ai = ai;
        _onAdd = onAdd;
        var palette = Theme.Current;

        Title = "Import Exercises";
        Width = 520;
        Height = 560;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Theme.Brush(palette.WindowBackground);

        var root = new DockPanel { Margin = new Thickness(16) };

        var header = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
        header.Children.Add(new TextBlock
        {
            Text = "Import Exercises",
            FontSize = 15,
            FontWeight = FontWeights.SemiBold,
            Foreground = Theme.Brush(palette.Foreground),
        });
        header.Children.Add(new TextBlock
        {
            Text = "Paste what your physiotherapist wrote. Check the result before adding it.",
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 2, 0, 0),
            Foreground = Theme.Brush(palette.SecondaryForeground),
        });
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);

        // Cancel and Add docked to the bottom, so a long list of parsed rows
        // never pushes the only way to commit or back out off-screen.
        var footer = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        var cancel = new Button
        {
            Content = "Cancel",
            Padding = new Thickness(14, 6, 14, 6),
            IsCancel = true,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        cancel.Click += (_, _) => Close();
        footer.Children.Add(cancel);

        _add = new Button
        {
            Content = "Add 0 Exercises",
            Padding = new Thickness(14, 6, 14, 6),
            IsDefault = true,
            IsEnabled = false,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        _add.Click += (_, _) =>
        {
            if (BuildDrafts() is not { } exercises) return;
            _onAdd(exercises);
            Close();
        };
        DockPanel.SetDock(_add, Dock.Right);
        footer.Children.Add(_add);
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);

        var body = new StackPanel();

        _text = new TextBox
        {
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 120,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        body.Children.Add(_text);
        body.Children.Add(new TextBlock
        {
            Text = Placeholder,
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 4, 0, 0),
            Foreground = Theme.Brush(palette.SecondaryForeground),
        });

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 8, 0, 0),
        };
        var read = new Button
        {
            Content = "Read Text",
            Padding = new Thickness(12, 4, 12, 4),
            ToolTip = "Pull the exercises out of the text on this PC",
        };
        read.Click += (_, _) => ParseLocally();
        actions.Children.Add(read);

        // Only offered when a key is stored: with none, the local parser is
        // the whole feature and a disabled button would just raise a question.
        if (_ai.IsConfigured)
        {
            var interpret = new Button
            {
                Content = "Interpret with AI",
                Padding = new Thickness(12, 4, 12, 4),
                Margin = new Thickness(8, 0, 0, 0),
                ToolTip = "Send the text to OpenAI, which handles unusual wording better",
            };
            interpret.Click += async (_, _) => await InterpretAsync(interpret);
            actions.Children.Add(interpret);
        }

        _clear = new Button
        {
            Content = "Clear",
            Padding = new Thickness(12, 4, 12, 4),
            Margin = new Thickness(8, 0, 0, 0),
            Visibility = Visibility.Collapsed,
        };
        _clear.Click += (_, _) => Reset();
        actions.Children.Add(_clear);
        body.Children.Add(actions);

        _errorMessage = new TextBlock
        {
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 8, 0, 0),
            Visibility = Visibility.Collapsed,
            Foreground = Theme.Brush(palette.Foreground),
        };
        body.Children.Add(_errorMessage);

        _foundHeading = new TextBlock
        {
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 12, 0, 0),
            Visibility = Visibility.Collapsed,
            Foreground = Theme.Brush(palette.Foreground),
        };
        body.Children.Add(_foundHeading);

        _emptyState = new TextBlock
        {
            Text = "No exercises found in that text. Try including the sets and reps, "
                + "like \"3 sets of 10\".",
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 12, 0, 0),
            Visibility = Visibility.Collapsed,
            Foreground = Theme.Brush(palette.SecondaryForeground),
        };
        body.Children.Add(_emptyState);
        body.Children.Add(_draftsHost);

        root.Children.Add(new ScrollViewer
        {
            Content = body,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        });
        Content = root;
    }

    // MARK: - Actions

    /// <summary>
    /// Interprets the text with OpenAI, replacing the preview rows on success.
    /// A failure leaves whatever was parsed locally exactly where it was.
    /// </summary>
    private async Task InterpretAsync(Button trigger)
    {
        if (_text.Text.Trim().Length == 0) return;
        _errorMessage.Visibility = Visibility.Collapsed;
        trigger.IsEnabled = false;
        var label = trigger.Content;
        trigger.Content = "Interpreting…";
        try
        {
            var interpreted = await _ai.InterpretAsync(_text.Text);
            _hasParsed = true;
            _drafts.Clear();
            _draftsHost.Children.Clear();
            foreach (var exercise in interpreted) AddDraftRow(exercise);
            UpdateState();
        }
        catch (AIImportException exception)
        {
            _errorMessage.Text = exception.Message;
            _errorMessage.Visibility = Visibility.Visible;
        }
        finally
        {
            trigger.Content = label;
            trigger.IsEnabled = true;
        }
    }

    private void ParseLocally()
    {
        _errorMessage.Visibility = Visibility.Collapsed;
        _hasParsed = true;
        var parsed = ExerciseImporter.Parse(_text.Text);
        _drafts.Clear();
        _draftsHost.Children.Clear();
        foreach (var exercise in parsed) AddDraftRow(exercise);
        UpdateState();
    }

    private void Reset()
    {
        _errorMessage.Visibility = Visibility.Collapsed;
        _hasParsed = false;
        _drafts.Clear();
        _draftsHost.Children.Clear();
        UpdateState();
    }

    private void UpdateState()
    {
        var count = _drafts.Count;
        _foundHeading.Text =
            $"Found {count} {(count == 1 ? "exercise" : "exercises")} — edit anything that came out wrong";
        _foundHeading.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _emptyState.Visibility =
            count == 0 && _hasParsed ? Visibility.Visible : Visibility.Collapsed;
        _clear.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _add.Content = $"Add {count} {(count == 1 ? "Exercise" : "Exercises")}";
        _add.IsEnabled = count > 0;
    }

    /// <summary>
    /// The preview rows as exercises, or <c>null</c> (having said which row is
    /// wrong) when one cannot be performed. The same rules as the editor's own
    /// rows, because these become exactly those rows.
    /// </summary>
    private IReadOnlyList<Exercise>? BuildDrafts()
    {
        var list = new List<Exercise>();
        for (var i = 0; i < _drafts.Count; i++)
        {
            var row = _drafts[i];
            if (!TryParseCount(row.Sets, "sets", i, out var sets)
                || !TryParseCount(row.Reps, "reps", i, out var reps)
                || !TryParseSeconds(row.Hold, "hold", i, Exercise.MaxHoldSeconds, out var hold)
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
                    "Pauselet");
                row.Name.Focus();
                return null;
            }
            list.Add(exercise);
        }
        return Exercise.Normalized(list) ?? [];
    }

    private bool TryParseCount(TextBox field, string label, int rowIndex, out int value)
    {
        if (int.TryParse(field.Text, out value)) return true;
        MessageBox.Show(
            this, $"Exercise {rowIndex + 1}: {label} needs to be a whole number.", "Pauselet");
        field.Focus();
        return false;
    }

    private bool TryParseSeconds(
        TextBox field, string label, int rowIndex, int maximum, out int seconds)
    {
        if (int.TryParse(field.Text, out seconds) && seconds >= 0 && seconds <= maximum)
        {
            return true;
        }
        MessageBox.Show(
            this,
            $"Exercise {rowIndex + 1}: {label} needs to be a whole number of seconds "
                + $"from 0 to {maximum}.",
            "Pauselet");
        field.Focus();
        seconds = 0;
        return false;
    }

    // MARK: - One preview row

    private void AddDraftRow(Exercise exercise)
    {
        var palette = Theme.Current;
        var body = new StackPanel();

        var name = new TextBox { Text = exercise.Name };
        var instructions = new TextBox
        {
            Text = exercise.Instructions,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 40,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        var sets = new TextBox { Width = 40, Text = exercise.Sets.ToString() };
        var reps = new TextBox { Width = 40, Text = exercise.Reps.ToString() };
        var hold = new TextBox { Width = 44, Text = exercise.HoldSeconds.ToString() };
        var restBetweenReps = new TextBox
        {
            Width = 44,
            Text = exercise.RestBetweenRepsSeconds.ToString(),
        };
        var restBetweenSets = new TextBox
        {
            Width = 44,
            Text = exercise.RestBetweenSetsSeconds.ToString(),
        };

        var remove = new Button
        {
            Content = "Remove",
            Padding = new Thickness(8, 1, 8, 1),
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        var headerRow = new DockPanel();
        DockPanel.SetDock(remove, Dock.Right);
        headerRow.Children.Add(remove);
        headerRow.Children.Add(new TextBlock
        {
            Text = "Name",
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = Theme.Brush(palette.SecondaryForeground),
        });
        body.Children.Add(headerRow);
        body.Children.Add(name);

        body.Children.Add(SmallLabel("Instructions"));
        body.Children.Add(instructions);

        var counts = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 6, 0, 0),
        };
        counts.Children.Add(InlineLabel("Sets"));
        counts.Children.Add(sets);
        counts.Children.Add(InlineLabel("Reps"));
        counts.Children.Add(reps);
        counts.Children.Add(InlineLabel("Hold"));
        counts.Children.Add(hold);
        body.Children.Add(counts);

        var rests = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 6, 0, 0),
        };
        rests.Children.Add(InlineLabel("Rest"));
        rests.Children.Add(restBetweenReps);
        rests.Children.Add(InlineLabel("Set rest"));
        rests.Children.Add(restBetweenSets);
        body.Children.Add(rests);

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

        var row = new DraftRow(
            exercise.Id, container, name, instructions, sets, reps,
            hold, restBetweenReps, restBetweenSets);
        remove.Click += (_, _) =>
        {
            _drafts.Remove(row);
            _draftsHost.Children.Remove(container);
            UpdateState();
        };
        _drafts.Add(row);
        _draftsHost.Children.Add(container);
    }

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
}
