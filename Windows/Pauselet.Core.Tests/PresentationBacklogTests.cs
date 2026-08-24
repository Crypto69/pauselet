using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// Tests for what happens to reminders that queued up behind a critical
/// overlay nobody acknowledged.
///
/// The scenario: "Tilt Back" takes over the screen and the user falls asleep
/// in front of it, or leaves the desk for the afternoon. The engine keeps
/// ticking, so every reminder that falls due in those hours fires into the
/// presenter and queues behind the occupied screen. Pressing Finish hours
/// later must not replay that backlog as a chain of consecutive takeovers —
/// only what is genuinely current still deserves the screen.
/// </summary>
public class PresentationBacklogTests
{
    private static readonly Instant Now = Instant.FromUnixTimeSeconds(1_800_000_000);

    private static Reminder MakeReminder(string title) => new()
    {
        Title = title,
        Schedule = new Schedule.Interval(30),
        Priority = Priority.Critical,
        CreatedAt = Now,
    };

    // MARK: - The pruning policy

    /// <summary>
    /// A reminder that queued moments before the acknowledgment is genuinely
    /// current — after sleep several criticals routinely fire on the same
    /// tick, and the second must still be shown once the first is dealt with.
    /// </summary>
    [Fact]
    public void FreshlyQueuedReminderIsStillShown()
    {
        var queued = MakeReminder("Stretch");
        var acknowledged = MakeReminder("Tilt Back");

        Assert.True(
            ReminderEngine.ShouldPresentQueued(
                queued.Id,
                Now.Plus(Duration.FromSeconds(-30)),
                acknowledged.Id,
                Now
            )
        );
    }

    /// <summary>
    /// The complaint this policy exists for: an entry that waited hours behind
    /// an unacknowledged overlay has had its moment pass, and must not be
    /// delivered as the "next" takeover.
    /// </summary>
    [Fact]
    public void StaleQueuedReminderIsDropped()
    {
        var queued = MakeReminder("Stretch");
        var acknowledged = MakeReminder("Tilt Back");

        Assert.False(
            ReminderEngine.ShouldPresentQueued(
                queued.Id,
                Now.Plus(Duration.FromSeconds(-3 * 3600)),
                acknowledged.Id,
                Now
            )
        );
    }

    /// <summary>
    /// The boundary matches <c>AbsorbBacklogFromDowntime</c>: exactly at the
    /// grace cutoff counts as stale, strictly inside it counts as current.
    /// </summary>
    [Fact]
    public void GraceBoundary()
    {
        var queued = MakeReminder("Stretch");
        var acknowledged = MakeReminder("Tilt Back");
        var cutoff = Now.Minus(ReminderEngine.DowntimeGrace);

        // An entry exactly at the cutoff is stale.
        Assert.False(
            ReminderEngine.ShouldPresentQueued(queued.Id, cutoff, acknowledged.Id, Now)
        );
        // An entry just inside the grace window is current.
        Assert.True(
            ReminderEngine.ShouldPresentQueued(
                queued.Id, cutoff.Plus(Duration.FromSeconds(1)), acknowledged.Id, Now
            )
        );
    }

    /// <summary>
    /// While the overlay sat unacknowledged, the same interval reminder kept
    /// falling due and queueing copies of itself. Saying "done" answers all of
    /// them — even a copy queued seconds ago must not reappear over an
    /// acknowledgment the user just gave.
    /// </summary>
    [Fact]
    public void QueuedDuplicateOfTheAcknowledgedReminderIsDroppedHoweverFresh()
    {
        var tilt = MakeReminder("Tilt Back");

        Assert.False(
            ReminderEngine.ShouldPresentQueued(
                tilt.Id,
                Now.Plus(Duration.FromSeconds(-10)),
                tilt.Id,
                Now
            )
        );
    }

    /// <summary>
    /// The full night-asleep shape: hours of re-fires of the on-screen
    /// reminder, a stale different reminder from mid-afternoon, and one other
    /// reminder that fired just before the user woke up. Finish must surface
    /// only the last of these.
    /// </summary>
    [Fact]
    public void HoursOfBacklogCollapseToTheOneCurrentReminder()
    {
        var tilt = MakeReminder("Tilt Back");
        var stretch = MakeReminder("Stretch");
        var meds = MakeReminder("Evening Meds");

        // (reminder, how long ago it queued)
        (Reminder Reminder, double Age)[] queue =
        [
            (tilt, 3 * 3600),
            (stretch, 2 * 3600),
            (tilt, 3600),
            (tilt, 40),  // fresh, but the user just answered this reminder
            (meds, 60),  // fresh and unanswered: still deserves the screen
        ];

        var surviving = queue.Where(entry =>
            ReminderEngine.ShouldPresentQueued(
                entry.Reminder.Id,
                Now.Plus(Duration.FromSeconds(-entry.Age)),
                tilt.Id,
                Now
            )
        ).ToList();

        Assert.Equal([meds.Id], surviving.Select(entry => entry.Reminder.Id).ToArray());
    }

    // MARK: - History

    /// <summary>
    /// A dropped entry is recorded as missed, so the history tab still shows
    /// what became of the fires that queued while nobody was watching.
    /// </summary>
    [Fact]
    public void DroppedPresentationsAreRecordedAsMissedAndPersisted()
    {
        var tilt = MakeReminder("Tilt Back");
        var stretch = MakeReminder("Stretch");
        var store = new InMemoryDataStore(new AppData { Reminders = [tilt, stretch] });
        var clock = new MutableDateProvider(Now);
        var engine = new ReminderEngine(store, clock);
        var savesBefore = store.SaveCount;

        engine.RecordMissedPresentations([tilt, stretch]);

        Assert.Equal(
            [ReminderEvent.Outcome.Missed, ReminderEvent.Outcome.Missed],
            engine.Events.Select(e => e.EventOutcome).ToArray()
        );
        Assert.Equal(
            [tilt.Id, stretch.Id],
            engine.Events.Select(e => e.ReminderId).ToArray()
        );
        // Missed events must survive a relaunch.
        Assert.True(store.SaveCount > savesBefore);
    }

    /// <summary>
    /// The common case — the queue was empty, or everything in it was still
    /// current — must not write to disk or touch history at all.
    /// </summary>
    [Fact]
    public void RecordingNothingIsANoOp()
    {
        var store = new InMemoryDataStore(new AppData { Reminders = [] });
        var clock = new MutableDateProvider(Now);
        var engine = new ReminderEngine(store, clock);
        var savesBefore = store.SaveCount;

        engine.RecordMissedPresentations([]);

        Assert.Empty(engine.Events);
        Assert.Equal(savesBefore, store.SaveCount);
    }
}
