using System.Windows.Threading;
using NodaTime;
using Pauselet.Core;

namespace Pauselet.App;

/// <summary>
/// How a row in the takeover should present itself while the coach runs.
/// (Mirrors ExerciseRowCoachState in ReminderUI.)
/// </summary>
internal enum ExerciseRowCoachState
{
    /// <summary>Untimed, or guided and simply waiting its turn.</summary>
    Idle,
    /// <summary>The guided exercise whose Start is highlighted.</summary>
    Suggested,
    /// <summary>Being coached now.</summary>
    Active,
    Completed,
    /// <summary>The user said they are not doing this one.</summary>
    Cancelled,
}

/// <summary>
/// Drives one takeover's guided exercises: the session cursor, the tick
/// timer, which exercises are done or cancelled, and the one place its audio
/// comes from. (Mirrors ExerciseCoach.swift.)
///
/// Created once per takeover and shared by every display's overlay, so a cue
/// is spoken once on a multi-monitor desk and a tick on one display shows on
/// all of them. The session itself is the pure <see cref="ExerciseSession"/>
/// from the core; this class only feeds it the clock and acts on what it
/// reports.
///
/// With the voice on, every phase is announced before it is timed: the
/// session is frozen at the phase start while the cue is spoken and released
/// when the synthesizer says it has finished, so "hold for 5 seconds" is
/// followed by five seconds, not by whatever was left after the sentence.
/// </summary>
internal sealed class ExerciseCoach : IDisposable
{
    /// <summary>Done: ticked by hand (untimed) or finished by the coach (guided).</summary>
    public HashSet<Guid> CompletedExerciseIds { get; } = [];
    /// <summary>Guided exercises the user has said they are not doing this time.</summary>
    public HashSet<Guid> CancelledExerciseIds { get; } = [];
    public ExerciseSession? Session { get; private set; }
    /// <summary>The exercise the session is coaching; <c>null</c> once it has completed.</summary>
    public Guid? ActiveExerciseId { get; private set; }
    /// <summary>
    /// The guided exercise whose Start is highlighted: the first neither done
    /// nor cancelled, so the obvious next thing is one keypress away.
    /// </summary>
    public Guid? SuggestedExerciseId { get; private set; }
    /// <summary>
    /// Updated on every tick, so views derive the countdown from
    /// <see cref="Session"/> and this rather than keeping time of their own.
    /// </summary>
    public Instant Now { get; private set; }

    /// <summary>Raised on every tick and every state change, on the UI thread.</summary>
    public event Action? Changed;

    public IReadOnlyList<Exercise> Exercises { get; }
    public bool HasGuidedExercises => Exercises.Any(exercise => exercise.IsGuided);

    private readonly ISpeechCoaching? _speech;
    private readonly bool _playsSounds;
    private readonly Func<Instant> _clock;
    private DispatcherTimer? _timer;
    private int _spokenCueCount;
    private int? _lastPhaseIndex;
    private DispatcherTimer? _announcementFallback;

    /// <param name="speech">
    /// <c>null</c> when the voice coach is off; chimes still play and phases
    /// start on time rather than after an announcement.
    /// </param>
    /// <param name="clock">Injected so a test can drive the coach without waiting.</param>
    public ExerciseCoach(
        IReadOnlyList<Exercise> exercises,
        Settings settings,
        ISpeechCoaching? speech,
        Func<Instant>? clock = null)
    {
        Exercises = exercises;
        _speech = speech;
        _playsSounds = settings.PlaysSound(Priority.Critical);
        _clock = clock ?? (() => SystemClock.Instance.GetCurrentInstant());
        Now = _clock();
        SuggestedExerciseId = Suggested(exercises, [], []);
    }

    // MARK: - Session control

    /// <summary>Coaches <paramref name="id"/> from the top, replacing any session in progress.</summary>
    public void Start(Guid id)
    {
        var exercise = Exercises.FirstOrDefault(candidate => candidate.Id == id);
        if (exercise is null || ExerciseTimeline.For(exercise) is not { } timeline) return;
        _speech?.Stop();
        Session = new ExerciseSession(timeline, _clock());
        ActiveExerciseId = id;
        CompletedExerciseIds.Remove(id);
        CancelledExerciseIds.Remove(id);
        _spokenCueCount = 0;
        _lastPhaseIndex = null;
        RecomputeSuggested();
        Tick();  // Announces "Get ready" straight away rather than a tick later.
        StartTimer();
    }

    public void StartSuggested()
    {
        if (SuggestedExerciseId is { } id) Start(id);
    }

    /// <summary>
    /// Space: pause or resume a session in progress, otherwise start the
    /// suggested exercise.
    /// </summary>
    public void PauseResumeOrStart()
    {
        if (Session is { IsLive: true }) TogglePause();
        else StartSuggested();
    }

    public void TogglePause()
    {
        if (Session is not { IsLive: true } session) return;
        var now = _clock();
        session.TogglePause(now);
        if (session.State == ExerciseSession.SessionState.Paused)
        {
            _speech?.Stop();
        }
        else if (session.State == ExerciseSession.SessionState.Running
            && _speech is not null && session.IsAtPhaseStart(now))
        {
            // A pause that cut the cue short leaves the phase untouched; say
            // it again so the person knows what they are resuming into.
            AnnounceCurrentPhase();
        }
        Tick();
    }

    /// <summary>
    /// Jumps to the next phase. Anything half-said is cut off so it cannot run
    /// into the next cue.
    /// </summary>
    public void Skip()
    {
        if (Session is not { IsLive: true } session) return;
        _speech?.Stop();
        session.Skip(_clock());
        if (session.State == ExerciseSession.SessionState.Announcing)
        {
            // The announcement that was in progress is gone with its phase;
            // the tick announces the new one.
            session.FinishAnnouncement(_clock());
        }
        Tick();
    }

    /// <summary>Abandons the session; the exercise stays neither done nor cancelled.</summary>
    public void Stop()
    {
        _speech?.Stop();
        StopTimer();
        // The phase whose announcement it was waiting on is gone with the
        // session, so the fallback has nothing left to release.
        StopAnnouncementFallback();
        Session = null;
        ActiveExerciseId = null;
        RecomputeSuggested();
        Changed?.Invoke();
    }

    // MARK: - Ticks and cancels

    /// <summary>The tick box on an untimed exercise.</summary>
    public void Toggle(Guid id)
    {
        if (CompletedExerciseIds.Contains(id))
        {
            CompletedExerciseIds.Remove(id);
        }
        else
        {
            CompletedExerciseIds.Add(id);
            // Ticking the exercise being coached ends its session: the person
            // has said they are done, whatever the timeline still had left.
            if (id == ActiveExerciseId) Stop();
        }
        RecomputeSuggested();
        Changed?.Invoke();
    }

    /// <summary>
    /// "Not doing this one": dims the row and moves the suggestion on. Start on
    /// the row takes it back.
    /// </summary>
    public void Cancel(Guid id)
    {
        if (id == ActiveExerciseId) Stop();
        CompletedExerciseIds.Remove(id);
        CancelledExerciseIds.Add(id);
        RecomputeSuggested();
        Changed?.Invoke();
    }

    /// <summary>
    /// How the row for <paramref name="id"/> should present itself;
    /// <c>null</c> for an untimed exercise, which keeps its plain tick box.
    /// </summary>
    public ExerciseRowCoachState? RowState(Guid id)
    {
        var exercise = Exercises.FirstOrDefault(candidate => candidate.Id == id);
        if (exercise is null || !exercise.IsGuided) return null;
        if (id == ActiveExerciseId && Session is not null && Session.PhaseAt(Now) is not null)
        {
            return ExerciseRowCoachState.Active;
        }
        if (CompletedExerciseIds.Contains(id)) return ExerciseRowCoachState.Completed;
        if (CancelledExerciseIds.Contains(id)) return ExerciseRowCoachState.Cancelled;
        return id == SuggestedExerciseId
            ? ExerciseRowCoachState.Suggested
            : ExerciseRowCoachState.Idle;
    }

    /// <summary>
    /// The caption for the active row: "Set 1 · Rep 3 · Hold", prefixed with
    /// "Paused" when it is. <c>null</c> when the row is not the active one.
    /// </summary>
    public string? RowCaption(Guid id)
    {
        if (id != ActiveExerciseId || Session is not { } session) return null;
        if (session.PhaseAt(Now) is not { } phase) return null;
        var caption = $"{phase.Title} · {phase.Label}";
        return session.State == ExerciseSession.SessionState.Paused
            ? $"Paused · {caption}"
            : caption;
    }

    /// <summary>
    /// Silences and stops everything. Done, Snooze and dismissing the takeover
    /// all end here.
    /// </summary>
    public void ShutDown()
    {
        _speech?.Stop();
        StopTimer();
        StopAnnouncementFallback();
        // The coach owns the synthesizer it was handed — it is built per
        // takeover — and it holds the default audio device until disposed.
        (_speech as IDisposable)?.Dispose();
    }

    // MARK: - The tick

    private void Tick()
    {
        Now = _clock();
        if (Session is not { } session)
        {
            Changed?.Invoke();
            return;
        }

        var phaseIndex = session.Timeline.PhaseIndexAt(session.Elapsed(Now));
        var phaseChanged = phaseIndex != _lastPhaseIndex;
        if (phaseChanged && _lastPhaseIndex is not null && phaseIndex is not null && _playsSounds)
        {
            Sounds.Play("Tink");
        }
        _lastPhaseIndex = phaseIndex;

        if (_speech is { } speech)
        {
            if (phaseChanged && phaseIndex is not null
                && session.State == ExerciseSession.SessionState.Running)
            {
                // A new phase with the voice on: freeze at its start, say its
                // cue, and let the clock go when the sentence is over.
                session.BeginAnnouncement(Now);
                _spokenCueCount = session.CueCount(Now);
                AnnounceCurrentPhase();
                Changed?.Invoke();
                return;
            }
            // Cues inside a phase (the "Three. Two. One." countdown) and the
            // closing line are spoken without stopping the clock. Only the
            // newest: after a stall the ones in between are stale, not a
            // backlog to read out.
            var cueCount = session.CueCount(Now);
            if (cueCount > _spokenCueCount
                && session.State == ExerciseSession.SessionState.Running)
            {
                speech.Speak(session.Timeline.Cues[cueCount - 1].Text);
            }
            _spokenCueCount = Math.Max(_spokenCueCount, cueCount);
        }

        if (session.MarkCompletedIfFinished(Now))
        {
            if (ActiveExerciseId is { } id) CompletedExerciseIds.Add(id);
            ActiveExerciseId = null;
            RecomputeSuggested();
            if (_playsSounds) Sounds.Play("Glass");
            StopTimer();
        }
        Changed?.Invoke();
    }

    /// <summary>
    /// Says the current phase's cue and releases the session when it has been
    /// said. The session may already be announcing (a fresh phase) or running
    /// at a phase start (a resume); either way it is frozen first so the
    /// timing is the same.
    /// </summary>
    private void AnnounceCurrentPhase()
    {
        if (_speech is not { } speech || Session is not { } session) return;
        if (session.PhaseAt(Now) is not { } phase) return;
        if (session.State == ExerciseSession.SessionState.Running)
        {
            session.BeginAnnouncement(Now);
        }
        var cue = ExerciseTimeline.Cue(phase, session.Timeline.ExerciseName);
        speech.Speak(cue, () => ReleaseAnnouncement(phase));
        // If the synthesizer never reports back (no usable voice, say), the
        // hold must still start: nobody should be frozen at "Get ready".
        StartAnnouncementFallback(phase);
    }

    /// <summary>
    /// Lets the clock run if the session is still frozen at the start of
    /// <paramref name="phase"/>; a no-op once it has moved on, so a late
    /// release cannot touch a later phase's announcement.
    /// </summary>
    private void ReleaseAnnouncement(ExercisePhase phase)
    {
        StopAnnouncementFallback();
        if (Session is not { } session
            || session.State != ExerciseSession.SessionState.Announcing
            || session.PhaseAt(Now) != phase)
        {
            return;
        }
        session.FinishAnnouncement(_clock());
        Tick();
    }

    private void StartAnnouncementFallback(ExercisePhase phase)
    {
        StopAnnouncementFallback();
        _announcementFallback = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(8),
        };
        _announcementFallback.Tick += (_, _) => ReleaseAnnouncement(phase);
        _announcementFallback.Start();
    }

    private void StopAnnouncementFallback()
    {
        _announcementFallback?.Stop();
        _announcementFallback = null;
    }

    private void StartTimer()
    {
        StopTimer();
        // DispatcherTimer keeps counting while a menu is open or a window is
        // being dragged, and its callbacks land on the UI thread the overlay
        // is drawn on.
        _timer = new DispatcherTimer(DispatcherPriority.Render)
        {
            Interval = TimeSpan.FromMilliseconds(200),
        };
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
    }

    private void StopTimer()
    {
        _timer?.Stop();
        _timer = null;
    }

    /// <summary>
    /// A hold must not "complete" while the PC is asleep or locked: pause, and
    /// let the user resume when they are back in position. The Mac's
    /// pause-on-sleep and iOS's pause-on-backgrounding, in the shape Windows
    /// reports it.
    /// </summary>
    public void SuspendForAbsence()
    {
        if (Session is not { } session) return;
        if (session.State != ExerciseSession.SessionState.Running
            && session.State != ExerciseSession.SessionState.Announcing)
        {
            return;
        }
        _speech?.Stop();
        session.Pause(_clock());
        Changed?.Invoke();
    }

    private void RecomputeSuggested() =>
        SuggestedExerciseId = Suggested(Exercises, CompletedExerciseIds, CancelledExerciseIds);

    private static Guid? Suggested(
        IReadOnlyList<Exercise> exercises, HashSet<Guid> completed, HashSet<Guid> cancelled) =>
        exercises.FirstOrDefault(exercise =>
            exercise.IsGuided
            && !completed.Contains(exercise.Id)
            && !cancelled.Contains(exercise.Id))?.Id;

    public void Dispose() => ShutDown();
}
