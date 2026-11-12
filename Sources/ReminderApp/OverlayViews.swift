import AppKit
import SwiftUI
import ReminderCore
import ReminderUI

/// The full-screen takeover shown for `.critical` reminders.
///
/// Design intent: this interrupts someone who is concentrating, so it should be
/// calm rather than alarming — dark, soft, and unhurried. For a reminder with an
/// activity duration it runs a countdown, which turns "stop working" into a
/// concrete, finite thing to do. An exercise reminder lists its exercises
/// between the title and the buttons; any of them can be coached set by set
/// from there, or all of them in sequence, with the countdown in a panel
/// where the activity ring would be.
struct CriticalOverlayView: View {
    let reminder: Reminder
    /// Shared by every display's copy of this view: what is done, the
    /// running session and its clock live there, so the displays agree and
    /// the cues are spoken once.
    @ObservedObject var coach: ExerciseCoach
    let onComplete: () -> Void
    let onSnooze: () -> Void

    /// The activity timer, shared like the coach so every display shows the
    /// same seconds and the finishing chime plays once.
    @ObservedObject var countdown: ActivityCountdown
    /// The held-Escape exit of a locked takeover, driven by the presenter's
    /// key monitor; the view only draws its progress.
    @ObservedObject var escapeHold: EscapeHold
    /// A preview never locks — the buttons work, and the hint says what the
    /// real takeover would do.
    let isPreview: Bool
    @State private var appeared = false

    /// - Parameter countdown: `nil` (snapshots) gets a silent countdown of
    ///   this view's own.
    init(
        reminder: Reminder,
        coach: ExerciseCoach,
        countdown: ActivityCountdown? = nil,
        escapeHold: EscapeHold? = nil,
        isPreview: Bool = false,
        onComplete: @escaping () -> Void,
        onSnooze: @escaping () -> Void
    ) {
        self.reminder = reminder
        self.coach = coach
        self.countdown = countdown ?? ActivityCountdown(
            seconds: reminder.activityDurationSeconds ?? 0, playsChime: false
        )
        self.escapeHold = escapeHold ?? EscapeHold()
        self.isPreview = isPreview
        self.onComplete = onComplete
        self.onSnooze = onSnooze
    }

    /// How firmly this takeover holds the screen right now. `Scheduler`
    /// decides from the reminder; a preview is never held.
    private var lockLevel: TakeoverDismissal {
        isPreview ? .anytime : Scheduler.dismissal(for: reminder)
    }

    private var canFinish: Bool { Scheduler.canFinish(lockLevel, remaining: countdown.remaining) }
    private var canSnooze: Bool { Scheduler.canSnooze(lockLevel, remaining: countdown.remaining) }

    /// A button's face, with a lock while the timer holds it.
    private func buttonLabel(_ title: String, locked: Bool) -> some View {
        HStack(spacing: 6) {
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(title)
        }
        .frame(minWidth: 108)
        .padding(.vertical, 11)
    }

    /// A soft red glow feathering in from every edge of the screen: the
    /// Critical tier's colour, saying "critical" without an alarm-red
    /// backdrop. Static, so it adds no motion at the edge of vision.
    ///
    /// The band starts off-screen: blurred, a band inside the frame fades
    /// out towards the edge too, peaking a little way in like a picture
    /// frame. Pushed past the edge, it is brightest at the edge itself.
    private var criticalEdgeGlow: some View {
        Rectangle()
            .strokeBorder(PriorityDot.color(for: .critical).opacity(0.28), lineWidth: 70)
            .padding(-60)
            .blur(radius: 30)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var hasCountdown: Bool { countdown.isAvailable }

    private var progress: Double { countdown.progress }

    var body: some View {
        ZStack {
            // A deep, soft backdrop rather than a harsh alert colour.
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.09, blue: 0.11).opacity(0.97),
                    Color(red: 0.02, green: 0.05, blue: 0.07).opacity(0.98),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            criticalEdgeGlow

            VStack(spacing: reminder.isExercise ? 22 : 34) {
                Image(systemName: reminder.symbolName)
                    .font(.system(size: reminder.isExercise ? 52 : 72, weight: .light))
                    .foregroundStyle(Color(red: 0.62, green: 0.89, blue: 0.85))
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 14) {
                    Text(reminder.title)
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    if !reminder.message.isEmpty {
                        Text(reminder.message)
                            .font(.system(size: 21, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.76))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 620)
                            .lineSpacing(4)
                    }
                }

                if let exercises = reminder.exercises, !exercises.isEmpty {
                    exerciseList(exercises)
                }

                if let session = coach.session {
                    coachPanel(session)
                    if hasCountdown {
                        // The activity timer keeps running behind the coach;
                        // one line keeps it honest without two rings.
                        Text("Timer · \(timeString(countdown.remaining)) \(countdown.remaining > 0 ? "remaining" : "complete")")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.5))
                    }
                } else if hasCountdown {
                    countdownRing
                }

                if coach.session == nil, coach.suggestedExerciseID != nil {
                    // Space starts the suggested exercise. A zero-size button
                    // is how a bare key gets a role in SwiftUI without a
                    // control on screen for it.
                    Button("Start", action: coach.startSuggested)
                        .keyboardShortcut(.space, modifiers: [])
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }

                HStack(spacing: 14) {
                    if coach.session == nil, coach.canStartAll {
                        // Runs every exercise still to do, in order, with the
                        // reminder's rest between them.
                        Button(action: coach.startAll) {
                            Text("Start All")
                                .frame(minWidth: 108)
                                .padding(.vertical, 11)
                        }
                        .buttonStyle(OverlayButtonStyle(kind: .secondary))
                        .keyboardShortcut("a", modifiers: [])
                    }

                    // Disabled buttons ignore their shortcuts; the guard in
                    // each action is belt and braces, so a held screen can
                    // never be left by a key however the shortcut is routed.
                    Button(action: { if canSnooze { onSnooze() } }) {
                        buttonLabel("Snooze", locked: !canSnooze)
                    }
                    .buttonStyle(OverlayButtonStyle(kind: .secondary))
                    .keyboardShortcut("s", modifiers: [])
                    .disabled(!canSnooze)

                    Button(action: { if canFinish { onComplete() } }) {
                        buttonLabel(
                            countdown.hasStarted && countdown.remaining > 0 ? "Finish Early" : "Done",
                            locked: !canFinish
                        )
                    }
                    .buttonStyle(OverlayButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canFinish)
                }
                .padding(.top, 4)

                Text(keyboardHint)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.38))

                if escapeHold.progress > 0 {
                    // Escape is down on a locked takeover: show the hold
                    // filling, so letting go early is a choice, not a mystery.
                    VStack(spacing: 6) {
                        Text("Keep holding Esc to leave")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                        ProgressView(value: escapeHold.progress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .frame(width: 180)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(60)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.97)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { appeared = true }
            countdown.start()
        }
    }

    /// The exercises, with Start and Cancel on each. Takes its natural height when the
    /// screen has room and scrolls otherwise — the siblings above and below
    /// are fixed-size, so whatever is left over is the list's. The scrolling
    /// form fades its last visible row and says so in the caption, since a
    /// cut that happens to land on a row boundary would otherwise look like
    /// the end of the list.
    private func exerciseList(_ exercises: [Exercise]) -> some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 10) {
                exerciseRows(exercises)
                    .frame(width: 620)
                exerciseCaption(exercises, scrolls: false)
            }

            VStack(spacing: 10) {
                ScrollView(.vertical) {
                    exerciseRows(exercises)
                        .frame(width: 620)
                        // A legacy ("always show") scroller takes its width
                        // from the viewport on the right, which would leave
                        // the rows off-centre from the title above; nudging
                        // the content by the same amount cancels it. Overlay
                        // scrollers reserve nothing, and get no nudge.
                        .padding(.leading, Self.reservedScrollerWidth)
                }
                .scrollIndicators(.visible)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.85),
                            .init(color: .black.opacity(0.15), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                exerciseCaption(exercises, scrolls: true)
            }
        }
        .frame(width: 660)
    }

    private static var reservedScrollerWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
    }

    private var keyboardHint: String {
        var parts: [String] = []
        switch (lockLevel, canFinish) {
        case (.locked, false):
            parts.append("Unlocks when the timer ends · hold Esc for 5 s to leave")
        case (.snoozeOnly, false):
            parts.append("Done unlocks when the timer ends · S to snooze")
        default:
            parts.append(
                reminder.isExercise
                    ? "Return when you're done · S to snooze"
                    : "Press Return when you're done · S to snooze"
            )
        }
        if reminder.isExercise {
            parts.append(
                "A to start all · 1–9 to start a row · "
                    + "Space to start or pause the coach · N next · X stop"
            )
        }
        // Said up front, so the screen going away at 0:00 is expected.
        if Scheduler.finishesAutomatically(reminder) {
            parts.append("finishes by itself at 0:00")
        }
        // A preview's buttons work; say what the real takeover would do.
        let real = Scheduler.dismissal(for: reminder)
        if isPreview, real != .anytime {
            parts.append(
                "preview: would be \(real == .locked ? "locked" : "Done-locked") "
                    + "for \(timeString(countdown.total))"
            )
        }
        return parts.joined(separator: " · ")
    }

    private func exerciseCaption(_ exercises: [Exercise], scrolls: Bool) -> some View {
        let cancelled = coach.cancelledExerciseIDs.count
        return Text(
            "\(coach.completedExerciseIDs.count) of \(exercises.count) done"
                + (cancelled > 0 ? " · \(cancelled) cancelled" : "")
                + (scrolls ? " · scroll for the rest" : "")
        )
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.5))
    }

    private func exerciseRows(_ exercises: [Exercise]) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(exercises.enumerated()), id: \.element.id) { index, exercise in
                let row = ExerciseOverlayRow(
                    exercise: exercise,
                    index: index,
                    showsIndex: index < 9,
                    coachState: coach.rowState(for: exercise.id),
                    onStart: { coach.start(exercise.id) },
                    onCancel: { coach.cancel(exercise.id) }
                )
                if index < 9 {
                    row.keyboardShortcut(
                        KeyEquivalent(Character(String(index + 1))), modifiers: []
                    )
                } else {
                    row
                }
            }
        }
    }

    // MARK: - Coach panel

    /// The running session: a ring counting down the current hold or rest,
    /// which set and rep it is, and the controls. Takes the activity ring's
    /// slot so the eye has one place to look.
    private func coachPanel(_ session: ExerciseSession) -> some View {
        let phase = session.phase(at: coach.now)
        let isPaused = session.state == .paused
        let isComplete = session.state == .completed
        let (remainingSeconds, progress): (Int, Double) = {
            if case let .phase(_, remaining, progress) = session.position(at: coach.now) {
                return (Int(remaining.rounded(.up)), progress)
            }
            return (0, 1)
        }()

        return HStack(spacing: 26) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        ExerciseOverlayRow.doneColor,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: progress)

                VStack(spacing: 1) {
                    if isComplete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(ExerciseOverlayRow.doneColor)
                    } else {
                        Text("\(remainingSeconds)")
                            .font(.system(size: 40, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    Text(isComplete ? "done" : (isPaused ? "paused" : (phase?.label.lowercased() ?? "")))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 132, height: 132)
            .opacity(isPaused ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 8) {
                Text(isComplete ? session.timeline.completionTitle : (phase?.title ?? ""))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(phase?.exerciseName ?? session.timeline.entries.last?.name ?? "")
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))

                HStack(spacing: 10) {
                    if isComplete {
                        if coach.suggestedExerciseID != nil {
                            Button("Start Next", action: coach.startSuggested)
                                .buttonStyle(OverlayButtonStyle(kind: .secondary))
                                .keyboardShortcut(.space, modifiers: [])
                        }
                        if coach.canStartAll {
                            Button("Start All", action: coach.startAll)
                                .buttonStyle(OverlayButtonStyle(kind: .secondary))
                                .keyboardShortcut("a", modifiers: [])
                        }
                    } else {
                        Button(isPaused ? "Resume" : "Pause", action: coach.togglePause)
                            .buttonStyle(OverlayButtonStyle(kind: .secondary))
                            .keyboardShortcut(.space, modifiers: [])
                        Button("Skip", action: coach.skip)
                            .buttonStyle(OverlayButtonStyle(kind: .secondary))
                            .keyboardShortcut("n", modifiers: [])
                        Button("Stop", action: coach.stop)
                            .buttonStyle(OverlayButtonStyle(kind: .secondary))
                            .keyboardShortcut("x", modifiers: [])
                    }
                }
                .padding(.top, 6)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
        .frame(width: 620)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var countdownRing: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        ExerciseOverlayRow.doneColor,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)

                VStack(spacing: 2) {
                    Text(timeString(countdown.remaining))
                        .font(.system(size: 40, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(countdown.remaining > 0 ? "remaining" : "complete")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 168, height: 168)
        }
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Button styling for the dark overlay, where standard controls look wrong.
struct OverlayButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind
    /// A held button is dimmed, not hidden: it says what will come back.
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .padding(.horizontal, 20)
            .foregroundStyle(kind == .primary ? Color(red: 0.03, green: 0.12, blue: 0.13) : .white)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        kind == .primary
                            ? Color(red: 0.55, green: 0.88, blue: 0.82)
                            : Color.white.opacity(0.13)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.white.opacity(kind == .primary ? 0 : 0.18), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : (isEnabled ? 1 : 0.45))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The small corner card shown for `.subtle` reminders.
///
/// This is the every-20-minutes weight shift: it must register without
/// hijacking attention, so it is quiet, small, and disappears on its own.
/// The Important tier's card: the subtle card's shape, but it never times
/// out. It stays until the user ticks it done or snoozes it, which is what
/// "important" has to mean for a reminder with a consequence behind it.
///
/// This is the app's own window rather than a system notification on
/// purpose. A notification's lifetime is macOS's per-app Alert Style, which
/// cannot differ between Normal and Important, and any Focus mode swallows
/// it silently in a Developer ID build. A window the app owns is subject to
/// neither, the same reasoning that makes the Critical tier an overlay.
struct ImportantCardView: View {
    /// A Critical reminder's advance warning, shown in the same card: its
    /// own text, the Critical tier's colour, and only the tick — there is
    /// nothing to snooze, since the warning is not the reminder.
    struct Warning {
        let title: String
        let message: String
    }

    let reminder: Reminder
    var warning: Warning? = nil
    let onComplete: () -> Void
    var onSnooze: () -> Void = {}

    @State private var appeared = false

    /// The done tick's colour, the same teal on every card.
    private static let accent = Color(red: 0.36, green: 0.72, blue: 0.67)
    /// The icon and hairline take the tier's colour, matching its dot: the
    /// Critical tier's for a warning, since that is what is coming.
    private var tierColor: Color {
        PriorityDot.color(for: warning == nil ? .important : .critical)
    }
    private var title: String { warning?.title ?? reminder.title }
    private var message: String { warning?.message ?? reminder.message }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: reminder.symbolName)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(tierColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            // Snooze is a labelled pill and Done a filled tick, so the two
            // cannot be confused by a glance or a head pointer. The tick is
            // tinted at rest, not only on hover: a card that must be answered
            // should say so.
            VStack(spacing: 8) {
                Button(action: onComplete) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Self.accent)
                }
                .buttonStyle(.plain)
                .help(warning == nil ? "Mark as done" : "Got it")
                .accessibilityLabel(warning == nil ? "Done" : "Got it")

                if warning == nil {
                    Button(action: onSnooze) {
                        Text("Snooze")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("Snooze")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tierColor.opacity(0.35), lineWidth: 1)
        )
        .padding(6)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) { appeared = true }
        }
    }
}

struct SubtleHintView: View {
    let reminder: Reminder
    let onComplete: () -> Void

    @State private var appeared = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            // The tier's colour, matching the reminder's dot in the list: this
            // card also stands in for Normal (previews and the fallback).
            Image(systemName: reminder.symbolName)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(PriorityDot.color(for: reminder.priority))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if !reminder.message.isEmpty {
                    Text(reminder.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        // Four lines rather than two: at two, a normal sentence
                        // was being cut off mid-word, and a reminder you cannot
                        // finish reading has failed at its one job.
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            Button(action: onComplete) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 21))
                    .foregroundStyle(
                        isHovering
                            ? Color(red: 0.30, green: 0.68, blue: 0.62)
                            : Color.secondary.opacity(0.45)
                    )
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("Mark as done")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .padding(6)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -8)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { appeared = true }
        }
    }
}
