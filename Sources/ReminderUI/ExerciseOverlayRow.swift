import SwiftUI
import ReminderCore

/// How a guided exercise's row presents the coach. An untimed exercise has
/// no state and keeps its plain tick box.
public enum ExerciseRowCoachState: Equatable, Sendable {
    /// Waiting, with a quiet Start.
    case idle
    /// Waiting as the obvious next one: Start is filled in.
    case suggested
    /// Running or paused; the caption says where it is ("Set 1 · Rep 3 · Hold").
    case active(caption: String)
    /// Finished by the coach.
    case completed
    /// The user said they are not doing this one. Start takes it back.
    case cancelled
}

/// One exercise on the full-screen takeover: the name with "3 × 10" and the
/// instructions, with either a tick box (untimed) or Start and Cancel pills
/// (guided). Done and cancelled rows dim rather than hide, so what has
/// happened stays legible. None of it is stored: it is working memory for
/// the session.
///
/// A guided row never has a tick box. The coach marks it done when the last
/// set is over, and Cancel is the way to say "not this one" — two controls
/// with two meanings, rather than a tick that could mean either.
///
/// One implementation for the Mac overlay and the iOS takeover, which share
/// the same dark design. The index badge is the Mac's keyboard hint (1–9
/// on a row); iOS leaves it out.
public struct ExerciseOverlayRow: View {
    public let exercise: Exercise
    public let index: Int
    /// The tick box on an untimed row. Ignored for a guided row, whose
    /// `coachState` carries completion.
    public let isDone: Bool
    public let showsIndex: Bool
    /// `nil` for an untimed exercise.
    public let coachState: ExerciseRowCoachState?
    public let onStart: (() -> Void)?
    public let onCancel: (() -> Void)?
    public let onToggle: () -> Void

    /// The teal the takeover uses for progress: ticked rows and the countdown
    /// ring on both platforms draw from here.
    public static let doneColor = Color(red: 0.42, green: 0.85, blue: 0.78)

    public init(
        exercise: Exercise,
        index: Int,
        isDone: Bool,
        showsIndex: Bool = true,
        coachState: ExerciseRowCoachState? = nil,
        onStart: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onToggle: @escaping () -> Void
    ) {
        self.exercise = exercise
        self.index = index
        self.isDone = isDone
        self.showsIndex = showsIndex
        self.coachState = coachState
        self.onStart = onStart
        self.onCancel = onCancel
        self.onToggle = onToggle
    }

    private var isGuided: Bool { coachState != nil }

    private var isActive: Bool {
        if case .active = coachState { return true }
        return false
    }

    private var isFinished: Bool {
        isGuided ? coachState == .completed : isDone
    }

    private var isCancelled: Bool { coachState == .cancelled }

    /// Dimmed: done either way, or cancelled.
    private var isDimmed: Bool { isFinished || isCancelled }

    private var showsStart: Bool {
        guard onStart != nil else { return false }
        switch coachState {
        case .idle, .suggested, .cancelled: return true
        case .active, .completed, nil: return false
        }
    }

    private var showsCancel: Bool {
        guard onCancel != nil else { return false }
        switch coachState {
        case .idle, .suggested: return true
        case .active, .completed, .cancelled, nil: return false
        }
    }

    /// Width the label leaves free at its trailing edge for the pills, which
    /// are laid over the row rather than nested in its button so a click
    /// lands on exactly one control.
    private var reservedWidth: CGFloat {
        (showsStart ? Self.startPillWidth : 0)
            + (showsCancel ? Self.pillSpacing + Self.cancelPillWidth : 0)
    }

    private static let startPillWidth: CGFloat = 68
    private static let cancelPillWidth: CGFloat = 78
    private static let pillSpacing: CGFloat = 8
    private static let rowInset: CGFloat = 18

    public var body: some View {
        Button(action: rowAction) {
            HStack(alignment: .top, spacing: 14) {
                leadingGlyph
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(exercise.name)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .strikethrough(isFinished)
                        Text(summaryText)
                            .font(.system(size: 15, weight: .regular, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isActive ? Self.doneColor : .white.opacity(0.6))
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

                if reservedWidth > 0 {
                    Color.clear.frame(width: reservedWidth, height: 1)
                }

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
            .padding(.horizontal, Self.rowInset)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        isActive
                            ? Self.doneColor.opacity(0.14)
                            : Color.white.opacity(isDimmed ? 0.04 : 0.08)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Self.doneColor.opacity(isActive ? 0.6 : 0), lineWidth: 1)
            )
            .opacity(isDimmed ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            HStack(spacing: Self.pillSpacing) {
                if showsStart, let onStart {
                    Button("Start", action: onStart)
                        .buttonStyle(CoachPillStyle(
                            emphasis: coachState == .suggested ? .filled : .ghost
                        ))
                        .frame(width: Self.startPillWidth)
                        .accessibilityLabel("Start \(exercise.name)")
                }
                if showsCancel, let onCancel {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(CoachPillStyle(emphasis: .ghost))
                        .frame(width: Self.cancelPillWidth)
                        .accessibilityLabel("Cancel \(exercise.name)")
                }
            }
            .padding(.trailing, Self.rowInset + (showsIndex ? 20 + 14 : 0))
        }
        .animation(.easeOut(duration: 0.18), value: isDimmed)
        .animation(.easeOut(duration: 0.18), value: isActive)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isFinished ? [.isSelected] : [])
    }

    /// Clicking the row: the tick box for an untimed exercise, Start for a
    /// guided one that is waiting, nothing otherwise.
    private func rowAction() {
        guard isGuided else { return onToggle() }
        if showsStart { onStart?() }
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        let (name, color): (String, Color) = {
            switch coachState {
            case nil:
                return (isDone ? "checkmark.circle.fill" : "circle",
                        isDone ? Self.doneColor : Color.white.opacity(0.4))
            case .completed:
                return ("checkmark.circle.fill", Self.doneColor)
            case .cancelled:
                return ("xmark.circle", Color.white.opacity(0.4))
            case .active:
                return ("timer", Self.doneColor)
            case .idle, .suggested:
                return ("play.circle", Color.white.opacity(0.4))
            }
        }()
        Image(systemName: name)
            .font(.system(size: 26, weight: .light))
            .foregroundStyle(color)
    }

    private var summaryText: String {
        switch coachState {
        case let .active(caption): return caption
        case .cancelled: return "Cancelled"
        default: return exercise.summary
        }
    }

    private var accessibilityText: String {
        var text = "\(exercise.name), \(exercise.sets) sets of \(exercise.reps)"
        if exercise.isGuided {
            text += ", hold \(ExerciseTimeline.seconds(exercise.holdSeconds))"
        }
        return text
    }

    private var accessibilityValue: String {
        switch coachState {
        case .active(let caption): return caption
        case .cancelled: return "Cancelled"
        default: return isFinished ? "Done" : "Not done"
        }
    }
}

/// The small Start and Cancel pills on a guided row. Lives here rather than
/// in the app so the iOS takeover can use the same one.
public struct CoachPillStyle: ButtonStyle {
    public enum Emphasis { case filled, ghost }
    public let emphasis: Emphasis

    public init(emphasis: Emphasis) {
        self.emphasis = emphasis
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .foregroundStyle(
                emphasis == .filled ? Color(red: 0.03, green: 0.12, blue: 0.13) : .white
            )
            .background(
                Capsule().fill(
                    emphasis == .filled
                        ? Color(red: 0.55, green: 0.88, blue: 0.82)
                        : Color.white.opacity(0.12)
                )
            )
            .overlay(
                Capsule().stroke(Color.white.opacity(emphasis == .filled ? 0 : 0.2), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
