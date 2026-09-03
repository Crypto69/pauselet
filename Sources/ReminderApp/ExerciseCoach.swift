import AppKit
import Foundation
import ReminderCore
import ReminderUI

/// Drives one takeover's guided exercises: the session cursor, the tick
/// timer, which exercises are done or cancelled, and the one place its audio
/// comes from.
///
/// Created once per takeover and shared by every display's
/// `CriticalOverlayView`, so a cue is spoken once on a multi-monitor desk and
/// a tick on one display shows on all of them. The session itself is the
/// pure `ExerciseSession` from the core; this class only feeds it the clock
/// and acts on what it reports.
///
/// With the voice on, every phase is announced before it is timed: the
/// session is frozen at the phase start while the cue is spoken and released
/// when the synthesizer says it has finished, so "hold for 5 seconds" is
/// followed by five seconds, not by whatever was left after the sentence.
@MainActor
final class ExerciseCoach: ObservableObject {
    /// Done: ticked by hand (untimed) or finished by the coach (guided).
    @Published private(set) var completedExerciseIDs: Set<UUID>
    /// Guided exercises the user has said they are not doing this time.
    @Published private(set) var cancelledExerciseIDs: Set<UUID>
    @Published private(set) var session: ExerciseSession?
    /// The exercise the session is coaching; `nil` once it has completed.
    @Published private(set) var activeExerciseID: UUID?
    /// The guided exercise whose Start is highlighted: the first neither
    /// done nor cancelled, so Space starts the obvious next thing.
    @Published private(set) var suggestedExerciseID: UUID?
    /// Republished on every tick, so views derive the countdown from
    /// `session` and this rather than keeping time of their own.
    @Published private(set) var now: Date

    let exercises: [Exercise]
    var hasGuidedExercises: Bool { exercises.contains(where: \.isGuided) }

    private let speech: SpeechCoaching?
    private let playsSounds: Bool
    private let clock: () -> Date
    private var timer: Timer?
    private var spokenCueCount = 0
    private var lastPhaseIndex: Int?
    private var sleepObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - speech: `nil` when the voice coach is off; chimes still play and
    ///     phases start on time rather than after an announcement.
    ///   - clock: injected so a snapshot can freeze the coach mid-session.
    init(
        exercises: [Exercise],
        settings: ReminderCore.Settings,
        speech: SpeechCoaching?,
        clock: @escaping () -> Date = Date.init
    ) {
        self.exercises = exercises
        self.speech = speech
        self.playsSounds = settings.playsSound(for: .critical)
        self.clock = clock
        completedExerciseIDs = []
        cancelledExerciseIDs = []
        now = clock()
        suggestedExerciseID = Self.suggested(in: exercises, completed: [], cancelled: [])
    }

    // MARK: - Session control

    /// Coaches `id` from the top, replacing any session in progress.
    func start(_ id: UUID) {
        guard let exercise = exercises.first(where: { $0.id == id }),
              let timeline = ExerciseTimeline(exercise: exercise)
        else { return }
        speech?.stop()
        let startedAt = clock()
        session = ExerciseSession(timeline: timeline, startedAt: startedAt)
        activeExerciseID = id
        completedExerciseIDs.remove(id)
        cancelledExerciseIDs.remove(id)
        spokenCueCount = 0
        lastPhaseIndex = nil
        recomputeSuggested()
        observeSleep()
        tick()  // Announces "Get ready" straight away rather than a tick later.
        startTimer()
    }

    func startSuggested() {
        if let id = suggestedExerciseID { start(id) }
    }

    /// Space: pause or resume a session in progress, otherwise start the
    /// suggested exercise.
    func pauseResumeOrStart() {
        if let session, session.isLive {
            togglePause()
        } else {
            startSuggested()
        }
    }

    func togglePause() {
        guard var session, session.isLive else { return }
        let now = clock()
        session.togglePause(at: now)
        switch session.state {
        case .paused:
            speech?.stop()
            self.session = session
        case .running:
            self.session = session
            // A pause that cut the cue short leaves the phase untouched;
            // say it again so the person knows what they are resuming into.
            if speech != nil, session.isAtPhaseStart(at: now) {
                announceCurrentPhase()
            }
        default:
            self.session = session
        }
        tick()
    }

    /// Jumps to the next phase. Anything half-said is cut off so it cannot
    /// run into the next cue.
    func skip() {
        guard var session, session.isLive else { return }
        speech?.stop()
        session.skip(at: clock())
        if session.state == .announcing {
            // The announcement that was in progress is gone with its phase;
            // the tick announces the new one.
            session.finishAnnouncement(at: clock())
        }
        self.session = session
        tick()
    }

    /// Abandons the session; the exercise stays neither done nor cancelled.
    func stop() {
        speech?.stop()
        stopTimer()
        session = nil
        activeExerciseID = nil
        recomputeSuggested()
    }

    // MARK: - Ticks and cancels

    /// The tick box on an untimed exercise.
    func toggle(_ id: UUID) {
        if completedExerciseIDs.contains(id) {
            completedExerciseIDs.remove(id)
        } else {
            completedExerciseIDs.insert(id)
            if id == activeExerciseID { stop() }
        }
        recomputeSuggested()
    }

    /// "Not doing this one": dims the row and moves the suggestion on.
    /// Start on the row takes it back.
    func cancel(_ id: UUID) {
        if id == activeExerciseID { stop() }
        completedExerciseIDs.remove(id)
        cancelledExerciseIDs.insert(id)
        recomputeSuggested()
    }

    /// How the row for `id` should present itself; `nil` for an untimed
    /// exercise, which keeps its plain tick box.
    func rowState(for id: UUID) -> ExerciseRowCoachState? {
        guard let exercise = exercises.first(where: { $0.id == id }), exercise.isGuided else {
            return nil
        }
        if id == activeExerciseID, let session, let phase = session.phase(at: now) {
            let caption = "\(phase.title) · \(phase.label)"
            return .active(caption: session.state == .paused ? "Paused · \(caption)" : caption)
        }
        if completedExerciseIDs.contains(id) { return .completed }
        if cancelledExerciseIDs.contains(id) { return .cancelled }
        return id == suggestedExerciseID ? .suggested : .idle
    }

    /// Silences and stops everything. Done, Snooze and dismissing the
    /// takeover all end here.
    func shutDown() {
        speech?.stop()
        stopTimer()
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
    }

    // MARK: - Snapshots

    /// A coach frozen `offset` seconds into `active`'s session, with no timer
    /// and no voice, so the snapshot harness can render the panel in a known
    /// state.
    static func previewing(
        exercises: [Exercise],
        settings: ReminderCore.Settings,
        completed: Set<UUID>,
        cancelled: Set<UUID> = [],
        active: UUID,
        atOffset offset: TimeInterval,
        paused: Bool = false
    ) -> ExerciseCoach {
        let frozenNow = Date()
        let coach = ExerciseCoach(
            exercises: exercises, settings: settings, speech: nil, clock: { frozenNow }
        )
        coach.completedExerciseIDs = completed
        coach.cancelledExerciseIDs = cancelled
        if let exercise = exercises.first(where: { $0.id == active }),
           let timeline = ExerciseTimeline(exercise: exercise) {
            var session = ExerciseSession(
                timeline: timeline, startedAt: frozenNow.addingTimeInterval(-offset)
            )
            if paused { session.pause(at: frozenNow) }
            coach.session = session
            coach.activeExerciseID = active
        }
        coach.recomputeSuggested()
        return coach
    }

    // MARK: - The tick

    private func tick() {
        now = clock()
        guard var session else { return }

        let phaseIndex = session.timeline.phaseIndex(at: session.elapsed(at: now))
        let phaseChanged = phaseIndex != lastPhaseIndex
        if phaseChanged, lastPhaseIndex != nil, phaseIndex != nil, playsSounds {
            Sounds.play(named: "Tink")
        }
        lastPhaseIndex = phaseIndex

        if let speech {
            if phaseChanged, phaseIndex != nil, session.state == .running {
                // A new phase with the voice on: freeze at its start, say its
                // cue, and let the clock go when the sentence is over.
                session.beginAnnouncement(at: now)
                self.session = session
                spokenCueCount = session.cueCount(at: now)
                announceCurrentPhase()
                return
            }
            // Cues inside a phase (the "Three. Two. One." countdown) and the
            // closing line are spoken without stopping the clock. Only the
            // newest: after a stall the ones in between are stale, not a
            // backlog to read out.
            let cueCount = session.cueCount(at: now)
            if cueCount > spokenCueCount, session.state == .running {
                speech.speak(session.timeline.cues[cueCount - 1].text)
            }
            spokenCueCount = max(spokenCueCount, cueCount)
        }

        if session.markCompletedIfFinished(at: now) {
            self.session = session
            if let activeExerciseID {
                completedExerciseIDs.insert(activeExerciseID)
            }
            activeExerciseID = nil
            recomputeSuggested()
            if playsSounds { Sounds.play(named: "Glass") }
            stopTimer()
        }
    }

    /// Says the current phase's cue and releases the session when it has
    /// been said. The session may already be announcing (a fresh phase) or
    /// running at a phase start (a resume); either way it is frozen first so
    /// the timing is the same.
    private func announceCurrentPhase() {
        guard let speech, var session, let phase = session.phase(at: now) else { return }
        if session.state == .running {
            session.beginAnnouncement(at: now)
            self.session = session
        }
        let cue = ExerciseTimeline.cue(for: phase, exerciseName: session.timeline.exerciseName)
        speech.speak(cue) { [weak self] in
            self?.releaseAnnouncement(of: phase)
        }
        // If the synthesizer never reports back (no usable voice, say), the
        // hold must still start: nobody should be frozen at "Get ready".
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self?.releaseAnnouncement(of: phase)
        }
    }

    /// Lets the clock run if the session is still frozen at the start of
    /// `phase`; a no-op once it has moved on, so a late release cannot
    /// touch a later phase's announcement.
    private func releaseAnnouncement(of phase: ExercisePhase) {
        guard var session, session.state == .announcing,
              session.phase(at: now) == phase
        else { return }
        session.finishAnnouncement(at: clock())
        self.session = session
        tick()
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // Keep counting while a menu is open or a window is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// A hold must not "complete" under a closed lid: pause when the Mac
    /// sleeps, and let the user resume when they are back in position.
    private func observeSleep() {
        guard sleepObserver == nil else { return }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, var session = self.session,
                      session.state == .running || session.state == .announcing
                else { return }
                self.speech?.stop()
                session.pause(at: self.clock())
                self.session = session
            }
        }
    }

    private func recomputeSuggested() {
        suggestedExerciseID = Self.suggested(
            in: exercises, completed: completedExerciseIDs, cancelled: cancelledExerciseIDs
        )
    }

    private static func suggested(
        in exercises: [Exercise], completed: Set<UUID>, cancelled: Set<UUID>
    ) -> UUID? {
        exercises.first { $0.isGuided && !completed.contains($0.id) && !cancelled.contains($0.id) }?.id
    }
}
