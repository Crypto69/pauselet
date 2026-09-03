import AppKit
import SwiftUI
import ReminderCore

/// Renders each UI surface to a PNG and exits.
///
/// Menu bar popovers and full-screen overlays are painful to capture from the
/// running app: a transient popover closes the moment focus shifts, and the
/// overlay covers the whole screen. This harness hosts the real views directly
/// so layout can be checked, reviewed in a pull request, and diffed after a
/// change — using the same code paths the app ships.
///
/// Run with: `Reminder --snapshot <output-directory>`
@MainActor
enum SnapshotHarness {
    /// Reads the launch arguments and, if asked, renders and exits.
    /// Returns true when it handled the launch, so the app should not continue.
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--snapshot") else { return false }

        let directory = arguments.indices.contains(flagIndex + 1)
            ? URL(fileURLWithPath: arguments[flagIndex + 1])
            : URL(fileURLWithPath: "build/ui")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        render(into: directory)
        return true
    }

    /// A short physio programme with the kind of instructions a handout has,
    /// including a multi-line one, so the rows show their real shape. Two are
    /// guided and one is untimed, so both kinds of row render.
    private static let sampleExercises: [Exercise] = [
        Exercise(
            name: "Shoulder external rotation",
            instructions: "Elbow tucked at your side, band in hand.\n"
                + "Rotate out slowly, pause, and return.",
            sets: 3, reps: 10,
            holdSeconds: 5, restBetweenRepsSeconds: 3, restBetweenSetsSeconds: 30
        ),
        Exercise(
            name: "Scapular retraction",
            instructions: "Squeeze the shoulder blades together and hold for two seconds.",
            sets: 3, reps: 12,
            holdSeconds: 10, restBetweenRepsSeconds: 5, restBetweenSetsSeconds: 20
        ),
        Exercise(
            name: "Wrist extension stretch",
            instructions: "Arm straight, palm down; ease the fingers back with the other hand.",
            sets: 2, reps: 8
        ),
    ]

    /// A representative set of reminders, so snapshots show every priority tier
    /// and schedule kind rather than an empty app.
    private static func sampleEngine() -> ReminderEngine {
        let now = Date()
        var tilt = Reminder(
            title: "Tilt Back",
            message: "Tilt your chair back for 5 minutes. Stop working and listen to calming music.",
            schedule: .interval(minutes: 60),
            priority: .critical,
            symbolName: "figure.seated.side",
            activityDurationSeconds: 300,
            createdAt: now
        )
        tilt.lastFiredAt = now.addingTimeInterval(-42 * 60)

        var shift = Reminder(
            title: "Weight Shift",
            message: "Activate your glutes and redistribute your weight.",
            schedule: .interval(minutes: 20),
            priority: .subtle,
            symbolName: "arrow.up.and.down.circle",
            createdAt: now
        )
        shift.lastFiredAt = now.addingTimeInterval(-16 * 60)

        var water = Reminder(
            title: "Drink Water",
            schedule: .interval(minutes: 60),
            priority: .normal,
            symbolName: "drop.fill",
            createdAt: now
        )
        water.lastFiredAt = now.addingTimeInterval(-25 * 60)

        var physio = Reminder(
            title: "Stretch & Range of Motion",
            message: "Run through your physio stretches.",
            schedule: .dailyAt(hour: 17, minute: 0, dayInterval: 2),
            priority: .important,
            symbolName: "figure.flexibility",
            activityDurationSeconds: 600,
            createdAt: now
        )
        physio.isEnabled = false

        let physioSet = Reminder(
            title: "Physio Set",
            message: "Three exercises from your physio programme.",
            schedule: .dailyAt(hour: 11, minute: 0, dayInterval: 1),
            priority: .critical,
            symbolName: "dumbbell.fill",
            exercises: Self.sampleExercises,
            createdAt: now
        )

        let call = Reminder(
            title: "Call Mum",
            schedule: .weeklyAt(hour: 18, minute: 30, weekdays: [1, 4]),
            priority: .normal,
            symbolName: "phone.fill",
            createdAt: now
        )

        // Tilt Back is the reminder whose message asks for calming music, so it
        // is the one that shows the music settings in a snapshot.
        tilt.music = .defaultPlaylist

        let store = InMemoryDataStore(
            data: AppData(
                reminders: [tilt, shift, water, physio, physioSet, call],
                settings: Settings(
                    defaultPlaylistURI: "spotify:playlist:37i9dQZF1DX4sWSpwq3LiO"
                )
            )
        )
        return ReminderEngine(store: store)
    }

    private static func render(into directory: URL) {
        let engine = sampleEngine()
        // The settings and editor views read these from the environment. They
        // are inert here: nothing calls them, so no Apple event is sent and
        // nothing is spoken while rendering snapshots.
        let music = MusicPlayer()
        let speech = SpeechCoach()
        /// An idle coach for the takeover snapshots: nothing running, ticks
        /// seeded as each snapshot needs.
        func idleCoach(for reminder: Reminder, completed: Set<UUID> = []) -> ExerciseCoach {
            ExerciseCoach.previewing(
                exercises: reminder.exercises ?? [], settings: engine.settings,
                completed: completed, active: UUID(), atOffset: 0
            )
        }

        snapshot(
            MenuBarView(engine: engine).environmentObject(engine),
            size: NSSize(width: 380, height: 470),
            named: "popover",
            into: directory
        )

        snapshot(
            SettingsView()
                .environmentObject(engine)
                .environmentObject(music)
                .environmentObject(speech),
            size: NSSize(width: 760, height: 560),
            named: "settings",
            into: directory
        )

        // The preferences form on its own, tall enough that the whole thing —
        // including the Music and Voice Coach sections — is in frame rather
        // than scrolled off.
        snapshot(
            PreferencesTab()
                .environmentObject(engine)
                .environmentObject(music)
                .environmentObject(speech),
            size: NSSize(width: 700, height: 820),
            named: "preferences",
            into: directory
        )

        // The voice coach section switched on, with the voice picker showing.
        var talking = engine.settings
        talking.voiceCoachEnabled = true
        let talkingEngine = ReminderEngine(
            store: InMemoryDataStore(data: AppData(reminders: engine.reminders, settings: talking))
        )
        snapshot(
            Form { VoiceCoachSection() }
                .formStyle(.grouped)
                .environmentObject(talkingEngine)
                .environmentObject(speech),
            size: NSSize(width: 700, height: 220),
            named: "preferences-voice",
            into: directory
        )

        snapshot(
            AboutTab(),
            size: NSSize(width: 700, height: 620),
            named: "about",
            into: directory
        )

        if let tilt = engine.reminders.first(where: { $0.priority == .critical }) {
            snapshot(
                CriticalOverlayView(
                    reminder: tilt, coach: idleCoach(for: tilt), onComplete: {}, onSnooze: {}
                ),
                size: NSSize(width: 1280, height: 800),
                named: "overlay-critical",
                into: directory
            )
        }

        // The exercise takeover: one row already ticked, so both states show.
        if let physioSet = engine.reminders.first(where: { $0.isExercise }) {
            let exercises = physioSet.exercises!
            snapshot(
                CriticalOverlayView(
                    reminder: physioSet,
                    coach: idleCoach(for: physioSet, completed: [exercises[0].id]),
                    onComplete: {}, onSnooze: {}
                ),
                size: NSSize(width: 1280, height: 800),
                named: "overlay-exercise",
                into: directory
            )

            // The coach mid-hold: the first exercise done, the second on set
            // 1, rep 2 with three seconds of its ten-second hold left
            // (lead-in 3 + hold 10 + rest 5 + 7 into the next hold).
            snapshot(
                CriticalOverlayView(
                    reminder: physioSet,
                    coach: ExerciseCoach.previewing(
                        exercises: exercises, settings: engine.settings,
                        completed: [exercises[0].id], active: exercises[1].id,
                        atOffset: 25
                    ),
                    onComplete: {}, onSnooze: {}
                ),
                size: NSSize(width: 1280, height: 800),
                named: "overlay-exercise-coach",
                into: directory
            )

            // Paused during the rest after set 1 (12 holds and 11 rests in,
            // then 7 s into the 20 s set rest), with the first exercise
            // cancelled so that state shows too.
            snapshot(
                CriticalOverlayView(
                    reminder: physioSet,
                    coach: ExerciseCoach.previewing(
                        exercises: exercises, settings: engine.settings,
                        completed: [], cancelled: [exercises[0].id], active: exercises[1].id,
                        atOffset: 3 + 12 * 10 + 11 * 5 + 7, paused: true
                    ),
                    onComplete: {}, onSnooze: {}
                ),
                size: NSSize(width: 1280, height: 800),
                named: "overlay-exercise-coach-rest",
                into: directory
            )

            // The worst case for the layout: a countdown ring *and* more
            // exercises than fit, on a short screen — the list must scroll
            // and the buttons must stay on screen.
            var long = physioSet
            long.activityDurationSeconds = 600
            long.exercises = (0..<7).map { index in
                var exercise = sampleExercises[index % sampleExercises.count]
                exercise.id = UUID()
                exercise.name = "\(exercise.name) \(index + 1)"
                return exercise
            }
            snapshot(
                CriticalOverlayView(
                    reminder: long, coach: idleCoach(for: long), onComplete: {}, onSnooze: {}
                ),
                size: NSSize(width: 1280, height: 800),
                named: "overlay-exercise-countdown",
                into: directory
            )

            snapshot(
                ReminderEditor(reminder: physioSet) { _ in }
                    .environmentObject(engine)
                    .environmentObject(music),
                size: NSSize(width: 470, height: 760),
                named: "editor-exercise",
                into: directory
            )

            // The exercise rows on their own, like editor-music below.
            snapshot(
                Form {
                    ExerciseListSection(exercises: .constant(physioSet.exercises!))
                }
                .formStyle(.grouped),
                size: NSSize(width: 470, height: 640),
                named: "editor-exercise-section",
                into: directory
            )
        }

        if let shift = engine.reminders.first(where: { $0.priority == .subtle }) {
            snapshot(
                SubtleHintView(reminder: shift, onComplete: {})
                    .padding(20)
                    .background(Color.gray.opacity(0.25)),
                size: NSSize(width: 360, height: 132),
                named: "overlay-subtle",
                into: directory
            )
        }

        // Editors render at their real sheet size. The form scrolls in the app,
        // so the snapshot shows the top of it, which is the part worth showing.
        snapshot(
            ReminderEditor(reminder: engine.reminders.first) { _ in }
                .environmentObject(engine)
                .environmentObject(music),
            size: NSSize(width: 470, height: 760),
            named: "editor",
            into: directory
        )

        // The per-reminder music controls on their own. The editor fixes its
        // own height, so this section scrolls out of frame in the editor
        // snapshots above; rendering it directly is the only way to review it
        // without driving the real sheet by hand.
        snapshot(
            Form {
                ReminderMusicSection(
                    music: .constant(.playlist(uri: "spotify:playlist:37i9dQZF1DX4sWSpwq3LiO"))
                )
            }
            .formStyle(.grouped)
            .environmentObject(engine)
            .environmentObject(music),
            size: NSSize(width: 470, height: 250),
            named: "editor-music",
            into: directory
        )

        // The blank editor: what you see when adding a reminder from scratch.
        snapshot(
            ReminderEditor(reminder: nil) { _ in }
                .environmentObject(engine)
                .environmentObject(music),
            size: NSSize(width: 470, height: 760),
            named: "editor-new",
            into: directory
        )
    }

    private static func snapshot<V: View>(
        _ view: V,
        size: NSSize,
        named name: String,
        into directory: URL
    ) {
        let hosting = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
        )
        hosting.frame = NSRect(origin: .zero, size: size)

        // Hosting the view in a real window lets materials, vibrancy and the
        // system appearance resolve the way they do in the app.
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        // Opaque window background: a clear one leaves white bands where the
        // view does not paint, which looks like a rendering fault in a README.
        window.backgroundColor = .windowBackgroundColor
        window.orderFrontRegardless()

        // Give SwiftUI a turn of the run loop to lay out before snapshotting;
        // without this, the first frame can come out blank.
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("snapshot \(name): could not allocate bitmap")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("snapshot \(name): could not encode PNG")
            return
        }
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try data.write(to: url)
            print("snapshot \(name): \(url.path)")
        } catch {
            print("snapshot \(name): write failed — \(error)")
        }
        window.orderOut(nil)
    }
}
