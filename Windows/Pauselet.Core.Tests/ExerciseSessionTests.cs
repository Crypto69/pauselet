using NodaTime;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// The guided-exercise programme: what a timeline contains, what the coach
/// says when, and how the session cursor follows wall time through pause,
/// resume and skip. (Mirrors ExerciseSessionTests.swift, case for case.)
/// </summary>
public class ExerciseSessionTests
{
    private static readonly Instant Epoch = Instant.FromUnixTimeSeconds(1_760_000_000);

    private static Instant At(double seconds) => Epoch + Duration.FromSeconds(seconds);

    /// <summary>2 sets × 3 reps, 5 s hold, 2 s between reps, 10 s between sets.</summary>
    private static Exercise TwoByThree => new()
    {
        Name = "Chin tucks", Sets = 2, Reps = 3,
        HoldSeconds = 5, RestBetweenRepsSeconds = 2, RestBetweenSetsSeconds = 10,
    };

    private static ExerciseTimeline Timeline(Exercise exercise)
    {
        var timeline = ExerciseTimeline.For(exercise);
        Assert.NotNull(timeline);
        return timeline!;
    }

    private static ExerciseSession Session() => new(Timeline(TwoByThree), Epoch);

    // MARK: - Timeline

    [Fact]
    public void UntimedExerciseHasNoTimeline()
    {
        Assert.Null(ExerciseTimeline.For(new Exercise { Name = "Squats" }));
        Assert.Null(ExerciseTimeline.For(new Exercise { Name = "Squats", HoldSeconds = 0 }));
    }

    [Fact]
    public void TimelinePhasesForTwoSetsOfThree()
    {
        var phases = Timeline(TwoByThree).Phases
            .Select(phase => string.Join(
                " ",
                phase.KindName, phase.Set, phase.Rep, (int)phase.Start, (int)phase.Duration))
            .ToArray();

        Assert.Equal(
        [
            "getReady 0 0 0 3",
            "hold 1 1 3 5",
            "restBetweenReps 1 1 8 2",
            "hold 1 2 10 5",
            "restBetweenReps 1 2 15 2",
            "hold 1 3 17 5",          // no rest after the last rep of a set
            "restBetweenSets 1 0 22 10",
            "hold 2 1 32 5",
            "restBetweenReps 2 1 37 2",
            "hold 2 2 39 5",
            "restBetweenReps 2 2 44 2",
            "hold 2 3 46 5",          // and nothing after the last set
        ], phases);
    }

    [Fact]
    public void ZeroRestsEmitNoRestPhases()
    {
        var timeline = Timeline(new Exercise { Name = "Plank", Sets = 2, Reps = 2, HoldSeconds = 4 });

        Assert.Equal(
        [
            ExercisePhase.Kind.GetReady, ExercisePhase.Kind.Hold, ExercisePhase.Kind.Hold,
            ExercisePhase.Kind.Hold, ExercisePhase.Kind.Hold,
        ], timeline.Phases.Select(phase => phase.PhaseKind).ToArray());
        Assert.Equal(3 + 4 * 4, timeline.TotalDuration);
    }

    [Fact]
    public void SingleSetSingleRep()
    {
        var timeline = Timeline(new Exercise
        {
            Name = "Plank", Sets = 1, Reps = 1, HoldSeconds = 30,
            RestBetweenRepsSeconds = 5, RestBetweenSetsSeconds = 60,
        });

        Assert.Equal(
            [ExercisePhase.Kind.GetReady, ExercisePhase.Kind.Hold],
            timeline.Phases.Select(phase => phase.PhaseKind).ToArray());
        Assert.Equal(33, timeline.TotalDuration);
    }

    [Fact]
    public void TotalDurationSumsPhases()
    {
        var timeline = Timeline(TwoByThree);
        Assert.Equal(51, timeline.TotalDuration);
        Assert.Equal(timeline.Phases.Sum(phase => phase.Duration), timeline.TotalDuration);
    }

    [Fact]
    public void PhaseIndexAtBoundariesIsHalfOpen()
    {
        var timeline = Timeline(TwoByThree);

        Assert.Equal(0, timeline.PhaseIndexAt(-1));
        Assert.Equal(0, timeline.PhaseIndexAt(0));
        Assert.Equal(0, timeline.PhaseIndexAt(2.999));
        Assert.Equal(1, timeline.PhaseIndexAt(3));
        Assert.Equal(6, timeline.PhaseIndexAt(22));
        Assert.Equal(11, timeline.PhaseIndexAt(50.999));
        Assert.Null(timeline.PhaseIndexAt(51));
        Assert.Null(timeline.PhaseIndexAt(1000));
    }

    [Fact]
    public void PhaseTitlesAndLabels()
    {
        var phases = Timeline(TwoByThree).Phases;

        Assert.Equal("Get ready", phases[0].Title);
        Assert.Equal("Get ready", phases[0].Label);
        Assert.Equal("Set 1 · Rep 1", phases[1].Title);
        Assert.Equal("Hold", phases[1].Label);
        Assert.Equal("Set 1 · Rep 1", phases[2].Title);
        Assert.Equal("Rest", phases[2].Label);
        Assert.Equal("Set 1 done", phases[6].Title);
        Assert.Equal("Rest between sets", phases[6].Label);
    }

    // MARK: - Cues

    [Fact]
    public void CueTextPerPhaseKind()
    {
        var timeline = Timeline(TwoByThree);
        const string name = "Chin tucks";

        Assert.Equal("Chin tucks. Get ready.", ExerciseTimeline.Cue(timeline.Phases[0], name));
        Assert.Equal(
            "Set 1, rep 1. Hold for 5 seconds.", ExerciseTimeline.Cue(timeline.Phases[1], name));
        Assert.Equal("Rest.", ExerciseTimeline.Cue(timeline.Phases[2], name));
        Assert.Equal("Rep 2. Hold.", ExerciseTimeline.Cue(timeline.Phases[3], name));
        Assert.Equal(
            "Set 1 done. Rest for 10 seconds.", ExerciseTimeline.Cue(timeline.Phases[6], name));
        Assert.Equal(
            "Set 2, rep 1. Hold for 5 seconds.", ExerciseTimeline.Cue(timeline.Phases[7], name));

        var oneSecond = Timeline(
            new Exercise { Name = "Blink", Sets = 1, Reps = 1, HoldSeconds = 1 });
        Assert.Equal(
            "Set 1, rep 1. Hold for 1 second.",
            ExerciseTimeline.Cue(oneSecond.Phases[1], "Blink"));
    }

    [Fact]
    public void CountdownCuesOnlyForHoldsOfSixSecondsOrMore()
    {
        var shortHold = Timeline(
            new Exercise { Name = "Short", Sets = 1, Reps = 1, HoldSeconds = 5 });
        Assert.DoesNotContain(shortHold.Cues, cue => cue.Text == "Three.");

        var longHold = Timeline(
            new Exercise { Name = "Long", Sets = 1, Reps = 1, HoldSeconds = 6 });
        var countdown = longHold.Cues
            .Where(cue => cue.Text is "Three." or "Two." or "One.")
            .ToList();
        Assert.Equal(
            ["Three.", "Two.", "One."], countdown.Select(cue => cue.Text).ToArray());
        // The hold runs 3...9; the words land on the last three seconds.
        Assert.Equal([6d, 7d, 8d], countdown.Select(cue => cue.At).ToArray());
    }

    [Fact]
    public void CuesAreSortedAndEndWithExerciseComplete()
    {
        var timeline = Timeline(new Exercise
        {
            Name = "Long", Sets = 2, Reps = 2, HoldSeconds = 8,
            RestBetweenRepsSeconds = 1, RestBetweenSetsSeconds = 4,
        });

        Assert.Equal(
            timeline.Cues.Select(cue => cue.At).Order().ToArray(),
            timeline.Cues.Select(cue => cue.At).ToArray());
        Assert.Equal("Long. Get ready.", timeline.Cues[0].Text);
        Assert.Equal("Exercise complete.", timeline.Cues[^1].Text);
        Assert.Equal(timeline.TotalDuration, timeline.Cues[^1].At);
        // Every phase start has exactly one cue.
        foreach (var phase in timeline.Phases)
        {
            Assert.True(
                timeline.Cues.Count(cue => cue.At == phase.Start) == 1,
                $"{phase.KindName} {phase.Set} {phase.Rep} {phase.Start}");
        }
    }

    // MARK: - Session

    [Fact]
    public void StartCountsTheGetReadyCueImmediately()
    {
        var session = Session();

        Assert.Equal(ExerciseSession.SessionState.Running, session.State);
        Assert.Equal(1, session.CueCount(Epoch));
        Assert.Equal(ExercisePhase.Kind.GetReady, session.PhaseAt(Epoch)?.PhaseKind);
    }

    [Fact]
    public void ElapsedFollowsWallClockNotTicks()
    {
        var session = Session();

        // Nothing observed the session in between; it must still be right.
        Assert.Equal(4.7, session.Elapsed(At(4.7)), 4);
        var position = session.PositionAt(At(4.7));
        Assert.False(position.IsComplete);
        Assert.Equal(1, position.Index);
        Assert.Equal(3.3, position.Remaining, 4);
        Assert.Equal(1.7 / 5, position.Progress, 4);
    }

    [Fact]
    public void PauseFreezesElapsedAndResumeContinues()
    {
        var session = Session();

        session.Pause(At(4));
        Assert.Equal(ExerciseSession.SessionState.Paused, session.State);
        Assert.Equal(4, session.Elapsed(At(4)));
        Assert.Equal(4, session.Elapsed(At(60)));

        session.Resume(At(60));
        Assert.Equal(ExerciseSession.SessionState.Running, session.State);
        Assert.Equal(5.5, session.Elapsed(At(61.5)), 4);

        session.TogglePause(At(62));
        Assert.Equal(ExerciseSession.SessionState.Paused, session.State);
        session.TogglePause(At(70));
        Assert.Equal(ExerciseSession.SessionState.Running, session.State);
        Assert.Equal(6, session.Elapsed(At(70)), 4);
    }

    [Fact]
    public void SkipJumpsToNextPhaseStart()
    {
        var session = Session();

        session.Skip(At(4));       // inside hold 1 (3...8) → rest at 8
        Assert.Equal(8, session.Elapsed(At(4)));
        Assert.Equal(ExercisePhase.Kind.RestBetweenReps, session.PhaseAt(At(4))?.PhaseKind);
        Assert.Equal(ExerciseSession.SessionState.Running, session.State);
        Assert.Equal(9, session.Elapsed(At(5)));
    }

    [Fact]
    public void SkipWhilePausedStaysPaused()
    {
        var session = Session();

        session.Pause(At(4));
        session.Skip(At(30));
        Assert.Equal(ExerciseSession.SessionState.Paused, session.State);
        Assert.Equal(8, session.Elapsed(At(100)));
    }

    [Fact]
    public void SkipPastLastPhaseFinishes()
    {
        var session = Session();

        session.Skip(At(47));      // inside the last hold (46...51)
        Assert.True(session.IsFinished(At(47)));
        Assert.True(session.PositionAt(At(47)).IsComplete);
        Assert.True(session.MarkCompletedIfFinished(At(47)));
        Assert.Equal(ExerciseSession.SessionState.Completed, session.State);
    }

    [Fact]
    public void CueCountAfterStallReportsOnlyTheCount()
    {
        var session = Session();

        // The get-ready cue, then hold, rest, hold at 3, 8 and 10.
        Assert.Equal(1, session.CueCount(At(2.9)));
        Assert.Equal(2, session.CueCount(At(3)));
        Assert.Equal(4, session.CueCount(At(11)));
        // A driver that last acted on count 1 speaks cues[3] only.
        Assert.Equal("Rep 2. Hold.", session.Timeline.Cues[3].Text);
        Assert.Equal(session.Timeline.Cues.Count, session.CueCount(At(51)));
    }

    [Fact]
    public void MarkCompletedFiresExactlyOnce()
    {
        var session = Session();

        Assert.False(session.MarkCompletedIfFinished(At(50.9)));
        Assert.True(session.MarkCompletedIfFinished(At(51)));
        Assert.False(session.MarkCompletedIfFinished(At(52)));
        Assert.Equal(ExerciseSession.SessionState.Completed, session.State);
        Assert.Equal(51, session.Elapsed(At(500)));
        Assert.Equal(session.Timeline.Cues.Count, session.CueCount(At(500)));
    }

    [Fact]
    public void ClockSetBackwardsDoesNotGoNegative()
    {
        var session = Session();

        Assert.Equal(0, session.Elapsed(At(-30)));
        Assert.Equal(ExercisePhase.Kind.GetReady, session.PhaseAt(At(-30))?.PhaseKind);

        session.Pause(At(10));
        session.Resume(At(20));
        Assert.Equal(10, session.Elapsed(At(15)));
    }

    [Fact]
    public void AnnouncementFreezesAtThePhaseStart()
    {
        var session = Session();

        // The driver noticed the hold 0.4 s late; the hold must not be shorter for it.
        session.BeginAnnouncement(At(3.4));
        Assert.Equal(ExerciseSession.SessionState.Announcing, session.State);
        Assert.Equal(3, session.Elapsed(At(3.4)));
        Assert.Equal(3, session.Elapsed(At(9)));
        Assert.True(session.IsAtPhaseStart(At(9)));
        Assert.Equal(ExercisePhase.Kind.Hold, session.PhaseAt(At(9))?.PhaseKind);

        session.FinishAnnouncement(At(5));
        Assert.Equal(ExerciseSession.SessionState.Running, session.State);
        Assert.Equal(5, session.Elapsed(At(7)));
        Assert.False(session.IsAtPhaseStart(At(7)));
    }

    [Fact]
    public void AnnouncementOnlyFromRunning()
    {
        var session = Session();

        session.Pause(At(4));
        session.BeginAnnouncement(At(4));
        Assert.Equal(ExerciseSession.SessionState.Paused, session.State);
        session.FinishAnnouncement(At(4));
        Assert.Equal(ExerciseSession.SessionState.Paused, session.State);
    }

    [Fact]
    public void PauseDuringAnnouncementAndSkipWhileAnnouncing()
    {
        var session = Session();

        session.BeginAnnouncement(At(3.1));
        session.TogglePause(At(4));
        Assert.Equal(ExerciseSession.SessionState.Paused, session.State);
        Assert.Equal(3, session.Elapsed(At(10)));
        session.TogglePause(At(10));
        Assert.Equal(ExerciseSession.SessionState.Running, session.State);
        Assert.True(session.IsAtPhaseStart(At(10)));

        session.BeginAnnouncement(At(10));
        session.Skip(At(12));
        Assert.Equal(ExerciseSession.SessionState.Announcing, session.State);
        Assert.Equal(8, session.Elapsed(At(20)));
        Assert.Equal(ExercisePhase.Kind.RestBetweenReps, session.PhaseAt(At(20))?.PhaseKind);

        session.Stop(At(20));
        Assert.Equal(ExerciseSession.SessionState.Stopped, session.State);
    }

    [Fact]
    public void StopIsTerminal()
    {
        var session = Session();

        session.Stop(At(4));
        Assert.Equal(ExerciseSession.SessionState.Stopped, session.State);
        Assert.Equal(4, session.Elapsed(At(40)));
        session.Resume(At(40));
        session.TogglePause(At(40));
        session.Skip(At(40));
        Assert.Equal(ExerciseSession.SessionState.Stopped, session.State);
        Assert.False(session.MarkCompletedIfFinished(At(400)));
    }
}
