import SwiftUI
import ReminderCore
import ReminderUI

/// The Preferences section for the spoken exercise coach: whether it talks,
/// which system voice it uses, and a way to hear it before an exercise does.
///
/// Voices are read once per appearance: enumerating them is not free, and
/// the list only changes when the user installs one in System Settings.
struct VoiceCoachSection: View {
    @EnvironmentObject private var engine: ReminderEngine
    @EnvironmentObject private var speech: SpeechCoach

    @State private var voices: [VoiceCatalog.Voice] = []

    /// What the Test button says — the coach's first real cue.
    static let sampleCue = "Set 1, rep 1. Hold for 5 seconds."

    var body: some View {
        Section("Voice Coach") {
            HelpRow(
                title: "Speak exercise cues",
                help: "Reads out each set, rep, hold and rest while the "
                    + "exercise takeover coaches you through an exercise. "
                    + "Only exercises with a hold time are coached; the "
                    + "others keep their tick box."
            ) {
                Toggle("", isOn: binding(\.voiceCoachEnabled)).labelsHidden()
            }

            if engine.settings.voiceCoachEnabled {
                voiceRow
                HelpRow(
                    title: "Speaking pace",
                    help: "How quickly the coach talks. The middle of the "
                        + "slider is the voice's normal speed; the coach "
                        + "starts a little slower than that, since you are "
                        + "moving while you listen."
                ) {
                    HStack(spacing: 8) {
                        Text("Slower").font(.caption).foregroundStyle(.secondary)
                        Slider(value: rateBinding, in: 30...70, step: 5)
                            .frame(width: 160)
                            .accessibilityLabel("Speaking pace")
                            .accessibilityValue("\(engine.settings.voiceCoachRate) percent")
                        Text("Faster").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(
                    "English voices only. Download more, or remove ones you "
                    + "tried, in System Settings › Accessibility › Spoken "
                    + "Content › System Voice › Manage Voices."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { voices = VoiceCatalog.installedVoices() }
    }

    private var voiceRow: some View {
        HStack(spacing: 4) {
            Text("Voice")
            HelpBadge(
                text: "The English system voice the coach speaks with. "
                    + "\"Best available\" picks the highest-quality one "
                    + "installed, preferring your own region."
            )

            Spacer(minLength: 10)

            Picker("", selection: voiceBinding) {
                Text("Best available").tag("")
                ForEach(voices) { voice in
                    Text(voice.label).tag(voice.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300)

            Button {
                speech.speak(
                    Self.sampleCue,
                    voiceIdentifier: engine.settings.voiceCoachVoiceIdentifier,
                    rate: engine.settings.voiceCoachRate
                )
            } label: {
                if speech.isSpeaking {
                    ProgressView().controlSize(.small).frame(width: 34)
                } else {
                    Text("Test").frame(width: 34)
                }
            }
            .disabled(speech.isSpeaking)
            .help("Say a sample cue with the chosen voice")
        }
    }

    private var rateBinding: Binding<Double> {
        Binding(
            get: { Double(engine.settings.voiceCoachRate) },
            set: { newValue in
                var settings = engine.settings
                settings.voiceCoachRate = Int(newValue.rounded())
                engine.updateSettings(settings)
            }
        )
    }

    /// The picker's empty tag stands for "no preference".
    private var voiceBinding: Binding<String> {
        Binding(
            get: { engine.settings.voiceCoachVoiceIdentifier ?? "" },
            set: { newValue in
                var settings = engine.settings
                settings.voiceCoachVoiceIdentifier = newValue.isEmpty ? nil : newValue
                engine.updateSettings(settings)
            }
        )
    }

    /// Writes straight through to the engine so changes persist immediately.
    private func binding<Value>(
        _ keyPath: WritableKeyPath<ReminderCore.Settings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { engine.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = engine.settings
                settings[keyPath: keyPath] = newValue
                engine.updateSettings(settings)
            }
        )
    }
}
