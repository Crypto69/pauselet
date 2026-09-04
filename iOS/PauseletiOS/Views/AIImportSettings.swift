import SwiftUI
import ReminderCore
import ReminderUI
import ReminderAI

/// The Settings section for interpreting pasted exercise text with AI.
///
/// The iOS twin of `Sources/ReminderApp/AIImportSettings.swift`. Entirely
/// optional: with no key stored, the importer still works using the built-in
/// parser and the app makes no network requests at all. That is why the copy
/// here is explicit about what gets sent where — it is the only part of the
/// app that leaves the device.
struct AIImportSection: View {
    @EnvironmentObject private var engine: ReminderEngine
    @EnvironmentObject private var ai: AIImportController

    /// Held locally so a half-typed key is not written on every keystroke.
    @State private var keyField = ""
    @State private var storeError: String?

    var body: some View {
        Section {
            HStack(spacing: 8) {
                SecureField("sk-…", text: $keyField)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(commitKey)
                    .accessibilityLabel("OpenAI API key")
                    .accessibilityIdentifier("aiKeyField")

                Button("Save") { commitKey() }
                    .disabled(keyField.isEmpty)
                    .buttonStyle(.borderless)
            }

            if ai.isConfigured {
                HStack {
                    Label("A key is stored in your keychain", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) { removeKey() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }

                Picker("Model", selection: modelBinding) {
                    ForEach(AIImportModel.allCases) { model in
                        Text(model.title).tag(model.rawValue)
                    }
                }

                Text(AIImportModel.resolve(engine.settings.aiImportModel).detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    ai.model = AIImportModel.resolve(engine.settings.aiImportModel)
                    ai.testKey()
                } label: {
                    if ai.isTesting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Testing\u{2026}")
                        }
                    } else {
                        Label("Test Key", systemImage: "checkmark.circle")
                    }
                }
                .disabled(ai.isTesting)
                .accessibilityIdentifier("aiTestKey")
            }

            if let storeError {
                Label(storeError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            switch ai.testResult {
            case .success:
                Label("The key works.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case let .failure(message):
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
        } header: {
            Text("Exercise Import")
        } footer: {
            Text(
                "Optional. Pasted exercise text is read on this iPhone; adding a key lets you "
                    + "send it to OpenAI instead, which handles unusual wording better. Only text "
                    + "you explicitly choose to interpret is ever sent, and your key is stored in "
                    + "the keychain on this device — it never syncs to iCloud."
            )
        }
        .onAppear { ai.refresh() }
    }

    private func commitKey() {
        storeError = ai.store(key: keyField)
        // Never leave the secret sitting in view state once it is stored.
        if storeError == nil { keyField = "" }
    }

    private func removeKey() {
        storeError = ai.store(key: nil)
        keyField = ""
    }

    /// The picker stores the raw model id; `nil` in settings means the default.
    private var modelBinding: Binding<String> {
        Binding(
            get: { AIImportModel.resolve(engine.settings.aiImportModel).rawValue },
            set: { newValue in
                var settings = engine.settings
                settings.aiImportModel = newValue == AIImportModel.default.rawValue ? nil : newValue
                engine.updateSettings(settings)
                ai.model = AIImportModel.resolve(newValue)
            }
        )
    }
}
