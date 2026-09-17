import SwiftUI
import Foundation
import ReminderCore
import ReminderUI

/// Drives one takeover's exercises: the session cursor, the tick timer,
/// which exercises are done or cancelled, and the one place its audio comes
/// from.
///
/// The iOS twin of `Sources/ReminderApp/ExerciseCoach.swift`. The session
/// itself is the pure `ExerciseSession` from the core, so both platforms run
/// the same programme and say the same things; this class only feeds it the
/// clock and acts on what it reports.
///
/// A session coaches one exercise (Start on its row) or every exercise still
/// to do, in order, with the reminder's rest between them (Start All). Either
/// way the timeline is built once, up front, by the core.
///
/// With the voice on, every phase is announced before it is timed: the
/// session is frozen at the phase start while the cue is spoken and released
/// when the synthesizer says it has finished, so "hold for 5 seconds" is
/// followed by five seconds, not by whatever was left after the sentence.
///
/// The one real platform difference is what counts as "the device went away".
/// The Mac pauses on sleep; iOS pauses on leaving the foreground, which covers
/// both the screen locking and the user switching apps — see `sceneDidLeave`.
@MainActor
final class ExerciseCoach: ObservableObject {
    /// Finished by the coach.
    @Published private(set) var completedExerciseIDs: Set<UUID>
    /// Exercises the user has said they are not doing this time.
    @Published private(set) var cancelledExerciseIDs: Set<UUID>
    @Published private(set) var session: ExerciseSession?
    /// The exercise whose Start is highlighted: the first neither done nor
    /// cancelled, so the obvious next thing is one tap away.
    @Published private(set) var suggestedExerciseID: UUID?
    /// Republished on every tick, so views derive the countdown from
    /// `session` and this rather than keeping time of their own.
    @Published private(set) var now: Date

    let exercises: [Exercise]
    /// The reminder's rest between exercises, used by Start All.
    let restBetweenExercisesSeconds: Int

    /// The exercise the session is on right now; `nil` between sessions and
    /// once one has completed.
    var activeExerciseID: UUID? { session?.phase(at: now)?.exerciseID }

    /// Neither done nor cancelled, in programme order: what Start All runs.
    var remainingExerciseIDs: [UUID] {
        exercises
            .filter { !completedExerciseIDs.contains($0.id) && !cancelledExerciseIDs.contains($0.id) }
            .map(\.id)
    }

    /// Start All earns its place once there are two or more left to run;
    /// with one, it is the same as Start.
    var canStartAll: Bool { remainingExerciseIDs.count > 1 }

    private let speech: SpeechCoaching?
    private let playsSounds: Bool
    private let clock: () -> Date
    private var timer: Timer?
    private var spokenCueCount = 0
    private var lastPhaseIndex: Int?
    /// Ties each announcement's release to the utterance that asked for it.
    private var announcementGeneration = 0
    private var announcementFallback: Task<Void, Never>?

    /// - Parameters:
    ///   - speech: `nil` when the voice coach is off; chimes still play and
    ///     phases start on time rather than after an announcement.
    ///   - clock: injected so tests can drive the coach without waiting.
    init(
        exercises: [Exercise],
        restBetweenExercisesSeconds: Int = 0,
        settings: ReminderCore.Settings,
        speech: SpeechCoaching?,
        clock: @escaping () -> Date = Date.init
    ) {
        self.exercises = exercises
        self.restBetweenExercisesSeconds = restBetweenExercisesSeconds
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
        completedExerciseIDs.remove(id)
        cancelledExerciseIDs.remove(id)
        run(timeline)
    }

    func startSuggested() {
        if let id = suggestedExerciseID { start(id) }
    }

    /// Runs every exercise still to do, in order, with the reminder's rest
    /// between one and the next, replacing any session in progress.
    func startAll() {
        let remaining = remainingExerciseIDs
        let queue = exercises.filter { remaining.contains($0.id) }
        guard let timeline = ExerciseTimeline(
            exercises: queue, restBetweenExercisesSeconds: restBetweenExercisesSeconds
        ) else { return }
        run(timeline)
    }

    /// - Parameter paused: A run handed over while paused (the exercise being
    ///   coached was cancelled mid-pause) stays paused; nothing is said until
    ///   the user resumes.
    private func run(_ timeline: ExerciseTimeline, paused: Bool = false) {
        speech?.stop()
        cancelAnnouncementFallback()
        var fresh = ExerciseSession(timeline: timeline, startedAt: clock())
        if paused { fresh.pause(at: clock()) }
        session = fresh
        spokenCueCount = 0
        lastPhaseIndex = nil
        recomputeSuggested()
        tick()  // Announces "Get ready" straight away rather than a tick later.
        startTimer()
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
        move { session, now in session.skip(at: now) }
    }

    private func move(_ reposition: (inout ExerciseSession, Date) -> Void) {
        guard var session, session.isLive else { return }
        speech?.stop()
        let now = clock()
        reposition(&session, now)
        if session.state == .announcing {
            // The announcement that was in progress is gone with its phase;
            // the tick announces the new one.
            session.finishAnnouncement(at: now)
        }
        self.session = session
        tick()
    }

    /// Abandons the session; the exercise it was on stays neither done nor
    /// cancelled.
    func stop() {
        speech?.stop()
        stopTimer()
        cancelAnnouncementFallback()
        session = nil
        recomputeSuggested()
    }

    // MARK: - Cancels

    /// "Not doing this one": dims the row and moves the suggestion on.
    /// Start on the row takes it back. An exercise still to come in the run in
    /// progress is taken out of it; the one being coached hands over to the
    /// next, or ends the session when it was the last (or on its own).
    func cancel(_ id: UUID) {
        now = clock()  // Judge "being coached" by the clock, not the last tick.
        completedExerciseIDs.remove(id)
        cancelledExerciseIDs.insert(id)
        recomputeSuggested()
        guard let session, session.isLive,
              let dropped = session.timeline.entries.first(where: { $0.id == id }),
              session.elapsed(at: now) < dropped.end
        else { return }
        dropFromRun(dropped, in: session)
    }

    /// Takes a cancelled exercise out of the run in progress. The timeline is
    /// rebuilt without it, which is what keeps the coaching honest: the
    /// exercise is never announced or run, its row never lights up, and the
    /// next lead-in signs off the exercise that actually finished before it.
    /// One still ahead of the cursor leaves the session exactly where it was,
    /// in the state it was in; the one being coached hands over to whatever
    /// follows it, from its lead-in, or ends the session when nothing does.
    private func dropFromRun(_ dropped: ExerciseTimeline.Entry, in old: ExerciseSession) {
        let entries = old.timeline.entries
        let isActive = old.phase(at: now)?.exerciseID == dropped.id
        let kept = isActive
            ? Array(entries.drop(while: { $0.id != dropped.id }).dropFirst())
            : entries.filter { $0.id != dropped.id }
        if isActive, kept.isEmpty {
            // Nothing follows. A run of several is over — it completes, as it
            // would have a moment later; an exercise on its own just stops.
            if entries.count > 1 {
                move { session, now in session.jump(to: session.timeline.totalDuration, at: now) }
            } else {
                stop()
            }
            return
        }
        let queue = kept.compactMap { entry in exercises.first { $0.id == entry.id } }
        guard let timeline = ExerciseTimeline(
            exercises: queue, restBetweenExercisesSeconds: restBetweenExercisesSeconds
        ) else {
            stop()
            return
        }
        if isActive {
            run(timeline, paused: old.state == .paused)
            return
        }
        // Everything before the cursor is unchanged — same phases, same cues —
        // so the session carries on from the same offset. An announcement in
        // flight still matches its phase and is released as normal when the
        // synthesizer reports back.
        var fresh = ExerciseSession(timeline: timeline, startedAt: now)
        fresh.jump(to: old.elapsed(at: now), at: now)
        switch old.state {
        case .paused: fresh.pause(at: now)
        case .announcing: fresh.beginAnnouncement(at: now)
        default: break
        }
        session = fresh
    }

    /// How the row for `id` should present itself.
    func rowState(for id: UUID) -> ExerciseRowCoachState {
        if let session, let phase = session.phase(at: now), phase.exerciseID == id {
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
        cancelAnnouncementFallback()
        SpeechCoach.deactivateAudioSession()
    }

    /// A hold must not "complete" in someone's pocket: pause when the app
    /// leaves the foreground, which is what both locking the screen and
    /// switching apps look like from here. The user resumes when they are
    /// back in position — the same choice the Mac makes on sleep.
    ///
    /// Deliberately not a background-audio session: coaching someone through
    /// a hold they cannot see the timer for is worse than waiting for them.
    func sceneDidLeave() {
        guard var session, session.state == .running || session.state == .announcing else {
            return
        }
        speech?.stop()
        session.pause(at: clock())
        self.session = session
    }

    // MARK: - The tick

    /// Runs one tick now, instead of waiting up to 0.2s for the timer.
    ///
    /// Exists for tests, which drive an injected clock and need the coach to
    /// observe it at a chosen moment; the app itself always ticks on the timer.
    func tickNow() { tick() }

    private func tick() {
        now = clock()
        guard var session else { return }
        let timeline = session.timeline
        let elapsed = session.elapsed(at: now)

        // Exercises whose last set has run are done, with the finishing
        // chime, and the suggestion moves on. A cancelled one that was jumped
        // over is left as cancelled.
        let phaseIndex = timeline.phaseIndex(at: elapsed)
        let phaseChanged = phaseIndex != lastPhaseIndex
        // An exercise can only end at a phase boundary, so the sweep for
        // finished ones is skipped on the other four ticks a second.
        let finished = phaseChanged
            ? timeline.finishedExerciseIDs(at: elapsed).filter {
                !completedExerciseIDs.contains($0) && !cancelledExerciseIDs.contains($0)
            }
            : []
        if !finished.isEmpty {
            completedExerciseIDs.formUnion(finished)
            recomputeSuggested()
            if playsSounds { Sounds.play(named: "Glass", route: .piercing) }
        }

        // A phase boundary that is also an exercise boundary has had its chime.
        if phaseChanged, lastPhaseIndex != nil, phaseIndex != nil, finished.isEmpty, playsSounds {
            Sounds.play(named: "Chime", route: .piercing)
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
                speech.speak(timeline.cues[cueCount - 1].text)
            }
            spokenCueCount = max(spokenCueCount, cueCount)
        }

        if session.markCompletedIfFinished(at: now) {
            self.session = session
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
        announcementGeneration += 1
        let generation = announcementGeneration
        speech.speak(phase.cue) { [weak self] in
            self?.releaseAnnouncement(of: phase, generation: generation)
        }
        // If the synthesizer never reports back (no usable voice, say), the
        // hold must still start: nobody should be frozen at "Get ready".
        announcementFallback?.cancel()
        announcementFallback = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.releaseAnnouncement(of: phase, generation: generation)
        }
    }

    /// Drops the pending fallback and invalidates any release still in
    /// flight: whatever was being announced is gone with its session.
    private func cancelAnnouncementFallback() {
        announcementFallback?.cancel()
        announcementFallback = nil
        announcementGeneration += 1
    }

    /// Lets the clock run if the session is still frozen at the start of
    /// `phase`; a no-op once it has moved on, so a late release cannot
    /// touch a later phase's announcement.
    ///
    /// `generation` ties the release to the utterance that asked for it: a
    /// cue re-spoken after a pause, or a session restarted on the same
    /// exercise, has an equal phase but must not be released by the earlier
    /// utterance's callback or its fallback.
    private func releaseAnnouncement(of phase: ExercisePhase, generation: Int) {
        guard generation == announcementGeneration,
              var session, session.state == .announcing,
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
        // Keep counting while a scroll or a sheet presentation is in flight.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func recomputeSuggested() {
        suggestedExerciseID = Self.suggested(
            in: exercises, completed: completedExerciseIDs, cancelled: cancelledExerciseIDs
        )
    }

    private static func suggested(
        in exercises: [Exercise], completed: Set<UUID>, cancelled: Set<UUID>
    ) -> UUID? {
        exercises.first { !completed.contains($0.id) && !cancelled.contains($0.id) }?.id
    }
}
