import AppKit
import SwiftUI
import ReminderCore

/// A borderless window that floats above everything, including full-screen apps.
///
/// Used for both the critical full-screen takeover and the subtle corner hint.
/// `NSPanel` with `.nonactivatingPanel` means showing a reminder never steals
/// keyboard focus from what the user is typing into.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect, isInteractive: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Above the screen saver so a critical pressure-relief prompt is never
        // hidden behind another window.
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
        ]
        hidesOnDeactivate = false
        // A subtle hint must not swallow clicks meant for the app underneath.
        ignoresMouseEvents = !isInteractive
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns every on-screen reminder surface and routes each priority tier to the
/// right presentation.
@MainActor
final class OverlayPresenter: NSObject, ReminderPresenting {
    /// Critical overlays, one per display so the prompt cannot be missed.
    private var criticalPanels: [OverlayPanel] = []
    private var subtlePanel: OverlayPanel?
    private var subtleDismissTask: Task<Void, Never>?

    /// Set by the app so overlay buttons can talk back to the engine.
    weak var engine: ReminderEngine?
    private let notifier: NotificationPresenter

    init(notifier: NotificationPresenter) {
        self.notifier = notifier
        super.init()
        // When the system will not deliver a notification, show the reminder in
        // the app's own window instead so it is never silently dropped.
        notifier.fallbackPresenter = { [weak self] reminder, settings in
            self?.showSubtle(reminder, settings: settings)
        }
    }

    func present(_ reminder: Reminder, settings: ReminderCore.Settings) {
        switch reminder.priority {
        case .subtle:
            showSubtle(reminder, settings: settings)
        case .normal, .important:
            notifier.post(reminder, settings: settings)
        case .critical:
            showCritical(reminder, settings: settings)
        }
    }

    func dismissAll() {
        closeCritical()
        closeSubtle()
    }

    /// Shows `reminder` exactly as it would appear when it fires, without
    /// touching its schedule or history.
    ///
    /// Buttons on a previewed overlay only close it — a preview must never
    /// complete or snooze the real reminder, or looking at one would silently
    /// reset its timer.
    func preview(_ reminder: Reminder, settings: ReminderCore.Settings) {
        switch reminder.priority {
        case .subtle:
            showSubtle(reminder, settings: settings, isPreview: true)
        case .normal, .important:
            // Posting a real notification for a preview would leave it sitting
            // in Notification Center, so show the in-app card instead. It
            // carries the same title, message and icon.
            showSubtle(reminder, settings: settings, isPreview: true)
        case .critical:
            showCritical(reminder, settings: settings, isPreview: true)
        }
    }

    // MARK: - Critical takeover

    private func showCritical(
        _ reminder: Reminder,
        settings: ReminderCore.Settings,
        isPreview: Bool = false
    ) {
        closeCritical()

        if settings.soundEnabled {
            Sounds.play(named: reminder.soundName ?? "Submarine")
        }

        // One panel per screen: on a multi-display desk the user may not be
        // looking at the main display.
        for screen in NSScreen.screens {
            let panel = OverlayPanel(contentRect: screen.frame, isInteractive: true)
            let view = CriticalOverlayView(
                reminder: reminder,
                onComplete: { [weak self] in
                    if !isPreview { self?.engine?.complete(id: reminder.id) }
                    self?.closeCritical()
                },
                onSnooze: { [weak self] in
                    if !isPreview { self?.engine?.snooze(id: reminder.id) }
                    self?.closeCritical()
                }
            )
            panel.contentView = NSHostingView(rootView: view)
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            criticalPanels.append(panel)
        }
    }

    private func closeCritical() {
        for panel in criticalPanels {
            panel.orderOut(nil)
        }
        criticalPanels.removeAll()
    }

    // MARK: - Subtle hint

    fileprivate func showSubtle(
        _ reminder: Reminder,
        settings: ReminderCore.Settings,
        isPreview: Bool = false
    ) {
        closeSubtle()

        guard let screen = NSScreen.main else { return }

        let view = SubtleHintView(reminder: reminder) { [weak self] in
            if !isPreview { self?.engine?.complete(id: reminder.id) }
            self?.closeSubtle()
        }

        // The panel is generous enough for a few lines of message, and the card
        // inside it hugs its content. Measuring the SwiftUI view first was
        // tried and produced a badly oversized panel, so the height is fixed
        // and the message is allowed up to four lines.
        let size = NSSize(width: 330, height: 132)
        let margin: CGFloat = 16
        // Top-right, tucked under the menu bar near where the app lives.
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - size.width - margin,
            y: screen.visibleFrame.maxY - size.height - margin
        )
        let panel = OverlayPanel(
            contentRect: NSRect(origin: origin, size: size), isInteractive: true
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
        subtlePanel = panel

        // Self-dismiss: a subtle nudge the user ignores should not linger.
        // A per-reminder duration wins over the global default, so a wordy
        // reminder can be given longer to read.
        let seconds = max(2, reminder.displaySeconds ?? settings.subtleDisplaySeconds)
        subtleDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.closeSubtle()
        }
    }

    private func closeSubtle() {
        subtleDismissTask?.cancel()
        subtleDismissTask = nil
        guard let panel = subtlePanel else { return }
        subtlePanel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }
}

enum Sounds {
    /// Plays a named system sound, ignoring names macOS does not know.
    static func play(named name: String) {
        NSSound(named: name)?.play()
    }

    /// System sounds offered in the reminder editor.
    static let available: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]
}
