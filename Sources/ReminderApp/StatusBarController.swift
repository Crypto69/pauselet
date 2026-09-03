import AppKit
import SwiftUI
import Combine
import ReminderCore
import ReminderAI

/// Owns the menu bar item, its popover, and the settings window.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let engine: ReminderEngine
    /// Used to show a reminder exactly as it will appear, from the editor.
    private weak var overlays: OverlayPresenter?
    /// Shared with the fire path so the settings UI reports the same Spotify
    /// state — a permission error raised by a real reminder shows up there too.
    private let music: MusicPlayer
    private let speech: SpeechCoach
    private let ai: AIImportController
    private var settingsWindow: NSWindow?
    private var eventMonitor: Any?

    init(
        engine: ReminderEngine,
        overlays: OverlayPresenter? = nil,
        music: MusicPlayer,
        speech: SpeechCoach,
        ai: AIImportController
    ) {
        self.engine = engine
        self.overlays = overlays
        self.music = music
        self.speech = speech
        self.ai = ai
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        refresh()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.menuBarImage()
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(handleClick)
        // Left click opens the popover; right click opens a quick menu.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Pauselet"
    }

    /// Loads the bundled template image, falling back to an SF Symbol so the
    /// app still shows something if the resource is missing.
    private static func menuBarImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "MenuBarIconTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        let fallback = NSImage(
            systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90",
            accessibilityDescription: "Pauselet"
        ) ?? NSImage(systemSymbolName: "bell", accessibilityDescription: "Pauselet")
        fallback?.isTemplate = true
        return fallback
    }

    private func configurePopover() {
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(engine: engine)
                .environmentObject(engine)
                .onOpenSettings { [weak self] in self?.openSettings() }
        )
    }

    // MARK: - Menu bar title

    /// Updates the countdown text beside the icon.
    func refresh() {
        guard let button = statusItem.button else { return }

        guard engine.settings.showsNextReminderInMenuBar else {
            button.title = ""
            return
        }

        if Scheduler.isPaused(settings: engine.settings, now: Date()) {
            button.title = " Paused"
            return
        }

        guard let next = engine.nextUp else {
            button.title = ""
            return
        }

        let countdown = Scheduler.countdownText(from: Date(), to: next.date)
        button.title = " \(countdown)"
    }

    // MARK: - Interaction

    @objc private func handleClick() {
        // `currentEvent` is nil for synthetic clicks (accessibility tools,
        // scripting). Default to the popover rather than ignoring the click,
        // so the app stays operable from assistive software — which matters a
        // great deal for this app's audience.
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)

        if isRightClick {
            showQuickMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        // An accessory app is not active by default, and a transient popover
        // closes the instant it fails to take focus. Activating first is what
        // makes the popover stay on screen and accept clicks.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// A right-click menu for the things people reach for most: pausing and
    /// quitting, without having to open the popover.
    private func showQuickMenu() {
        let menu = NSMenu()
        let paused = Scheduler.isPaused(settings: engine.settings, now: Date())

        if paused {
            menu.addItem(
                withTitle: "Resume Reminders", action: #selector(resume), keyEquivalent: ""
            ).target = self
        } else {
            for minutes in [30, 60, 120] {
                let item = NSMenuItem(
                    title: "Pause for \(minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m")",
                    action: #selector(pauseFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = minutes
                menu.addItem(item)
            }
            menu.addItem(
                withTitle: "Pause Indefinitely",
                action: #selector(pauseIndefinitely),
                keyEquivalent: ""
            ).target = self
        }

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ","
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Pauselet", action: #selector(quit), keyEquivalent: "q"
        ).target = self

        // Pop the menu directly below the button rather than assigning
        // `statusItem.menu`: assigning it would replace the button's click
        // action, so the next left click would open this menu instead of the
        // popover.
        guard let button = statusItem.button else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
    }

    @objc private func pauseFromMenu(_ sender: NSMenuItem) {
        engine.pause(forMinutes: sender.tag)
        refresh()
    }

    @objc private func pauseIndefinitely() {
        engine.setPaused(true)
        refresh()
    }

    @objc private func resume() {
        engine.resume()
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    // MARK: - Settings window

    func openSettings() {
        popover.performClose(nil)

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pauselet"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: SettingsView()
                .environmentObject(engine)
                .environmentObject(music)
                .environmentObject(speech)
                .environmentObject(ai)
                .onPreviewReminder { [weak self] reminder in
                    guard let self else { return }
                    self.overlays?.preview(reminder, settings: self.engine.settings)
                }
        )
        window.minSize = NSSize(width: 640, height: 460)
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Lets the popover ask the status controller to open the settings window
/// without holding a reference to it.
private struct OpenSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

/// Lets the reminder editor show a reminder the way it will really appear.
private struct PreviewReminderKey: EnvironmentKey {
    static let defaultValue: (Reminder) -> Void = { _ in }
}

extension EnvironmentValues {
    var openReminderSettings: () -> Void {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }

    var previewReminder: (Reminder) -> Void {
        get { self[PreviewReminderKey.self] }
        set { self[PreviewReminderKey.self] = newValue }
    }
}

extension View {
    func onOpenSettings(_ action: @escaping () -> Void) -> some View {
        environment(\.openReminderSettings, action)
    }

    func onPreviewReminder(_ action: @escaping (Reminder) -> Void) -> some View {
        environment(\.previewReminder, action)
    }
}
