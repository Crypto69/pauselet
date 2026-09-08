import SwiftUI
import ReminderCore
import ReminderUI

/// The editor's list of exercises for an Exercise reminder: one
/// `ExerciseRowEditor` per exercise, swipe to delete, drag to reorder in edit
/// mode, the rest the coach takes between exercises when it runs them all,
/// and buttons to add another or import a whole programme from pasted text.
struct ExerciseListSection: View {
    @Binding var exercises: [Exercise]
    /// The reminder's rest between one exercise and the next when the whole
    /// list runs in sequence. Only shown once there are two exercises for it
    /// to sit between.
    @Binding var restBetweenExercisesSeconds: Int
    @EnvironmentObject private var ai: AIImportController
    @State private var isImporting = false

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

            if exercises.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    CountField(
                        label: "Rest between exercises (s)",
                        value: $restBetweenExercisesSeconds,
                        range: Exercise.restRange
                    )
                    Text("Seconds between one exercise and the next when you Start All.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("editorRestBetweenExercises")
            }

            Button {
                exercises.append(Exercise(name: ""))
            } label: {
                Label("Add Exercise", systemImage: "plus.circle.fill")
            }
            .accessibilityIdentifier("editorAddExercise")

            Button {
                isImporting = true
            } label: {
                Label("Import from Text\u{2026}", systemImage: "doc.on.clipboard")
            }
            .accessibilityIdentifier("editorImportExercises")
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
        .sheet(isPresented: $isImporting) {
            ExerciseImportSheet { imported in
                // Switching the type to Exercise seeds one blank row for
                // typing into. Importing is the alternative to typing, so that
                // untouched placeholder is replaced rather than left above the
                // imported rows. Anything the person actually filled in stays.
                exercises.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                exercises.append(contentsOf: imported)
            }
            // A sheet gets a fresh environment; the import controller has to be
            // handed to it explicitly.
            .environmentObject(ai)
        }
    }
}
