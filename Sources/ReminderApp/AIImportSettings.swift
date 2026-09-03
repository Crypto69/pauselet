import SwiftUI
import ReminderCore
import ReminderUI
import ReminderAI

/// The Preferences section for interpreting pasted exercise text with AI.
///
/// Entirely optional: with no key stored, the importer still works using the
/// built-in parser and the app makes no network requests at all. That is why
/// the copy here is explicit about what gets sent where — it is the only part
/// of the app that leaves the machine.
struct AIImportSection: View {
    @EnvironmentObject private var engine: ReminderEngine
    @EnvironmentObject private var ai: AIImportController

    /// Held locally so a half-typed key is not written on every keystroke —
    /// the same reason `MusicSettings` stages its playlist link.
    @State private var keyField = ""
    @State private var storeError: String?

    var body: some View {
        Section {
            LabeledContent("OpenAI API key") {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 8) {
                        // `labelsHidden` keeps the placeholder inside the
                        // field; without it LabeledContent renders "sk-…" as
                        // an external label beside the box.
                        SecureField("sk-…", text: $keyField)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 260)
                            .onSubmit(commitKey)

                        Button("Save") { commitKey() }
                            .disabled(keyField.isEmpty)
                    }

                    if ai.isConfigured {
                        HStack(spacing: 8) {
                            Label("A key is stored in your keychain", systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Remove", role: .destructive) { removeKey() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }
                }
            }

            if ai.isConfigured {
                LabeledContent("Model") {
                    HStack(spacing: 8) {
                        Picker("Model", selection: modelBinding) {
                            ForEach(AIImportModel.allCases) { model in
                                Text(model.title).tag(model.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)

                        Button {
                            ai.model = AIImportModel.resolve(engine.settings.aiImportModel)
                            ai.testKey()
                        } label: {
                            if ai.isTesting {
                                ProgressView().controlSize(.small).frame(width: 34)
                            } else {
                                Text("Test").frame(width: 34)
                            }
                        }
                        .disabled(ai.isTesting)
                        .help("Check the key and model by interpreting one short phrase")
                    }
                }

                Text(AIImportModel.resolve(engine.settings.aiImportModel).detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
        } header: {
            Text("Exercise Import")
        } footer: {
            Text(
                "Optional. Pasted exercise text is read on this Mac; adding a key lets you send "
                    + "it to OpenAI instead, which handles unusual wording better. Only text you "
                    + "explicitly choose to interpret is ever sent, and your key is stored in the "
                    + "macOS keychain."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
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
