import Foundation
import Observation

/// User-facing choices, surfaced in the Settings scene, persisted to `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    /// Which engine a dictation transcribes with.
    ///
    /// Apple's `SpeechTranscriber` is the default and downloads nothing of ours — the system's
    /// per-locale speech assets are shared between apps, so on most devices there is nothing to
    /// install. The studio's own recognizer is the improvement the person opts into; it is the
    /// same model this app already transcribes files with, so choosing it costs no second model.
    enum DictationEngineChoice: String, CaseIterable, Identifiable, Sendable {
        case appleSpeech, studio
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .appleSpeech: "Apple Speech"
            case .studio: "Studio"
            }
        }
        var detail: String {
            switch self {
            case .appleSpeech: "On-device · nothing to download"
            case .studio: "On-device · more accurate · uses the speech model"
            }
        }
    }

    private enum Keys {
        static let wordTimestamps = "settings.wordTimestamps"
        static let autoFollowTranscript = "settings.autoFollowTranscript"
        static let showConfidence = "settings.showConfidence"
        static let locationCaptureEnabled = "settings.locationCaptureEnabled"
        static let dictationEngine = "settings.dictationEngine"
        static let dictationIdentifiesSpeakers = "settings.dictationIdentifiesSpeakers"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Capture word-level timestamps (costs decode time) — off by default.
    var wordTimestamps: Bool {
        didSet { defaults.set(wordTimestamps, forKey: Keys.wordTimestamps) }
    }
    /// Auto-follow the live transcript as it grows (yields to manual scroll).
    var autoFollowTranscript: Bool {
        didSet { defaults.set(autoFollowTranscript, forKey: Keys.autoFollowTranscript) }
    }
    /// Verbatim/confidence display: flag low-confidence words in a saved transcript — off by
    /// default so the reading view stays clean; a verifier turns it on per the detail view.
    var showConfidence: Bool {
        didSet { defaults.set(showConfidence, forKey: Keys.showConfidence) }
    }
    /// Tag a live recording with the coarse place it was made (reverse-geocoded to a short place
    /// name, captured once at recording start). **Off by default**, because turning it on puts the
    /// place on the wire: `location_name`, `latitude` and `longitude` are columns on
    /// `transcript_session`, so a tagged place travels to the account with the session it tags.
    var locationCaptureEnabled: Bool {
        didSet { defaults.set(locationCaptureEnabled, forKey: Keys.locationCaptureEnabled) }
    }

    /// Which engine a dictation uses. Apple's, until the person chooses otherwise.
    var dictationEngine: DictationEngineChoice {
        didSet { defaults.set(dictationEngine.rawValue, forKey: Keys.dictationEngine) }
    }
    /// Run the diarizer over a dictation and label each segment's speaker. **Off by default**: a
    /// dictation is usually one voice, and the pass is a second model over the same audio.
    var dictationIdentifiesSpeakers: Bool {
        didSet { defaults.set(dictationIdentifiesSpeakers, forKey: Keys.dictationIdentifiesSpeakers) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // didSet doesn't fire during init, so these loads never write back the default.
        self.wordTimestamps = defaults.object(forKey: Keys.wordTimestamps) as? Bool ?? false
        self.autoFollowTranscript = defaults.object(forKey: Keys.autoFollowTranscript) as? Bool ?? true
        self.showConfidence = defaults.object(forKey: Keys.showConfidence) as? Bool ?? false
        self.locationCaptureEnabled = defaults.object(forKey: Keys.locationCaptureEnabled) as? Bool ?? false
        self.dictationEngine = defaults.string(forKey: Keys.dictationEngine)
            .flatMap(DictationEngineChoice.init(rawValue:)) ?? .appleSpeech
        self.dictationIdentifiesSpeakers =
            defaults.object(forKey: Keys.dictationIdentifiesSpeakers) as? Bool ?? false
    }
}
