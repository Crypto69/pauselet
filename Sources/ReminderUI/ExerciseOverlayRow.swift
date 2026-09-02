import SwiftUI
import ReminderCore

/// One exercise on the full-screen takeover: a tick, the name with "3 × 10",
/// and the instructions. Ticking dims the row rather than hiding it, so what
/// has been done stays legible. The tick is working memory for the session;
/// it is never stored.
///
/// One implementation for the Mac overlay and the iOS takeover, which share
/// the same dark design. The index badge is the Mac's keyboard hint (1–9
/// toggle rows); iOS leaves it out.
public struct ExerciseOverlayRow: View {
    public let exercise: Exercise
    public let index: Int
    public let isDone: Bool
    public let showsIndex: Bool
    public let onToggle: () -> Void

    /// The teal the takeover uses for progress: ticked rows and the countdown
    /// ring on both platforms draw from here.
    public static let doneColor = Color(red: 0.42, green: 0.85, blue: 0.78)

    public init(
        exercise: Exercise,
        index: Int,
        isDone: Bool,
        showsIndex: Bool = true,
        onToggle: @escaping () -> Void
    ) {
        self.exercise = exercise
        self.index = index
        self.isDone = isDone
        self.showsIndex = showsIndex
        self.onToggle = onToggle
    }

    public var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(isDone ? Self.doneColor : Color.white.opacity(0.4))
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(exercise.name)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .strikethrough(isDone)
                        Text(exercise.summary)
                            .font(.system(size: 15, weight: .regular, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    if !exercise.instructions.isEmpty {
                        Text(exercise.instructions)
                            .font(.system(size: 15, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                if showsIndex {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 20, height: 20)
                        .background(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                        .accessibilityHidden(true)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(isDone ? 0.04 : 0.08))
            )
            .opacity(isDone ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: isDone)
        .accessibilityLabel("\(exercise.name), \(exercise.sets) sets of \(exercise.reps)")
        .accessibilityValue(isDone ? "Done" : "Not done")
        .accessibilityAddTraits(isDone ? [.isSelected] : [])
    }
}
