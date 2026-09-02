import SwiftUI
import ReminderCore
import ReminderUI

/// The editor's list of exercises for an Exercise reminder: one
/// `ExerciseRowEditor` per exercise, swipe to delete, drag to reorder in edit
/// mode, and a button to add another.
struct ExerciseListSection: View {
    @Binding var exercises: [Exercise]

    var body: some View {
        Section {
            ForEach($exercises) { $exercise in
                ExerciseRowEditor(exercise: $exercise)
                    .padding(.vertical, 4)
            }
            .onDelete { offsets in
                exercises.remove(atOffsets: offsets)
            }
            .onMove { source, destination in
                exercises.move(fromOffsets: source, toOffset: destination)
            }

            Button {
                exercises.append(Exercise(name: ""))
            } label: {
                Label("Add Exercise", systemImage: "plus.circle.fill")
            }
            .accessibilityIdentifier("editorAddExercise")
        } header: {
            HStack {
                Text("Exercises")
                Spacer()
                EditButton()
                    .font(.footnote)
                    .textCase(nil)
            }
        } footer: {
            Text(Exercise.summary(of: exercises) ?? "Add at least one exercise.")
        }
    }
}
