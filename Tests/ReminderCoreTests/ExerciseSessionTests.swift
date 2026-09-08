import XCTest
@testable import ReminderCore

/// The coached programme: what a timeline contains for one exercise and for
/// a run of them, what the coach says when, and how the session cursor
/// follows wall time through pause, resume and skip.
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

    /// An exercise with no hold is still coached: each rep gets the fixed
    /// tempo instead of a hold, so a whole programme can run unattended.
    func testExerciseWithoutAHoldIsPacedRepByRep() throws {
        let timeline = try timeline(Exercise(name: "Squats", sets: 1, reps: 3,
                                             restBetweenRepsSeconds: 2))

        XCTAssertEqual(timeline.phases.map(\.kind),
                       [.getReady, .rep, .restBetweenReps, .rep, .restBetweenReps, .rep])
        XCTAssertEqual(timeline.phases[1].duration, TimeInterval(ExerciseTimeline.repSeconds))
        XCTAssertEqual(timeline.phases[1].title, "Set 1 · Rep 1")
        XCTAssertEqual(timeline.phases[1].label, "Go")
        XCTAssertEqual(timeline.phases[1].cue, "Set 1, rep 1.")
        XCTAssertEqual(timeline.phases[3].cue, "Rep 2.")
        XCTAssertEqual(timeline.totalDuration, 3 + 3 * 3 + 2 * 2)
        XCTAssertFalse(timeline.cues.contains { $0.text == "Three." },
                       "The countdown belongs to holds, not paced reps")
    }

    func testNothingRunnableHasNoTimeline() {
        XCTAssertNil(ExerciseTimeline(exercise: Exercise(name: "Squats", sets: 0)))
        XCTAssertNil(ExerciseTimeline(exercises: []))
        XCTAssertNil(ExerciseTimeline(exercises: [Exercise(name: "Squats", reps: 0)]))
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

        XCTAssertEqual(timeline.phases[0].cue, "Chin tucks. Get ready.")
        XCTAssertEqual(timeline.phases[1].cue, "Set 1, rep 1. Hold for 5 seconds.")
        XCTAssertEqual(timeline.phases[2].cue, "Rest.")
        XCTAssertEqual(timeline.phases[3].cue, "Rep 2. Hold.")
        XCTAssertEqual(timeline.phases[6].cue, "Set 1 done. Rest for 10 seconds.")
        XCTAssertEqual(timeline.phases[7].cue, "Set 2, rep 1. Hold for 5 seconds.")

        let oneSecond = try self.timeline(Exercise(name: "Blink", sets: 1, reps: 1, holdSeconds: 1))
        XCTAssertEqual(oneSecond.phases[1].cue, "Set 1, rep 1. Hold for 1 second.")
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

    func testEveryPhaseNamesItsExercise() throws {
        let exercise = twoByThree
        let timeline = try timeline(exercise)

        XCTAssertEqual(timeline.entries.map(\.id), [exercise.id])
        XCTAssertEqual(timeline.entries.first?.start, 0)
        XCTAssertEqual(timeline.entries.first?.end, timeline.totalDuration)
        XCTAssertEqual(timeline.completionTitle, "Exercise complete")
        for phase in timeline.phases {
            XCTAssertEqual(phase.exerciseID, exercise.id)
            XCTAssertEqual(phase.exerciseName, "Chin tucks")
        }
    }

    // MARK: - A run of exercises

    /// Two exercises with 10 s between them: the first, the rest (which
    /// belongs to the second), the second's lead-in, the second.
    func testSequencePutsTheRestBetweenExercisesBeforeTheNextLeadIn() throws {
        let tucks = Exercise(name: "Chin tucks", sets: 1, reps: 2, holdSeconds: 5)
        let shifts = Exercise(name: "Weight shifts", sets: 1, reps: 2)
        let timeline = try XCTUnwrap(ExerciseTimeline(
            exercises: [tucks, shifts], restBetweenExercisesSeconds: 10
        ))

        let phases = timeline.phases.map {
            [$0.kind.rawValue, "\(Int($0.start))", "\(Int($0.duration))"].joined(separator: " ")
        }
        XCTAssertEqual(phases, [
            "getReady 0 3",
            "hold 3 5",
            "hold 8 5",
            "restBetweenExercises 13 10",
            "getReady 23 3",
            "rep 26 3",
            "rep 29 3",
        ])
        XCTAssertEqual(timeline.phases[3].exerciseID, shifts.id, "The rest is the next one's")
        XCTAssertEqual(timeline.phases[3].title, "Up next")
        XCTAssertEqual(timeline.phases[3].label, "Rest")

        XCTAssertEqual(timeline.entries.map(\.id), [tucks.id, shifts.id])
        XCTAssertEqual(timeline.entries[0].end, 13)
        XCTAssertEqual(timeline.entries[1].start, 23)
        XCTAssertEqual(timeline.entries[1].end, 32)
        XCTAssertEqual(timeline.totalDuration, 32)
        XCTAssertEqual(timeline.completionTitle, "All exercises complete")
    }

    func testSequenceCuesSignOffTheExerciseBefore() throws {
        let tucks = Exercise(name: "Chin tucks", sets: 1, reps: 1, holdSeconds: 5)
        let shifts = Exercise(name: "Weight shifts", sets: 1, reps: 1)
        let rows = Exercise(name: "Rows", sets: 1, reps: 1)

        let withRest = try XCTUnwrap(ExerciseTimeline(
            exercises: [tucks, shifts], restBetweenExercisesSeconds: 30
        ))
        XCTAssertEqual(withRest.phases[2].cue,
                       "Chin tucks complete. Rest for 30 seconds. Next, Weight shifts.")
        XCTAssertEqual(withRest.phases[3].cue, "Weight shifts. Get ready.")
        XCTAssertEqual(withRest.cues.last?.text, "All exercises complete.")

        let noRest = try XCTUnwrap(ExerciseTimeline(exercises: [tucks, shifts, rows]))
        XCTAssertEqual(noRest.phases.map(\.kind),
                       [.getReady, .hold, .getReady, .rep, .getReady, .rep])
        XCTAssertEqual(noRest.phases[2].cue, "Chin tucks complete. Weight shifts. Get ready.")
        XCTAssertEqual(noRest.phases[4].cue, "Weight shifts complete. Rows. Get ready.")
    }

    func testFinishedExercisesAndTheStartOfTheNext() throws {
        let tucks = Exercise(name: "Chin tucks", sets: 1, reps: 2, holdSeconds: 5)
        let shifts = Exercise(name: "Weight shifts", sets: 1, reps: 2)
        let timeline = try XCTUnwrap(ExerciseTimeline(
            exercises: [tucks, shifts], restBetweenExercisesSeconds: 10
        ))

        XCTAssertEqual(timeline.finishedExerciseIDs(at: 12.9), [])
        XCTAssertEqual(timeline.finishedExerciseIDs(at: 13), [tucks.id])
        XCTAssertEqual(timeline.finishedExerciseIDs(at: 31.9), [tucks.id])
        XCTAssertEqual(timeline.finishedExerciseIDs(at: 32), [tucks.id, shifts.id])

        XCTAssertEqual(timeline.startOfExercise(after: tucks.id), 23,
                       "Past the rest, to the next lead-in")
        XCTAssertEqual(timeline.startOfExercise(after: shifts.id), 32, "The last one: the end")
        XCTAssertEqual(timeline.startOfExercise(after: UUID()), 32)
    }

    func testSequenceLeavesOutWhatCannotRun() throws {
        let tucks = Exercise(name: "Chin tucks", sets: 1, reps: 1, holdSeconds: 5)
        let broken = Exercise(name: "Nothing", sets: 0, reps: 0)
        let timeline = try XCTUnwrap(ExerciseTimeline(exercises: [broken, tucks]))

        XCTAssertEqual(timeline.entries.map(\.id), [tucks.id])
        XCTAssertEqual(timeline.phases.first?.cue, "Chin tucks. Get ready.")
    }

    func testJumpMovesTheCursorAndClampsToTheSession() throws {
        var session = ExerciseSession(timeline: try timeline(twoByThree), startedAt: epoch)

        session.jump(to: 32, at: at(4))
        XCTAssertEqual(session.elapsed(at: at(4)), 32)
        XCTAssertEqual(session.phase(at: at(4))?.title, "Set 2 · Rep 1")
        XCTAssertEqual(session.elapsed(at: at(5)), 33, "Keeps running from the new position")

        session.jump(to: 1000, at: at(5))
        XCTAssertTrue(session.isFinished(at: at(5)))

        session.stop(at: at(5))
        session.jump(to: 0, at: at(5))
        XCTAssertTrue(session.isFinished(at: at(5)), "A stopped session does not move")
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
