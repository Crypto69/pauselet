import SwiftUI
import AppKit
import ReminderCore
import ReminderAI

/// The app runs on AppKit's lifecycle rather than SwiftUI's `App`.
///
/// SwiftUI requires at least one scene, and for a menu bar app with no
/// primary window the usual trick is an empty `Settings` scene. That scene
/// brings a window with it: ⌘, opens a blank "Pauselet Settings" panel that
/// is not the app's settings at all, and `CommandGroup(replacing: .appSettings)`
/// removes the menu item without disabling the shortcut. A reviewer pressing
/// the standard shortcut would see an empty window and reasonably call the app
/// broken.
///
/// Everything the app does already lives in `AppDelegate` and the status bar,
/// so there is nothing for a scene to hold. Starting NSApplication directly
/// means no scene exists to be opened by accident, and the only settings
/// window is the one `StatusBarController.openSettings()` builds.
@main
@MainActor
enum PauseletMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        // NSApplication holds its delegate weakly, so it has to be kept alive
        // here or it is deallocated before the app finishes launching.
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }

    private static var retainedDelegate: AppDelegate?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusBarController?
    private var engine: ReminderEngine?
    private var notifier: NotificationPresenter?
    private var overlays: OverlayPresenter?
    private var music: MusicPlayer?
    private var speech: SpeechCoach?
    private var ai: AIImportController?
    private var tickTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var activityToken: NSObjectProtocol?

    /// How often the engine re-evaluates. Every 5 seconds is far more often
    /// than any schedule needs, but it keeps the menu bar countdown honest and
    /// costs nothing measurable.
    private static let tickInterval: TimeInterval = 5

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)

        // `--snapshot <dir>` renders the UI to PNGs and exits, so layout can be
        // reviewed without driving the menu bar by hand.
        if SnapshotHarness.runIfRequested() {
            NSApp.terminate(nil)
            return
        }

        let notifier = NotificationPresenter()
        let music = MusicPlayer()
        let speech = SpeechCoach()
        let ai = AIImportController()
        let overlays = OverlayPresenter(notifier: notifier, music: music, speech: speech)

        let store: DataStoring
        do {
            store = try FileDataStore()
        } catch {
            // Falling back to memory keeps the app usable for the session even
            // if Application Support is somehow unwritable.
            store = InMemoryDataStore(
                data: AppData(reminders: DefaultReminders.starterSet())
            )
        }

        let engine = ReminderEngine(store: store, presenter: overlays)
        notifier.engine = engine
        notifier.music = music
        overlays.engine = engine
        notifier.configure()

        // Opt out of App Nap for the timers only: a napped menu bar app gets
        // its timers coalesced and a reminder that fires minutes late has
        // failed at its one job. Idle *system* sleep stays allowed — this must
        // never keep the Mac awake.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Reminder scheduling must stay on time"
        )

        self.notifier = notifier
        self.overlays = overlays
        self.engine = engine
        self.music = music
        self.speech = speech
        self.ai = ai
        ai.model = AIImportModel.resolve(engine.settings.aiImportModel)
        self.statusController = StatusBarController(
            engine: engine, overlays: overlays, music: music, speech: speech, ai: ai
        )

        // Clear the backlog *before* the first tick. Everything overdue at this
        // point fell due while the app was closed, and replaying it on launch
        // means overlays and music for reminders whose moment passed hours ago.
        engine.absorbBacklogFromDowntime()

        startTicking()
        observeWake()

        // `--open-settings` opens the settings window straight after launch.
        // Handy for testing, since the window is otherwise only reachable by
        // clicking through the menu bar popover.
        if CommandLine.arguments.contains("--open-settings") {
            statusController?.openSettings()
        }
    }

    private func startTicking() {
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.tickInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.engine?.tick()
                self.statusController?.refresh()
            }
        }
        // Keep firing while menus are open or a window is being resized.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        engine?.tick()
        statusController?.refresh()
    }

    /// Tick immediately on wake. The timer does not fire while the Mac is
    /// asleep, so without this the first post-wake reminder would be late by up
    /// to one tick and the countdown would show a stale value.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.engine?.tick()
                self.statusController?.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        engine?.persist()
    }
}
