import XCTest
@testable import ReminderCore

/// The guided-exercise programme: what a timeline contains, what the coach
/// says when, and how the session cursor follows wall time through pause,
/// resume and skip.
final class ExerciseSessionTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_760_000_000)

    private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    /// 2 sets × 3 reps, 5 s hold, 2 s between reps, 10 s between sets.
    private var twoByThree: Exercise {
        Exercise(
            name: "Chin tucks", sets: 2, reps: 3,
            holdSeconds: 5, restBetweenRepsSeconds: 2, restBetweenSetsSeconds: 10
        )
    }

    private func timeline(_ exercise: Exercise) throws -> ExerciseTimeline {
        try XCTUnwrap(ExerciseTimeline(exercise: exercise))
    }

    // MARK: - Timeline

    func testUntimedExerciseHasNoTimeline() {
        XCTAssertNil(ExerciseTimeline(exercise: Exercise(name: "Squats")))
        XCTAssertNil(ExerciseTimeline(exercise: Exercise(name: "Squats", holdSeconds: 0)))
    }

    func testTimelinePhasesForTwoSetsOfThree() throws {
        let phases = try timeline(twoByThree).phases.map {
            [$0.kind.rawValue, "\($0.set)", "\($0.rep)", "\(Int($0.start))", "\(Int($0.duration))"]
                .joined(separator: " ")
        }

        XCTAssertEqual(phases, [
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
        ])
    }

    func testZeroRestsEmitNoRestPhases() throws {
        let exercise = Exercise(name: "Plank", sets: 2, reps: 2, holdSeconds: 4)
        let timeline = try timeline(exercise)

        XCTAssertEqual(timeline.phases.map(\.kind), [.getReady, .hold, .hold, .hold, .hold])
        XCTAssertEqual(timeline.totalDuration, 3 + 4 * 4)
    }

    func testSingleSetSingleRep() throws {
        let timeline = try timeline(Exercise(name: "Plank", sets: 1, reps: 1, holdSeconds: 30,
                                             restBetweenRepsSeconds: 5, restBetweenSetsSeconds: 60))

        XCTAssertEqual(timeline.phases.map(\.kind), [.getReady, .hold])
        XCTAssertEqual(timeline.totalDuration, 33)
    }

    func testTotalDurationSumsPhases() throws {
        let timeline = try timeline(twoByThree)
        XCTAssertEqual(timeline.totalDuration, 51)
        XCTAssertEqual(timeline.totalDuration, timeline.phases.reduce(0) { $0 + $1.duration })
    }

    func testPhaseIndexAtBoundariesIsHalfOpen() throws {
        let timeline = try timeline(twoByThree)

        XCTAssertEqual(timeline.phaseIndex(at: -1), 0, "Before the start counts as the start")
        XCTAssertEqual(timeline.phaseIndex(at: 0), 0)
        XCTAssertEqual(timeline.phaseIndex(at: 2.999), 0)
        XCTAssertEqual(timeline.phaseIndex(at: 3), 1, "The end of a phase is the next phase")
        XCTAssertEqual(timeline.phaseIndex(at: 22), 6)
        XCTAssertEqual(timeline.phaseIndex(at: 50.999), 11)
        XCTAssertNil(timeline.phaseIndex(at: 51))
        XCTAssertNil(timeline.phaseIndex(at: 1000))
    }

    func testPhaseTitlesAndLabels() throws {
        let phases = try timeline(twoByThree).phases

        XCTAssertEqual(phases[0].title, "Get ready")
        XCTAssertEqual(phases[0].label, "Get ready")
        XCTAssertEqual(phases[1].title, "Set 1 · Rep 1")
        XCTAssertEqual(phases[1].label, "Hold")
        XCTAssertEqual(phases[2].title, "Set 1 · Rep 1")
        XCTAssertEqual(phases[2].label, "Rest")
        XCTAssertEqual(phases[6].title, "Set 1 done")
        XCTAssertEqual(phases[6].label, "Rest between sets")
    }

    // MARK: - Cues

    func testCueTextPerPhaseKind() throws {
        let timeline = try timeline(twoByThree)
        let name = "Chin tucks"

        XCTAssertEqual(ExerciseTimeline.cue(for: timeline.phases[0], exerciseName: name),
                       "Chin tucks. Get ready.")
        XCTAssertEqual(ExerciseTimeline.cue(for: timeline.phases[1], exerciseName: name),
                       "Set 1, rep 1. Hold for 5 seconds.")
        XCTAssertEqual(ExerciseTimeline.cue(for: timeline.phases[2], exerciseName: name),
                       "Rest.")
        XCTAssertEqual(ExerciseTimeline.cue(for: timeline.phases[3], exerciseName: name),
                       "Rep 2. Hold.")
        XCTAssertEqual(ExerciseTimeline.cue(for: timeline.phases[6], exerciseName: name),
                       "Set 1 done. Rest for 10 seconds.")
        XCTAssertEqual(ExerciseTimeline.cue(for: timeline.phases[7], exerciseName: name),
                       "Set 2, rep 1. Hold for 5 seconds.")

        let oneSecond = try self.timeline(Exercise(name: "Blink", sets: 1, reps: 1, holdSeconds: 1))
        XCTAssertEqual(ExerciseTimeline.cue(for: oneSecond.phases[1], exerciseName: "Blink"),
                       "Set 1, rep 1. Hold for 1 second.")
    }

    func testCountdownCuesOnlyForHoldsOfSixSecondsOrMore() throws {
        let short = try timeline(Exercise(name: "Short", sets: 1, reps: 1, holdSeconds: 5))
        XCTAssertFalse(short.cues.contains { $0.text == "Three." })

        let long = try timeline(Exercise(name: "Long", sets: 1, reps: 1, holdSeconds: 6))
        let countdown = long.cues.filter { ["Three.", "Two.", "One."].contains($0.text) }
        XCTAssertEqual(countdown.map(\.text), ["Three.", "Two.", "One."])
        // The hold runs 3...9; the words land on the last three seconds.
        XCTAssertEqual(countdown.map(\.at), [6, 7, 8])
    }

    func testCuesAreSortedAndEndWithExerciseComplete() throws {
        let timeline = try timeline(Exercise(name: "Long", sets: 2, reps: 2, holdSeconds: 8,
                                             restBetweenRepsSeconds: 1, restBetweenSetsSeconds: 4))

        XCTAssertEqual(timeline.cues.map(\.at), timeline.cues.map(\.at).sorted())
        XCTAssertEqual(timeline.cues.first?.text, "Long. Get ready.")
        XCTAssertEqual(timeline.cues.last?.text, "Exercise complete.")
        XCTAssertEqual(timeline.cues.last?.at, timeline.totalDuration)
        // Every phase start has exactly one cue.
        for phase in timeline.phases {
            XCTAssertEqual(timeline.cues.filter { $0.at == phase.start }.count, 1, "\(phase)")
        }
    }

    // MARK: - Session

    func testStartCountsTheGetReadyCueImmediately() throws {
        let session = ExerciseSession(timeline: try timeline(twoByThree), startedAt: epoch)

        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.cueCount(at: epoch), 1)
        XCTAssertEqual(session.phase(at: epoch)?.kind, .getReady)
    }

    func testElapsedFollowsWallClockNotTicks() throws {
        let session = ExerciseSession(timeline: try timeline(twoByThree), startedAt: epoch)

        // Nothing observed the session in between; it must still be right.
        XCTAssertEqual(session.elapsed(at: at(4.7)), 4.7, accuracy: 0.0001)
        guard case let .phase(index, remaining, progress) = session.position(at: at(4.7)) else {
            return XCTFail("Expected a phase")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(remaining, 3.3, accuracy: 0.0001)
        XCTAssertEqual(progress, 1.7 / 5, accuracy: 0.0001)
    }

    func testPauseFreezesElapsedAndResumeContinues() throws {
        var session = ExerciseSession(timeline: try timeline(twoByThree), startedAt: epoch)

        session.pause(at: at(4))
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(session.elapsed(at: at(4)), 4)
        XCTAssertEqual(session.elapsed(at: at(60)), 4, "Paused time does not count")

        session.resume(at: at(60))
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.elapsed(at: at(61.5)), 5.5, accuracy: 0.0001)

        session.togglePause(at: at(62))
        XCTAssertEqual(session.state, .paused)
        session.togglePause(at: at(70))
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.elapsed(at: at(70)), 6, accuracy: 0.0001)
    }

    func testSkipJumpsToNextPhaseStart() throws {
        var session = ExerciseSession(timeline: try timeline(twoByThree), startedAt: epoch)

        session.skip(at: at(4))       // inside hold 1 (3...8) → rest at 8
        XCTAssertEqual(session.elapsed(at: at(4)), 8)
        XCTAssertEqual(session.phase(at: at(4))?.kind, .restBetweenReps)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.elapsed(at: at(5)), 9, "Keeps running from the new position")
    }

    func testSkipWhilePausedStaysPaused() throws {
        var session = ExerciseSession(timeline: try timeline(twoByThree), startedAt: epoch)

        session.pause(at: at(4))
        session.skip(at: at(30))
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(session.elapsed(at: at(100)), 8)
    }

    func testSkipPastLastPhaseFinishes() throws {
        var session = ExerciseSession(timeline: try timeline(twoByThree), startedAt: epoch)

        session.skip(at: at(47))      // inside the last hold (46...51)
        XCTAssertTrue(session.isFinished(at: at(47)))
        XCTAssertEqual(session.position(at: at(47)), .complete)
        XCTAssertTrue(session.markCompletedIfFinished(at: at(47)))
        XCTAssertEqual(session.state, .completed)
    }

    func testCueCountAfterStallReportsOnlyTheCount() throws {
        let session = ExerciseSession(timeline: try timeline(twoByThree), startedAt: epoch)

        // The get-ready cue, then hold, rest, hold at 3, 8 and 10.
        XCTAssertEqual(session.cueCount(at: at(2.9)), 1)
        XCTAssertEqual(session.cueCount(at: at(3)), 2)
        XCTAssertEqual(session.cueCount(at: at(11)), 4)
        // A driver that last acted on count 1 speaks cues[3] only.
        XCTAssertEqual(session.timeline.cues[3].text, "Rep 2. Hold.")
        XCTAssertEqual(session.cueCount(at: at(51)), session.timeline.cues.count)
    }

    func testMarkCompletedFiresExactlyOnce() throws {
        var session = ExerciseSession(timeline: try timeline(twoByThree), startedAt: epoch)

        XCTAssertFalse(session.markCompletedIfFinished(at: at(50.9)))
        XCTAssertTrue(session.markCompletedIfFinished(at: at(51)))
        XCTAssertFalse(session.markCompletedIfFinished(at: at(52)))
        XCTAssertEqual(session.state, .completed)
        XCTAssertEqual(session.elapsed(at: at(500)), 51, "Clamped at the end")
        XCTAssertEqual(session.cueCount(at: at(500)), session.timeline.cues.count)
    }

    func testClockSetBackwardsDoesNotGoNegative() throws {
        var session = ExerciseSession(timeline: try timeline(twoByThree), startedAt: epoch)

        XCTAssertEqual(session.elapsed(at: at(-30)), 0)
        XCTAssertEqual(session.phase(at: at(-30))?.kind, .getReady)

        session.pause(at: at(10))
        session.resume(at: at(20))
        XCTAssertEqual(session.elapsed(at: at(15)), 10, "Never below what was banked")
    }

    func testAnnouncementFreezesAtThePhaseStart() throws {
        var session = ExerciseSession(timeline: try timeline(twoByThree), startedAt: epoch)

        // The driver noticed the hold 0.4 s late; the hold must not be shorter for it.
        session.beginAnnouncement(at: at(3.4))
        XCTAssertEqual(session.state, .announcing)
        XCTAssertEqual(session.elapsed(at: at(3.4)), 3)
        XCTAssertEqual(session.elapsed(at: at(9)), 3, "Frozen while the cue is spoken")
        XCTAssertTrue(session.isAtPhaseStart(at: at(9)))
        XCTAssertEqual(session.phase(at: at(9))?.kind, .hold)

        session.finishAnnouncement(at: at(5))
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.elapsed(at: at(7)), 5, "The full 5 s hold starts now")
        XCTAssertFalse(session.isAtPhaseStart(at: at(7)))
    }

    func testAnnouncementOnlyFromRunning() throws {
        var session = ExerciseSession(timeline: try timeline(twoByThree), startedAt: epoch)

        session.pause(at: at(4))
        session.beginAnnouncement(at: at(4))
        XCTAssertEqual(session.state, .paused)
        session.finishAnnouncement(at: at(4))
        XCTAssertEqual(session.state, .paused)
    }

    func testPauseDuringAnnouncementAndSkipWhileAnnouncing() throws {
        var session = ExerciseSession(timeline: try timeline(twoByThree), startedAt: epoch)

        session.beginAnnouncement(at: at(3.1))
        session.togglePause(at: at(4))
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(session.elapsed(at: at(10)), 3)
        session.togglePause(at: at(10))
        XCTAssertEqual(session.state, .running)
        XCTAssertTrue(session.isAtPhaseStart(at: at(10)), "Nothing of the hold has run")

        session.beginAnnouncement(at: at(10))
        session.skip(at: at(12))
        XCTAssertEqual(session.state, .announcing, "Still the driver's turn to speak")
        XCTAssertEqual(session.elapsed(at: at(20)), 8, "At the next phase's start, frozen")
        XCTAssertEqual(session.phase(at: at(20))?.kind, .restBetweenReps)

        session.stop(at: at(20))
        XCTAssertEqual(session.state, .stopped)
    }

    func testStopIsTerminal() throws {
        var session = ExerciseSession(timeline: try timeline(twoByThree), startedAt: epoch)

        session.stop(at: at(4))
        XCTAssertEqual(session.state, .stopped)
        XCTAssertEqual(session.elapsed(at: at(40)), 4)
        session.resume(at: at(40))
        session.togglePause(at: at(40))
        session.skip(at: at(40))
        XCTAssertEqual(session.state, .stopped)
        XCTAssertFalse(session.markCompletedIfFinished(at: at(400)))
    }
}
