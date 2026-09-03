import AVFoundation
import Foundation

/// What the exercise coach needs from a voice: say this now, or be quiet.
/// A protocol so the coach can be driven without a synthesizer in tests and
/// snapshots.
@MainActor
protocol SpeechCoaching: AnyObject {
    /// Interrupts whatever is being said and says `text`. `onFinish` runs
    /// when the whole line has been said — not when it is cut off by `stop`
    /// or by the next `speak`, since whoever cut it off has moved on.
    func speak(_ text: String, onFinish: (() -> Void)?)
    func stop()
}

extension SpeechCoaching {
    func speak(_ text: String) { speak(text, onFinish: nil) }
}

/// The one speech synthesizer in the app, so cues are spoken once however
/// many displays show the takeover, and the Preferences Test button uses the
/// same voice path the coach does.
@MainActor
final class SpeechCoach: NSObject, ObservableObject, SpeechCoaching {
    /// True while an utterance is in progress; the Test button shows it.
    @Published private(set) var isSpeaking = false

    /// The stored preference. Resolved through `VoiceCatalog.resolve` on every
    /// utterance, so a voice the user later uninstalls degrades to the best
    /// available one rather than to silence.
    var voiceIdentifier: String?
    /// `Settings.voiceCoachRate`: percent of normal, 50 = the platform default.
    var rate: Int = 45

    private let synthesizer = AVSpeechSynthesizer()
    /// The completion for the utterance in flight, keyed by the utterance so
    /// a stale delegate callback for an interrupted line cannot fire it.
    private var pending: (utterance: AVSpeechUtterance, onFinish: () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, onFinish: (() -> Void)?) {
        speak(text, voiceIdentifier: voiceIdentifier, rate: rate, onFinish: onFinish)
    }

    /// Speaks with a specific voice and pace — the Test button, previewing
    /// the picker's current choice before it is saved.
    func speak(
        _ text: String, voiceIdentifier: String?, rate: Int, onFinish: (() -> Void)? = nil
    ) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = VoiceCatalog.resolve(voiceIdentifier)
        utterance.rate = Self.utteranceRate(percent: rate)
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        if let onFinish { pending = (utterance, onFinish) }
        synthesizer.speak(utterance)
    }

    func stop() {
        pending = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// 50 % is `AVSpeechUtteranceDefaultSpeechRate`; the ends of the slider
    /// are clamped well inside AVFoundation's range, where speech is still
    /// speech rather than a drawl or a blur.
    static func utteranceRate(percent: Int) -> Float {
        let clamped = min(max(percent, 20), 80)
        return Float(clamped) / 100
    }

    private func finished(_ utterance: AVSpeechUtterance, completely: Bool) {
        isSpeaking = false
        guard let pending, pending.utterance === utterance else { return }
        self.pending = nil
        if completely { pending.onFinish() }
    }
}

extension SpeechCoach: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.finished(utterance, completely: true) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.finished(utterance, completely: false) }
    }
}

/// The system voices worth offering, best first.
enum VoiceCatalog {
    struct Voice: Identifiable, Hashable {
        /// `AVSpeechSynthesisVoice.identifier`, the value stored in settings.
        let id: String
        let name: String
        /// BCP-47, e.g. "en-AU".
        let language: String
        let quality: AVSpeechSynthesisVoiceQuality

        /// "Kate — English (UK) · Enhanced". Some voices already carry the
        /// quality in their name ("Kate (Enhanced)"); it is shown once.
        var label: String {
            let languageName = Locale.current.localizedString(forIdentifier: language) ?? language
            let bareName = name
                .replacingOccurrences(of: " (Enhanced)", with: "")
                .replacingOccurrences(of: " (Premium)", with: "")
            return "\(bareName) — \(languageName) · \(VoiceCatalog.qualityName(quality))"
        }
    }

    /// Installed English voices — the cues are English, so a voice in
    /// another language would mangle them — ordered so the first is the one
    /// to use by default: premium before enhanced before standard, since a
    /// good voice in a neighbouring accent beats a tinny one in your own;
    /// then the user's own region; then by name. Personal voices are left
    /// out (they need their own authorisation) and so are the novelty and
    /// Eloquence voices, which nobody wants coaching them — unless they are
    /// all there is.
    static func installedVoices() -> [Voice] {
        let english = AVSpeechSynthesisVoice.speechVoices().compactMap { voice -> Voice? in
            if #available(macOS 14, *), voice.voiceTraits.contains(.isPersonalVoice) {
                return nil
            }
            guard isEnglish(voice.language) else { return nil }
            return Voice(
                id: voice.identifier, name: voice.name,
                language: voice.language, quality: voice.quality
            )
        }
        let real = english.filter { !isNovelty($0) }
        let candidates = real.isEmpty ? english : real
        return candidates.sorted { lhs, rhs in
            if lhs.quality.rawValue != rhs.quality.rawValue {
                return lhs.quality.rawValue > rhs.quality.rawValue
            }
            let lhsHome = isHomeRegion(lhs), rhsHome = isHomeRegion(rhs)
            if lhsHome != rhsHome { return lhsHome }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func defaultVoice() -> Voice? { installedVoices().first }

    /// The voice to speak with: the stored one if it is still installed,
    /// otherwise the best available.
    static func resolve(_ identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return defaultVoice().flatMap { AVSpeechSynthesisVoice(identifier: $0.id) }
    }

    static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    private static func isNovelty(_ voice: Voice) -> Bool {
        voice.id.hasPrefix("com.apple.speech.synthesis.voice.")
            || voice.id.hasPrefix("com.apple.eloquence.")
    }

    private static func isEnglish(_ language: String) -> Bool {
        Locale(identifier: language).language.languageCode?.identifier == "en"
    }

    private static func isHomeRegion(_ voice: Voice) -> Bool {
        guard let region = Locale.current.region?.identifier else { return false }
        return Locale(identifier: voice.language).region?.identifier == region
    }
}
