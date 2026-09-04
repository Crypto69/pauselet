import SwiftUI
import ReminderCore
import ReminderUI

/// The Settings section for the spoken exercise coach: whether it talks,
/// which system voice it uses, and a way to hear it before an exercise does.
///
/// The iOS twin of `Sources/ReminderApp/VoiceCoachSettings.swift`, writing to
/// the same three shared `Settings` fields, so a device's preference means the
/// same thing whichever app wrote it.
///
/// Voices are read once per appearance: enumerating them is not free, and
/// the list only changes when the user installs one in Settings.
struct VoiceCoachSection: View {
    @EnvironmentObject private var engine: ReminderEngine
    @EnvironmentObject private var speech: SpeechCoach

    @State private var voices: [VoiceCatalog.Voice] = []

    /// What the Test button says — the coach's first real cue.
    static let sampleCue = "Set 1, rep 1. Hold for 5 seconds."

    var body: some View {
        Section {
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
                Picker("Voice", selection: voiceBinding) {
                    Text("Best available").tag("")
                    ForEach(voices) { voice in
                        Text(voice.label).tag(voice.id)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Speaking pace")
                    HStack(spacing: 8) {
                        Text("Slower").font(.caption).foregroundStyle(.secondary)
                        Slider(value: rateBinding, in: 30...70, step: 5)
                            .accessibilityLabel("Speaking pace")
                            .accessibilityValue("\(engine.settings.voiceCoachRate) percent")
                        Text("Faster").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Button {
                    speech.speak(
                        Self.sampleCue,
                        voiceIdentifier: engine.settings.voiceCoachVoiceIdentifier,
                        rate: engine.settings.voiceCoachRate
                    )
                } label: {
                    if speech.isSpeaking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Speaking\u{2026}")
                        }
                    } else {
                        Label("Test Voice", systemImage: "speaker.wave.2")
                    }
                }
                .disabled(speech.isSpeaking)
                .accessibilityIdentifier("voiceCoachTest")
            }
        } header: {
            Text("Voice Coach")
        } footer: {
            if engine.settings.voiceCoachEnabled {
                Text(
                    "English voices only. Download more in Settings › "
                    + "Accessibility › Spoken Content › Voices. Cues duck other "
                    + "audio rather than stopping it, and play even on Silent. "
                    + "A coached exercise pauses if you leave Pauselet, so a "
                    + "hold never finishes in your pocket."
                )
            }
        }
        .onAppear { voices = VoiceCatalog.installedVoices() }
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
