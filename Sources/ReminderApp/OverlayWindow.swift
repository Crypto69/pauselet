import AppKit
import SwiftUI
import ReminderCore

/// A borderless window that floats above everything, including full-screen apps.
///
/// Used for both the critical full-screen takeover and the subtle corner hint.
/// `NSPanel` with `.nonactivatingPanel` means a *subtle* reminder never steals
/// keyboard focus from what the user is typing into. The critical takeover
/// opts into keyboard focus instead: its whole point is to interrupt, and its
/// Return/S shortcuts cannot work from a window that can never become key.
final class OverlayPanel: NSPanel {
    private let takesKeyboardFocus: Bool

    init(contentRect: NSRect, isInteractive: Bool, takesKeyboardFocus: Bool = false) {
        self.takesKeyboardFocus = takesKeyboardFocus
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

    override var canBecomeKey: Bool { takesKeyboardFocus }
    override var canBecomeMain: Bool { false }
}

/// Owns every on-screen reminder surface and routes each priority tier to the
/// right presentation.
///
/// Reminders that fire while their surface is occupied are queued, not
/// dropped: after sleep or the end of quiet hours several reminders routinely
/// become due on the same tick, and the second must not silently replace the
/// first — for a pressure-relief prompt that would be a missed reminder.
///
/// The queue is only honoured while it is fresh, though. Entries that sat for
/// hours behind an unacknowledged overlay are pruned when the user finally
/// responds, so pressing Finish after falling asleep does not hand them the
/// next takeover, and the next. See `advanceCritical`.
@MainActor
final class OverlayPresenter: NSObject, ReminderPresenting {
    /// Critical overlays, one per display so the prompt cannot be missed.
    private var criticalPanels: [OverlayPanel] = []
    private var criticalQueue:
        [(reminder: Reminder, settings: ReminderCore.Settings, queuedAt: Date)] = []
    /// Whether this app was active before the takeover activated it, so focus
    /// is only handed back when the takeover was the thing that took it.
    private var wasActiveBeforeCritical = false

    private var subtlePanel: OverlayPanel?
    private var subtleQueue: [(
        reminder: Reminder, settings: ReminderCore.Settings, minimumSeconds: Int
    )] = []
    private var subtleDismissTask: Task<Void, Never>?

    /// Set by the app so overlay buttons can talk back to the engine.
    weak var engine: ReminderEngine?
    private let notifier: NotificationPresenter
    private let music: MusicPlayer

    init(notifier: NotificationPresenter, music: MusicPlayer) {
        self.notifier = notifier
        self.music = music
        super.init()
        // When the system will not deliver a notification, show the reminder in
        // the app's own window instead so it is never silently dropped. An
        // important reminder demoted to the corner card must not also inherit
        // the card's 8-second lifetime — it gets a sticky minimum instead.
        notifier.fallbackPresenter = { [weak self] reminder, settings in
            let minimum = reminder.priority >= .important ? 60 : 0
            self?.showSubtle(reminder, settings: settings, minimumSeconds: minimum)
        }
    }

    func present(_ reminder: Reminder, settings: ReminderCore.Settings) {
        // Music is independent of the tier: a subtle nudge can start a playlist
        // just as a critical takeover can. It runs on a background queue, so
        // the launch wait never delays the surface appearing below.
        music.play(for: reminder, settings: settings)

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
        criticalQueue.removeAll()
        subtleQueue.removeAll()
        closeCriticalPanels()
        closeSubtlePanel()
        // Pausing the engine takes the overlay's buttons — the only music
        // controls — off screen with it, so reminder-started music must stop
        // here or it plays on with no way to silence it.
        music.stopReminderMusic()
    }

    /// Shows `reminder` exactly as it would appear when it fires, without
    /// touching its schedule or history.
    ///
    /// Buttons on a previewed overlay only close it — a preview must never
    /// complete or snooze the real reminder, or looking at one would silently
    /// reset its timer. A preview replaces whatever is showing rather than
    /// queueing behind it: the user asked to see it now.
    func preview(_ reminder: Reminder, settings: ReminderCore.Settings) {
        // Music plays for a preview too — hearing what a reminder will sound
        // like is most of the point of previewing one that starts a playlist.
        music.play(for: reminder, settings: settings)

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
        if !criticalPanels.isEmpty {
            if isPreview {
                closeCriticalPanels()
            } else {
                // Another critical reminder is already demanding attention.
                // Queue this one; it appears the moment the current one is
                // acknowledged — provided that moment comes soon enough for it
                // to still be worth showing.
                criticalQueue.append((reminder, settings, Date()))
                return
            }
        } else {
            // A fresh takeover session begins: remember whose focus this was.
            // Queued continuations keep the original answer, or the activation
            // the first takeover performed would count as "already active" and
            // focus would never be handed back.
            wasActiveBeforeCritical = NSApp.isActive
        }
        displayCritical(reminder, settings: settings, isPreview: isPreview)
    }

    private func displayCritical(
        _ reminder: Reminder,
        settings: ReminderCore.Settings,
        isPreview: Bool
    ) {
        if settings.playsSound(for: reminder.priority) {
            Sounds.play(named: reminder.soundName ?? "Submarine")
        }

        // One panel per screen: on a multi-display desk the user may not be
        // looking at the main display.
        for screen in NSScreen.screens {
            let panel = OverlayPanel(
                contentRect: screen.frame, isInteractive: true, takesKeyboardFocus: true
            )
            let view = CriticalOverlayView(
                reminder: reminder,
                onComplete: { [weak self] in
                    guard let self else { return }
                    if !isPreview { self.engine?.complete(id: reminder.id) }
                    // Stops the music only if a reminder actually started it
                    // (or is still starting it); the user's own listening is
                    // never touched.
                    self.music.stopReminderMusic()
                    self.advanceCritical(afterAcknowledging: reminder.id)
                },
                onSnooze: { [weak self] in
                    guard let self else { return }
                    if !isPreview { self.engine?.snooze(id: reminder.id) }
                    self.music.stopReminderMusic()
                    self.advanceCritical(afterAcknowledging: reminder.id)
                }
            )
            panel.contentView = NSHostingView(rootView: view)
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            criticalPanels.append(panel)
        }

        // Activate and take key so the advertised Return / S shortcuts really
        // work — a keyboard or switch user must be able to acknowledge this
        // without a pointer. Stealing focus is acceptable here and only here:
        // the takeover's entire purpose is to interrupt.
        NSApp.activate(ignoringOtherApps: true)
        let keyPanel = criticalPanels.first { $0.screen == NSScreen.main }
            ?? criticalPanels.first
        keyPanel?.makeKeyAndOrderFront(nil)
    }

    /// Closes the current takeover and shows the next queued one that is still
    /// current, if any.
    ///
    /// Anything that queued behind an overlay nobody was looking at — the user
    /// fell asleep, or left the desk for the afternoon — is dropped rather
    /// than delivered in a burst, and recorded as missed so history shows what
    /// became of it. `ReminderEngine.shouldPresentQueued` holds the policy.
    private func advanceCritical(afterAcknowledging acknowledgedID: UUID) {
        let now = Date()
        var dropped: [Reminder] = []
        criticalQueue.removeAll { entry in
            let keep = ReminderEngine.shouldPresentQueued(
                reminderID: entry.reminder.id,
                queuedAt: entry.queuedAt,
                acknowledgedID: acknowledgedID,
                now: now
            )
            if !keep { dropped.append(entry.reminder) }
            return !keep
        }
        engine?.recordMissedPresentations(dropped)

        // Pruning happens before the panels close, so the focus hand-back
        // decision inside `closeCriticalPanels` sees the queue it will
        // actually drain — a queue of nothing but stale entries must hand
        // focus back, not hold it for takeovers that will never appear.
        closeCriticalPanels()
        if let next = criticalQueue.first {
            criticalQueue.removeFirst()
            displayCritical(next.reminder, settings: next.settings, isPreview: false)
        }
    }

    private func closeCriticalPanels() {
        guard !criticalPanels.isEmpty else { return }
        for panel in criticalPanels {
            panel.orderOut(nil)
        }
        criticalPanels.removeAll()
        // Hand focus back to whatever the user was doing, but only when the
        // takeover was what took it — closing a preview must not deactivate
        // the settings window the user is working in.
        if criticalQueue.isEmpty && !wasActiveBeforeCritical {
            NSApp.deactivate()
        }
    }

    // MARK: - Subtle hint

    fileprivate func showSubtle(
        _ reminder: Reminder,
        settings: ReminderCore.Settings,
        isPreview: Bool = false,
        minimumSeconds: Int = 0
    ) {
        if subtlePanel != nil {
            if isPreview {
                closeSubtlePanel()
            } else {
                // A card is already up. Queue this one so it shows when the
                // current card is acknowledged or times out — after a wake
                // from sleep several subtle reminders land on the same tick,
                // and replacing would silently lose all but the last.
                subtleQueue.append((reminder, settings, minimumSeconds))
                return
            }
        }
        displaySubtle(
            reminder, settings: settings,
            isPreview: isPreview, minimumSeconds: minimumSeconds
        )
    }

    private func displaySubtle(
        _ reminder: Reminder,
        settings: ReminderCore.Settings,
        isPreview: Bool,
        minimumSeconds: Int
    ) {
        guard let screen = NSScreen.main else { return }

        let view = SubtleHintView(reminder: reminder) { [weak self] in
            guard let self else { return }
            if !isPreview { self.engine?.complete(id: reminder.id) }
            // Acknowledging stops reminder-started music, consistent with the
            // critical overlay. A card that merely times out leaves the music
            // playing — "listen to calming music" should outlive an 8-second
            // card, and the user never asked for silence.
            self.music.stopReminderMusic()
            self.dismissSubtleAndAdvance()
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
        let seconds = max(
            max(2, reminder.displaySeconds ?? settings.subtleDisplaySeconds),
            minimumSeconds
        )
        subtleDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissSubtleAndAdvance()
        }
    }

    /// Takes the current card down and shows the next queued one, if any.
    private func dismissSubtleAndAdvance() {
        closeSubtlePanel()
        if let next = subtleQueue.first {
            subtleQueue.removeFirst()
            displaySubtle(
                next.reminder, settings: next.settings,
                isPreview: false, minimumSeconds: next.minimumSeconds
            )
        }
    }

    private func closeSubtlePanel() {
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
