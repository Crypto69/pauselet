using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// Tests for <c>RecordExternalFire</c>, the reconciliation entry point used on
/// iOS where the system delivers pre-scheduled notifications and alarms while
/// the app is not running. It must produce the state a live <c>Tick()</c>
/// would have, and it must be safe to call repeatedly with the same facts.
/// </summary>
public class ExternalFireTests
{
    private static readonly DateTimeZone Utc = DateTimeZone.Utc;

    private static Instant Date(int year, int month, int day, int hour = 0, int minute = 0) =>
        TestDates.At(Utc, year, month, day, hour, minute);

    private static (ReminderEngine, MutableDateProvider) MakeEngine(
        IReadOnlyList<Reminder> reminders, Instant now)
    {
        var store = new InMemoryDataStore(new AppData
        {
            Reminders = reminders, Settings = new Settings(), Events = [],
        });
        var clock = new MutableDateProvider(now);
        var engine = new ReminderEngine(store, clock, null, Utc);
        return (engine, clock);
    }

    [Fact]
    public void StampsAnchorAndRecordsFiredEvent()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(60), CreatedAt = created,
        };
        var (engine, _) = MakeEngine([reminder], Date(2026, 3, 10, 11, 0));

        var stamp = Date(2026, 3, 10, 10, 0);
        engine.RecordExternalFire(reminder.Id, stamp);

        Assert.Equal(stamp, engine.ReminderWithId(reminder.Id)?.LastFiredAt);
        Assert.Equal(
            1, engine.Events.Count(e => e.EventOutcome == ReminderEvent.Outcome.Fired)
        );
        Assert.Equal(stamp, engine.Events.First().Date);
    }

    [Fact]
    public void RepeatedReconciliationDoesNotDuplicate()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(60), CreatedAt = created,
        };
        var (engine, _) = MakeEngine([reminder], Date(2026, 3, 10, 11, 0));

        var stamp = Date(2026, 3, 10, 10, 0);
        engine.RecordExternalFire(reminder.Id, stamp);
        engine.RecordExternalFire(reminder.Id, stamp);
        engine.RecordExternalFire(reminder.Id, stamp);

        Assert.Equal(
            1, engine.Events.Count(e => e.EventOutcome == ReminderEvent.Outcome.Fired)
        );
    }

    [Fact]
    public void OlderStampThanExistingAnchorIsIgnored()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(60), CreatedAt = created,
        } with { LastFiredAt = Date(2026, 3, 10, 11, 0) };
        var (engine, _) = MakeEngine([reminder], Date(2026, 3, 10, 11, 30));

        engine.RecordExternalFire(reminder.Id, Date(2026, 3, 10, 10, 0));

        // An anchor must never move backwards.
        Assert.Equal(Date(2026, 3, 10, 11, 0), engine.ReminderWithId(reminder.Id)?.LastFiredAt);
        Assert.Empty(engine.Events);
    }

    [Fact]
    public void ElapsedSnoozeIsConsumedByTheFireThatHonouredIt()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(60), CreatedAt = created,
        } with { SnoozedUntil = Date(2026, 3, 10, 9, 40) };
        var (engine, _) = MakeEngine([reminder], Date(2026, 3, 10, 10, 0));

        engine.RecordExternalFire(reminder.Id, Date(2026, 3, 10, 9, 40));

        Assert.Null(engine.ReminderWithId(reminder.Id)?.SnoozedUntil);
        Assert.Equal(
            Date(2026, 3, 10, 9, 40), engine.ReminderWithId(reminder.Id)?.LastFiredAt
        );
    }

    [Fact]
    public void FutureSnoozeSurvivesAnEarlierExternalFire()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Tilt", Schedule = new Schedule.Interval(60), CreatedAt = created,
            // The user snoozed *after* the notification was delivered; the
            // snooze is a promise about the future and must not be consumed by
            // the past fire being reconciled.
        } with { SnoozedUntil = Date(2026, 3, 10, 12, 0) };
        var (engine, _) = MakeEngine([reminder], Date(2026, 3, 10, 10, 30));

        engine.RecordExternalFire(reminder.Id, Date(2026, 3, 10, 10, 0));

        Assert.Equal(
            Date(2026, 3, 10, 12, 0), engine.ReminderWithId(reminder.Id)?.SnoozedUntil
        );
    }

    [Fact]
    public void UnknownReminderIsANoOp()
    {
        var (engine, _) = MakeEngine([], Date(2026, 3, 10, 10, 0));
        engine.RecordExternalFire(Guid.NewGuid(), Date(2026, 3, 10, 9, 0));
        Assert.Empty(engine.Events);
    }

    [Fact]
    public void ReconciledFireCountsTowardAdherence()
    {
        var created = Date(2026, 3, 10, 9, 0);
        var reminder = new Reminder
        {
            Title = "Water", Schedule = new Schedule.Interval(60), CreatedAt = created,
        };
        var (engine, _) = MakeEngine([reminder], Date(2026, 3, 10, 11, 0));

        engine.RecordExternalFire(reminder.Id, Date(2026, 3, 10, 10, 0));
        engine.Complete(reminder.Id);

        Assert.Equal(1.0, engine.Adherence(reminder.Id, created));
    }
}
