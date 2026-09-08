import SwiftUI
import ReminderCore
import ReminderUI

/// The editor's list of exercises for an Exercise reminder: one
/// `ExerciseRowEditor` per exercise with move and remove buttons, the rest
/// the coach takes between exercises when it runs them all, and buttons to
/// add another or import a whole programme. Adding a row focuses its name
/// field so the next thing typed lands in the right place.
///
/// The form lives in a ScrollView rather than a List, so there is no drag
/// reordering here; the arrows on each row move it up or down instead.
struct ExerciseListSection: View {
    @Binding var exercises: [Exercise]
    /// The reminder's rest between one exercise and the next when the whole
    /// list runs in sequence. Only shown once there are two exercises for it
    /// to sit between.
    @Binding var restBetweenExercisesSeconds: Int
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
                        rowControls(for: exercise)
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

            if exercises.count > 1 {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    CountField(
                        label: "Rest between exercises",
                        value: $restBetweenExercisesSeconds,
                        range: Exercise.restRange
                    )
                    .frame(width: 238)
                    Text("Seconds, when you Start All.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
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

    /// Move up, move down and remove, stacked beside the row. The arrows
    /// are the only way to reorder in a ScrollView-backed form, so they are
    /// always present, and disabled rather than hidden at either end so the
    /// column keeps its shape from row to row.
    private func rowControls(for exercise: Exercise) -> some View {
        let index = exercises.firstIndex { $0.id == exercise.id } ?? 0
        let label = exercise.name.isEmpty ? "exercise" : exercise.name
        return VStack(spacing: 6) {
            Button {
                move(exercise.id, by: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .foregroundStyle(.secondary)
            }
            .disabled(index == 0)
            .help("Move this exercise up")
            .accessibilityLabel("Move \(label) up")

            Button {
                move(exercise.id, by: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(.secondary)
            }
            .disabled(index == exercises.count - 1)
            .help("Move this exercise down")
            .accessibilityLabel("Move \(label) down")

            Button(role: .destructive) {
                remove(exercise.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .help("Remove this exercise")
            .accessibilityLabel("Remove \(label)")
        }
        .buttonStyle(.borderless)
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

    /// Swaps the exercise with its neighbour `offset` rows away (−1 up,
    /// +1 down); a no-op at either end.
    private func move(_ id: UUID, by offset: Int) {
        guard let index = exercises.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard exercises.indices.contains(target) else { return }
        exercises.swapAt(index, target)
    }
}
