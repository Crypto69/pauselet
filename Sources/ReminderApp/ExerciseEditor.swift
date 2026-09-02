import SwiftUI
import ReminderCore
import ReminderUI

/// The editor's list of exercises for an Exercise reminder: one
/// `ExerciseRowEditor` per exercise with a remove button, and a button to add
/// another. Adding a row focuses its name field so the next thing typed lands
/// in the right place.
///
/// The form lives in a ScrollView rather than a List, so there is no drag
/// reordering here; the order exercises are added is the order they appear.
struct ExerciseListSection: View {
    @Binding var exercises: [Exercise]
    @FocusState private var focusedName: UUID?

    var body: some View {
        Section("Exercises") {
            ForEach($exercises) { $exercise in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        ExerciseRowEditor(exercise: $exercise)
                            .focused($focusedName, equals: exercise.id)
                        Button(role: .destructive) {
                            remove(exercise.id)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this exercise")
                        .accessibilityLabel("Remove \(exercise.name.isEmpty ? "exercise" : exercise.name)")
                    }
                    if exercise.id != exercises.last?.id {
                        Divider()
                    }
                }
            }

            if exercises.isEmpty {
                Text("Add at least one exercise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                add()
            } label: {
                Label("Add Exercise", systemImage: "plus")
            }
        }
    }

    private func add() {
        let exercise = Exercise(name: "")
        exercises.append(exercise)
        // The field exists after the next layout pass.
        DispatchQueue.main.async { focusedName = exercise.id }
    }

    private func remove(_ id: UUID) {
        exercises.removeAll { $0.id == id }
    }
}
