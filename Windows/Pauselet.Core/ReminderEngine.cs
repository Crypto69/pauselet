using CommunityToolkit.Mvvm.ComponentModel;
using NodaTime;

namespace Pauselet.Core;

/// <summary>
/// Something that can present a reminder to the user.
///
/// The engine never touches WPF directly; it hands fired reminders to a
/// presenter. Tests substitute a recording presenter to assert exactly what
/// would have been shown.
/// </summary>
public interface IReminderPresenting
{
    void Present(Reminder reminder, Settings settings);
    /// <summary>
    /// Called when a subtle/normal reminder should be taken off screen because
    /// the engine was paused or the reminder was disabled.
    /// </summary>
    void DismissAll();
}

/// <summary>Supplies "now". Injected so tests can drive time by hand.</summary>
public interface IDateProviding
{
    Instant Now { get; }
}

public sealed class SystemDateProvider : IDateProviding
{
    public Instant Now => SystemClock.Instance.GetCurrentInstant();
}

/// <summary>A clock the tests control directly.</summary>
public sealed class MutableDateProvider : IDateProviding
{
    private readonly object _gate = new();
    private Instant _now;

    public MutableDateProvider(Instant now) => _now = now;

    public Instant Now
    {
        get { lock (_gate) return _now; }
    }

    public void Set(Instant date)
    {
        lock (_gate) _now = date;
    }

    public void Advance(Duration interval)
    {
        lock (_gate) _now = _now.Plus(interval);
    }

    public void AdvanceSeconds(double seconds) => Advance(Duration.FromSeconds(seconds));
}

/// <summary>
/// Owns the reminder list, decides what fires, and records history.
///
/// The engine is deliberately UI-agnostic: <c>Tick()</c> is the single entry
/// point that advances the world, and it is safe to call as often as you like.
/// Construct and call it on the WPF dispatcher thread — the Swift original is
/// <c>@MainActor</c> for the same reason.
/// </summary>
public sealed class ReminderEngine : ObservableObject
{
    private List<Reminder> _reminders = [];
    private List<ReminderEvent> _events = [];
    private Settings _settings = new();
    private (Reminder Reminder, Instant Date)? _nextUp;

    public IReadOnlyList<Reminder> Reminders => _reminders;
    public IReadOnlyList<ReminderEvent> Events => _events;

    public Settings Settings
    {
        get => _settings;
        private set => SetProperty(ref _settings, value);
    }

    /// <summary>The most recent tick's view of what fires next, for the tray.</summary>
    public (Reminder Reminder, Instant Date)? NextUp
    {
        get => _nextUp;
        private set => SetProperty(ref _nextUp, value);
    }

    private readonly IDataStoring _store;
    private readonly IDateProviding _dateProvider;
    private IReminderPresenting? _presenter;
    private readonly DateTimeZone _zone;

    /// <summary>History is capped so the file cannot grow without bound over years of use.</summary>
    public const int MaxStoredEvents = 2000;

    /// <summary>
    /// How recently a reminder must have fallen due to still be delivered
    /// late: by <c>AbsorbBacklogFromDowntime()</c> at launch, and by the
    /// presenter's queue when an acknowledgment finally arrives (see
    /// <c>ShouldPresentQueued</c>).
    ///
    /// Long enough that quitting and relaunching — to install an update, say —
    /// does not swallow a reminder that genuinely came due in the meantime, and
    /// short enough that nothing from an earlier session survives it.
    /// </summary>
    public static readonly Duration DowntimeGrace = Duration.FromSeconds(120);

    public ReminderEngine(
        IDataStoring store,
        IDateProviding? dateProvider = null,
        IReminderPresenting? presenter = null,
        DateTimeZone? zone = null)
    {
        _store = store;
        _dateProvider = dateProvider ?? new SystemDateProvider();
        _presenter = presenter;
        _zone = zone ?? DateTimeZoneProviders.Tzdb.GetSystemDefault();
        LoadFromStore();
    }

    public void SetPresenter(IReminderPresenting? presenter)
    {
        _presenter = presenter;
    }

    private Instant Now => _dateProvider.Now;

    // MARK: - Persistence

    private void LoadFromStore()
    {
        try
        {
            var data = _store.Load();
            _reminders = data.Reminders.ToList();
            _settings = data.Settings;
            _events = data.Events.ToList();
            // A first launch loads the starter set from a file that does not
            // exist yet. Write it out straight away, so the reminders' timing
            // anchors survive a restart instead of being reseeded to "now"
            // every time the app opens.
            if (!_store.HasPersistedData)
            {
                Persist();
            }
        }
        catch
        {
            // A corrupt or unreadable file must not prevent the app from
            // starting; fall back to defaults rather than crashing on launch.
            _reminders = DefaultReminders.StarterSet(Now).ToList();
            _settings = new Settings();
            _events = [];
        }
        RefreshNextUp();
    }

    public void Persist()
    {
        var data = new AppData
        {
            Reminders = _reminders,
            Settings = _settings,
            Events = _events.Skip(Math.Max(0, _events.Count - MaxStoredEvents)).ToList(),
        };
        try
        {
            _store.Save(data);
        }
        catch
        {
            // A failed write must not take the running engine down.
        }
        // Adopt the stored precision in memory. Dates are written at
        // whole-second precision, so without this the in-memory values would
        // differ from disk by a fraction of a second and comparisons against a
        // reloaded reminder would fail.
        var normalized = FileDataStore.NormalizingDates(data);
        _reminders = normalized.Reminders.ToList();
        _settings = normalized.Settings;
        _events = normalized.Events.ToList();
        NotifyContentChanged();
    }

    private void NotifyContentChanged()
    {
        OnPropertyChanged(nameof(Reminders));
        OnPropertyChanged(nameof(Settings));
        OnPropertyChanged(nameof(Events));
    }

    // MARK: - CRUD

    public void Add(Reminder reminder)
    {
        var added = reminder;
        // Anchor a new interval reminder to now so its first fire is a full
        // interval away rather than immediate.
        if (added.LastFiredAt is null)
        {
            added = added with { CreatedAt = Now };
        }
        _reminders.Add(added);
        Persist();
        RefreshNextUp();
    }

    public void Update(Reminder reminder)
    {
        var index = _reminders.FindIndex(r => r.Id == reminder.Id);
        if (index < 0) return;
        _reminders[index] = reminder;
        Persist();
        RefreshNextUp();
    }

    public void Delete(Guid id)
    {
        _reminders.RemoveAll(r => r.Id == id);
        Persist();
        RefreshNextUp();
    }

    public void SetEnabled(bool enabled, Guid id)
    {
        var index = _reminders.FindIndex(r => r.Id == id);
        if (index < 0) return;
        var updated = _reminders[index] with { IsEnabled = enabled };
        // Re-anchor so re-enabling does not fire instantly from a stale timestamp.
        if (enabled)
        {
            updated = updated with { LastFiredAt = Now, SnoozedUntil = null };
        }
        _reminders[index] = updated;
        Persist();
        RefreshNextUp();
    }

    public Reminder? ReminderWithId(Guid id) => _reminders.FirstOrDefault(r => r.Id == id);

    // MARK: - Ticking

    /// <summary>
    /// Consumes everything that fell due while the app was not running, without
    /// presenting any of it. Call once at launch, before the first
    /// <c>Tick()</c>.
    ///
    /// A reminder is a request to be interrupted *at a moment*, not a debt that
    /// accrues while nobody is listening. Without this, opening the app after a
    /// day away replays the backlog in one burst: every interval reminder is
    /// overdue by design, and last night's wall-clock slot arrives at lunchtime
    /// — complete with its overlay and its music. That is not a late reminder,
    /// it is noise, and for a critical tier it is a full-screen takeover the
    /// user did nothing to deserve.
    ///
    /// Anything that came due within <c>DowntimeGrace</c> is left alone, so a
    /// quick relaunch still delivers a reminder that is genuinely current.
    ///
    /// Sleep is deliberately not treated this way: the app *is* running, the
    /// user may well be sitting at a machine that idled out, and a
    /// pressure-relief prompt still applies. See <c>Tick()</c>'s catch-up path.
    /// </summary>
    public IReadOnlyList<Reminder> AbsorbBacklogFromDowntime()
    {
        var current = Now;
        var cutoff = current.Minus(DowntimeGrace);
        var absorbed = new List<Reminder>();

        // "Stale" means the running engine would have acted on it before the
        // cutoff. That is judged through Scheduler.DeliveryMoment, so a fire
        // that merely fell due inside quiet hours — which the live engine
        // holds until the window ends, and would still deliver — is left
        // alone rather than being written off as missed.
        bool IsStale(Instant due, Priority priority) =>
            Scheduler.DeliveryMoment(due, priority, _settings, _zone) is { } moment
                ? moment <= cutoff
                : due <= cutoff;

        // Stagger slots for the interval reminders that went fully overdue
        // while the machine was asleep, so they come back spread out and in
        // their original order rather than stacked on one instant. `cutoff`
        // stands in for when the engine stopped honouring fires.
        var staggered = Scheduler.ReanchorAllForDowntime(
            _reminders, cutoff, current,
            reminder =>
                reminder.IsEnabled
                && reminder.SnoozedUntil is null
                && reminder.Schedule is Schedule.Interval
                && Scheduler.PendingFireDate(reminder, _zone) is { } due
                && IsStale(due, reminder.Priority));

        for (var index = 0; index < _reminders.Count; index++)
        {
            if (!_reminders[index].IsEnabled) continue;
            var didAbsorb = false;
            var priority = _reminders[index].Priority;

            // A snooze belongs to the session that set it: "remind me in five
            // minutes" said two days ago is not still owed.
            if (_reminders[index].SnoozedUntil is { } snoozedUntil
                && IsStale(snoozedUntil, priority))
            {
                _reminders[index] = _reminders[index] with { SnoozedUntil = null };
                didAbsorb = true;
            }

            if (_reminders[index].SnoozedUntil is null)
            {
                switch (_reminders[index].Schedule)
                {
                    case Schedule.Interval:
                        // An interval measures time spent working, and nothing
                        // was measuring it. Restart the clock, exactly as
                        // Resume() does after a pause — each reminder getting a
                        // slot of its own so a set of them does not come back
                        // welded together.
                        if (Scheduler.PendingFireDate(_reminders[index], _zone)
                                is { } pending
                            && IsStale(pending, priority))
                        {
                            _reminders[index] = _reminders[index] with
                            {
                                LastFiredAt =
                                    staggered.TryGetValue(_reminders[index].Id, out var staggeredAt)
                                        ? staggeredAt
                                        : current,
                            };
                            didAbsorb = true;
                        }
                        break;

                    case Schedule.DailyAt:
                    case Schedule.WeeklyAt:
                        // Stamping the elapsed slot consumes the whole backlog
                        // at once while keeping an "every N days" grid in
                        // phase. A slot inside the grace window is left for
                        // Tick().
                        if (Scheduler.LatestElapsedSlot(_reminders[index], current, _zone)
                                is { } slot
                            && IsStale(slot, priority))
                        {
                            _reminders[index] = _reminders[index] with
                            {
                                LastFiredAt = slot,
                            };
                            didAbsorb = true;
                        }
                        break;
                }
            }

            if (didAbsorb)
            {
                Record(ReminderEvent.Outcome.Missed, _reminders[index], current);
                absorbed.Add(_reminders[index]);
            }
        }

        if (absorbed.Count > 0) Persist();
        RefreshNextUp();
        return absorbed;
    }

    /// <summary>
    /// Whether a presentation that has been waiting off-screen since
    /// <paramref name="queuedAt"/> should still be shown once the user
    /// acknowledges reminder <paramref name="acknowledgedId"/> at
    /// <paramref name="now"/>.
    ///
    /// While a critical takeover sits unacknowledged the engine keeps ticking,
    /// so reminders that fall due fire into the presenter and queue behind the
    /// occupied screen. When the user finally responds hours later — they fell
    /// asleep, or walked away — replaying that queue means acknowledging one
    /// overlay only to be handed the next, and the next. The same principle as
    /// <c>AbsorbBacklogFromDowntime()</c> applies: a reminder is a request to
    /// be interrupted at a moment, and the moment of anything queued more than
    /// <c>DowntimeGrace</c> ago has passed.
    ///
    /// A queued duplicate of the acknowledged reminder is dropped however
    /// fresh: the user has just said "done" (or "not now") to that reminder,
    /// and re-presenting it immediately would contradict them.
    /// </summary>
    public static bool ShouldPresentQueued(
        Guid reminderId, Instant queuedAt, Guid acknowledgedId, Instant now)
    {
        if (reminderId == acknowledgedId) return false;
        return queuedAt > now.Minus(DowntimeGrace);
    }

    /// <summary>
    /// One fire the system delivered on the app's behalf. <c>StampDate</c> is
    /// the stamp the fire was scheduled with (see <see cref="ProjectedFire"/>);
    /// <c>DeliveredAt</c> is when it reached the user, defaulting to the stamp,
    /// which is the delivery moment for every fire except a wall-clock
    /// catch-up.
    /// </summary>
    public sealed record ExternalFire
    {
        public required Guid ReminderId { get; init; }
        public required Instant StampDate { get; init; }
        private readonly Instant? _deliveredAt;
        public Instant DeliveredAt
        {
            get => Instant.Max(StampDate, _deliveredAt ?? StampDate);
            init => _deliveredAt = value;
        }
    }

    /// <summary>
    /// Records that <paramref name="id"/> fired *outside* the running app. See
    /// <see cref="RecordExternalFires"/>; this is the single-fire convenience.
    /// </summary>
    public void RecordExternalFire(Guid id, Instant stamp, Instant? deliveredAt = null)
    {
        var fire = new ExternalFire { ReminderId = id, StampDate = stamp };
        if (deliveredAt is { } delivered) fire = fire with { DeliveredAt = delivered };
        RecordExternalFires([fire]);
    }

    /// <summary>
    /// Folds fires the system delivered on the app's behalf into engine state,
    /// so it matches what a live <c>Tick()</c> would have produced: the anchor
    /// moves to the fire's stamp, a snooze the fire honoured is consumed, and
    /// history records the fire at the moment it reached the user — the same
    /// moment <c>Tick()</c> records its own fires at.
    ///
    /// Idempotent: reconciliation runs on every foreground pass and must not
    /// duplicate history or move anchors backwards, so a fire that is already
    /// accounted for — by a previous pass, or because the app was running and
    /// ticked it — is left alone. A stamp at or before the reminder's anchor
    /// is a fire the engine could never have produced (an alarm rule's
    /// occurrence from before the reminder existed, say) and is ignored too.
    ///
    /// One persist for the whole batch: the first frame after days away can
    /// have dozens of these.
    /// </summary>
    public void RecordExternalFires(IReadOnlyList<ExternalFire> fires)
    {
        var changed = false;
        foreach (var fire in fires.OrderBy(f => f.DeliveredAt))
        {
            var index = _reminders.FindIndex(r => r.Id == fire.ReminderId);
            if (index < 0) continue;
            var stamp = fire.StampDate.RoundedToSecond();
            var delivered = fire.DeliveredAt.RoundedToSecond();
            var anchor = _reminders[index].LastFiredAt ?? _reminders[index].CreatedAt;
            if (stamp <= anchor) continue;
            // Defence in depth against a rewound anchor (an edit saved from a
            // stale copy): the delivery moment is fixed for a given fire, so
            // an event already dated there means this fire is on record.
            if (_events.Any(e =>
                    e.ReminderId == fire.ReminderId
                    && e.EventOutcome == ReminderEvent.Outcome.Fired
                    && e.Date == delivered))
            {
                continue;
            }
            _reminders[index] = _reminders[index] with { LastFiredAt = stamp };
            // The fire that honoured a snooze consumes it. Deliberately
            // stricter than Tick()'s unconditional clear: a snooze set *after*
            // this fire was delivered is a promise about the future, and the
            // past fire being reconciled must not eat it.
            if (_reminders[index].SnoozedUntil is { } snoozed && snoozed <= stamp)
            {
                _reminders[index] = _reminders[index] with { SnoozedUntil = null };
            }
            Record(ReminderEvent.Outcome.Fired, _reminders[index], delivered);
            changed = true;
        }
        if (!changed) return;
        Persist();
        RefreshNextUp();
    }

    /// <summary>
    /// Records queued presentations the presenter dropped unshown (see
    /// <c>ShouldPresentQueued</c>), so history still shows what happened to
    /// them.
    /// </summary>
    public void RecordMissedPresentations(IReadOnlyList<Reminder> dropped)
    {
        if (dropped.Count == 0) return;
        var current = Now;
        foreach (var reminder in dropped)
        {
            Record(ReminderEvent.Outcome.Missed, reminder, current);
        }
        Persist();
    }

    /// <summary>
    /// Advances the engine. Fires everything that is due and returns what
    /// fired.
    ///
    /// Safe to call at any frequency; a reminder cannot fire twice for the same
    /// due window because firing stamps <c>LastFiredAt</c>.
    /// </summary>
    public IReadOnlyList<Reminder> Tick()
    {
        var current = Now;
        ExpireTimedPauseIfNeeded(current);

        if (Scheduler.IsPaused(_settings, current))
        {
            RefreshNextUp();
            return [];
        }

        var fired = new List<Reminder>();
        var skippedAny = false;
        for (var index = 0; index < _reminders.Count; index++)
        {
            // The whole firing policy — what the stamp is, whether a slot that
            // passed inside quiet hours is skipped, how a snooze is consumed —
            // lives in Scheduler.NextStep. The tick only asks whether the
            // step's moment has arrived and then applies it.
            if (Scheduler.NextStep(_reminders[index], current, _settings, _zone)
                    is not { } step
                || step.FireDate > current)
            {
                continue;
            }

            _reminders[index] = step.Apply(_reminders[index]);
            if (step.StepOutcome == Scheduler.FireStep.Outcome.Skip)
            {
                Record(ReminderEvent.Outcome.Missed, _reminders[index], current);
                skippedAny = true;
            }
            else
            {
                fired.Add(_reminders[index]);
            }
        }

        if (fired.Count > 0)
        {
            // Highest priority first, so a critical overlay is the last thing
            // presented and therefore the thing sitting in front of the user.
            var ordered = fired.OrderBy(r => r.Priority).ToList();
            foreach (var reminder in ordered)
            {
                Record(ReminderEvent.Outcome.Fired, reminder, current);
                _presenter?.Present(reminder, _settings);
            }
        }
        if (fired.Count > 0 || skippedAny)
        {
            Persist();
        }

        RefreshNextUp();
        return fired;
    }

    /// <summary>
    /// Re-anchors every interval reminder after a stretch of downtime,
    /// preserving how far apart they were. The policy itself lives in
    /// <see cref="Scheduler.ReanchorForDowntime"/> so the projection and the
    /// live engine cannot drift apart.
    /// </summary>
    private void ReanchorIntervals(Instant downtimeStart, Instant resumeDate)
    {
        var anchors = Scheduler.ReanchorAllForDowntime(
            _reminders, downtimeStart, resumeDate);
        if (anchors.Count == 0) return;
        for (var index = 0; index < _reminders.Count; index++)
        {
            if (anchors.TryGetValue(_reminders[index].Id, out var anchor))
            {
                _reminders[index] = _reminders[index] with { LastFiredAt = anchor };
            }
        }
    }

    /// <summary>
    /// A timed pause that has run out lifts itself, and re-anchors interval
    /// reminders to the moment it ended — the same thing <c>Resume()</c> does
    /// by hand, and what the projection assumed while the pause was running —
    /// so a long pause never dumps an overdue fire on the user the instant it
    /// lifts. Anchors already past the pause's end are left alone.
    /// </summary>
    private void ExpireTimedPauseIfNeeded(Instant date)
    {
        if (_settings.PausedUntil is not { } until || date < until) return;
        var pausedAt = _settings.PausedAt;
        _settings = _settings with { PausedUntil = null, IsPaused = false, PausedAt = null };
        ReanchorIntervals(pausedAt ?? until, until);
        Persist();
    }

    private void RefreshNextUp()
    {
        // The countdown shows when a reminder will actually reach the user:
        // the projection's first delivery, which judges quiet hours at each
        // candidate's fire time and looks past a timed pause. During quiet
        // hours the true next fire is the 07:00 one, and a slot that lands
        // inside the window will not really fire then.
        var current = Now;
        (Reminder Reminder, Instant Date)? best = null;
        foreach (var reminder in _reminders)
        {
            if (!reminder.IsEnabled) continue;
            if (Projection.ProjectedFires(reminder, current, 1, _settings, _zone)
                    .FirstOrDefault() is not { } first)
            {
                continue;
            }
            var date = first.FireDate;
            if (best is { } currentBest)
            {
                if (date < currentBest.Date
                    || (date == currentBest.Date
                        && reminder.Priority > currentBest.Reminder.Priority))
                {
                    best = (reminder, date);
                }
            }
            else
            {
                best = (reminder, date);
            }
        }
        NextUp = best;
    }

    // MARK: - User responses

    public void Complete(Guid id)
    {
        var index = _reminders.FindIndex(r => r.Id == id);
        if (index < 0) return;
        var current = Now;
        var reminder = _reminders[index];

        switch (reminder.Schedule)
        {
            case Schedule.Interval:
                // The interval restarts from the completion, so "done" always
                // buys a full interval of peace.
                _reminders[index] = reminder with { LastFiredAt = current };
                break;

            case Schedule.DailyAt:
            case Schedule.WeeklyAt:
            {
                // Distinguish acknowledging a fire that just happened from
                // marking the task done ahead of its slot. A fire newer than
                // the last acknowledgement means this is the acknowledgement —
                // keep the fire stamp so the next slot stays on schedule.
                // Otherwise the user did the task early, so consume the
                // upcoming slot rather than firing it a few hours after they
                // said "done".
                var awaitingAck =
                    reminder.LastFiredAt is { } firedAt
                    && (reminder.LastAcknowledgedAt is not { } ackedAt || firedAt > ackedAt);
                if (!awaitingAck)
                {
                    if (Scheduler.NextScheduleSlot(reminder, _zone) is { } upcoming
                        && upcoming > current)
                    {
                        _reminders[index] = reminder with { LastFiredAt = upcoming };
                    }
                    else
                    {
                        // The slot already elapsed without firing (sleep, quiet
                        // hours): completing consumes that elapsed slot too.
                        _reminders[index] = reminder with
                        {
                            LastFiredAt =
                                Scheduler.LatestElapsedSlot(reminder, current, _zone)
                                ?? current,
                        };
                    }
                }
                break;
            }
        }

        _reminders[index] = _reminders[index] with
        {
            LastAcknowledgedAt = current,
            SnoozedUntil = null,
        };
        Record(ReminderEvent.Outcome.Completed, _reminders[index], current);
        Persist();
        RefreshNextUp();
    }

    public void Snooze(Guid id, int? minutes = null)
    {
        var index = _reminders.FindIndex(r => r.Id == id);
        if (index < 0) return;
        var current = Now;
        var delay = Math.Max(1, minutes ?? _settings.SnoozeMinutes);
        _reminders[index] = _reminders[index] with
        {
            SnoozedUntil = current.Plus(Duration.FromMinutes(delay)),
        };
        Record(ReminderEvent.Outcome.Snoozed, _reminders[index], current);
        Persist();
        RefreshNextUp();
    }

    public void Dismiss(Guid id)
    {
        var index = _reminders.FindIndex(r => r.Id == id);
        if (index < 0) return;
        var current = Now;
        _reminders[index] = _reminders[index] with { LastAcknowledgedAt = current };
        Record(ReminderEvent.Outcome.Dismissed, _reminders[index], current);
        Persist();
        RefreshNextUp();
    }

    // MARK: - Global controls

    public void SetPaused(bool paused)
    {
        _settings = _settings with
        {
            IsPaused = paused,
            PausedUntil = null,
            PausedAt = paused ? Now : null,
        };
        if (paused) _presenter?.DismissAll();
        Persist();
        RefreshNextUp();
    }

    public void PauseFor(int minutes)
    {
        _settings = _settings with
        {
            IsPaused = true,
            PausedAt = Now,
            PausedUntil = Now.Plus(Duration.FromMinutes(minutes)),
        };
        _presenter?.DismissAll();
        Persist();
        RefreshNextUp();
    }

    public void Resume()
    {
        var pausedAt = _settings.PausedAt;
        _settings = _settings with { IsPaused = false, PausedUntil = null, PausedAt = null };
        // Re-anchor interval reminders so a long pause does not dump every
        // missed reminder on the user the instant they come back — while
        // preserving how far apart they were. Stamping them all with `now`
        // (which this used to do) welds every reminder sharing an interval
        // onto the same second, permanently.
        var current = Now;
        ReanchorIntervals(pausedAt ?? current, current);
        Persist();
        RefreshNextUp();
    }

    public void UpdateSettings(Settings newSettings)
    {
        _settings = newSettings;
        Persist();
        RefreshNextUp();
    }

    // MARK: - History

    private void Record(ReminderEvent.Outcome outcome, Reminder reminder, Instant date)
    {
        _events.Add(new ReminderEvent
        {
            ReminderId = reminder.Id,
            ReminderTitle = reminder.Title,
            Date = date,
            EventOutcome = outcome,
        });
        if (_events.Count > MaxStoredEvents)
        {
            _events.RemoveRange(0, _events.Count - MaxStoredEvents);
        }
    }

    public void ClearHistory()
    {
        _events.Clear();
        Persist();
    }

    /// <summary>Counts of each outcome for <paramref name="reminderId"/> since <paramref name="date"/>, for the stats view.</summary>
    public Dictionary<ReminderEvent.Outcome, int> Stats(Guid reminderId, Instant date)
    {
        var counts = new Dictionary<ReminderEvent.Outcome, int>();
        foreach (var e in _events)
        {
            if (e.ReminderId != reminderId || e.Date < date) continue;
            counts[e.EventOutcome] = counts.GetValueOrDefault(e.EventOutcome) + 1;
        }
        return counts;
    }

    /// <summary>
    /// Adherence for <paramref name="reminderId"/>: completed ÷ fired, over the
    /// given window. Returns <c>null</c> when nothing fired in the window.
    /// </summary>
    public double? Adherence(Guid reminderId, Instant date)
    {
        var counts = Stats(reminderId, date);
        var fired = counts.GetValueOrDefault(ReminderEvent.Outcome.Fired);
        if (fired == 0) return null;
        var completed = counts.GetValueOrDefault(ReminderEvent.Outcome.Completed);
        return Math.Min(1.0, (double)completed / fired);
    }
}
