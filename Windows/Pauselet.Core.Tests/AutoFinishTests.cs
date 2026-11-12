using System.Text;
using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// A takeover that closes itself when its countdown ends. Mirrors the Swift
/// <c>AutoFinishTests</c>.
/// </summary>
public class AutoFinishTests
{
    private static Reminder Critical(int? countdown = 300, bool? autoFinish = null) =>
        new Reminder
        {
            Title = "Tilt back",
            Schedule = new Schedule.Interval(60),
            Priority = Priority.Critical,
            ActivityDurationSeconds = countdown,
            AutoFinish = autoFinish,
            CreatedAt = Instant.FromUnixTimeSeconds(1_760_000_000),
        };

    [Fact]
    public void WaitsForDoneByDefault() =>
        Assert.False(Takeovers.FinishesAutomatically(Critical()));

    [Fact]
    public void FinishesItselfWhenAskedAndThereIsACountdown() =>
        Assert.True(Takeovers.FinishesAutomatically(Critical(autoFinish: true)));

    [Fact]
    public void NeverWithoutACountdown()
    {
        Assert.False(Takeovers.FinishesAutomatically(Critical(countdown: null, autoFinish: true)));
        Assert.False(Takeovers.FinishesAutomatically(Critical(countdown: 0, autoFinish: true)));
    }

    [Fact]
    public void PersistsAndTheDefaultIsNotWritten()
    {
        var data = new AppData { Reminders = [Critical()], Settings = new Settings(), Events = [] };
        var waiting = AppDataJson.Encode(data);
        Assert.DoesNotContain("autoFinish", Encoding.UTF8.GetString(waiting));
        Assert.Null(AppDataJson.Decode(waiting).Reminders[0].AutoFinish);

        var automatic = AppDataJson.Encode(data with { Reminders = [Critical(autoFinish: true)] });
        Assert.Contains("\"autoFinish\" : true", Encoding.UTF8.GetString(automatic));
        Assert.True(AppDataJson.Decode(automatic).Reminders[0].AutoFinish);
    }

    [Fact]
    public void TheFinishedStateIsShownBeforeTheScreenGoes()
    {
        Assert.InRange(Takeovers.AutoFinishDelay.TotalSeconds, 1, 3);
    }
}
