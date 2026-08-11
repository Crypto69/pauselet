import SwiftUI
import AppKit
import ReminderCore

@main
struct ReminderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The UI lives entirely in the status bar and in windows the delegate
        // opens, so there is no primary scene. `Settings` gives SwiftUI a valid
        // (empty) scene without putting a window on screen at launch.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusBarController?
    private var engine: ReminderEngine?
    private var notifier: NotificationPresenter?
    private var overlays: OverlayPresenter?
    private var tickTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

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
        let overlays = OverlayPresenter(notifier: notifier)

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
        overlays.engine = engine
        notifier.configure()

        self.notifier = notifier
        self.overlays = overlays
        self.engine = engine
        self.statusController = StatusBarController(engine: engine, overlays: overlays)

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
