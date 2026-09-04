import SwiftUI
import ReminderCore
import ReminderUI

/// Paste a physiotherapist's instructions, see what was understood, fix
/// anything wrong, and add the lot — instead of typing six fields per exercise.
///
/// The iOS twin of `Sources/ReminderApp/ExerciseImportSheet.swift`. The flow is
/// deliberately identical — paste, Read Text, editable preview, Add N — and the
/// preview rows are the *real* `ExerciseRowEditor`, so a mis-parse is corrected
/// here rather than after the exercises have been committed. Nothing is added
/// until the person presses Add, which is what makes an imperfect parse — and
/// an AI reply — safe.
///
/// The layout is its own: the Mac sheet is 470pt and mouse-shaped, so this is a
/// `NavigationStack` over a `Form` with the actions in the toolbar, where a
/// thumb can reach them. The parsing engine and the row editor are shared, and
/// those are the parts that must not drift.
struct ExerciseImportSheet: View {
    /// Called with the exercises to append. The sheet never mutates the
    /// editor's list itself.
    let onAdd: ([Exercise]) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var ai: AIImportController

    @State private var text = ""
    @State private var drafts: [Exercise] = []
    /// Set once the person has asked for a parse, so the empty state does not
    /// read as a failure before they have typed anything.
    @State private var hasParsed = false
    @State private var isInterpreting = false
    @State private var errorMessage: String?
    @FocusState private var isTextFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                entry

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                results
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("importCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(addTitle) {
                        onAdd(drafts)
                        dismiss()
                    }
                    .disabled(drafts.isEmpty || !drafts.allSatisfy(\.isValid))
                    .accessibilityIdentifier("importAdd")
                }
                // The keyboard covers the Read Text button while the paste box
                // has focus, which is exactly when it is next wanted.
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("Done") { isTextFocused = false }
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    /// "Add 2" rather than "Add 2 Exercises": the longer label is wide enough
    /// to truncate the navigation title beside it, and the section header
    /// already says what was found.
    private var addTitle: String {
        drafts.isEmpty ? "Add" : "Add \(drafts.count)"
    }

    private var entry: some View {
        Section {
            TextField(Self.placeholder, text: $text, axis: .vertical)
                .lineLimit(4...10)
                .focused($isTextFocused)
                .accessibilityLabel("Pasted exercise text")
                .accessibilityIdentifier("importText")

            Button {
                isTextFocused = false
                parseLocally()
            } label: {
                Label("Read Text", systemImage: "text.viewfinder")
            }
            .disabled(trimmedText.isEmpty)
            .accessibilityIdentifier("importReadText")

            if ai.isConfigured {
                Button {
                    isTextFocused = false
                    interpret()
                } label: {
                    if isInterpreting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Interpreting\u{2026}")
                        }
                    } else {
                        Label("Interpret with AI", systemImage: "sparkles")
                    }
                }
                .disabled(trimmedText.isEmpty || isInterpreting)
                .accessibilityIdentifier("importInterpret")
            }

            if !drafts.isEmpty {
                Button("Clear", role: .destructive) { reset() }
            }
        } header: {
            Text("Paste")
        } footer: {
            Text(
                "Paste what your physiotherapist wrote. Check the result before "
                + "adding it."
            )
        }
    }

    @ViewBuilder
    private var results: some View {
        if !drafts.isEmpty {
            Section {
                ForEach($drafts) { $draft in
                    ExerciseRowEditor(exercise: $draft)
                        .padding(.vertical, 4)
                }
                .onDelete { offsets in
                    drafts.remove(atOffsets: offsets)
                }
            } header: {
                Text("Found \(drafts.count) \(drafts.count == 1 ? "exercise" : "exercises")")
            } footer: {
                Text("Edit anything that came out wrong. Swipe a row away to drop it.")
            }
        } else if hasParsed {
            Section {
                Label(
                    "No exercises found in that text. Try including the sets and "
                        + "reps, like \"3 sets of 10\".",
                    systemImage: "questionmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseLocally() {
        errorMessage = nil
        hasParsed = true
        drafts = ExerciseImporter.parse(text)
    }

    /// Falls back to nothing on failure — the local parse stays on screen and
    /// the error says what happened, rather than silently substituting a worse
    /// result for the one the person asked for.
    private func interpret() {
        errorMessage = nil
        isInterpreting = true
        Task {
            defer { isInterpreting = false }
            do {
                let interpreted = try await ai.interpret(text)
                hasParsed = true
                drafts = interpreted
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reset() {
        drafts = []
        hasParsed = false
        errorMessage = nil
    }

    private static let placeholder = """
        3 sets of 10 chin tucks, hold 5 seconds, rest 30 seconds between sets
        Wall slides 3 x 15
        """
}
