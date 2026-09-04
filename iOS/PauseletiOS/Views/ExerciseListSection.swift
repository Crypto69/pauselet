import SwiftUI
import ReminderCore
import ReminderUI

/// The editor's list of exercises for an Exercise reminder: one
/// `ExerciseRowEditor` per exercise, swipe to delete, drag to reorder in edit
/// mode, and buttons to add another or import a whole programme from pasted
/// text.
struct ExerciseListSection: View {
    @Binding var exercises: [Exercise]
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
