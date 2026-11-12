using System.Text;
using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// How firmly a Critical takeover holds the screen while its countdown
/// runs. Mirrors the Swift <c>DismissalTests</c>.
/// </summary>
public class DismissalTests
{
    private static Reminder Critical(int? countdown = 300, TakeoverDismissal? dismissal = null) =>
        new Reminder
        {
            Title = "Tilt back",
            Schedule = new Schedule.Interval(60),
            Priority = Priority.Critical,
            ActivityDurationSeconds = countdown,
            Dismissal = dismissal,
            CreatedAt = Instant.FromUnixTimeSeconds(1_760_000_000),
        };

    private static AppData Data(Reminder reminder) =>
        new() { Reminders = [reminder], Settings = new Settings(), Events = [] };

    [Fact]
    public void AnyTimeByDefault() =>
        Assert.Equal(TakeoverDismissal.Anytime, Takeovers.Dismissal(Critical()));

    [Fact]
    public void TheChosenLevelAppliesWithACountdown()
    {
        Assert.Equal(TakeoverDismissal.SnoozeOnly,
            Takeovers.Dismissal(Critical(dismissal: TakeoverDismissal.SnoozeOnly)));
        Assert.Equal(TakeoverDismissal.Locked,
            Takeovers.Dismissal(Critical(dismissal: TakeoverDismissal.Locked)));
    }

    [Fact]
    public void NoLevelWithoutACountdown()
    {
        Assert.Equal(TakeoverDismissal.Anytime,
            Takeovers.Dismissal(Critical(countdown: null, dismissal: TakeoverDismissal.Locked)));
        Assert.Equal(TakeoverDismissal.Anytime,
            Takeovers.Dismissal(Critical(countdown: 0, dismissal: TakeoverDismissal.Locked)));
    }

    [Fact]
    public void AnyTimeAllowsBothThroughout()
    {
        Assert.True(Takeovers.CanFinish(TakeoverDismissal.Anytime, 299));
        Assert.True(Takeovers.CanSnooze(TakeoverDismissal.Anytime, 299));
    }

    [Fact]
    public void SnoozeOnlyHoldsDoneUntilTheTimerEnds()
    {
        Assert.False(Takeovers.CanFinish(TakeoverDismissal.SnoozeOnly, 1));
        Assert.True(Takeovers.CanSnooze(TakeoverDismissal.SnoozeOnly, 1));
        Assert.True(Takeovers.CanFinish(TakeoverDismissal.SnoozeOnly, 0));
    }

    [Fact]
    public void LockedHoldsBothUntilTheTimerEnds()
    {
        Assert.False(Takeovers.CanFinish(TakeoverDismissal.Locked, 1));
        Assert.False(Takeovers.CanSnooze(TakeoverDismissal.Locked, 1));
        Assert.True(Takeovers.CanFinish(TakeoverDismissal.Locked, 0));
        Assert.True(Takeovers.CanSnooze(TakeoverDismissal.Locked, 0));
    }

    [Fact]
    public void TheEmergencyExitTakesADeliberateHold() =>
        Assert.InRange(Takeovers.EmergencyExitHold.TotalSeconds, 3, 10);

    [Fact]
    public void PersistsAndTheDefaultIsNotWritten()
    {
        var open = AppDataJson.Encode(Data(Critical()));
        Assert.DoesNotContain("dismissal", Encoding.UTF8.GetString(open));
        Assert.Null(AppDataJson.Decode(open).Reminders[0].Dismissal);

        var locked = AppDataJson.Encode(Data(Critical(dismissal: TakeoverDismissal.Locked)));
        Assert.Contains("\"dismissal\" : \"locked\"", Encoding.UTF8.GetString(locked));
        Assert.Equal(TakeoverDismissal.Locked, AppDataJson.Decode(locked).Reminders[0].Dismissal);

        var snoozeOnly = AppDataJson.Encode(Data(Critical(dismissal: TakeoverDismissal.SnoozeOnly)));
        Assert.Contains("\"dismissal\" : \"snoozeOnly\"", Encoding.UTF8.GetString(snoozeOnly));
    }

    [Fact]
    public void AnUnknownLevelReadsAsUnset()
    {
        var locked = Encoding.UTF8.GetString(
            AppDataJson.Encode(Data(Critical(dismissal: TakeoverDismissal.Locked))));
        var newer = locked.Replace("\"locked\"", "\"handcuffed\"");
        var reminder = AppDataJson.Decode(Encoding.UTF8.GetBytes(newer)).Reminders[0];
        Assert.Null(reminder.Dismissal);
        Assert.Equal("Tilt back", reminder.Title);
    }

    [Fact]
    public void RawValuesRoundTripAndMatchTheSwiftEnum()
    {
        foreach (var level in Enum.GetValues<TakeoverDismissal>())
        {
            Assert.Equal(level, Takeovers.Parse(Takeovers.RawValue(level)));
            Assert.False(string.IsNullOrEmpty(Takeovers.Title(level)));
        }
        Assert.Equal("snoozeOnly", Takeovers.RawValue(TakeoverDismissal.SnoozeOnly));
    }
}
