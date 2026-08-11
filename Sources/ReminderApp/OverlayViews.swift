import SwiftUI
import ReminderCore

/// The full-screen takeover shown for `.critical` reminders.
///
/// Design intent: this interrupts someone who is concentrating, so it should be
/// calm rather than alarming — dark, soft, and unhurried. For a reminder with an
/// activity duration it runs a countdown, which turns "stop working" into a
/// concrete, finite thing to do.
struct CriticalOverlayView: View {
    let reminder: Reminder
    let onComplete: () -> Void
    let onSnooze: () -> Void

    @State private var remaining: Int
    @State private var hasStarted = false
    @State private var appeared = false

    init(reminder: Reminder, onComplete: @escaping () -> Void, onSnooze: @escaping () -> Void) {
        self.reminder = reminder
        self.onComplete = onComplete
        self.onSnooze = onSnooze
        _remaining = State(initialValue: reminder.activityDurationSeconds ?? 0)
    }

    private var hasCountdown: Bool { (reminder.activityDurationSeconds ?? 0) > 0 }

    private var progress: Double {
        guard let total = reminder.activityDurationSeconds, total > 0 else { return 0 }
        return 1 - (Double(remaining) / Double(total))
    }

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

            VStack(spacing: 34) {
                Image(systemName: reminder.symbolName)
                    .font(.system(size: 72, weight: .light))
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

                if hasCountdown {
                    countdown
                }

                HStack(spacing: 14) {
                    Button(action: onSnooze) {
                        Text("Snooze")
                            .frame(minWidth: 108)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(OverlayButtonStyle(kind: .secondary))
                    .keyboardShortcut("s", modifiers: [])

                    Button(action: onComplete) {
                        Text(hasCountdown && hasStarted && remaining > 0 ? "Finish Early" : "Done")
                            .frame(minWidth: 108)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(OverlayButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)

                Text("Press Return when you're done · S to snooze")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(60)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.97)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { appeared = true }
            if hasCountdown { hasStarted = true }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard hasCountdown, hasStarted, remaining > 0 else { return }
            remaining -= 1
            if remaining == 0 {
                // The activity is finished; let the user see that before it closes.
                Sounds.play(named: "Glass")
            }
        }
    }

    private var countdown: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color(red: 0.42, green: 0.85, blue: 0.78),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)

                VStack(spacing: 2) {
                    Text(timeString(remaining))
                        .font(.system(size: 40, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(remaining > 0 ? "remaining" : "complete")
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
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The small corner card shown for `.subtle` reminders.
///
/// This is the every-20-minutes weight shift: it must register without
/// hijacking attention, so it is quiet, small, and disappears on its own.
struct SubtleHintView: View {
    let reminder: Reminder
    let onComplete: () -> Void

    @State private var appeared = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: reminder.symbolName)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Color(red: 0.36, green: 0.72, blue: 0.67))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if !reminder.message.isEmpty {
                    Text(reminder.message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
