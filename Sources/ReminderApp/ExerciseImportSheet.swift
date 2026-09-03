import SwiftUI
import ReminderCore
import ReminderUI
import ReminderAI

/// Paste a physiotherapist's instructions, see what was understood, fix
/// anything wrong, and add the lot — instead of typing six fields per exercise.
///
/// The preview rows are the *real* editor rows (`ExerciseRowEditor`), not a
/// read-only summary, so correcting a mis-parse happens here rather than after
/// the exercises have been committed. Nothing is added until the person presses
/// Add, which is what makes an imperfect parse — and an AI reply — safe.
struct ExerciseImportSheet: View {
    /// Called with the exercises to append. The sheet never mutates the
    /// editor's list itself.
    let onAdd: ([Exercise]) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var engine: ReminderEngine
    @EnvironmentObject private var ai: AIImportController

    @State private var text = ""
    @State private var drafts: [Exercise] = []
    /// Set once the person has asked for a parse, so the empty state does not
    /// read as a failure before they have typed anything.
    @State private var hasParsed = false
    @State private var isInterpreting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    entry
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    results
                }
                .padding(16)
            }
            Divider()
            footer
        }
        // A sheet presented from the editor sheet cannot grow past the window
        // behind it, and a fixed height pushes Cancel/Add off-screen once a
        // few exercises are parsed. Sizing to a range keeps the footer — the
        // only way to commit or back out — always reachable.
        .frame(width: 470)
        .frame(minHeight: 380, idealHeight: 460, maxHeight: 620)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import Exercises")
                .font(.headline)
            Text("Paste what your physiotherapist wrote. Check the result before adding it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.body)
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(Self.placeholder)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            // The hint is an example, not content: it must
                            // wrap inside the box rather than widen it.
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                            .padding(.horizontal, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.3))
                )

            HStack(spacing: 8) {
                Button("Read Text") { parseLocally() }
                    .disabled(trimmedText.isEmpty)
                    .help("Pull the exercises out of the text on this Mac")

                if ai.isConfigured {
                    Button {
                        interpret()
                    } label: {
                        if isInterpreting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Interpret with AI", systemImage: "sparkles")
                        }
                    }
                    .disabled(trimmedText.isEmpty || isInterpreting)
                    .help("Send the text to OpenAI, which handles unusual wording better")
                }

                Spacer()

                if !drafts.isEmpty {
                    Button("Clear", role: .destructive) { reset() }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if !drafts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Found \(drafts.count) \(drafts.count == 1 ? "exercise" : "exercises")")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Edit anything that came out wrong")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach($drafts) { $draft in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            ExerciseRowEditor(exercise: $draft)
                            Button(role: .destructive) {
                                drafts.removeAll { $0.id == draft.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(draft.name.isEmpty ? "exercise" : draft.name)")
                        }
                        if draft.id != drafts.last?.id { Divider() }
                    }
                }
            }
        } else if hasParsed {
            Label(
                "No exercises found in that text. Try including the sets and reps, "
                    + "like \"3 sets of 10\".",
                systemImage: "questionmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Add \(drafts.count) \(drafts.count == 1 ? "Exercise" : "Exercises")") {
                onAdd(drafts)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(drafts.isEmpty || !drafts.allSatisfy(\.isValid))
        }
        .padding(12)
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
