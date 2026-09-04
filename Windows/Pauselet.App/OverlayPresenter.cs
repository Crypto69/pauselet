using NodaTime;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// Owns every on-screen reminder surface and routes each priority tier to the
/// right presentation: subtle → corner card, normal/important → toast,
/// critical → full-screen takeover on every monitor.
///
/// Reminders that fire while their surface is occupied are queued, not
/// dropped: after sleep or the end of quiet hours several reminders routinely
/// become due on the same tick, and the second must not silently replace the
/// first — for a pressure-relief prompt that would be a missed reminder.
///
/// The queue is only honoured while it is fresh, though. Entries that sat for
/// hours behind an unacknowledged overlay are pruned when the user finally
/// responds, so pressing Finish after falling asleep does not hand them the
/// next takeover, and the next. See <see cref="AdvanceCritical"/>;
/// <c>ReminderEngine.ShouldPresentQueued</c> holds the policy.
/// </summary>
internal sealed class OverlayPresenter : IReminderPresenting
{
    private readonly List<CriticalOverlayWindow> _criticalWindows = [];
    private readonly List<(Reminder Reminder, Core.Settings Settings, Instant QueuedAt)>
        _criticalQueue = [];

    /// <summary>
    /// The coach driving the takeover currently on screen, shared by every
    /// monitor's window so a cue is spoken once and a tick shows everywhere.
    /// Survives a monitor hot-plug: the windows are rebuilt around it rather
    /// than the session being restarted.
    /// </summary>
    private ExerciseCoach? _criticalCoach;

    private SubtleCardWindow? _subtleCard;
    private readonly List<(Reminder Reminder, Core.Settings Settings, int MinimumSeconds)>
        _subtleQueue = [];

    /// <summary>Set by the app so overlay buttons can talk back to the engine.</summary>
    public ReminderEngine? Engine { get; set; }

    private readonly ToastPresenter _notifier;

    public OverlayPresenter(ToastPresenter notifier)
    {
        _notifier = notifier;
        // When the system will not deliver a notification, show the reminder in
        // the app's own window instead so it is never silently dropped. An
        // important reminder demoted to the corner card must not also inherit
        // the card's 8-second lifetime — it gets a sticky minimum instead.
        notifier.FallbackPresenter = (reminder, settings) =>
        {
            var minimum = reminder.Priority >= Priority.Important ? 60 : 0;
            ShowSubtle(reminder, settings, isPreview: false, minimumSeconds: minimum);
        };
    }

    public void Present(Reminder reminder, Core.Settings settings)
    {
        Log.Line($"present: {reminder.Title} ({reminder.Priority})");
        switch (reminder.Priority)
        {
            case Priority.Subtle:
                ShowSubtle(reminder, settings, isPreview: false);
                break;
            case Priority.Normal:
            case Priority.Important:
                _notifier.Post(reminder, settings);
                break;
            case Priority.Critical:
                ShowCritical(reminder, settings, isPreview: false);
                break;
        }
    }

    public void DismissAll()
    {
        _criticalQueue.Clear();
        _subtleQueue.Clear();
        CloseCriticalWindows();
        CloseSubtleCard();
    }

    /// <summary>
    /// Shows <paramref name="reminder"/> exactly as it would appear when it
    /// fires, without touching its schedule or history.
    ///
    /// Buttons on a previewed overlay only close it — a preview must never
    /// complete or snooze the real reminder, or looking at one would silently
    /// reset its timer. A preview replaces whatever is showing rather than
    /// queueing behind it: the user asked to see it now.
    /// </summary>
    public void Preview(Reminder reminder, Core.Settings settings)
    {
        switch (reminder.Priority)
        {
            case Priority.Subtle:
            // Posting a real toast for a preview would leave it sitting in the
            // notification centre, so the notification tiers preview as the
            // in-app card. It carries the same title, message and icon.
            case Priority.Normal:
            case Priority.Important:
                ShowSubtle(reminder, settings, isPreview: true);
                break;
            case Priority.Critical:
                ShowCritical(reminder, settings, isPreview: true);
                break;
        }
    }

    // MARK: - Critical takeover

    private void ShowCritical(Reminder reminder, Core.Settings settings, bool isPreview)
    {
        if (_criticalWindows.Count > 0)
        {
            if (isPreview)
            {
                // A preview replaces whatever is on screen. CloseCriticalWindows
                // only takes the windows down, so the coach behind them has to
                // be ended here too — otherwise its timer keeps ticking and
                // speaking with nothing left to show it.
                ShutDownCoach();
                CloseCriticalWindows();
            }
            else
            {
                // Another critical reminder is already demanding attention.
                // Queue this one; it appears the moment the current one is
                // acknowledged — provided that moment comes soon enough for it
                // to still be worth showing.
                _criticalQueue.Add(
                    (reminder, settings, SystemClock.Instance.GetCurrentInstant())
                );
                return;
            }
        }
        DisplayCritical(reminder, settings, isPreview);
    }

    private void DisplayCritical(Reminder reminder, Core.Settings settings, bool isPreview)
    {
        // Always Critical here, but asked of the settings rather than assumed,
        // so the one rule about which tiers make a sound stays in one place.
        if (settings.PlaysSound(reminder.Priority))
        {
            Sounds.Play(reminder.SoundName ?? "Submarine");
        }

        _criticalCoach = BuildCoach(reminder, settings);

        // One window per monitor: on a multi-display desk the user may not be
        // looking at the main display.
        var screens = System.Windows.Forms.Screen.AllScreens;
        foreach (var screen in screens)
        {
            var window = new CriticalOverlayWindow(
                reminder,
                screen.Bounds,
                isPrimary: screen.Primary,
                coach: _criticalCoach,
                onComplete: () =>
                {
                    if (!isPreview) Engine?.Complete(reminder.Id);
                    AdvanceCritical(reminder.Id);
                },
                onSnooze: () =>
                {
                    if (!isPreview) Engine?.Snooze(reminder.Id);
                    AdvanceCritical(reminder.Id);
                }
            );
            // Monitor hot-plug mid-takeover: re-lay the panels out (a gap the
            // Mac version still has; WM_DISPLAYCHANGE makes it easy here).
            window.DisplayLayoutChanged += () =>
                RelayoutCritical(reminder, settings, isPreview);
            _criticalWindows.Add(window);
            window.Show();
        }

        Log.Line($"critical takeover shown on {_criticalWindows.Count} display(s)");

        // A polite activation attempt so the advertised Return / S shortcuts
        // work without a click. Windows may refuse focus to a background
        // process — the takeover itself does not depend on it (topmost
        // coverage works regardless) and the buttons remain primary.
        _criticalWindows.FirstOrDefault(w => w.IsPrimaryScreen)?.TryActivate();
    }

    /// <summary>
    /// Tears down and re-shows the takeover after a monitor is plugged in or
    /// removed while it is up, so every current display is covered. The
    /// re-display skips the sound — the reminder already announced itself.
    /// </summary>
    private void RelayoutCritical(Reminder reminder, Core.Settings settings, bool isPreview)
    {
        if (_criticalWindows.Count == 0) return;
        CloseCriticalWindows();
        var screens = System.Windows.Forms.Screen.AllScreens;
        foreach (var screen in screens)
        {
            var window = new CriticalOverlayWindow(
                reminder,
                screen.Bounds,
                isPrimary: screen.Primary,
                coach: _criticalCoach,
                onComplete: () =>
                {
                    if (!isPreview) Engine?.Complete(reminder.Id);
                    AdvanceCritical(reminder.Id);
                },
                onSnooze: () =>
                {
                    if (!isPreview) Engine?.Snooze(reminder.Id);
                    AdvanceCritical(reminder.Id);
                }
            );
            window.DisplayLayoutChanged += () =>
                RelayoutCritical(reminder, settings, isPreview);
            _criticalWindows.Add(window);
            window.Show();
        }
    }

    /// <summary>
    /// Closes the current takeover and shows the next queued one that is still
    /// current, if any.
    ///
    /// Anything that queued behind an overlay nobody was looking at — the user
    /// fell asleep, or left the desk for the afternoon — is dropped rather
    /// than delivered in a burst, and recorded as missed so history shows what
    /// became of it.
    /// </summary>
    private void AdvanceCritical(Guid acknowledgedId)
    {
        var now = SystemClock.Instance.GetCurrentInstant();
        var dropped = new List<Reminder>();
        _criticalQueue.RemoveAll(entry =>
        {
            var keep = ReminderEngine.ShouldPresentQueued(
                entry.Reminder.Id, entry.QueuedAt, acknowledgedId, now
            );
            if (!keep) dropped.Add(entry.Reminder);
            return !keep;
        });
        Engine?.RecordMissedPresentations(dropped);

        // The end of this takeover, unlike a monitor relayout, is where the
        // coach's timer and voice are torn down.
        ShutDownCoach();

        CloseCriticalWindows();
        if (_criticalQueue.Count > 0)
        {
            var next = _criticalQueue[0];
            _criticalQueue.RemoveAt(0);
            DisplayCritical(next.Reminder, next.Settings, isPreview: false);
        }
    }

    private void CloseCriticalWindows()
    {
        if (_criticalWindows.Count == 0) return;
        foreach (var window in _criticalWindows)
        {
            window.CloseOverlay();
        }
        _criticalWindows.Clear();
    }

    /// <summary>
    /// The coach for an exercise takeover, or <c>null</c> for an ordinary one.
    /// The voice is attached only when the setting is on and the exercises
    /// include a guided one, so a list of plain tick boxes never talks.
    /// </summary>
    private static ExerciseCoach? BuildCoach(Reminder reminder, Core.Settings settings)
    {
        if (!reminder.IsExercise || reminder.Exercises is not { Count: > 0 } exercises)
        {
            return null;
        }
        var wantsVoice = settings.VoiceCoachEnabled
            && exercises.Any(exercise => exercise.IsGuided);
        ISpeechCoaching? speech = null;
        if (wantsVoice)
        {
            var coachVoice = new SpeechCoach
            {
                VoiceIdentifier = settings.VoiceCoachVoiceIdentifier,
                Rate = settings.VoiceCoachRate,
            };
            speech = coachVoice;
        }
        return new ExerciseCoach(exercises, settings, speech);
    }

    /// <summary>
    /// Ends the current coach: stops its timer, silences it, and disposes the
    /// synthesizer it owns. Every path that retires a takeover goes through
    /// here — a coach left running is a timer that keeps speaking over an
    /// overlay that is no longer on screen.
    /// </summary>
    private void ShutDownCoach()
    {
        _criticalCoach?.ShutDown();
        _criticalCoach = null;
    }

    /// <summary>
    /// Pauses a running coach when the PC sleeps or the session locks — a hold
    /// must not tick away behind a lock screen. Program.cs routes the system
    /// events here.
    /// </summary>
    public void SuspendCoach() => _criticalCoach?.SuspendForAbsence();

    // MARK: - Subtle hint

    private void ShowSubtle(
        Reminder reminder, Core.Settings settings, bool isPreview, int minimumSeconds = 0)
    {
        if (_subtleCard is not null)
        {
            if (isPreview)
            {
                CloseSubtleCard();
            }
            else
            {
                // A card is already up. Queue this one so it shows when the
                // current card is acknowledged or times out — after a wake
                // from sleep several subtle reminders land on the same tick,
                // and replacing would silently lose all but the last.
                _subtleQueue.Add((reminder, settings, minimumSeconds));
                return;
            }
        }
        DisplaySubtle(reminder, settings, isPreview, minimumSeconds);
    }

    private void DisplaySubtle(
        Reminder reminder, Core.Settings settings, bool isPreview, int minimumSeconds)
    {
        // Self-dismiss: a subtle nudge the user ignores should not linger.
        // A per-reminder duration wins over the global default, so a wordy
        // reminder can be given longer to read.
        var seconds = Math.Max(
            Math.Max(2, reminder.DisplaySeconds ?? settings.SubtleDisplaySeconds),
            minimumSeconds
        );

        var card = new SubtleCardWindow(
            reminder,
            seconds,
            onComplete: () =>
            {
                if (!isPreview) Engine?.Complete(reminder.Id);
                DismissSubtleAndAdvance();
            },
            onTimedOut: DismissSubtleAndAdvance
        );
        _subtleCard = card;
        card.Show();
    }

    /// <summary>Takes the current card down and shows the next queued one, if any.</summary>
    private void DismissSubtleAndAdvance()
    {
        CloseSubtleCard();
        if (_subtleQueue.Count > 0)
        {
            var next = _subtleQueue[0];
            _subtleQueue.RemoveAt(0);
            DisplaySubtle(
                next.Reminder, next.Settings, isPreview: false, next.MinimumSeconds
            );
        }
    }

    private void CloseSubtleCard()
    {
        var card = _subtleCard;
        _subtleCard = null;
        card?.CloseCard();
    }
}
