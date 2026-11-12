using System.Text;
using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// The "None" row of the sound picker: a reminder that makes no sound at
/// all when it fires, whatever the tier and the master switch say. Mirrors
/// the Swift <c>SoundTests</c>.
/// </summary>
public class SoundTests
{
    private static Reminder Critical(bool? isSilent = null, string? soundName = null) =>
        new Reminder
        {
            Title = "Tilt back",
            Schedule = new Schedule.Interval(60),
            Priority = Priority.Critical,
            ActivityDurationSeconds = 300,
            SoundName = soundName,
            IsSilent = isSilent,
            WarningMinutes = 5,
            CreatedAt = Instant.FromUnixTimeSeconds(1_760_000_000),
        };

    [Fact]
    public void AReminderSoundsByDefault() =>
        Assert.True(new Settings().PlaysSound(Critical()));

    [Fact]
    public void SilentReminderPlaysNothingEvenWithSoundsOn() =>
        Assert.False(new Settings { SoundEnabled = true }.PlaysSound(Critical(isSilent: true)));

    [Fact]
    public void SoundsOffIsStillOff()
    {
        Assert.False(new Settings { SoundEnabled = false }.PlaysSound(Critical()));
        Assert.False(new Settings { SoundEnabled = false }.PlaysSound(Critical(isSilent: true)));
    }

    [Fact]
    public void TierRuleIsUntouched()
    {
        Assert.False(new Settings().PlaysSound(Critical() with { Priority = Priority.Normal }));
        Assert.True(new Settings().PlaysSound(Critical() with { Priority = Priority.Important }));
        Assert.False(new Settings().PlaysSound(
            Critical(isSilent: true) with { Priority = Priority.Important }));
    }

    [Fact]
    public void SilentDoesNotSilenceTheWarning()
    {
        Assert.True(Warnings.PlaysSound(Critical(isSilent: true), new Settings()));
        Assert.True(new Settings().PlaysSound(Critical() with { WarningIsSilent = true }));
    }

    [Fact]
    public void SilentPersistsAndTheDefaultIsNotWritten()
    {
        var data = new AppData { Reminders = [Critical()], Settings = new Settings(), Events = [] };
        var sounding = AppDataJson.Encode(data);
        Assert.DoesNotContain("isSilent", Encoding.UTF8.GetString(sounding));
        Assert.Null(AppDataJson.Decode(sounding).Reminders[0].IsSilent);

        var silent = AppDataJson.Encode(data with { Reminders = [Critical(isSilent: true)] });
        Assert.Contains("\"isSilent\" : true", Encoding.UTF8.GetString(silent));
        Assert.True(AppDataJson.Decode(silent).Reminders[0].IsSilent);
    }

    [Fact]
    public void SilentReminderCarriesNoSoundName()
    {
        var data = new AppData
        {
            Reminders = [Critical(isSilent: true)], Settings = new Settings(), Events = [],
        };
        Assert.DoesNotContain("soundName", Encoding.UTF8.GetString(AppDataJson.Encode(data)));
    }
}
