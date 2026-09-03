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
    @EnvironmentObject private var engine: ReminderEngine
    @EnvironmentObject private var ai: AIImportController
    @FocusState private var focusedName: UUID?
    @State private var isImporting = false

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

            HStack(spacing: 12) {
                Button {
                    add()
                } label: {
                    Label("Add Exercise", systemImage: "plus")
                }

                Button {
                    isImporting = true
                } label: {
                    Label("Import from Text\u{2026}", systemImage: "doc.on.clipboard")
                }
                .help("Paste what your physiotherapist wrote and turn it into exercises")
            }
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
            // A sheet gets a fresh environment; the engine and the import
            // controller have to be handed to it explicitly.
            .environmentObject(engine)
            .environmentObject(ai)
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
