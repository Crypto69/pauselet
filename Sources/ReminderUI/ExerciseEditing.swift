import SwiftUI
import ReminderCore

/// The fields for one exercise — name, instructions, sets, reps, and the
/// hold and rest times that make it a guided one — shared by the Mac and iOS
/// editors so the two cannot drift on what an exercise is.
/// Each platform wraps rows in its own section (the Mac adds a remove button,
/// iOS uses swipe-to-delete and reordering).
public struct ExerciseRowEditor: View {
    @Binding private var exercise: Exercise

    public init(exercise: Binding<Exercise>) {
        _exercise = exercise
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Exercise name", text: $exercise.name)
                .accessibilityLabel("Exercise name")
            TextField("Instructions", text: $exercise.instructions, axis: .vertical)
                .lineLimit(1...4)
                .accessibilityLabel("Instructions")
            #if os(macOS)
            // Side by side, each just wide enough for its field, so the arrows
            // sit next to the number they change rather than at the far end
            // of the row. (Letting them size themselves makes the Form row
            // wider than the sheet.)
            HStack(spacing: 18) {
                CountField(label: "Sets", value: $exercise.sets, range: 1...20)
                    .frame(width: 128)
                CountField(label: "Reps", value: $exercise.reps, range: 1...100)
                    .frame(width: 132)
                Spacer(minLength: 0)
            }
            // The timing row: three fields do not fit beside each other in
            // the sheet, so hold and the rep rest share a row and the set
            // rest gets the caption for company.
            HStack(spacing: 18) {
                CountField(label: "Hold", value: $exercise.holdSeconds, range: Exercise.holdRange)
                    .frame(width: 128)
                CountField(
                    label: "Rest", value: $exercise.restBetweenRepsSeconds,
                    range: Exercise.restRange
                )
                .frame(width: 132)
                .disabled(!exercise.isGuided)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                CountField(
                    label: "Set rest", value: $exercise.restBetweenSetsSeconds,
                    range: Exercise.restRange
                )
                .frame(width: 150)
                .disabled(!exercise.isGuided)
                Text(timingCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            #else
            // Stacked: two full-width steppers do not fit an iPhone row.
            CountField(label: "Sets", value: $exercise.sets, range: 1...20)
            CountField(label: "Reps", value: $exercise.reps, range: 1...100)
            CountField(label: "Hold (s)", value: $exercise.holdSeconds, range: Exercise.holdRange)
            CountField(
                label: "Rest between reps (s)", value: $exercise.restBetweenRepsSeconds,
                range: Exercise.restRange
            )
            CountField(
                label: "Rest between sets (s)", value: $exercise.restBetweenSetsSeconds,
                range: Exercise.restRange
            )
            Text(timingCaption)
                .font(.footnote)
                .foregroundStyle(.secondary)
            #endif
        }
    }

    private var timingCaption: String {
        exercise.isGuided
            ? "Seconds per rep, between reps, and between sets."
            : "Seconds. Hold 0 leaves this exercise untimed."
    }
}

/// A small whole-number field with stepper arrows.
///
/// The number is typed as well as stepped: fifteen reps is one keystroke, not
/// five clicks. Putting the field inside the stepper's label keeps the digits
/// and the arrows on one baseline without the hand-measured offsets a
/// side-by-side pair needs. Out-of-range values snap back into range.
public struct CountField: View {
    public let label: String
    @Binding private var value: Int
    public let range: ClosedRange<Int>

    public init(label: String, value: Binding<Int>, range: ClosedRange<Int>) {
        self.label = label
        _value = value
        self.range = range
    }

    public var body: some View {
        Stepper(value: $value, in: range) {
            HStack(spacing: 6) {
                Text(label)
                TextField("", value: $value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .frame(width: 48)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
            }
        }
        .onChange(of: value) { newValue in
            let clamped = min(max(newValue, range.lowerBound), range.upperBound)
            if clamped != newValue { value = clamped }
        }
        .accessibilityLabel(label)
        .accessibilityValue("\(value)")
    }
}
