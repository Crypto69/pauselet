import XCTest
import ReminderCore
@testable import Pauselet

/// Tests for the iOS coach *driver* — the platform layer around the shared
/// `ExerciseSession`. The timeline's own behaviour is already pinned by
/// `ExerciseSessionTests`, which runs on this destination too, so nothing here
/// re-tests it: these cover what the driver adds — which exercise is
/// suggested, what the rows report, what gets spoken and when, and the two
/// rules that matter medically (a cue is never spoken twice, and a hold never
/// completes while the app is in the background).
@MainActor
final class ExerciseCoachTests: XCTestCase {

    /// Records what it was asked to say, and only reports an utterance
    /// finished when the test says so — the coach's announcement gate is the
    /// thing under test, and a real synthesizer would make it a race.
    private final class StubSpeech: SpeechCoaching {
        private(set) var spoken: [String] = []
        private(set) var stopCount = 0
        private var onFinish: (() -> Void)?

        func speak(_ text: String, onFinish: (() -> Void)?) {
            spoken.append(text)
            self.onFinish = onFinish
        }

        func stop() {
            stopCount += 1
            onFinish = nil
        }

        /// Reports the utterance in flight as fully said.
        func finishSpeaking() {
            let callback = onFinish
            onFinish = nil
            callback?()
        }
    }

    /// A clock the test moves by hand, so a five-second hold takes no time.
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private func guided(
        name: String = "Chin tucks",
        sets: Int = 2,
        reps: Int = 2,
        hold: Int = 5,
        repRest: Int = 0,
        setRest: Int = 0
    ) -> Exercise {
        Exercise(
            name: name, instructions: "", sets: sets, reps: reps,
            holdSeconds: hold, restBetweenRepsSeconds: repRest,
            restBetweenSetsSeconds: setRest
        )
    }

    private func untimed(name: String = "Walk") -> Exercise {
        Exercise(name: name, instructions: "", sets: 1, reps: 1, holdSeconds: 0)
    }

    private func makeCoach(
        _ exercises: [Exercise],
        speech: StubSpeech? = nil,
        clock: TestClock,
        soundEnabled: Bool = false
    ) -> ExerciseCoach {
        var settings = Settings()
        settings.soundEnabled = soundEnabled
        return ExerciseCoach(
            exercises: exercises,
            settings: settings,
            speech: speech,
            clock: { clock.now }
        )
    }

    // MARK: - Suggestion

    func testSuggestsFirstGuidedExerciseAndSkipsUntimedOnes() {
        let clock = TestClock()
        let walk = untimed()
        let tucks = guided()
        let coach = makeCoach([walk, tucks], clock: clock)

        XCTAssertEqual(coach.suggestedExerciseID, tucks.id)
        XCTAssertTrue(coach.hasGuidedExercises)
    }

    func testCancellingMovesTheSuggestionOn() {
        let clock = TestClock()
        let first = guided(name: "First")
        let second = guided(name: "Second")
        let coach = makeCoach([first, second], clock: clock)

        coach.cancel(first.id)

        XCTAssertEqual(coach.suggestedExerciseID, second.id)
        XCTAssertEqual(coach.rowState(for: first.id), .cancelled)
    }

    func testStartingACancelledExerciseTakesItBack() {
        let clock = TestClock()
        let exercise = guided()
        let coach = makeCoach([exercise], clock: clock)

        coach.cancel(exercise.id)
        coach.start(exercise.id)

        XCTAssertFalse(coach.cancelledExerciseIDs.contains(exercise.id))
        XCTAssertEqual(coach.activeExerciseID, exercise.id)
    }

    // MARK: - Row state

    func testUntimedRowHasNoCoachStateAndTicks() {
        let clock = TestClock()
        let walk = untimed()
        let coach = makeCoach([walk], clock: clock)

        XCTAssertNil(coach.rowState(for: walk.id))

        coach.toggle(walk.id)
        XCTAssertTrue(coach.completedExerciseIDs.contains(walk.id))

        coach.toggle(walk.id)
        XCTAssertFalse(coach.completedExerciseIDs.contains(walk.id))
    }

    func testActiveRowCaptionNamesTheSetRepAndPhase() {
        let clock = TestClock()
        let exercise = guided(hold: 5)
        let coach = makeCoach([exercise], clock: clock)

        coach.start(exercise.id)
        // Past the 3s lead-in, into the first hold.
        clock.advance(4)
        coach.tickNow()
        XCTAssertEqual(coach.activeExerciseID, exercise.id)

        guard case let .active(caption)? = coach.rowState(for: exercise.id) else {
            return XCTFail("expected an active row state")
        }
        XCTAssertTrue(caption.contains("Set 1"), caption)
    }

    func testPausedRowCaptionSaysPaused() {
        let clock = TestClock()
        let exercise = guided()
        let coach = makeCoach([exercise], clock: clock)

        coach.start(exercise.id)
        clock.advance(4)
        coach.togglePause()

        guard case let .active(caption)? = coach.rowState(for: exercise.id) else {
            return XCTFail("expected an active row state")
        }
        XCTAssertTrue(caption.hasPrefix("Paused · "), caption)
    }

    // MARK: - Speech

    func testGetReadyIsAnnouncedImmediatelyOnStart() {
        let clock = TestClock()
        let speech = StubSpeech()
        let exercise = guided(name: "Chin tucks")
        let coach = makeCoach([exercise], speech: speech, clock: clock)

        coach.start(exercise.id)

        XCTAssertEqual(speech.spoken, ["Chin tucks. Get ready."])
    }

    /// The point of the announcement gate: while the cue is being spoken the
    /// clock is frozen, so a five-second hold is five seconds of holding
    /// rather than five seconds minus the sentence.
    func testClockIsFrozenWhileTheCueIsSpoken() {
        let clock = TestClock()
        let speech = StubSpeech()
        let exercise = guided()
        let coach = makeCoach([exercise], speech: speech, clock: clock)

        coach.start(exercise.id)
        XCTAssertEqual(coach.session?.state, .announcing)

        // Two seconds of talking must not consume the lead-in.
        clock.advance(2)
        XCTAssertEqual(coach.session?.elapsed(at: clock.now), 0)

        speech.finishSpeaking()
        XCTAssertEqual(coach.session?.state, .running)

        clock.advance(1)
        XCTAssertEqual(coach.session?.elapsed(at: clock.now), 1)
    }

    /// A stalled timer or a clock jump must yield one utterance, not the
    /// backlog of every cue it skipped over.
    func testAClockJumpSpeaksOnlyTheNewestCue() {
        let clock = TestClock()
        let speech = StubSpeech()
        // A 10s hold has "Three. Two. One." inside it.
        let exercise = guided(sets: 1, reps: 1, hold: 10)
        let coach = makeCoach([exercise], speech: speech, clock: clock)

        coach.start(exercise.id)
        speech.finishSpeaking()          // "Get ready" done, lead-in running
        clock.advance(3)
        coach.tickNow()                  // into the hold, which announces
        speech.finishSpeaking()          // the hold's own cue

        let before = speech.spoken.count
        // Jump past all three countdown words at once.
        clock.advance(9)
        coach.tickNow()

        XCTAssertEqual(speech.spoken.count - before, 1)
        XCTAssertEqual(speech.spoken.last, "One.")
    }

    func testStopSilencesTheVoiceAndClearsTheSession() {
        let clock = TestClock()
        let speech = StubSpeech()
        let exercise = guided()
        let coach = makeCoach([exercise], speech: speech, clock: clock)

        coach.start(exercise.id)
        coach.stop()

        XCTAssertNil(coach.session)
        XCTAssertNil(coach.activeExerciseID)
        XCTAssertGreaterThan(speech.stopCount, 0)
        // Abandoning is neither doing nor refusing it.
        XCTAssertFalse(coach.completedExerciseIDs.contains(exercise.id))
        XCTAssertFalse(coach.cancelledExerciseIDs.contains(exercise.id))
    }

    // MARK: - Backgrounding

    /// The iOS equivalent of the Mac's pause-on-sleep: a hold must not tick
    /// away while the phone is in a pocket. This is the rule that keeps a
    /// coached rep honest, so it is asserted on the clock, not just the flag.
    func testLeavingTheForegroundPausesARunningHold() {
        let clock = TestClock()
        let speech = StubSpeech()
        let exercise = guided(hold: 30)
        let coach = makeCoach([exercise], speech: speech, clock: clock)

        coach.start(exercise.id)
        speech.finishSpeaking()
        clock.advance(2)

        coach.sceneDidLeave()
        XCTAssertEqual(coach.session?.state, .paused)

        let atPause = coach.session?.elapsed(at: clock.now)
        clock.advance(600)  // ten minutes in a pocket
        XCTAssertEqual(coach.session?.elapsed(at: clock.now), atPause)
    }

    func testLeavingTheForegroundLeavesAPausedSessionAlone() {
        let clock = TestClock()
        let exercise = guided()
        let coach = makeCoach([exercise], clock: clock)

        coach.start(exercise.id)
        clock.advance(1)
        coach.togglePause()
        let elapsed = coach.session?.elapsed(at: clock.now)

        coach.sceneDidLeave()

        XCTAssertEqual(coach.session?.state, .paused)
        XCTAssertEqual(coach.session?.elapsed(at: clock.now), elapsed)
    }

    func testSceneDidLeaveIsHarmlessWithNoSession() {
        let clock = TestClock()
        let coach = makeCoach([guided()], clock: clock)

        coach.sceneDidLeave()

        XCTAssertNil(coach.session)
    }

    // MARK: - Completion

    func testFinishingTheTimelineMarksTheExerciseDone() {
        let clock = TestClock()
        // Shortest possible guided exercise: 3s lead-in + one 1s hold.
        let exercise = guided(sets: 1, reps: 1, hold: 1)
        let coach = makeCoach([exercise], clock: clock)

        coach.start(exercise.id)
        clock.advance(10)
        coach.tickNow()

        XCTAssertTrue(coach.completedExerciseIDs.contains(exercise.id))
        XCTAssertNil(coach.activeExerciseID)
        XCTAssertEqual(coach.rowState(for: exercise.id), .completed)
        XCTAssertNil(coach.suggestedExerciseID)
    }

    func testTickingAnActiveUntimedExerciseStopsItsSession() {
        let clock = TestClock()
        let exercise = guided()
        let coach = makeCoach([exercise], clock: clock)

        coach.start(exercise.id)
        coach.toggle(exercise.id)

        XCTAssertTrue(coach.completedExerciseIDs.contains(exercise.id))
        XCTAssertNil(coach.session)
    }

    // MARK: - No voice

    /// With the coach silent the phases must still start on time rather than
    /// waiting for an announcement that never comes.
    func testWithoutSpeechThePhasesRunWithoutAnnouncing() {
        let clock = TestClock()
        let exercise = guided()
        let coach = makeCoach([exercise], speech: nil, clock: clock)

        coach.start(exercise.id)

        XCTAssertEqual(coach.session?.state, .running)
        clock.advance(2)
        XCTAssertEqual(coach.session?.elapsed(at: clock.now), 2)
    }
}
