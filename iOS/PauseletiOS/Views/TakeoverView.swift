import SwiftUI
import ReminderCore
import ReminderUI

/// The full-screen acknowledgment view for `.critical` reminders — the ported
/// macOS `CriticalOverlayView`. On iOS it appears when a fire happens with the
/// app frontmost, or one tap after the system alarm's "Open" button.
///
/// Design intent is unchanged: this interrupts someone who is concentrating,
/// so it is calm rather than alarming — dark, soft, and unhurried. A reminder
/// with an activity duration runs a countdown, which turns "stop working"
/// into a concrete, finite thing to do. An exercise reminder lists its
/// exercises with a tick each; the buttons stay pinned beneath however long
/// the list is.
struct TakeoverView: View {
    let item: AppModel.TakeoverItem
    let onAction: (AppModel.TakeoverAction) -> Void

    @State private var remaining: Int
    @State private var hasStarted = false
    @State private var appeared = false
    /// Which exercises have been ticked — working memory for this session,
    /// never stored.
    @State private var completedExerciseIDs: Set<UUID> = []

    private var reminder: Reminder { item.reminder }

    init(item: AppModel.TakeoverItem, onAction: @escaping (AppModel.TakeoverAction) -> Void) {
        self.item = item
        self.onAction = onAction
        _remaining = State(initialValue: item.reminder.activityDurationSeconds ?? 0)
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
                    Color(red: 0.04, green: 0.09, blue: 0.11),
                    Color(red: 0.02, green: 0.05, blue: 0.07),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 30) {
                    Image(systemName: reminder.symbolName)
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(Color(red: 0.62, green: 0.89, blue: 0.85))
                        .symbolRenderingMode(.hierarchical)
                        .padding(.top, 40)

                    VStack(spacing: 12) {
                        Text(reminder.title)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        if !reminder.message.isEmpty {
                            Text(reminder.message)
                                .font(.system(size: 18, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.76))
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                        }
                    }
                    .padding(.horizontal, 28)

                    if let exercises = reminder.exercises, !exercises.isEmpty {
                        exerciseList(exercises)
                    }

                    if hasCountdown {
                        countdown
                    }
                }
                .padding(.bottom, 24)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.97)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Pinned under the content so a long exercise list never scrolls
            // Done out of reach; for a plain reminder it reads the same as
            // before.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button {
                        onAction(.complete)
                    } label: {
                        Text(doneTitle)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                    }
                    .buttonStyle(TakeoverButtonStyle(kind: .primary))
                    .accessibilityIdentifier("takeoverDone")

                    Button {
                        onAction(.snooze)
                    } label: {
                        Text("Snooze")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                    }
                    .buttonStyle(TakeoverButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("takeoverSnooze")
                }
                .padding(.horizontal, 36)
                .padding(.top, 14)
                .padding(.bottom, 24)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.02, green: 0.05, blue: 0.07).opacity(0),
                            Color(red: 0.02, green: 0.05, blue: 0.07),
                        ],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.25)
                    )
                    .ignoresSafeArea()
                )
                .opacity(appeared ? 1 : 0)
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { appeared = true }
            if hasCountdown { hasStarted = true }
        }
        // The countdown ticks only while there is one to run, and the ticker
        // lives with the view rather than being recreated on every body pass.
        .task(id: hasStarted) {
            guard hasCountdown, hasStarted else { return }
            while !Task.isCancelled, remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                remaining -= 1
                if remaining == 0 {
                    // The activity is finished; let the user hear that before
                    // it closes.
                    Sounds.play(named: Sounds.countdownComplete)
                }
            }
        }
    }

    private var doneTitle: String {
        hasCountdown && hasStarted && remaining > 0 ? "Finish Early" : "Done"
    }

    private func exerciseList(_ exercises: [Exercise]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(completedExerciseIDs.count) of \(exercises.count) done")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity)

            ForEach(Array(exercises.enumerated()), id: \.element.id) { index, exercise in
                ExerciseOverlayRow(
                    exercise: exercise,
                    index: index,
                    isDone: completedExerciseIDs.contains(exercise.id),
                    showsIndex: false
                ) {
                    if completedExerciseIDs.contains(exercise.id) {
                        completedExerciseIDs.remove(exercise.id)
                    } else {
                        completedExerciseIDs.insert(exercise.id)
                    }
                }
                .accessibilityIdentifier("takeoverExercise-\(index)")
            }
        }
        .padding(.horizontal, 24)
    }

    private var countdown: some View {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            remaining > 0
                ? "\(timeString(remaining)) remaining"
                : "Activity complete"
        )
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Button styling for the dark takeover, where standard controls look wrong.
struct TakeoverButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium, design: .rounded))
            .foregroundStyle(
                kind == .primary ? Color(red: 0.03, green: 0.12, blue: 0.13) : .white
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        kind == .primary
                            ? Color(red: 0.55, green: 0.88, blue: 0.82)
                            : Color.white.opacity(0.13)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(kind == .primary ? 0 : 0.18), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
